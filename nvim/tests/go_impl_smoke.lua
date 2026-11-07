-- Space gm on the navigation fixture: the type under the cursor and the row
-- to insert at, the assertion line, the fix picked among code actions, and
-- the whole thing with gopls: `var _ Store = (*fileStore)(nil)` after the
-- type and the missing Save method declared below.
local go_impl = require("go_impl")
local buffer = vim.api.nvim_get_current_buf()

local function find(text)
    for number, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
        if line:find(text, 1, true) then
            return number
        end
    end
    error("no line with " .. text)
end

vim.api.nvim_win_set_cursor(0, { find("type fileStore struct"), 6 })
local name, row = go_impl.type_at_cursor(buffer, find("type fileStore struct") - 1, 6)
assert(name == "fileStore", "the type under the cursor: " .. tostring(name))
assert(vim.api.nvim_buf_get_lines(buffer, row, row + 1, false)[1]:match("}$"), "the row of the declaration's end")
assert(go_impl.assertion("Store", "fileStore") == "var _ Store = (*fileStore)(nil)", "the assertion")
assert(go_impl.missing_methods_action({ { title = "Organize imports" }, { title = "Declare missing methods of *fileStore" } }).title
    == "Declare missing methods of *fileStore", "the fix among the actions")
assert(go_impl.missing_methods_action({ { title = "Organize imports" } }) == nil, "no fix")

assert(vim.wait(30000, function()
    return #vim.lsp.get_clients({ bufnr = buffer, name = "gopls" }) > 0
end, 100), "gopls attached")
local finished, failure = false, nil
go_impl.implement(buffer, "Store", "fileStore", row, function(err)
    finished, failure = true, err
end)
assert(vim.wait(30000, function()
    return finished
end, 100), "implement finished")
assert(failure == nil, "implement: " .. tostring(failure))
local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
local text = table.concat(lines, "\n")
assert(text:find("var _ Store = (*fileStore)(nil)", 1, true), "the assertion written")
assert(text:find("func (f *fileStore) Save(o Order) error", 1, true) or text:find("func (fileStore) Save(o Order) error", 1, true)
    or text:find("Save(o Order) error", 1, true), "Save declared: " .. text)
assert(text:find("panic(\"unimplemented\")", 1, true) and text:find("// Save implements [Store]", 1, true), "with a body to fill in and a doc comment")
print("GO_IMPL_OK")
