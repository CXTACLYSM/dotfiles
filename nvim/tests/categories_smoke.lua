-- Search categories on the fixture verify.sh writes (a git repository with
-- contracts, generated code, tests, mocks and internal folders): the rules,
-- the same files from the Lua rules and from fd / rg with the ignore file,
-- Alt-c in files / grep / symbols keeping the query (fzf-lua and the file
-- tree stubbed), workspace symbols from gopls narrowed and filtered by
-- category, and declarations by kind (Alt-k) from the AST helper.
local categories = require("categories")
local fzf = require("fzf-lua")
local root = vim.fn.getcwd()

local function sorted(list)
    table.sort(list)
    return list
end

local function lines_of(command)
    local result = vim.system({ "sh", "-c", command }, { cwd = root, text = true }):wait()
    assert(result.code == 0 or result.code == 1, command .. ": " .. (result.stderr or ""))
    return sorted(vim.split(result.stdout, "\n", { trimempty = true }))
end

local function same(got, want, what)
    assert(vim.deep_equal(got, want), what .. ": " .. vim.inspect(got) .. " ~= " .. vim.inspect(want))
end

-- Rules.
for rel, class in pairs({
    ["api/order/v1/order.proto"] = "rpc",
    ["pkg/api/order/v1/order.pb.go"] = "rpc",
    ["pkg/api/order/v1/order_grpc.pb.go"] = "rpc",
    ["pkg/api/order/v1/order.pb.validate.go"] = "rpc",
    ["internal/pb/x.pb.go"] = "rpc",
    ["buf.gen.yaml"] = "rpc",
    ["internal/order/service_test.go"] = "tests",
    ["internal/order/mocks/store.go"] = "tests",
    ["internal/order/store_mock.go"] = "tests",
    ["internal/order/testdata/golden.json"] = "tests",
    ["tests/suite.go"] = "tests",
    ["internal/order/service.go"] = "internal",
    ["svc/internal/pay/pay.go"] = "internal",
    ["internal/x.go"] = "internal",
    ["cmd/app/main.go"] = false,
    ["pkg/internalapi/x.go"] = false,
}) do
    assert((categories.classify(rel) or false) == class, rel .. " -> " .. tostring(categories.classify(rel)))
end
assert(categories.matches("internal/order/", "internal/order/repo/pg.go"), "nested folder")
assert(not categories.matches("internal/order/", "internal/orders/batch.go"), "folder prefix stops at /")
assert(not categories.matches("internal/order/", "internal/order/service_test.go"), "tests are not internal")
assert(not categories.matches("rpc", nil) and categories.matches("all", nil), "outside the root")
same(categories.gopls_queries("all", " Save "), { "Save" }, "all")
same(categories.gopls_queries("all", ""), {}, "nothing to ask")
same(categories.gopls_queries("internal/order/", "Save"), { "'internal/order Save" }, "folder")
same(categories.gopls_queries("svc/internal/pay/", ""), { "'internal/pay" }, "monorepo folder")
same(categories.gopls_queries("internal", "Save"), { "'internal Save" }, "internal")
same(categories.gopls_queries("tests", "Save"), { "Save", "'test Save", "'mock Save" }, "tests")
assert(categories.symbol_name("internal/order.Service.Save") == "order.Service.Save", "package path dropped")
print("CATEGORY_RULES_OK")

-- Listing.
local list = {}
for _, item in ipairs(categories.list(root)) do
    list[item.name] = item.count
end
same(list, {
    all = 13,
    rpc = 4,
    tests = 3,
    internal = 3,
    ["internal/order/"] = 2,
    ["internal/order/repo/"] = 1,
    ["internal/orders/"] = 1,
}, "categories")
assert(categories.list(root, true)[1].count == 14, "Space F counts ignored files")
print("CATEGORY_LIST_OK")

-- fd and rg with the ignore file list what the Lua rules say, ignored files
-- stay out unless Space F.
local every = lines_of("rg --files --hidden --glob '!.git' --no-ignore")
for _, category in ipairs({ "rpc", "tests", "internal", "internal/order/" }) do
    for _, no_ignore in ipairs({ false, true }) do
        local flag, paths = categories.narrowing(category)
        local where = paths and (" " .. table.concat(paths, " ")) or ""
        local toggle = no_ignore and " --no-ignore" or ""
        local listed = vim.system(categories.files_command({ category = category, hidden = true, no_ignore = no_ignore }),
            { cwd = root, text = true }):wait()
        local fd = sorted(vim.split(listed.stdout, "\n", { trimempty = true }))
        local rg = lines_of("rg --files --hidden --glob '!.git'" .. toggle .. flag .. where)
        local want = vim.tbl_filter(function(rel)
            return categories.matches(category, rel) and (no_ignore or not rel:match("%.env$"))
        end, every)
        same(fd, want, "fd " .. category .. toggle)
        same(rg, want, "rg " .. category .. toggle)
    end
end
print("CATEGORY_FILES_OK")

-- Pickers: Alt-c opens the list, Enter reopens in the chosen category with
-- the typed query, Esc in the same one.
local calls = {}
local real = {}
for _, name in ipairs({ "live_grep", "grep", "fzf_exec", "fzf_live" }) do
    real[name] = fzf[name]
    fzf[name] = function(contents, opts)
        if name ~= "fzf_exec" and name ~= "fzf_live" then
            contents, opts = nil, contents
        end
        table.insert(calls, { name = name, contents = contents, opts = opts })
    end
end
-- Files open the tree (lua/file_tree.lua).
local file_tree = require("file_tree")
local real_tree = file_tree.open
file_tree.open = function(opts)
    table.insert(calls, { name = "files", opts = opts })
end
local function last(name)
    local call = calls[#calls]
    assert(call and call.name == name, "expected " .. name .. ", got " .. vim.inspect(call and call.name))
    return call
end
local function choose(picker, closed, category)
    picker.opts.actions[categories.key].fn({}, closed)
    local chooser = last("fzf_exec")
    if category == nil then
        chooser.opts.actions.esc({})
        return chooser
    end
    for _, line in ipairs(chooser.contents) do
        local plain = fzf.utils.strip_ansi_coloring(line)
        if plain:match("^%S*%s+(%S+)") == category then
            chooser.opts.actions.enter({ line })
            return chooser
        end
    end
    error("no " .. category .. " in " .. vim.inspect(chooser.contents))
end

categories.files(root)
local files = last("files")
assert(files.opts.title == " files · all " and files.opts.cmd[#files.opts.cmd] == ".", "files open on all")
assert(vim.tbl_contains(files.opts.cmd, "--hidden") and not vim.tbl_contains(files.opts.cmd, "--ignore-file"),
    "hidden files, no category: " .. vim.inspect(files.opts.cmd))
assert(files.opts.actions[categories.key].header, "Alt-c in the header")
local chooser = choose(files, { last_query = "serv" }, "internal/order/")
assert(fzf.utils.strip_ansi_coloring(chooser.contents[1]):match("^● all"), "current category marked")
files = last("files")
assert(files.opts.query == "serv", "query kept")
local cmd = table.concat(files.opts.cmd, " ")
assert(cmd:find("%-%-ignore%-file [^ ]*internal%.ignore") and cmd:match(" internal/order$"),
    "ignore file and the folder as the search path: " .. cmd)
assert(files.opts.title == " files · internal/order/ ", "title shows the category")
files.opts.actions["alt-i"].fn({}, { last_query = "repo" })
files = last("files")
assert(vim.tbl_contains(files.opts.cmd, "--no-ignore") and files.opts.title:find("with ignored", 1, true),
    "Alt-i shows ignored files")
choose(files, { last_query = "repo" }, nil)
files = last("files")
cmd = table.concat(files.opts.cmd, " ")
assert(files.opts.query == "repo" and cmd:find("--no-ignore", 1, true) and cmd:match(" internal/order$"),
    "Esc keeps the category, the query and Alt-i")

categories.live_grep(root)
local grep = last("live_grep")
assert(grep.opts.rg_opts == fzf.defaults.grep.rg_opts, "live grep opens on all")
choose(grep, { last_query = "Create(Order", is_live = true }, "rpc")
grep = last("live_grep")
assert(grep.opts.search == "Create(Order" and grep.opts.no_esc == true, "typed regex kept as is")
assert(grep.opts.rg_opts:match("rpc%.ignore' %-e$"), "ignore file before -e: " .. grep.opts.rg_opts)
choose(grep, { last_query = "svc", is_live = false, search = "Create", no_esc = true }, "tests")
grep = last("grep")
assert(grep.opts.search == "Create" and grep.opts.query == "svc", "after Ctrl-g the fuzzy grep stays fuzzy")

categories.grep(root, [[\bCreateOrder\b]], true)
grep = last("grep")
assert(grep.opts.search == [[\bCreateOrder\b]] and grep.opts.no_esc == true, "word search")
choose(grep, { last_query = "", is_live = false, search = [[\bCreateOrder\b]], no_esc = true }, "internal")
grep = last("grep")
assert(grep.opts.search == [[\bCreateOrder\b]] and grep.opts.rg_opts:find("internal.ignore", 1, true),
    "word search in a category")
local hits = lines_of("rg " .. grep.opts.rg_opts:gsub(" %-e$", "") .. " -l 'CreateOrder'")
same(vim.tbl_map(fzf.utils.strip_ansi_coloring, hits), { "internal/order/service.go", "internal/orders/batch.go" },
    "rg with the category options")
print("CATEGORY_PICKERS_OK")

-- Symbols from gopls.
local attached = vim.wait(20000, function()
    return #vim.lsp.get_clients({ bufnr = 0, name = "gopls" }) == 1
end, 50)
assert(attached, "gopls did not attach")

local function run(contents, query)
    local fn = contents
    if query then
        fn = contents({ query })
    end
    local got, done = {}, false
    fn(function(line)
        if line == nil then
            done = true
        else
            table.insert(got, line)
        end
    end)
    assert(vim.wait(10000, function()
        return done
    end, 20), "symbols did not arrive")
    return got
end

local function files_of(lines)
    local set = {}
    for _, line in ipairs(lines) do
        local entry = require("fzf-lua.path").entry_to_file(line, { cwd = root })
        assert(entry.path and entry.line > 0, "entry parses: " .. line)
        set[vim.fs.relpath(root, entry.path)] = true
    end
    return sorted(vim.tbl_keys(set))
end

-- gopls loads the workspace in the background; ask until it answers.
categories.symbols(root)
local symbols = last("fzf_live")
assert(symbols.opts.winopts.title == " symbols · all ", "symbols open on all")
local everything
local deadline = vim.uv.now() + 20000
repeat
    everything = files_of(run(symbols.contents, "CreateOrder"))
    if #everything >= 6 then
        break
    end
    vim.wait(300)
until vim.uv.now() > deadline
same(everything, {
    "internal/order/mocks/store_mock.go",
    "internal/order/service.go",
    "internal/order/service_test.go",
    "internal/orders/batch.go",
    "pkg/api/order/v1/order.pb.go",
    "pkg/api/order/v1/order_grpc.pb.go",
}, "all symbols")

choose(symbols, { last_query = "CreateOrder" }, "internal/order/")
symbols = last("fzf_live")
assert(symbols.opts.query == "CreateOrder" and symbols.opts.exec_empty_query, "query kept, folder lists on empty")
same(files_of(run(symbols.contents, "CreateOrder")), { "internal/order/service.go" }, "folder symbols")
same(files_of(run(symbols.contents, "")), { "internal/order/repo/pg.go", "internal/order/service.go" },
    "an empty query lists the folder")

choose(symbols, { last_query = "CreateOrder" }, "tests")
symbols = last("fzf_live")
same(files_of(run(symbols.contents, "CreateOrder")),
    { "internal/order/mocks/store_mock.go", "internal/order/service_test.go" }, "test symbols")

choose(symbols, { last_query = "CreateOrder" }, "rpc")
symbols = last("fzf_live")
local rpc_lines = run(symbols.contents, "CreateOrder")
same(files_of(rpc_lines), { "pkg/api/order/v1/order.pb.go", "pkg/api/order/v1/order_grpc.pb.go" }, "rpc symbols")
assert(fzf.utils.strip_ansi_coloring(rpc_lines[1]):match("^%S+ %a+ [%w%.]*CreateOrder"),
    "kind and name first: " .. rpc_lines[1])

-- Ctrl-g: fuzzy over the answer, in the same category.
symbols.opts.actions["ctrl-g"].fn({}, { last_query = "CreateOrder" })
local fuzzy = last("fzf_exec")
same(files_of(run(fuzzy.contents)), { "pkg/api/order/v1/order.pb.go", "pkg/api/order/v1/order_grpc.pb.go" },
    "fuzzy keeps the category")
fuzzy.opts.actions["ctrl-g"].fn({}, {})
symbols = last("fzf_live")
assert(symbols.opts.query == "CreateOrder", "Ctrl-g back to live")
print("CATEGORY_SYMBOLS_OK")

-- Alt-k: kinds of declarations from the AST helper, in a category.
local function choose_kind(picker, closed, kind)
    local before = #calls
    picker.opts.actions[categories.kind_key].fn({}, closed)
    assert(vim.wait(10000, function()
        return #calls > before
    end, 20), "no list of kinds")
    local chooser = last("fzf_exec")
    assert(chooser.opts.prompt == "Kind> " and chooser.opts.winopts.fullscreen == false, "a small list of kinds")
    for _, line in ipairs(chooser.contents) do
        if fzf.utils.strip_ansi_coloring(line):match("^%S*%s+(%S+)") == kind then
            chooser.opts.actions.enter({ line })
            return chooser
        end
    end
    error("no " .. kind .. " in " .. vim.inspect(chooser.contents))
end
local function kinds_of(chooser)
    return vim.tbl_map(function(line)
        return vim.trim((fzf.utils.strip_ansi_coloring(line):gsub("^●", ""):gsub("%s+", " ")))
    end, chooser.contents)
end
local function declared(picker)
    return vim.tbl_map(function(line)
        local entry = require("fzf-lua.path").entry_to_file(line, { cwd = root })
        local shown = vim.trim(fzf.utils.strip_ansi_coloring(line):gsub(fzf.utils.nbsp .. ".*$", ""):gsub("%s+", " "))
        return shown .. " @ " .. vim.fs.relpath(root, entry.path) .. ":" .. entry.line
    end, run(picker.contents))
end

choose(symbols, { last_query = "Create" }, "all")
symbols = last("fzf_live")
local kinds = choose_kind(symbols, { last_query = "Create" }, "struct")
same(kinds_of(kinds), { "all 12", "struct 4", "interface 1", "func 4", "method 3" }, "kinds with counts")
local structs = last("fzf_exec")
assert(structs.opts.query == "Create" and structs.opts.winopts.title == " symbols · all · struct ",
    "the query and the kind in the title")
same(declared(structs), {
    "▦ struct MockStore @ internal/order/mocks/store_mock.go:5",
    "▦ struct Service @ internal/order/service.go:3",
    "▦ struct CreateOrderRequest @ pkg/api/order/v1/order.pb.go:5",
    "▦ struct FieldValidationError @ pkg/api/order/v1/order.pb.validate.go:5",
}, "every struct, generated ones too")
choose(structs, { last_query = "" }, "internal/order/")
structs = last("fzf_exec")
same(declared(structs), { "▦ struct Service @ internal/order/service.go:3" }, "kind and category together")
choose_kind(structs, { last_query = "" }, "method")
same(declared(last("fzf_exec")), { "ƒ method (*Service) CreateOrder @ internal/order/service.go:5" },
    "methods with their receiver")
choose_kind(last("fzf_exec"), { last_query = "Save" }, "all")
symbols = last("fzf_live")
assert(symbols.opts.query == "Save" and symbols.opts.winopts.title == " symbols · internal/order/ ",
    "all kinds: the live gopls search again")

for name, fn in pairs(real) do
    fzf[name] = fn
end
file_tree.open = real_tree
print("CATEGORY_KINDS_OK")

print("CATEGORIES_SMOKE_OK")
