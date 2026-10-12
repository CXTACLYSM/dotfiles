-- Build, vet and test tasks for Go projects.
--
-- build/vet run asynchronously from the module or workspace root and land in
-- the quickfix list, so a refactor that breaks thirty files is walked with
-- ]q / [q instead of by re-reading compiler output.
--
-- Tests follow the tmux workspace model of the `dev` script: the command is
-- sent to the `tests` window of the current tmux session (`<name>/tests`
-- for a subproject editor window), so the run keeps its own scrollback and
-- Neovim never blocks. Outside tmux the test runs asynchronously into the
-- quickfix list instead.

local M = {}

M.defaults = {
    build_command = "go build ./... && go vet ./...",
    test_flags = { "-count=1" },
    -- Go compiler / vet output: `# pkg` headers are dropped, `./f.go:1:2: m`
    -- and `f.go:1: m` are errors, indented lines continue the previous one.
    errorformat = table.concat({
        "%-G# %.%#",
        "%-Gvet: %.%#",
        "%-G%.%# [build failed]",
        "%A%f:%l:%c: %m",
        "%A%f:%l: %m",
        "%C%*\\s%m",
        "%-G%.%#",
    }, ","),
}

M.opts = vim.deepcopy(M.defaults)

-- ============================================================
-- Roots and packages
-- ============================================================

local function normalize(path)
    local absolute = vim.fs.normalize(vim.fs.abspath(path))
    return vim.uv.fs_realpath(absolute) or absolute
end

function M.module_root(path)
    path = normalize(path)
    return normalize(vim.fs.root(path, "go.mod") or vim.fs.dirname(path))
end

function M.workspace_root(path)
    path = normalize(path)
    return normalize(vim.fs.root(path, "go.work") or vim.fs.root(path, "go.mod") or vim.fs.dirname(path))
end

-- Package path of `dir` relative to `root`, in `go` command form.
function M.package_pattern(dir, root)
    dir = normalize(dir)
    root = normalize(root)
    if dir == root then
        return "."
    end
    local relative = vim.fs.relpath(root, dir)
    if not relative then
        return nil
    end
    return "./" .. relative
end

-- ============================================================
-- Nearest test
-- ============================================================

local test_prefixes = { "Test", "Example", "Fuzz", "Benchmark" }

local function test_kind(name)
    for _, prefix in ipairs(test_prefixes) do
        if name:sub(1, #prefix) == prefix then
            local rest = name:sub(#prefix + 1)
            if rest == "" or not rest:match("^%l") then
                return prefix
            end
        end
    end
    return nil
end

-- Name and kind of the top-level test function enclosing (row, col).
function M.nearest_test(bufnr, row, col)
    local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col } })
    if not ok then
        return nil
    end

    while node do
        if node:type() == "function_declaration" then
            local name_node = node:field("name")[1]
            local name = name_node and vim.treesitter.get_node_text(name_node, bufnr) or ""
            local kind = test_kind(name)
            if kind then
                return name, kind
            end
            return nil
        end
        node = node:parent()
    end

    return nil
end

-- Build the `go test` argument list for a package, optionally one function.
function M.test_command(pattern, name, kind, opts)
    opts = opts or M.opts
    local command = { "go", "test", pattern }
    vim.list_extend(command, opts.test_flags or {})
    if name then
        local flag = kind == "Benchmark" and "-bench" or "-run"
        if kind == "Benchmark" then
            table.insert(command, "-run=^$")
        end
        table.insert(command, string.format("%s=^%s$", flag, name))
        table.insert(command, "-v")
    end
    return command
end

-- Quote only what the shell would otherwise interpret, so the line that
-- lands in the tests window stays readable and re-runnable by hand.
function M.shell_line(command)
    local parts = {}
    for _, part in ipairs(command) do
        if part:match("^[%w%-%./=_,]+$") then
            table.insert(parts, part)
        else
            table.insert(parts, vim.fn.shellescape(part))
        end
    end
    return table.concat(parts, " ")
end

-- ============================================================
-- tmux
-- ============================================================

-- `editor` -> `tests`, `backend/editor` -> `backend/tests`, anything else in a
-- subproject keeps its prefix, a root-level window maps to plain `tests`.
function M.tests_window(window_name)
    local prefix = window_name:match("^(.*)/[^/]+$")
    if prefix then
        return prefix .. "/tests"
    end
    return "tests"
end

local function tmux(args)
    local result = vim.system(vim.list_extend({ "tmux" }, args), { text = true }):wait()
    if result.code ~= 0 then
        return nil, vim.trim(result.stderr or "")
    end
    return vim.trim(result.stdout or "")
end

-- The tests window of the current tmux session: target and its directory,
-- or nil and a reason.
function M.tests_target()
    if not vim.env.TMUX then
        return nil, "not inside tmux"
    end

    local session = tmux({ "display-message", "-p", "#S" })
    local window = tmux({ "display-message", "-p", "#W" })
    if not session or not window then
        return nil, "tmux session is unavailable"
    end

    local target = string.format("=%s:%s", session, M.tests_window(window))
    local cwd, err = tmux({ "display-message", "-p", "-t", target, "#{pane_current_path}" })
    if not cwd then
        return nil, "no tests window: " .. (err or target)
    end
    return target, cwd
end

function M.send_to_tests_window(target, line)
    local ok, err = tmux({ "send-keys", "-t", target, line, "Enter" })
    if not ok then
        return nil, err
    end
    return true
end

-- ============================================================
-- Quickfix runner
-- ============================================================

local function run_to_quickfix(command, cwd, title, opts)
    vim.notify(title .. " …", vim.log.levels.INFO)
    vim.system({ "sh", "-c", command }, { cwd = cwd, text = true }, function(result)
        vim.schedule(function()
            local output = (result.stdout or "") .. (result.stderr or "")
            local lines = vim.split(output, "\n", { trimempty = true })
            local items = vim.fn.getqflist({
                lines = lines,
                efm = opts.errorformat,
            }).items
            local valid = vim.tbl_filter(function(item)
                return item.valid == 1
            end, items)

            vim.fn.setqflist({}, " ", {
                title = title,
                items = valid,
            })

            if #valid == 0 and result.code == 0 then
                vim.cmd("cclose")
                vim.notify(title .. ": OK", vim.log.levels.INFO)
            elseif #valid == 0 then
                vim.notify(title .. " failed:\n" .. table.concat(lines, "\n"), vim.log.levels.ERROR)
            else
                vim.cmd("botright copen")
                vim.cmd("wincmd p")
                -- Land on the first problem; ]q / [q walk the rest.
                pcall(vim.cmd, "cfirst")
                vim.notify(string.format("%s: %d problem%s", title, #valid, #valid == 1 and "" or "s"), vim.log.levels.WARN)
            end
        end)
    end)
end

-- ============================================================
-- Public actions
-- ============================================================

function M.build()
    local file = vim.api.nvim_buf_get_name(0)
    local root = M.workspace_root(file ~= "" and file or vim.fn.getcwd())
    run_to_quickfix(M.opts.build_command, root, "go build + vet", M.opts)
end

-- scope: "nearest" (function under the cursor, else its package),
--        "package", or "all" (every package of the module).
function M.test(scope)
    local bufnr = vim.api.nvim_get_current_buf()
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then
        vim.notify("Save the buffer before running tests", vim.log.levels.INFO)
        return
    end

    local dir = vim.fs.dirname(normalize(file))
    local root = M.module_root(file)
    local pattern
    local name, kind

    if scope == "all" then
        pattern = "./..."
    else
        pattern = M.package_pattern(dir, root) or "."
        if scope ~= "package" then
            local cursor = vim.api.nvim_win_get_cursor(0)
            name, kind = M.nearest_test(bufnr, cursor[1] - 1, cursor[2])
        end
    end

    local command = M.test_command(pattern, name, kind, M.opts)
    local line = M.shell_line(command)

    local target, cwd = M.tests_target()
    if target then
        -- The tests window may sit in another directory; pin the run to the
        -- module root so `./pkg` patterns resolve.
        if normalize(cwd) ~= root then
            line = string.format("cd -- %s && %s", vim.fn.shellescape(root), line)
        end
        local sent, err = M.send_to_tests_window(target, line)
        if sent then
            -- One line: a multi-line notification would raise a hit-enter
            -- prompt in the editor.
            vim.notify(line .. "  → tmux " .. target:gsub("^=", ""), vim.log.levels.INFO)
            return
        end
        vim.notify("tmux send failed, running in quickfix: " .. tostring(err), vim.log.levels.WARN)
    end

    run_to_quickfix(line, root, "go test " .. (name or pattern), M.opts)
end

function M.setup(user_opts)
    M.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts or {})

    vim.api.nvim_create_user_command("GoBuild", M.build, {
        desc = "go build ./... && go vet ./... into the quickfix list",
    })
    vim.api.nvim_create_user_command("GoTest", function(command)
        M.test(command.args ~= "" and command.args or "nearest")
    end, {
        nargs = "?",
        complete = function()
            return { "nearest", "package", "all" }
        end,
        desc = "Run Go tests in the tmux tests window (nearest | package | all)",
    })
end

return M
