local M = {}

local open_pairs = {
    ["("] = ")",
    ["{"] = "}",
    ["["] = "]",
    ['"'] = '"',
    ["'"] = "'",
    ["`"] = "`",
}

local closing = {
    [")"] = true,
    ["}"] = true,
    ["]"] = true,
}

local function around_cursor()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]

    return line:sub(col, col), line:sub(col + 1, col + 1)
end

local function escaped_before_cursor()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local backslashes = 0

    while col > 0 and line:sub(col, col) == "\\" do
        backslashes = backslashes + 1
        col = col - 1
    end

    return backslashes % 2 == 1
end

function M.open(char)
    local close = assert(open_pairs[char], "unsupported pair opener")
    local _, right = around_cursor()
    local is_escaped_quote = (char == '"' or char == "'")
        and escaped_before_cursor()

    -- In quoted Go strings/runes, an escaped quote is content, not a new pair.
    if is_escaped_quote then
        return "<C-v>" .. char
    end

    -- Only self-closing delimiters can reuse the character to the right.
    -- An opening bracket before an outer closer starts a nested pair.
    if char == close and right == close then
        return "<Right>"
    end

    return char .. close .. "<Left>"
end

function M.close(char)
    assert(closing[char], "unsupported pair closer")

    local _, right = around_cursor()
    if right == char then
        return "<Right>"
    end

    return char
end

function M.backspace()
    -- Preserve native completion-menu filtering and cancellation behavior.
    if vim.fn.pumvisible() == 1 then
        return "<BS>"
    end

    local left, right = around_cursor()
    if open_pairs[left] == right then
        return "<BS><Del>"
    end

    return "<BS>"
end

function M.enter()
    -- Keep the native completion-menu action unchanged.
    if vim.fn.pumvisible() == 1 then
        return "<CR>"
    end

    local left, right = around_cursor()
    if left == "{" and right == "}" then
        -- Split the pair, then open the body line above the closing brace.
        -- The active filetype indent expression supplies the correct indent.
        return "<CR><C-o>O"
    end

    return "<CR>"
end

function M.setup()
    for opener in pairs(open_pairs) do
        vim.keymap.set("i", opener, function()
            return M.open(opener)
        end, {
            expr = true,
            silent = true,
            desc = "Insert matching pair",
        })
    end

    for closer in pairs(closing) do
        vim.keymap.set("i", closer, function()
            return M.close(closer)
        end, {
            expr = true,
            silent = true,
            desc = "Skip matching closer",
        })
    end

    vim.keymap.set("i", "<BS>", M.backspace, {
        expr = true,
        silent = true,
        desc = "Delete empty pair",
    })

    vim.keymap.set("i", "<CR>", M.enter, {
        expr = true,
        silent = true,
        desc = "Open an indented brace block",
    })
end

return M
