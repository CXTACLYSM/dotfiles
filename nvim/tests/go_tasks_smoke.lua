local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/site")

local go_tasks = require("go_tasks")

-- Roots and package patterns.
local base = vim.fn.tempname()
local work = base .. "/repo"
local module = work .. "/svc"
local pkg = module .. "/internal/store"
vim.fn.mkdir(pkg, "p")
vim.fn.writefile({ "go 1.23.0", "", "use ./svc" }, work .. "/go.work")
vim.fn.writefile({ "module example.com/svc", "", "go 1.23.0" }, module .. "/go.mod")
vim.fn.writefile({ "package store" }, pkg .. "/store_test.go")

local real = function(path) return vim.uv.fs_realpath(path) or path end
assert(go_tasks.module_root(pkg .. "/store_test.go") == real(module), "module root")
assert(go_tasks.workspace_root(pkg .. "/store_test.go") == real(work), "workspace root prefers go.work")
assert(go_tasks.package_pattern(pkg, module) == "./internal/store", "package pattern")
assert(go_tasks.package_pattern(module, module) == ".", "module root pattern")
vim.fn.delete(base, "rf")

-- Nearest test detection through Tree-sitter.
vim.cmd("enew!")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "package store",
    "",
    "import \"testing\"",
    "",
    "func helper(t *testing.T) {",
    "\tt.Helper()",
    "}",
    "",
    "func TestSave(t *testing.T) {",
    "\tt.Run(\"ok\", func(t *testing.T) {",
    "\t\thelper(t)",
    "\t})",
    "}",
    "",
    "func BenchmarkSave(b *testing.B) {",
    "\tfor i := 0; i < b.N; i++ {",
    "\t}",
    "}",
    "",
    "func Testify() {}",
})
vim.bo.filetype = "go"
vim.treesitter.get_parser(0, "go"):parse()

local name, kind = go_tasks.nearest_test(0, 10, 4)
assert(name == "TestSave" and kind == "Test", "subtest cursor resolves to the top-level Test")
name, kind = go_tasks.nearest_test(0, 15, 2)
assert(name == "BenchmarkSave" and kind == "Benchmark", "benchmark detection")
assert(go_tasks.nearest_test(0, 5, 2) == nil, "helper is not a test")
assert(go_tasks.nearest_test(0, 19, 2) == nil, "Testify is not a test function")
assert(go_tasks.nearest_test(0, 1, 0) == nil, "top level has no test")

-- Command construction.
local opts = { test_flags = { "-count=1" } }
assert(vim.deep_equal(
    go_tasks.test_command("./internal/store", "TestSave", "Test", opts),
    { "go", "test", "./internal/store", "-count=1", "-run=^TestSave$", "-v" }
), "run command")
assert(vim.deep_equal(
    go_tasks.test_command(".", "BenchmarkSave", "Benchmark", opts),
    { "go", "test", ".", "-count=1", "-run=^$", "-bench=^BenchmarkSave$", "-v" }
), "bench command")
assert(vim.deep_equal(go_tasks.test_command("./...", nil, nil, opts), { "go", "test", "./...", "-count=1" }), "all")

-- tmux target derivation follows the dev workspace layout.
assert(go_tasks.tests_window("editor") == "tests", "root editor -> tests")
assert(go_tasks.tests_window("server") == "tests", "root server -> tests")
assert(go_tasks.tests_window("backend/editor") == "backend/tests", "subproject editor")
assert(go_tasks.tests_window("apps_web/server") == "apps_web/tests", "subproject server")

-- Outside tmux there is no target and the quickfix path is used.
local saved = vim.env.TMUX
vim.env.TMUX = nil
local target, reason = go_tasks.tests_target()
assert(target == nil and reason == "not inside tmux", "no tmux target outside tmux")
vim.env.TMUX = saved

-- Compiler output parses into quickfix items with the configured errorformat.
local parsed = vim.fn.getqflist({
    lines = {
        "# example.com/svc/internal/store",
        "./store.go:12:5: undefined: foo",
        "internal/store/store.go:20:2: declared and not used: x",
        "vet: ./store.go:3:2: some vet note",
        "FAIL\texample.com/svc/internal/store [build failed]",
    },
    efm = go_tasks.defaults.errorformat,
}).items
local valid = vim.tbl_filter(function(item) return item.valid == 1 end, parsed)
assert(#valid == 2, "expected two quickfix errors, got " .. #valid .. ": " .. vim.inspect(parsed))
assert(valid[1].lnum == 12 and valid[1].col == 5 and valid[1].text:find("undefined: foo", 1, true), vim.inspect(valid[1]))
assert(valid[2].lnum == 20 and valid[2].text:find("declared and not used", 1, true), vim.inspect(valid[2]))

-- The line sent to tmux quotes only what the shell would interpret.
assert(go_tasks.shell_line({ "go", "test", "./internal/store", "-count=1", "-run=^TestSave$", "-v" })
    == "go test ./internal/store -count=1 '-run=^TestSave$' -v", go_tasks.shell_line({ "go", "test", "-run=^TestSave$" }))

go_tasks.setup({})
assert(vim.fn.exists(":GoBuild") == 2 and vim.fn.exists(":GoTest") == 2, "commands")

print("GO_TASKS_SMOKE_OK")
