local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

-- Space gc: the cover profile parsed into lines (a line any ran block
-- covers is covered), the module path, and the bars drawn on a buffer of
-- the module; then a real `go test -coverprofile` on a fixture.
local go_cover = require("go_cover")

local function same(got, want, what)
    assert(vim.deep_equal(got, want), what .. ": " .. vim.inspect(got) .. " ~= " .. vim.inspect(want))
end

same(go_cover.parse({
    "mode: count",
    "example.com/svc/calc.go:3.20,5.2 1 2",
    "example.com/svc/calc.go:5.2,7.2 1 0",
    "example.com/svc/calc.go:9.15,11.2 1 0",
    "garbage",
}), {
    ["example.com/svc/calc.go"] = { [3] = true, [4] = true, [5] = true, [6] = false, [7] = false, [9] = false, [10] = false, [11] = false },
}, "lines by block; a shared line counts covered when one block ran")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.writefile({ "module example.com/svc", "", "go 1.23.0" }, root .. "/go.mod")
vim.fn.writefile({
    "package svc",
    "",
    "func Add(a, b int) int {",
    "\treturn a + b",
    "}",
    "",
    "func Sub(a, b int) int {",
    "\treturn a - b",
    "}",
}, root .. "/calc.go")
vim.fn.writefile({
    "package svc",
    "",
    'import "testing"',
    "",
    "func TestAdd(t *testing.T) {",
    "\tif Add(1, 2) != 3 {",
    '\t\tt.Fatal("add")',
    "\t}",
    "}",
}, root .. "/calc_test.go")
assert(go_cover.module_path(root) == "example.com/svc", "module path from go.mod")

vim.cmd.edit(root .. "/calc.go")
local buffer = vim.api.nvim_get_current_buf()
assert(go_cover.lines_of(buffer) == nil, "nothing before a run")

local finished, failure = false, nil
go_cover.run(root .. "/calc.go", function(err)
    finished, failure = true, err
end)
assert(vim.wait(60000, function()
    return finished
end, 100), "go test finished")
assert(failure == nil, "go test ran: " .. tostring(failure))
assert(go_cover.state.percent == "50.0", "half of the statements: " .. tostring(go_cover.state.percent))
local hit, miss = go_cover.counts(buffer)
assert(hit == 2 and miss == 2, string.format("Add covered, Sub not: %d / %d", hit, miss))
local marks = vim.api.nvim_buf_get_extmarks(buffer, go_cover.namespace, 0, -1, { details = true })
local by_line = {}
for _, mark in ipairs(marks) do
    by_line[mark[2] + 1] = mark[4].sign_hl_group
end
-- Go's blocks start at the first statement and end at the closing brace.
same(by_line, { [4] = "GoCoverHit", [5] = "GoCoverHit", [8] = "GoCoverMiss", [9] = "GoCoverMiss" }, "bars by line")

-- Opening another file of the module later draws its bars too; clear
-- removes everything.
vim.cmd.edit(root .. "/calc_test.go")
vim.cmd.edit(root .. "/calc.go")
assert(#vim.api.nvim_buf_get_extmarks(vim.api.nvim_get_current_buf(), go_cover.namespace, 0, -1, {}) == 4, "bars after reopening")
go_cover.clear()
assert(#vim.api.nvim_buf_get_extmarks(buffer, go_cover.namespace, 0, -1, {}) == 0 and go_cover.state.root == nil, "cleared")
vim.fn.delete(root, "rf")
print("GO_COVER_OK")
