-- Search categories for Go projects full of gRPC contracts and generated
-- code. Space f / Space F, Space /, Space * and Space sS show one category
-- of the project at a time; Alt-c inside any of them lists the categories
-- with file counts, Enter switches and keeps the typed query, Esc returns to
-- the picker as it was. Every picker opens on `all`.
--
--   all               every file, as before
--   rpc               contracts and the code generated from them: .proto,
--                     *.pb.go (*_grpc.pb.go too), *.pb.*.go (gateway,
--                     validate), connect, twirp, swagger, buf configs
--   tests             *_test.go, mocks and fakes, testdata/, test/, tests/
--   internal          internal/ at any depth, without rpc and tests
--   internal/<dir>/   one folder of it; every nested folder is listed
--
-- Files and grep hand the category to fd / rg as one more ignore file. Its
-- rules rank below .gitignore, so ignored files stay hidden (Space F shows
-- them, still within the category); a folder becomes the search path.
-- Symbols come from gopls, which returns at most 100 per query, and
-- generated code can take all of them. For internal the query is narrowed
-- on the server first: gopls ANDs space-separated fields and `'x` is an
-- exact substring of the package path, so `'internal/order Save` finds Save
-- only there; tests ask `'test` and `'mock` besides. Every symbol is then
-- checked by the path of its file. Alt-k in Space sS chooses the kind of
-- declaration (struct, interface, func, method, …); see "Declarations by
-- kind" below.

local M = {}

M.rpc_files = {
    "*.proto",
    "*.pb.go",
    "*.pb.*.go",
    "*.connect.go",
    "*.twirp.go",
    "*.swagger.json",
    "*.swagger.yaml",
    "buf.yaml",
    "buf.gen.yaml",
    "buf.work.yaml",
    "buf.lock",
}

M.test_files = { "*_test.go", "*mock*.go" }

M.test_dirs = { "testdata", "test", "tests", "mock", "mocks", "fake", "fakes" }

-- The key inside the pickers.
M.key = "alt-c"

-- Name globs (no slash) as Lua patterns on the last path component.
local function name_pattern(glob)
    local escaped = glob:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
    return "^" .. escaped:gsub("%*", ".*") .. "$"
end

local rpc_patterns = vim.tbl_map(name_pattern, M.rpc_files)
local test_patterns = vim.tbl_map(name_pattern, M.test_files)

local function any_name(name, patterns)
    for _, pattern in ipairs(patterns) do
        if name:match(pattern) then
            return true
        end
    end
    return false
end

-- "rpc", "tests", "internal" or nil (only in `all`) for a path relative to
-- the project root. The same rules as the ignore files below.
function M.classify(rel)
    local name = rel:match("[^/]+$") or rel
    if any_name(name, rpc_patterns) then
        return "rpc"
    end
    local dirs = "/" .. (rel:match("^(.*)/") or "") .. "/"
    if any_name(name, test_patterns) then
        return "tests"
    end
    for _, dir in ipairs(M.test_dirs) do
        if dirs:find("/" .. dir .. "/", 1, true) then
            return "tests"
        end
    end
    if dirs:find("/internal/", 1, true) then
        return "internal"
    end
    return nil
end

-- A folder of internal is spelled with a trailing slash: "internal/order/".
local function is_dir(category)
    return category:sub(-1) == "/"
end

local function rules_of(category)
    return is_dir(category) and "internal" or category
end

function M.matches(category, rel)
    if category == "all" then
        return true
    end
    if not rel then
        return false
    end
    local class = M.classify(rel)
    if is_dir(category) then
        return class == "internal" and rel:sub(1, #category) == category
    end
    return class == category
end

-- .gitignore rules of a category: everything is ignored, folders are walked,
-- the category is let back in, the other categories are ignored again (the
-- last matching line wins).
function M.ignore_lines(rules)
    local lines = { "*", "!*/" }
    local function add(prefix, names, dirs)
        for _, glob in ipairs(names) do
            table.insert(lines, prefix .. glob)
        end
        for _, dir in ipairs(dirs or {}) do
            table.insert(lines, prefix .. "**/" .. dir .. "/**")
        end
    end
    if rules == "rpc" then
        add("!", M.rpc_files)
    elseif rules == "tests" then
        add("!", M.test_files, M.test_dirs)
        add("", M.rpc_files)
    else
        add("!", {}, { "internal" })
        add("", M.test_files, M.test_dirs)
        add("", M.rpc_files)
    end
    return lines
end

-- The ignore file of a category under stdpath("cache"), rewritten when the
-- rules change.
function M.ignore_file(rules)
    local dir = vim.fn.stdpath("cache") .. "/categories"
    local file = dir .. "/" .. rules .. ".ignore"
    local content = table.concat(M.ignore_lines(rules), "\n") .. "\n"
    local current = io.open(file, "r")
    local old = current and current:read("*a")
    if current then
        current:close()
    end
    if old ~= content then
        vim.fn.mkdir(dir, "p")
        local out = assert(io.open(file, "w"))
        out:write(content)
        out:close()
    end
    return file
end

-- Queries for gopls, answers merged in this order. A folder of internal (or
-- internal itself) goes first as an exact field on the package path. Tests
-- have no such path, so `'test` (TestX, *_test packages, test/ folders) and
-- `'mock` (MockX, mocks/) are asked besides the query itself.
function M.gopls_queries(category, query)
    query = vim.trim(query or "")
    local function with(field)
        return vim.trim("'" .. field .. " " .. query)
    end
    local queries
    if category == "tests" then
        queries = { query, with("test"), with("mock") }
    elseif category == "internal" then
        queries = { with("internal") }
    elseif is_dir(category) then
        local path = "/" .. category
        local scope = path:match("/(internal/.*)/$") or path:match("/(internal)/$")
        queries = { scope and not scope:find("%s") and with(scope) or query }
    else
        queries = { query }
    end
    return vim.tbl_filter(function(q)
        return q ~= ""
    end, queries)
end

-- Categories of the project with file counts: all, rpc, tests, internal
-- (empty ones left out), then every folder of internal. With a single
-- internal/ its own folder is the same as `internal` and is not repeated.
function M.list(root, no_ignore)
    local cmd = { "rg", "--files", "--hidden", "--glob", "!.git" }
    if no_ignore then
        table.insert(cmd, "--no-ignore")
    end
    local result = vim.system(cmd, { cwd = root, text = true }):wait(10000)

    local counts = { all = 0, rpc = 0, tests = 0, internal = 0 }
    local dirs, roots = {}, {}
    for rel in (result.stdout or ""):gmatch("[^\n]+") do
        counts.all = counts.all + 1
        local class = M.classify(rel)
        if class then
            counts[class] = counts[class] + 1
        end
        if class == "internal" then
            local start = ("/" .. rel):find("/internal/", 1, true)
            local last = start + #"internal"
            roots[rel:sub(1, last)] = true
            while last do
                local dir = rel:sub(1, last)
                dirs[dir] = (dirs[dir] or 0) + 1
                last = rel:find("/", last + 1, true)
            end
        end
    end

    local list = { { name = "all", count = counts.all } }
    for _, name in ipairs({ "rpc", "tests", "internal" }) do
        if counts[name] > 0 then
            table.insert(list, { name = name, count = counts[name] })
        end
    end
    local single_root = vim.tbl_count(roots) == 1
    local names = vim.tbl_keys(dirs)
    table.sort(names)
    for _, name in ipairs(names) do
        if not (single_root and roots[name]) then
            table.insert(list, { name = name, count = dirs[name] })
        end
    end
    return list
end


-- ============================================================
-- Pickers
-- ============================================================

-- A picker is reopened from its spec: kind (files, live_grep, grep,
-- symbols), root, category, query and what the kind needs besides.
local open = {}

local function notify(message, level)
    vim.notify(message, level or vim.log.levels.INFO, { title = "categories" })
end

local function title(what, category)
    return string.format(" %s · %s ", what, category)
end

-- The spec with what the closed picker knew: the typed query, the toggles
-- of fzf-lua grep (Alt-i, Alt-h, Ctrl-g between live and fuzzy grep). The
-- file tree keeps its toggles in the spec itself.
local function updated(spec, opts)
    local fzf = require("fzf-lua")
    local next_spec = vim.deepcopy(spec)
    next_spec.query = opts.last_query or fzf.get_last_query() or ""
    if spec.kind == "grep" or spec.kind == "live_grep" then
        next_spec.hidden = opts.hidden
        next_spec.no_ignore = opts.no_ignore
        if opts.is_live then
            next_spec.kind = "live_grep"
        else
            next_spec.kind = "grep"
            next_spec.search = opts.search or spec.search
            next_spec.no_esc = opts.no_esc
        end
    end
    return next_spec
end

-- A small list of { name, count } with the current one marked: Enter
-- reopens the picker of `spec` with `field` set to the chosen name, Esc as
-- it was.
local function pick(spec, field, list, what)
    local fzf = require("fzf-lua")
    local utils = fzf.utils
    local width = 0
    for _, item in ipairs(list) do
        width = math.max(width, vim.fn.strdisplaywidth(item.name))
    end
    local lines = {}
    for _, item in ipairs(list) do
        local current = item.name == spec[field]
        local name = current and utils.ansi_codes.yellow(item.name) or item.name
        table.insert(lines, string.format("%s %s%s  %s",
            current and "●" or " ",
            name,
            string.rep(" ", width - vim.fn.strdisplaywidth(item.name)),
            utils.ansi_codes.grey(tostring(item.count))))
    end

    local function back()
        open[spec.kind](spec)
    end

    fzf.fzf_exec(lines, {
        prompt = what:gsub("^%l", string.upper) .. "> ",
        -- Not resumable: FzfLua resume stays on the picker. This also keeps
        -- the default "hide" profile from turning Esc into hiding.
        no_resume = true,
        fzf_opts = { ["--no-multi"] = true, ["--tiebreak"] = "index" },
        -- A short list without a preview: not full screen.
        winopts = { title = " " .. what .. " ", fullscreen = false, width = 0.5, height = 0.6 },
        actions = {
            ["enter"] = function(selected)
                local line = selected[1] and utils.strip_ansi_coloring(selected[1]) or ""
                local name = line:match("^%S*%s+(%S+)")
                if name then
                    spec[field] = name
                end
                back()
            end,
            ["esc"] = back,
            ["ctrl-c"] = back,
        },
    })
end

-- List the categories; Enter reopens the picker in the chosen one, Esc in
-- the same one.
function M.choose(spec)
    local ok, list = pcall(M.list, spec.root, spec.no_ignore)
    if not ok then
        notify("rg is needed to list categories: " .. tostring(list), vim.log.levels.WARN)
        open[spec.kind](spec)
        return
    end
    pick(spec, "category", list, "category")
end

local function switch_action(spec)
    return {
        fn = function(_, opts)
            M.choose(updated(spec, opts))
        end,
        header = "category",
    }
end

-- The fd / rg flag (with a leading space, empty for `all`) and the search
-- paths of a category.
function M.narrowing(category)
    if category == "all" then
        return "", nil
    end
    local flag = " --ignore-file " .. vim.fn.shellescape(M.ignore_file(rules_of(category)))
    return flag, is_dir(category) and { category:sub(1, -2) } or nil
end

-- The file list of a category: fd (rg without it) with the flags of the
-- picker, run in the root.
function M.files_command(spec)
    local ignore = spec.category ~= "all" and M.ignore_file(rules_of(spec.category)) or nil
    local cmd
    if vim.fn.executable("fd") == 1 then
        cmd = { "fd", "--color=never", "--type", "f", "--type", "l", "--exclude", ".git", "--exclude", ".jj" }
    else
        cmd = { "rg", "--files", "--color=never", "--glob", "!.git", "--glob", "!.jj" }
    end
    if spec.hidden then
        table.insert(cmd, "--hidden")
    end
    if spec.no_ignore then
        table.insert(cmd, "--no-ignore")
    end
    if ignore then
        vim.list_extend(cmd, { "--ignore-file", ignore })
    end
    if cmd[1] == "fd" then
        table.insert(cmd, ".")
    end
    if is_dir(spec.category) then
        table.insert(cmd, spec.category:sub(1, -2))
    end
    return cmd
end

-- Files as a tree (lua/file_tree.lua). Alt-i / Alt-h show ignored /
-- hidden files or not, as in fzf-lua's files.
function open.files(spec)
    local function toggle(field)
        return {
            fn = function(_, opts)
                local next_spec = updated(spec, opts)
                next_spec[field] = not next_spec[field]
                open.files(next_spec)
            end,
            header = false,
        }
    end
    -- Pinned files, then recent ones (without the current file and the
    -- pinned ones) head the tree.
    local pins = require("pins")
    local current = vim.api.nvim_buf_get_name(0)
    local pinned = pins.list(spec.root)
    local recent = vim.tbl_filter(function(rel)
        return not vim.tbl_contains(pinned, rel)
    end, pins.recent(spec.root, 8, current))
    require("file_tree").open({
        cwd = spec.root,
        cmd = M.files_command(spec),
        query = spec.query,
        current = current,
        no_ignore = spec.no_ignore,
        groups = {
            { name = "pinned", mark = "◆", paths = pinned, numbered = true },
            { name = "recent", mark = "★", paths = recent },
        },
        title = title("files", spec.category) .. (spec.no_ignore and "· with ignored " or ""),
        actions = {
            [M.key] = switch_action(spec),
            ["alt-i"] = toggle("no_ignore"),
            ["alt-h"] = toggle("hidden"),
        },
    })
end

-- The flag goes before the trailing `-e` of the grep options.
local function grep_rg_opts(flag)
    local rg_opts = require("fzf-lua").defaults.grep.rg_opts
    if flag == "" then
        return rg_opts
    end
    return (rg_opts:gsub("%-e$", flag:sub(2) .. " -e"))
end

function open.live_grep(spec)
    local fzf = require("fzf-lua")
    local flag, paths = M.narrowing(spec.category)
    fzf.live_grep({
        cwd = spec.root,
        resume = false,
        hidden = spec.hidden,
        no_ignore = spec.no_ignore,
        -- the typed text is already a regex
        search = spec.query,
        no_esc = true,
        rg_opts = grep_rg_opts(flag),
        search_paths = paths,
        actions = { [M.key] = switch_action(spec) },
        winopts = { title = title("grep", spec.category) },
    })
end

function open.grep(spec)
    local fzf = require("fzf-lua")
    local flag, paths = M.narrowing(spec.category)
    fzf.grep({
        cwd = spec.root,
        resume = false,
        hidden = spec.hidden,
        no_ignore = spec.no_ignore,
        search = spec.search,
        no_esc = spec.no_esc,
        query = spec.query,
        rg_opts = grep_rg_opts(flag),
        search_paths = paths,
        actions = { [M.key] = switch_action(spec) },
        winopts = { title = title("grep", spec.category) },
    })
end


-- ============================================================
-- Workspace symbols
-- ============================================================

local symbol_method = "workspace/symbol"

-- gopls of the current buffer, any running server otherwise (Space sS from
-- a README still searches the Go code).
local function symbol_clients()
    local clients = vim.lsp.get_clients({ bufnr = 0, method = symbol_method })
    if #clients == 0 then
        clients = vim.lsp.get_clients({ method = symbol_method })
    end
    return clients
end

-- gopls qualifies names when the query reaches into the package path
-- ("internal/order.Service.Save"); the file path is shown anyway.
function M.symbol_name(name)
    return (name:gsub("^.*/", ""))
end

-- Painters by highlight group, made once per answer; text stays plain when
-- the group does not exist.
local function painters()
    local utils = require("fzf-lua").utils
    return setmetatable({}, {
        __index = function(cache, group)
            local _, _, paint = utils.ansi_from_hl(group, "")
            cache[group] = paint or function(text)
                return text
            end
            return cache[group]
        end,
    })
end

-- The query letters in the name, in order, case-insensitive.
local function highlight(name, query, paint)
    local wanted = query:lower():gsub("[%s']", "")
    if wanted == "" then
        return name
    end
    local out, at = {}, 1
    for index = 1, #name do
        local char = name:sub(index, index)
        if at <= #wanted and char:lower() == wanted:sub(at, at) then
            table.insert(out, paint(char))
            at = at + 1
        else
            table.insert(out, char)
        end
    end
    return table.concat(out)
end

-- One picker line in the layout of fzf-lua's workspace symbols:
-- "<icon> Kind name   ␂path:line:col:". fzf-lua opens and previews
-- the part after the non-breaking space.
local function symbol_entry(symbol, root, query, icons, paint)
    local kind = vim.lsp.protocol.SymbolKind[symbol.kind] or "Unknown"
    local name = M.symbol_name(symbol.name)
    local label = icons[kind] and (icons[kind] .. " " .. kind) or kind

    local plain = label .. " " .. name
    local text = paint["@" .. kind:lower()](label) .. " " .. highlight(name, query, paint.FzfLuaLiveSym)
    local pad = string.rep(" ", math.max(1, 48 - vim.fn.strdisplaywidth(plain)))

    local path = vim.uri_to_fname(symbol.location.uri)
    local shown = vim.fs.relpath(root, path) or path
    local start = symbol.location.range.start
    return text .. pad .. require("fzf-lua").utils.nbsp .. string.format("%s:%s:%s:",
        shown,
        paint.FzfLuaPathLineNr(tostring(start.line + 1)),
        paint.FzfLuaPathColNr(tostring(start.character + 1)))
end

-- Symbols of the category for what was typed: `done(lines)` once every
-- client answered every query. Returns a function that cancels the
-- requests still running.
function M.fetch_symbols(clients, root, category, typed, done)
    -- gopls reports real paths; the root may be a symlink (/tmp on macOS).
    root = vim.uv.fs_realpath(root) or root
    local queries = M.gopls_queries(category, typed)
    local answers, requests = {}, {}
    local pending, finished = 0, false

    local function finish()
        if pending > 0 or finished then
            return
        end
        finished = true
        local icons = require("fzf-lua.config").globals.lsp.symbols.symbol_icons or {}
        local paint = painters()
        local lines, seen = {}, {}
        for index = 1, #queries * #clients do
            for _, symbol in ipairs(answers[index] or {}) do
                local location = symbol.location
                if location and location.range then
                    local start = location.range.start
                    local key = location.uri .. ":" .. start.line .. ":" .. start.character
                    local rel = vim.fs.relpath(root, vim.uri_to_fname(location.uri))
                    if not seen[key] and M.matches(category, rel) then
                        seen[key] = true
                        table.insert(lines, symbol_entry(symbol, root, typed, icons, paint))
                    end
                end
            end
        end
        done(lines)
    end

    for q, query in ipairs(queries) do
        for c, client in ipairs(clients) do
            local index = (q - 1) * #clients + c
            pending = pending + 1
            local ok, id = client:request(symbol_method, { query = query }, function(err, result)
                requests[index] = nil
                answers[index] = not err and result or nil
                pending = pending - 1
                finish()
            end)
            if ok then
                requests[index] = { client = client, id = id }
            else
                pending = pending - 1
            end
        end
    end
    finish()

    return function()
        for _, request in pairs(requests) do
            request.client:cancel_request(request.id)
        end
        requests = {}
    end
end

-- ============================================================
-- Declarations by kind
-- ============================================================

-- Space sS explores the project by kind of declaration too: Alt-k lists
-- struct, interface, type, func, method, const and var with their counts
-- in the category. A kind is a fuzzy list of every such top-level
-- declaration, read by the AST helper (lua/go_decls.lua) rather than
-- gopls: no limit of 100, and an empty query lists them all. `all` is the
-- live gopls search.
M.kind_key = "alt-k"

-- Icon (from the symbol icons) and highlight of each kind.
local kind_look = {
    struct = { "Struct", "@type" },
    interface = { "Interface", "@type" },
    type = { "Class", "@type" },
    func = { "Function", "@function" },
    method = { "Method", "@function.method" },
    const = { "Constant", "@constant" },
    var = { "Variable", "@variable" },
}

-- The Go files gopls sees in a category: .gitignore does not hide
-- generated code from the compiler, vendor/, node_modules/ and testdata/
-- stay out (the directoryFilters of gopls).
function M.go_files_command(spec)
    local cmd
    if vim.fn.executable("fd") == 1 then
        cmd = { "fd", "--color=never", "--type", "f", "--extension", "go", "--no-ignore" }
        for _, dir in ipairs({ ".git", "vendor", "node_modules", "testdata" }) do
            vim.list_extend(cmd, { "--exclude", dir })
        end
    else
        cmd = { "rg", "--files", "--color=never", "--no-ignore", "--glob", "*.go" }
        for _, dir in ipairs({ ".git", "vendor", "node_modules", "testdata" }) do
            vim.list_extend(cmd, { "--glob", "!**/" .. dir .. "/**" })
        end
    end
    if spec.category ~= "all" then
        vim.list_extend(cmd, { "--ignore-file", M.ignore_file(rules_of(spec.category)) })
    end
    if cmd[1] == "fd" then
        table.insert(cmd, ".")
    end
    if is_dir(spec.category) then
        table.insert(cmd, spec.category:sub(1, -2))
    end
    return cmd
end

-- Declarations of the category: done(list) or done(nil, err).
function M.declarations(spec, done)
    vim.system(M.go_files_command(spec), { cwd = spec.root, text = true }, vim.schedule_wrap(function(result)
        local paths = vim.split(result.stdout or "", "\n", { trimempty = true })
        table.sort(paths)
        require("go_decls").collect(spec.root, paths, done)
    end))
end

local function declarations_failed(err)
    notify("Declarations need the AST helper (./install.sh builds it): " .. tostring(err), vim.log.levels.WARN)
end

-- List the kinds with their counts in the category.
function M.choose_kind(spec)
    M.declarations(spec, function(list, err)
        if not list then
            declarations_failed(err)
            open[spec.kind](spec)
            return
        end
        local counts = require("go_decls").counts(list)
        local kinds = { { name = "all", count = #list } }
        for _, kind in ipairs(require("go_decls").kinds) do
            if counts[kind] then
                table.insert(kinds, { name = kind, count = counts[kind] })
            end
        end
        pick(spec, "go_kind", kinds, "kind")
    end)
end

local function kind_action(spec)
    return {
        fn = function(_, opts)
            local next_spec = updated(spec, opts)
            -- From the fuzzy mode the typed filter becomes the query.
            if spec.fuzzy then
                next_spec.fuzzy = false
                next_spec.query = next_spec.query ~= "" and next_spec.query or spec.query
            end
            M.choose_kind(next_spec)
        end,
        header = "kind",
    }
end

-- File actions without the fd / rg toggles (Alt-i, Alt-h, Alt-f), which
-- reopen a files picker; Alt-c and Alt-k.
local function symbol_actions(spec)
    local actions = { [M.key] = switch_action(spec), [M.kind_key] = kind_action(spec) }
    for key, action in pairs(require("fzf-lua").defaults.actions.files) do
        if not (type(action) == "table" and action.reuse) then
            actions[key] = action
        end
    end
    return actions
end

-- "<icon> kind name   ␂path:line:col:", the layout of the symbol lines.
local function declaration_entry(declaration, icons, paint)
    local look = kind_look[declaration.kind] or { "Unknown", "Normal" }
    local icon = icons[look[1]]
    local label = (icon and (icon .. " ") or "") .. declaration.kind
    local name = require("go_decls").label(declaration)
    local plain = label .. " " .. name
    return paint[look[2]](label) .. " " .. name
        .. string.rep(" ", math.max(1, 48 - vim.fn.strdisplaywidth(plain)))
        .. require("fzf-lua").utils.nbsp
        .. string.format("%s:%s:%s:", declaration.path,
            paint.FzfLuaPathLineNr(tostring(declaration.line)),
            paint.FzfLuaPathColNr(tostring(declaration.col)))
end

-- Every declaration of one kind in the category; fzf filters them.
function open.declarations(spec)
    local fzf = require("fzf-lua")
    fzf.fzf_exec(function(cb)
        M.declarations(spec, function(list, err)
            if not list then
                declarations_failed(err)
                cb(nil)
                return
            end
            local icons = require("fzf-lua.config").globals.lsp.symbols.symbol_icons or {}
            local paint = painters()
            for _, declaration in ipairs(list) do
                if declaration.kind == spec.go_kind then
                    cb(declaration_entry(declaration, icons, paint))
                end
            end
            cb(nil)
        end)
    end, {
        cwd = spec.root,
        query = spec.query,
        previewer = "builtin",
        file_icons = false,
        git_icons = false,
        fzf_opts = { ["--multi"] = true },
        actions = symbol_actions(spec),
        winopts = { title = title("symbols", spec.category) .. "· " .. spec.go_kind .. " " },
    })
end

-- Live: every keystroke asks gopls again. Fuzzy (Ctrl-g): the answer to the
-- last query, filtered by fzf; Ctrl-g goes back. A kind other than `all`
-- lists declarations instead.
function open.symbols(spec)
    if spec.go_kind and spec.go_kind ~= "all" then
        return open.declarations(spec)
    end
    local fzf = require("fzf-lua")
    local clients = symbol_clients()
    if #clients == 0 then
        notify("No LSP client with workspace symbols")
        return
    end

    local actions = symbol_actions(spec)
    local opts = {
        cwd = spec.root,
        previewer = "builtin",
        file_icons = false,
        git_icons = false,
        fzf_opts = { ["--multi"] = true },
        actions = actions,
    }

    if spec.fuzzy then
        opts.query = spec.filter
        opts.winopts = { title = title("symbols", spec.category) .. "· " .. spec.query .. " " }
        opts.actions["ctrl-g"] = {
            fn = function()
                open.symbols(vim.tbl_extend("force", spec, { fuzzy = false }))
            end,
            header = "live query",
        }
        -- Alt-c keeps the fuzzy mode: the filter is the typed query, the
        -- gopls query stays.
        opts.actions[M.key] = {
            fn = function(_, o)
                local next_spec = vim.deepcopy(spec)
                next_spec.filter = o.last_query or fzf.get_last_query() or ""
                M.choose(next_spec)
            end,
            header = "category",
        }
        fzf.fzf_exec(function(cb)
            M.fetch_symbols(clients, spec.root, spec.category, spec.query, function(lines)
                for _, line in ipairs(lines) do
                    cb(line)
                end
                cb(nil)
            end)
        end, opts)
        return
    end

    opts.query = spec.query
    opts.winopts = { title = title("symbols", spec.category) }
    -- An empty query of internal or tests lists their symbols.
    opts.exec_empty_query = #M.gopls_queries(spec.category, "") > 0
    opts.actions["ctrl-g"] = {
        fn = function(_, o)
            local next_spec = updated(spec, o)
            next_spec.fuzzy = true
            next_spec.filter = ""
            open.symbols(next_spec)
        end,
        header = "fuzzy search",
    }
    local cancel = function() end
    fzf.fzf_live(function(args)
        local typed = type(args) == "table" and args[1] or args or ""
        cancel()
        return function(cb)
            cancel = M.fetch_symbols(clients, spec.root, spec.category, typed, function(lines)
                for _, line in ipairs(lines) do
                    cb(line)
                end
                cb(nil)
            end)
        end
    end, opts)
end


-- ============================================================
-- Entry points
-- ============================================================

-- opts: no_ignore (Space F).
function M.files(root, opts)
    open.files({
        kind = "files",
        root = root,
        category = "all",
        query = "",
        hidden = true,
        no_ignore = opts and opts.no_ignore or false,
    })
end

function M.live_grep(root)
    open.live_grep({ kind = "live_grep", root = root, category = "all", query = "" })
end

-- A fixed search with fuzzy filtering of the results: the word under the
-- cursor (whole word) or the selection.
function M.grep(root, search, no_esc)
    open.grep({
        kind = "grep",
        root = root,
        category = "all",
        query = "",
        search = search,
        no_esc = no_esc,
    })
end

function M.symbols(root)
    open.symbols({ kind = "symbols", root = root, category = "all", go_kind = "all", query = "" })
end

M._open = open

return M
