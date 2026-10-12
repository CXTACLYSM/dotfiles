local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path
-- `--clean` drops the pack directory; nvim-dap is a pinned plugin there.
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/site/pack/core/opt/nvim-dap")

local go_debug = require("go_debug")
local opts = { build_flags = {}, output_mode = "remote", test_flags = { "-test.v" } }

-- Pure configuration builders.
local test = go_debug.test_configuration("TestSave", "Test", "/repo/internal/store", opts)
assert(test.type == "delve" and test.request == "launch" and test.mode == "test", vim.inspect(test))
assert(test.program == "/repo/internal/store", "program is the package dir")
assert(vim.deep_equal(test.args, { "-test.v", "-test.run=^TestSave$" }), vim.inspect(test.args))
assert(test.buildFlags == nil, "no build flags by default")
assert(test.name == "Debug TestSave", test.name)

local bench = go_debug.test_configuration("BenchmarkSave", "Benchmark", "/repo", opts)
assert(vim.deep_equal(bench.args, { "-test.v", "-test.run=^$", "-test.bench=^BenchmarkSave$" }), vim.inspect(bench.args))

local package_tests = go_debug.test_configuration(nil, nil, "/repo/pkg", opts)
assert(package_tests.name == "Debug package tests" and vim.deep_equal(package_tests.args, { "-test.v" }), vim.inspect(package_tests))

local tagged = go_debug.test_configuration("TestX", "Test", "/repo", { build_flags = { "-tags=integration" }, test_flags = {} })
assert(tagged.buildFlags == "-tags=integration", tostring(tagged.buildFlags))

local main = go_debug.main_configuration("/repo/cmd/api", opts, { "--port", "8080" })
assert(main.mode == "debug" and main.program == "/repo/cmd/api" and main.name == "Debug api", vim.inspect(main))
assert(vim.deep_equal(main.args, { "--port", "8080" }), "program args")

-- package main detection.
vim.cmd("enew!")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "// Command api serves.", "package main", "" })
assert(go_debug.is_main_package(0), "package main")
vim.cmd("enew!")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "package store" })
assert(not go_debug.is_main_package(0), "library package")

-- Adapter and configurations are registered with nvim-dap.
go_debug.setup(opts)
local dap = require("dap")
assert(type(dap.adapters.delve) == "function", "delve adapter")
local launched
dap.adapters.delve(function(adapter) launched = adapter end, { request = "launch", mode = "test" })
assert(launched.type == "server" and launched.port == "${port}", vim.inspect(launched))
assert(launched.executable.command == "dlv" and launched.executable.args[1] == "dap", vim.inspect(launched.executable))
local remote
dap.adapters.delve(function(adapter) remote = adapter end, { request = "attach", mode = "remote", port = 4000 })
assert(remote.type == "server" and remote.port == 4000 and remote.host == "127.0.0.1", vim.inspect(remote))

local names = {}
for _, configuration in ipairs(dap.configurations.go) do
    table.insert(names, configuration.name)
end
assert(#names == 3 and names[1]:find("package main", 1, true) and names[3]:find("Attach", 1, true), vim.inspect(names))
assert(vim.fn.exists(":GoDebugTest") == 2 and vim.fn.exists(":GoDebug") == 2, "commands")
assert(vim.trim(vim.fn.sign_getdefined("DapBreakpoint")[1].text) == "●", "breakpoint sign")

print("GO_DEBUG_SMOKE_OK")
