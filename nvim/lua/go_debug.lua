-- Go debugging with nvim-dap and delve.
--
-- The adapter starts `dlv dap` on a free port for every session, so there
-- is no daemon to manage. Configurations cover a `main` package, the test
-- under the cursor, the package's tests and attaching to a running process.
-- The UI is nvim-dap's own: REPL, hover, a scopes sidebar and a frames
-- float, without an extra plugin. Signs use plain Unicode glyphs.

local M = {}

M.defaults = {
    dlv = "dlv",
    -- Extra `go build` flags for the debug binary, e.g. { "-tags=integration" }.
    build_flags = {},
    -- Program output goes to the DAP REPL instead of dlv's own terminal.
    output_mode = "remote",
    -- Delve substitutes these for `-test.run` when debugging one function.
    test_flags = { "-test.v" },
}

M.opts = vim.deepcopy(M.defaults)

-- ============================================================
-- Configuration builders (pure, tested)
-- ============================================================

local function build_flags(opts)
    if #(opts.build_flags or {}) == 0 then
        return nil
    end
    return table.concat(opts.build_flags, " ")
end

-- Launch configuration for one test function in `dir`.
function M.test_configuration(name, kind, dir, opts)
    opts = opts or M.opts
    local args = vim.deepcopy(opts.test_flags or {})
    if name then
        if kind == "Benchmark" then
            table.insert(args, "-test.run=^$")
            table.insert(args, "-test.bench=^" .. name .. "$")
        else
            table.insert(args, "-test.run=^" .. name .. "$")
        end
    end

    return {
        type = "delve",
        request = "launch",
        mode = "test",
        name = name and ("Debug " .. name) or "Debug package tests",
        program = dir,
        args = args,
        buildFlags = build_flags(opts),
        outputMode = opts.output_mode,
    }
end

-- Launch configuration for a `main` package directory.
function M.main_configuration(dir, opts, program_args)
    opts = opts or M.opts
    return {
        type = "delve",
        request = "launch",
        mode = "debug",
        name = "Debug " .. vim.fs.basename(dir),
        program = dir,
        args = program_args or {},
        buildFlags = build_flags(opts),
        outputMode = opts.output_mode,
    }
end

-- Whether the buffer's first non-blank line declares package main.
function M.is_main_package(bufnr)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, 20, false)) do
        local package = line:match("^%s*package%s+([%w_]+)")
        if package then
            return package == "main"
        end
    end
    return false
end

-- ============================================================
-- nvim-dap wiring
-- ============================================================

local function current_dir()
    local file = vim.api.nvim_buf_get_name(0)
    if file == "" then
        return vim.fn.getcwd()
    end
    return vim.fs.dirname(vim.fs.normalize(vim.fs.abspath(file)))
end

function M.debug_nearest_test()
    local dap = require("dap")
    local go_tasks = require("go_tasks")
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local name, kind = go_tasks.nearest_test(bufnr, cursor[1] - 1, cursor[2])
    local dir = current_dir()

    if name then
        vim.notify("delve: " .. name, vim.log.levels.INFO)
    else
        vim.notify("delve: tests of " .. vim.fs.basename(dir), vim.log.levels.INFO)
    end
    dap.run(M.test_configuration(name, kind, dir, M.opts))
end

function M.debug_package()
    local dap = require("dap")
    local dir = current_dir()
    if not M.is_main_package(vim.api.nvim_get_current_buf()) then
        local answer = vim.fn.input("Directory of package main: ", dir .. "/", "dir")
        if answer == "" then
            return
        end
        dir = vim.fs.normalize(answer)
    end

    local raw_args = vim.fn.input("Program arguments: ")
    local args = raw_args ~= "" and vim.split(raw_args, " ", { trimempty = true }) or {}
    dap.run(M.main_configuration(dir, M.opts, args))
end

function M.setup(user_opts)
    M.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts or {})

    local dap = require("dap")

    dap.adapters.delve = function(callback, config)
        if config.request == "attach" and config.mode == "remote" then
            callback({
                type = "server",
                host = config.host or "127.0.0.1",
                port = config.port or 38697,
            })
            return
        end

        callback({
            type = "server",
            port = "${port}",
            executable = {
                command = M.opts.dlv,
                args = { "dap", "-l", "127.0.0.1:${port}" },
                detached = true,
            },
            options = {
                initialize_timeout_sec = 20,
            },
        })
    end

    dap.configurations.go = {
        {
            type = "delve",
            request = "launch",
            name = "Debug package main (current directory)",
            mode = "debug",
            program = "${fileDirname}",
            outputMode = M.opts.output_mode,
        },
        {
            type = "delve",
            request = "launch",
            name = "Debug package tests (current directory)",
            mode = "test",
            program = "${fileDirname}",
            outputMode = M.opts.output_mode,
        },
        {
            type = "delve",
            request = "attach",
            name = "Attach to a local process",
            mode = "local",
            processId = require("dap.utils").pick_process,
        },
    }

    -- Plain glyphs that every terminal font carries.
    vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DiagnosticError", numhl = "" })
    vim.fn.sign_define("DapBreakpointCondition", { text = "◆", texthl = "DiagnosticWarn", numhl = "" })
    vim.fn.sign_define("DapLogPoint", { text = "◇", texthl = "DiagnosticInfo", numhl = "" })
    vim.fn.sign_define("DapBreakpointRejected", { text = "○", texthl = "Comment", numhl = "" })
    vim.fn.sign_define("DapStopped", { text = "→", texthl = "DiagnosticOk", linehl = "Visual", numhl = "" })

    dap.listeners.after.event_initialized["go_debug"] = function()
        vim.notify("delve: session started", vim.log.levels.INFO)
    end
    dap.listeners.before.event_terminated["go_debug"] = function()
        vim.notify("delve: session ended", vim.log.levels.INFO)
    end
    dap.listeners.before.event_exited["go_debug"] = function(_, body)
        vim.notify("delve: program exited with code " .. tostring(body and body.exitCode), vim.log.levels.INFO)
    end

    vim.api.nvim_create_user_command("GoDebugTest", M.debug_nearest_test, {
        desc = "Debug the test under the cursor (or the package tests) with delve",
    })
    vim.api.nvim_create_user_command("GoDebug", M.debug_package, {
        desc = "Debug a package main with delve",
    })
end

return M
