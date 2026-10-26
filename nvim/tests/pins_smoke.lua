-- Pinned and recent files on the file tree fixture: Space p pins and
-- unpins, the numbers survive a restart (stdpath("state")), Alt-1…9 open
-- them, the window bar shows the number, the list moves and unpins, and
-- the recent files come newest first without the current one.
local pins = require("pins")
local fzf = require("fzf-lua")
local root = vim.fn.getcwd()

local function same(got, want, what)
    assert(vim.deep_equal(got, want), what .. ": " .. vim.inspect(got) .. " ~= " .. vim.inspect(want))
end

pins._reset()
same(pins.list(root), {}, "nothing pinned")
vim.cmd.edit(root .. "/internal/order/service.go")
pins.toggle(root)
vim.cmd.edit(root .. "/go.mod")
pins.toggle(root)
same(pins.list(root), { "internal/order/service.go", "go.mod" }, "pinned in order")
assert(pins.number(root, root .. "/go.mod") == 2, "number of a pinned file")
pins._reset()
same(pins.list(root), { "internal/order/service.go", "go.mod" }, "kept across restarts")
assert(require("breadcrumbs").render():find("◆2", 1, true), "the window bar shows the number")
pins.toggle(root, "/elsewhere/file.go")
same(pins.list(root), { "internal/order/service.go", "go.mod" }, "a file outside the project is not pinned")
print("PINS_TOGGLE_OK")

for number = 1, 9 do
    assert(vim.fn.maparg("<M-" .. number .. ">", "n") ~= "", "Alt-" .. number)
end
assert(vim.fn.maparg("<leader>p", "n") ~= "" and vim.fn.maparg("<leader>P", "n") ~= "", "Space p / Space P")
vim.fn.maparg("<M-1>", "n", false, true).callback()
assert(vim.api.nvim_buf_get_name(0) == root .. "/internal/order/service.go", "Alt-1 opens pin 1")
print("PINS_JUMP_OK")

-- The list: lines, and the keys move and unpin.
local reloads = 0
local keys = pins.pick_keys(root, function()
    reloads = reloads + 1
    return "reload"
end)
assert(keys["alt-down"](1) == "reload+pos(2)", "Alt-↓ moves the file down")
same(pins.list(root), { "go.mod", "internal/order/service.go" }, "moved")
assert(keys["alt-up"](1) == "", "the first one does not go up")
assert(keys["ctrl-x"](1) == "reload+pos(1)", "Ctrl-x unpins")
same(pins.list(root), { "internal/order/service.go" }, "unpinned")
assert(reloads == 2, "the list is written anew after a change")
local line = fzf.utils.strip_ansi_coloring(pins.lines(root)[1])
assert(line:match("^1  service%.go  internal/order/") and line:sub(-#"internal/order/service.go") == "internal/order/service.go",
    "list line: " .. line)
local real_exec, picked = fzf.fzf_exec, nil
fzf.fzf_exec = function(contents, opts)
    picked = { contents = contents, opts = opts }
end
pins.pick(root)
fzf.fzf_exec = real_exec
assert(picked.opts.keymap.fzf["ctrl-x"]:match("^transform:") and picked.opts.previewer == "builtin", "the picker")
pins.toggle(root)
same(pins.list(root), {}, "Space p again unpins")
print("PINS_LIST_OK")

-- Recent: files by the order they were entered, the current one left out.
vim.cmd.edit(root .. "/cmd/app/main.go")
vim.cmd.edit(root .. "/README.md")
vim.cmd.edit(root .. "/internal/user/user.go")
local recent = pins.recent(root, 8, vim.api.nvim_buf_get_name(0))
same(vim.list_slice(recent, 1, 2), { "README.md", "cmd/app/main.go" }, "recent files")
assert(not vim.tbl_contains(recent, "internal/user/user.go"), "without the current file")
print("PINS_SMOKE_OK")
