-- Breadcrumbs in the window bar: the file relative to the project and the
-- Go scopes around the cursor, outermost first:
--
--   internal/order/service.go › (*Service) PlaceOrder › func
--   internal/order/model.go › Order › Total
--
-- Built from the Tree-sitter tree the highlighter already keeps, so moving
-- the cursor sends no LSP request. Buffers without an active highlighter
-- (big files, other languages) show the path only. Floats, quickfix, help
-- and other non-file windows get no bar.

local M = {}

M.opts = {
    separator = " › ",
    -- Directories kept in front of the file name; deeper paths start with …
    max_dirs = 3,
}

local expression = "%{%v:lua.require'breadcrumbs'.render()%}"

local function escape(text)
    return (text:gsub("%%", "%%%%"))
end

local function text(node, bufnr)
    return vim.treesitter.get_node_text(node, bufnr):gsub("%s+", " ")
end

local function field_text(node, field, bufnr)
    local child = node:field(field)[1]
    return child and text(child, bufnr) or nil
end

-- Receiver type of a method declaration: "*Service", "Cache[K, V]".
local function receiver(node, bufnr)
    local list = node:field("receiver")[1]
    if not list then
        return nil
    end
    for child in list:iter_children() do
        if child:type() == "parameter_declaration" then
            return field_text(child, "type", bufnr)
        end
    end
    return nil
end

-- A const or var spec is a scope only at package level, not inside a body.
local function package_level(node)
    local parent = node:parent()
    while parent do
        local type = parent:type()
        if type == "block" or type == "func_literal" then
            return false
        end
        if type == "source_file" then
            return true
        end
        parent = parent:parent()
    end
    return false
end

local labels = {
    function_declaration = function(node, bufnr)
        return field_text(node, "name", bufnr)
    end,
    method_declaration = function(node, bufnr)
        local name = field_text(node, "name", bufnr)
        local recv = receiver(node, bufnr)
        return name and (recv and ("(" .. recv .. ") " .. name) or name)
    end,
    func_literal = function()
        return "func"
    end,
    type_spec = function(node, bufnr)
        return field_text(node, "name", bufnr)
    end,
    type_alias = function(node, bufnr)
        return field_text(node, "name", bufnr)
    end,
    field_declaration = function(node, bufnr)
        return field_text(node, "name", bufnr)
    end,
    method_elem = function(node, bufnr)
        return field_text(node, "name", bufnr)
    end,
    method_spec = function(node, bufnr)
        return field_text(node, "name", bufnr)
    end,
    const_spec = function(node, bufnr)
        return package_level(node) and field_text(node, "name", bufnr) or nil
    end,
    var_spec = function(node, bufnr)
        return package_level(node) and field_text(node, "name", bufnr) or nil
    end,
}

-- Scope labels around (row, col), outermost first. Empty without an active
-- Tree-sitter highlighter on the buffer.
function M.scopes(bufnr, row, col)
    if not vim.treesitter.highlighter.active[bufnr] then
        return {}
    end
    local ok, node = pcall(vim.treesitter.get_node, {
        bufnr = bufnr,
        pos = { row, col },
        ignore_injections = true,
    })
    if not ok or not node then
        return {}
    end

    local scopes = {}
    while node do
        local label = labels[node:type()]
        local name = label and label(node, bufnr)
        if name and name ~= "" then
            table.insert(scopes, 1, name)
        end
        node = node:parent()
    end
    return scopes
end

-- File path relative to the working directory, long paths shortened.
function M.path(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    local relative = vim.fs.relpath(vim.fn.getcwd(), name) or vim.fn.fnamemodify(name, ":~")
    local parts = vim.split(relative, "/", { plain = true })
    if #parts > M.opts.max_dirs + 1 then
        parts = vim.list_slice(parts, #parts - M.opts.max_dirs, #parts)
        table.insert(parts, 1, "…")
    end
    return table.concat(parts, "/")
end

function M.render()
    local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(win) then
        return ""
    end
    local bufnr = vim.api.nvim_win_get_buf(win)
    local cursor = vim.api.nvim_win_get_cursor(win)

    local out = { "%#BreadcrumbPath#", escape(M.path(bufnr)) }
    if vim.bo[bufnr].modified then
        table.insert(out, "%#BreadcrumbModified# ●")
    end
    for _, scope in ipairs(M.scopes(bufnr, cursor[1] - 1, cursor[2])) do
        table.insert(out, "%#BreadcrumbSeparator#" .. M.opts.separator)
        table.insert(out, "%#BreadcrumbSymbol#" .. escape(scope))
    end
    table.insert(out, "%*")
    return table.concat(out)
end

-- The bar is set per window, only for a normal file window.
function M.attach(win)
    if not vim.api.nvim_win_is_valid(win) then
        return
    end
    local bufnr = vim.api.nvim_win_get_buf(win)
    local file_window = vim.api.nvim_win_get_config(win).relative == ""
        and vim.bo[bufnr].buftype == ""
        and vim.api.nvim_buf_get_name(bufnr) ~= ""
    local wanted = file_window and expression or ""
    if vim.wo[win].winbar ~= wanted then
        vim.wo[win].winbar = wanted
    end
end

function M.setup(user_opts)
    M.opts = vim.tbl_deep_extend("force", M.opts, user_opts or {})

    for group, link in pairs({
        BreadcrumbPath = "Comment",
        BreadcrumbSeparator = "NonText",
        BreadcrumbSymbol = "Function",
        BreadcrumbModified = "DiagnosticWarn",
    }) do
        vim.api.nvim_set_hl(0, group, { link = link, default = true })
    end

    local group = vim.api.nvim_create_augroup("breadcrumbs", { clear = true })
    vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "FileType", "BufFilePost" }, {
        group = group,
        callback = function()
            M.attach(vim.api.nvim_get_current_win())
        end,
    })
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        M.attach(win)
    end
end

return M
