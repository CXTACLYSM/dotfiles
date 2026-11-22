local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

-- Esc with the completion menu (lua/completion_keys.lua): the first press
-- starts choosing with j / k (the `jk` mapping set aside so j moves at
-- once), the second closes the menu and leaves Insert; without a menu Esc
-- is Esc; the mode ends with the menu.
local keys = require("completion_keys")
local menu = false
vim.fn.pumvisible = function()
    return menu and 1 or 0
end

vim.keymap.set("i", "jk", "<Esc>", { desc = "Normal mode" })
keys.setup()
assert(vim.fn.maparg("<Esc>", "i", false, true).expr == 1, "Esc is an expression mapping in Insert")

assert(keys.esc() == "<Esc>" and not keys.choosing, "no menu: Esc")

menu = true
assert(keys.esc() == "" and keys.choosing, "the first Esc starts choosing")
assert(vim.fn.maparg("jk", "i") == "", "jk set aside while choosing")
local j = vim.fn.maparg("j", "i", false, true)
assert(j.buffer == 1 and j.expr == 1 and j.desc == "Next completion", "j walks the menu: " .. vim.inspect(j))
assert(vim.fn.maparg("k", "i", false, true).desc == "Previous completion", "k walks the menu")
assert(j.callback() == "<C-n>", "j is Ctrl-n with the menu")
menu = false
assert(j.callback() == "j", "j is j without it")
menu = true

assert(keys.esc() == "<C-e><Esc>" and not keys.choosing, "the second Esc closes the menu and leaves Insert")
assert(vim.fn.maparg("jk", "i") == "<Esc>", "jk is back")
assert(vim.fn.maparg("j", "i") == "" and vim.fn.maparg("k", "i") == "", "j and k are plain again")
print("COMPLETION_KEYS_ESC_OK")

-- The menu closed another way (Enter, a word matching nothing): the mode
-- ends with it.
keys.esc()
assert(keys.choosing, "choosing")
menu = false
vim.api.nvim_exec_autocmds("CompleteDone", {})
assert(not keys.choosing and vim.fn.maparg("jk", "i") == "<Esc>", "CompleteDone ends choosing, jk back")
keys.leave()
assert(not keys.choosing, "leave twice is fine")
print("COMPLETION_KEYS_DONE_OK")

print("COMPLETION_KEYS_SMOKE_OK")
