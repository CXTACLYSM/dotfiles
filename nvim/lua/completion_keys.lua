-- The keys of the completion menu: Esc, j, k.
--
-- With the menu open, the first Esc switches to choosing — j / k walk the
-- items, as in the pickers (lua/picker_mode.lua), Enter accepts — and the
-- second Esc closes the menu (Ctrl-e) and leaves Insert mode as before.
-- Typing a letter meanwhile narrows the menu as usual; the mode ends with
-- the menu. Without a menu Esc is Esc.
--
-- `jk` leaves Insert mode in this config; while choosing, that mapping
-- is put aside so that a single j moves at once instead of waiting a
-- second for a possible k, and comes back when the menu closes.

local M = {}

-- Whether the choosing mode is on (for tests).
M.choosing = false

local saved_jk = nil

local function pum()
    return vim.fn.pumvisible() == 1
end

-- Enter the choosing mode: j / k as Ctrl-n / Ctrl-p in this buffer, `jk`
-- set aside.
function M.enter()
    if M.choosing then
        return
    end
    M.choosing = true
    local jk = vim.fn.maparg("jk", "i", false, true)
    if jk and jk.lhs then
        saved_jk = jk
        pcall(vim.keymap.del, "i", "jk")
    end
    local buf = vim.api.nvim_get_current_buf()
    vim.keymap.set("i", "j", function()
        return pum() and "<C-n>" or "j"
    end, { buffer = buf, expr = true, desc = "Next completion" })
    vim.keymap.set("i", "k", function()
        return pum() and "<C-p>" or "k"
    end, { buffer = buf, expr = true, desc = "Previous completion" })
end

-- Leave the choosing mode: the keys as they were.
function M.leave()
    if not M.choosing then
        return
    end
    M.choosing = false
    local buf = vim.api.nvim_get_current_buf()
    pcall(vim.keymap.del, "i", "j", { buffer = buf })
    pcall(vim.keymap.del, "i", "k", { buffer = buf })
    if saved_jk then
        vim.fn.mapset("i", false, saved_jk)
        saved_jk = nil
    end
end

-- What Esc does in Insert mode: with a menu, the first press starts
-- choosing, the second closes the menu and leaves Insert; without a menu,
-- Esc.
function M.esc()
    if not pum() then
        return "<Esc>"
    end
    if not M.choosing then
        M.enter()
        return ""
    end
    M.leave()
    return "<C-e><Esc>"
end

function M.setup()
    vim.keymap.set("i", "<Esc>", M.esc, { expr = true, desc = "Choose from the menu / close it / leave Insert" })
    local group = vim.api.nvim_create_augroup("completion_keys", { clear = true })
    -- The menu closed one way or another: Enter, Ctrl-e, a word that
    -- matched nothing, leaving Insert.
    vim.api.nvim_create_autocmd({ "CompleteDone", "InsertLeave" }, {
        group = group,
        callback = function()
            if M.choosing and not pum() then
                M.leave()
            end
        end,
    })
end

return M
