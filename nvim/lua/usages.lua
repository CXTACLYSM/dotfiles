-- ]u / [u: the next / previous use of the name under the cursor in this
-- file: a variable, a parameter, a field, a function. The places are the
-- ones gopls marks after a pause (textDocument/documentHighlight), so a
-- `total` of another function or a field `x.total` does not count. In the
-- order of the file and around past its ends, with a count (3]u); the
-- message says which one of how many: "total 2/5". ]r / [r are the same.

local M = {}

local function before(a, b)
    return a.line < b.line or (a.line == b.line and a.character < b.character)
end

local function echo(text)
    vim.api.nvim_echo({ { text } }, false, {})
end

-- The index in `ranges` (LSP ranges in the order of the file) `step`
-- places from `cursor` (an LSP position): from the range the cursor is in,
-- or from where it stands between two of them; around past the ends. The
-- second value is the index of the range under the cursor, or nil.
function M.step(ranges, cursor, step)
    local count = #ranges
    local current, after = nil, count + 1
    for index, range in ipairs(ranges) do
        if not before(cursor, range.start) and before(cursor, range["end"]) then
            current = index
        end
        if after == count + 1 and before(cursor, range.start) then
            after = index
        end
    end
    local target
    if current then
        target = current + step
    elseif step > 0 then
        target = after + step - 1
    else
        target = after + step
    end
    return (target - 1) % count + 1, current
end

-- Moves `step` uses forward (or back when negative) from the cursor.
function M.jump(step)
    local win = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_win_get_buf(win)
    local client = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/documentHighlight" })[1]
    if not client then
        echo("Usages: no language server in this buffer")
        return
    end

    local params = vim.lsp.util.make_position_params(win, client.offset_encoding)
    local cursor = vim.api.nvim_win_get_cursor(win)
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    local name = vim.fn.expand("<cword>")
    local visual = vim.api.nvim_get_mode().mode:find("^[vV\22]") ~= nil

    client:request("textDocument/documentHighlight", params, function(err, result)
        -- Too late: the cursor or the text moved while gopls answered.
        if err
            or not vim.api.nvim_win_is_valid(win)
            or vim.api.nvim_get_current_win() ~= win
            or vim.api.nvim_win_get_buf(win) ~= bufnr
            or not vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor)
            or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick
        then
            return
        end
        if not result or #result == 0 then
            echo("Usages: no name under the cursor")
            return
        end

        local ranges = vim.tbl_map(function(item)
            return item.range
        end, result)
        table.sort(ranges, function(a, b)
            return before(a.start, b.start)
        end)
        local index, current = M.step(ranges, params.position, step)
        if #ranges == 1 and current then
            echo(name .. ": used only here")
            return
        end

        local start = ranges[index].start
        local line = vim.api.nvim_buf_get_lines(bufnr, start.line, start.line + 1, false)[1] or ""
        local col = vim.str_byteindex(line, client.offset_encoding, start.character, false)
        -- Each jump goes to the jump list, as with n after a search.
        if not visual then
            vim.cmd("normal! m'")
        end
        vim.api.nvim_win_set_cursor(win, { start.line + 1, col })
        if not visual then
            vim.cmd("normal! zv")
        end
        echo(string.format("%s %d/%d", name, index, #ranges))
    end, bufnr)
end

function M.next()
    M.jump(vim.v.count1)
end

function M.previous()
    M.jump(-vim.v.count1)
end

return M
