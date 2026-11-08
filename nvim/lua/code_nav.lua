-- Moves over the syntax tree (Tree-sitter), in any language with a
-- parser: Alt-j / Alt-k to the next / previous node of the same level,
-- Alt-h up (the start of the statement, then its parent), Alt-l into
-- the first child, [S / ]S to the start / end of the declaration around
-- the cursor (function, method, type).
--
-- The node of the cursor is the largest one starting on the cursor's
-- line at or before the cursor, so the moves stay on the level of
-- statements: on `v, err := f()` it is the statement, not `v`, and
-- repeated Alt-j walks the statements of the block. Every move adds to
-- the jump list (Ctrl-o goes back) and takes a count.

local M = {}

local function notify(message)
    vim.notify(message, vim.log.levels.INFO, { title = "code" })
end

local function is_root(node)
    return node:parent() == nil
end

-- Containers that start with their first child and only hold siblings
-- (Go's statement_list inside a block): the moves look through them.
M.transparent = { statement_list = true }

local function transparent(node)
    return M.transparent[node:type()] == true
end

-- The node of the cursor: the smallest named node there, then its
-- ancestors while they start at the same place — on the same line for
-- the siblings (the statement of the line), at the same column for the
-- parent and the child (never the root).
function M.node_at(bufnr, row, col, same_line)
    local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col }, ignore_injections = true })
    if not ok or not node or is_root(node) then
        return nil
    end
    local parent = node:parent()
    while parent and not is_root(parent) and not transparent(parent) do
        local prow, pcol = parent:start()
        local nrow, ncol = node:start()
        if not (prow == nrow and (same_line or pcol == ncol)) then
            break
        end
        node = parent
        parent = node:parent()
    end
    return node
end

local function current(same_line)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local node = M.node_at(0, cursor[1] - 1, cursor[2], same_line)
    if not node then
        notify("No syntax tree here")
    end
    return node
end

-- The cursor to the start (or the end) of the node, through the jump list.
local function jump_to(node, at_end)
    local row, col
    if at_end then
        row, col = node:end_()
        if col == 0 then
            row = row - 1
            col = #(vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or "")
        end
        col = math.max(col - 1, 0)
    else
        row, col = node:start()
    end
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { row + 1, col })
end

-- Alt-j / Alt-k: the next / previous sibling, `count` times.
function M.sibling(direction)
    local node = current(true)
    if not node then
        return
    end
    local target = node
    for _ = 1, vim.v.count1 do
        local next
        if direction > 0 then
            next = target:next_named_sibling()
        else
            next = target:prev_named_sibling()
        end
        if not next then
            break
        end
        target = next
    end
    if target ~= node then
        jump_to(target)
    end
end

-- Alt-h: up. From inside a node its start first, then the parent that
-- starts before it (never the root).
function M.parent()
    local node = current(false)
    if not node then
        return
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local target = node
    local steps = vim.v.count1
    local row, col = node:start()
    if row ~= cursor[1] - 1 or col ~= cursor[2] then
        -- The first step: the start of the node of the cursor.
        steps = steps - 1
        if steps == 0 then
            jump_to(node)
            return
        end
    end
    for _ = 1, steps do
        local parent = target:parent()
        while parent and not is_root(parent) and (transparent(parent)
                or (parent:start() == target:start() and select(2, parent:start()) == select(2, target:start()))) do
            parent = parent:parent()
        end
        if not parent or is_root(parent) then
            break
        end
        target = parent
    end
    if target ~= node or steps < vim.v.count1 then
        jump_to(target)
    end
end

-- Alt-l: the first named child that starts after the node's start.
function M.child()
    local node = current(false)
    if not node then
        return
    end
    local target = node
    for _ = 1, vim.v.count1 do
        local row, col = target:start()
        local found
        for child in target:iter_children() do
            if child:named() then
                local crow, ccol = child:start()
                if crow > row or (crow == row and ccol > col) then
                    found = child
                    break
                end
            end
        end
        while found and transparent(found) and found:named_child(0) do
            found = found:named_child(0)
        end
        if not found then
            break
        end
        target = found
    end
    if target ~= node then
        jump_to(target)
    end
end

-- The declaration around the cursor: a function, method, type, closure
-- (Go), or any *_declaration / *_definition node of another language.
M.declaration_types = {
    function_declaration = true,
    method_declaration = true,
    type_declaration = true,
    func_literal = true,
}

function M.declaration_at_cursor(bufnr)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { cursor[1] - 1, cursor[2] }, ignore_injections = true })
    if not ok then
        return nil
    end
    while node and not is_root(node) do
        local kind = node:type()
        if M.declaration_types[kind] or kind:match("_declaration$") or kind:match("_definition$") then
            return node
        end
        node = node:parent()
    end
    return nil
end

-- [S / ]S: the start / end of the declaration around the cursor; with a
-- count, the declaration that many levels up (a closure, then its
-- function).
function M.declaration(at_end)
    local node = M.declaration_at_cursor(0)
    for _ = 2, vim.v.count1 do
        local up = node and node:parent()
        while up and not is_root(up) and not (M.declaration_types[up:type()] or up:type():match("_declaration$")) do
            up = up:parent()
        end
        node = up and not is_root(up) and up or node
    end
    if not node then
        notify("Not inside a declaration")
        return
    end
    jump_to(node, at_end)
end

return M
