-- Breadcrumbs in the window bar: the file relative to the project and the
-- Go scopes around the cursor, outermost first:
--
--   󰟓 internal/order/service.go › 󰆧 (s *Service) PlaceOrder › 󰊕 func
--   󰟓 internal/order/model.go › 󰙅 Order › 󰜢 Total
--
-- The file has the icon of its type (nvim-web-devicons, as in the file
-- tree and the tabs), the directories are dim and the name is bright; each
-- scope has the icon and the colour of its kind: a type in the colour of
-- types, a function or method in the colour of functions, a field in the
-- colour of fields, a closure dim. Without the icons plugin the bar is
-- plain text. A bar wider than the window loses the start of the path, not
-- the place of the cursor.
--
-- Built from the Tree-sitter tree the highlighter already keeps, so moving
-- the cursor sends no LSP request. Buffers without an active highlighter
-- (big files, other languages) show the path only. Floats, quickfix, help
-- and other non-file windows get no bar. A pinned file shows its number
-- first (◆2), from opts.pin.

local M = {}

M.opts = {
    separator = " › ",
    -- Directories kept in front of the file name; deeper paths start with …
    max_dirs = 3,
    -- function(path) → the pin number of a file, or nil.
    pin = nil,
    -- Icons by the kind of a scope: the set of lua/icons.lua, the same as
    -- in the completion menu and the symbol pickers. nil: none.
    icons = {
        ["function"] = require("icons").kind["function"],
        method = require("icons").kind.method,
        closure = require("icons").kind["function"],
        type = require("icons").kind.struct,
        interface = require("icons").kind.interface,
        field = require("icons").kind.field,
        constant = require("icons").kind.constant,
        variable = require("icons").kind.variable,
    },
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

-- Receiver of a method declaration as declared, its name with the type:
-- "s *Service", "c *Cache[K, V]"; "memoryStore" when it has no name.
local function receiver(node, bufnr)
    local list = node:field("receiver")[1]
    if not list then
        return nil
    end
    for child in list:iter_children() do
        if child:type() == "parameter_declaration" then
            local type = field_text(child, "type", bufnr)
            local name = field_text(child, "name", bufnr)
            return type and (name and (name .. " " .. type) or type)
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

-- A type spec is an "interface" when it declares one, a "type" otherwise.
local function type_kind(node)
    local type = node:field("type")[1]
    return type and type:type() == "interface_type" and "interface" or "type"
end

-- kind, text of the scope a node is, or nil.
local labels = {
    function_declaration = function(node, bufnr)
        return "function", field_text(node, "name", bufnr)
    end,
    method_declaration = function(node, bufnr)
        local name = field_text(node, "name", bufnr)
        local recv = receiver(node, bufnr)
        return "method", name and (recv and ("(" .. recv .. ") " .. name) or name)
    end,
    func_literal = function()
        return "closure", "func"
    end,
    type_spec = function(node, bufnr)
        return type_kind(node), field_text(node, "name", bufnr)
    end,
    type_alias = function(node, bufnr)
        return "type", field_text(node, "name", bufnr)
    end,
    field_declaration = function(node, bufnr)
        return "field", field_text(node, "name", bufnr)
    end,
    method_elem = function(node, bufnr)
        return "method", field_text(node, "name", bufnr)
    end,
    method_spec = function(node, bufnr)
        return "method", field_text(node, "name", bufnr)
    end,
    const_spec = function(node, bufnr)
        return "constant", package_level(node) and field_text(node, "name", bufnr) or nil
    end,
    var_spec = function(node, bufnr)
        return "variable", package_level(node) and field_text(node, "name", bufnr) or nil
    end,
}

-- The scopes around (row, col), outermost first: { kind, text }. Empty
-- without an active Tree-sitter highlighter on the buffer.
function M.crumbs(bufnr, row, col)
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

    local crumbs = {}
    while node do
        local label = labels[node:type()]
        if label then
            local kind, name = label(node, bufnr)
            if name and name ~= "" then
                table.insert(crumbs, 1, { kind = kind, text = name })
            end
        end
        node = node:parent()
    end
    return crumbs
end

-- The texts of the scopes around (row, col), outermost first.
function M.scopes(bufnr, row, col)
    return vim.tbl_map(function(crumb)
        return crumb.text
    end, M.crumbs(bufnr, row, col))
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

-- The icon of the file and its highlight group, from nvim-web-devicons
-- when it is loaded; nil without it. The icons of the scopes go with it.
local function file_icon(path)
    local devicons = package.loaded["nvim-web-devicons"]
    if not devicons then
        return nil
    end
    local name = path:match("[^/]+$") or path
    local glyph, hl = devicons.get_icon(name, nil, { default = true })
    return glyph, hl
end

local kind_groups = {
    ["function"] = "BreadcrumbFunction",
    method = "BreadcrumbFunction",
    closure = "BreadcrumbClosure",
    type = "BreadcrumbType",
    interface = "BreadcrumbType",
    field = "BreadcrumbField",
    constant = "BreadcrumbConstant",
    variable = "BreadcrumbVariable",
}

function M.render()
    local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(win) then
        return ""
    end
    local bufnr = vim.api.nvim_win_get_buf(win)
    local cursor = vim.api.nvim_win_get_cursor(win)
    local path = M.path(bufnr)
    local glyph, glyph_hl = file_icon(path)

    local out = { " " }
    local pin = M.opts.pin and M.opts.pin(vim.api.nvim_buf_get_name(bufnr))
    if pin then
        table.insert(out, "%#BreadcrumbPin#◆" .. pin .. " ")
    end
    if glyph then
        table.insert(out, "%#" .. (glyph_hl or "BreadcrumbFile") .. "#" .. glyph .. " ")
    end
    -- Too long for the window: the start of the path goes first.
    table.insert(out, "%<")
    local dir, file = path:match("^(.*/)([^/]*)$")
    if dir then
        table.insert(out, "%#BreadcrumbDir#" .. escape(dir))
    end
    table.insert(out, "%#BreadcrumbFile#" .. escape(file or path))
    if vim.bo[bufnr].modified then
        table.insert(out, "%#BreadcrumbModified# ●")
    end
    local icons = glyph and M.opts.icons or nil
    for _, crumb in ipairs(M.crumbs(bufnr, cursor[1] - 1, cursor[2])) do
        local group = kind_groups[crumb.kind] or "BreadcrumbSymbol"
        table.insert(out, "%#BreadcrumbSeparator#" .. M.opts.separator)
        local icon = icons and icons[crumb.kind]
        if icon then
            table.insert(out, "%#" .. group .. "Icon#" .. icon .. " ")
        end
        table.insert(out, "%#" .. group .. "#" .. escape(crumb.text))
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

-- The colours: the file name in the colour of text, bold; the directories,
-- the separators and a closure dim; the scopes in the colours their kinds
-- have in the code, their icons the same (own groups, so a theme can tune
-- them apart).
local function set_highlights()
    local function hl(name)
        return vim.api.nvim_get_hl(0, { name = name, link = false })
    end
    local function exists(name)
        return next(vim.api.nvim_get_hl(0, { name = name })) ~= nil
    end
    vim.api.nvim_set_hl(0, "BreadcrumbFile", { fg = hl("Normal").fg, bold = true, default = true })
    for group, link in pairs({
        BreadcrumbDir = "Comment",
        BreadcrumbPath = "Comment",
        BreadcrumbSeparator = "NonText",
        BreadcrumbSymbol = "Function",
        BreadcrumbFunction = "Function",
        BreadcrumbClosure = "Comment",
        BreadcrumbType = "Type",
        BreadcrumbField = exists("@variable.member") and "@variable.member" or "Identifier",
        BreadcrumbConstant = "Constant",
        BreadcrumbVariable = "Identifier",
        BreadcrumbModified = "DiagnosticWarn",
        BreadcrumbPin = "Special",
    }) do
        vim.api.nvim_set_hl(0, group, { link = link, default = true })
    end
    for _, group in ipairs({ "BreadcrumbFunction", "BreadcrumbClosure", "BreadcrumbType", "BreadcrumbField",
        "BreadcrumbConstant", "BreadcrumbVariable" }) do
        vim.api.nvim_set_hl(0, group .. "Icon", { fg = hl(group).fg, default = true })
    end
end

function M.setup(user_opts)
    M.opts = vim.tbl_deep_extend("force", M.opts, user_opts or {})

    set_highlights()

    local group = vim.api.nvim_create_augroup("breadcrumbs", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = group,
        callback = set_highlights,
    })
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
