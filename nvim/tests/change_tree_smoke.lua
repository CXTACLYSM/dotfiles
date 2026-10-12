-- Change tree end to end in a git fixture: `greeting` was edited after the
-- last commit, `main` calls it and `TestGreeting` tests it. The tree must
-- have greeting as its root and both of them below it, and :ChangeTree!
-- must open the view.
local attached = vim.wait(20000, function()
    return #vim.lsp.get_clients({ bufnr = 0, name = "gopls" }) == 1
end, 50)
assert(attached, "gopls did not attach")

local change_tree = require("change_tree")
assert(change_tree.opts.auto == false, "build after save is off by default")

local notices = {}
local original_notify = vim.notify
vim.notify = function(message, level, opts)
    table.insert(notices, tostring(message))
    return original_notify(message, level, opts)
end

change_tree.build(vim.api.nvim_get_current_buf(), false)

local timeout_ms = tonumber(os.getenv("NVIM_CHANGE_TREE_TIMEOUT_MS")) or 60000
local built = vim.wait(timeout_ms, function()
    return change_tree.last() ~= nil
        or (not change_tree.is_building() and #notices > 0 and notices[#notices]:find("failed", 1, true) ~= nil)
end, 50)
assert(built and change_tree.last(), "change tree was not built: " .. vim.inspect(notices))

local graph = change_tree.last()
local roots = {}
for _, root in ipairs(graph.roots) do
    table.insert(roots, root.symbol.qualified or root.symbol.name)
end
assert(#roots == 1 and roots[1]:find("greeting", 1, true), "roots: " .. vim.inspect(roots))

local lines, _, summary = change_tree.render(graph)
local text = table.concat(lines, "\n")
print(text)
print(summary)

assert(text:find("Δ func", 1, true), "changed root row")
assert(text:find("caller main", 1, true), "main calls greeting:\n" .. text)
assert(text:find("TestGreeting", 1, true), "TestGreeting covers greeting:\n" .. text)
assert(text:find("main.go:", 1, true), "rows carry locations")

vim.cmd("ChangeTree!")
local view = vim.api.nvim_get_current_win()
assert(vim.bo[vim.api.nvim_win_get_buf(view)].filetype == "changetree", "change tree view is open")
assert(vim.api.nvim_win_get_config(view).relative ~= "", "view is a floating window")

for _, command in ipairs({ "ChangeTreeText", "ChangeTreeLedger", "ChangeTreeTrace", "ChangeTreeIndex" }) do
    vim.cmd(command)
    local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert(content ~= "", command .. " is empty")
end

print("CHANGE_TREE_SMOKE_OK")
