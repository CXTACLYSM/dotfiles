-- The look of the native completion menu (vim.lsp.completion): the kind of
-- an item as an icon in the colour of its kind instead of the word
-- "Function", first in the row, the detail of a function without the
-- `func` keyword and no longer than a column, and the documentation popup
-- with the signature as a line of Go above the doc comment, wrapped at
-- words.
--
--   󰊕 Print    (a ...any) (n int, err error)
--   󰊕 Printf   (format string, a ...any) (n int, err error)
--   󰜢 Name     string
--
-- The icons and colours are those of the window bar (lua/breadcrumbs.lua):
-- a function or method blue, a type yellow, a field lavender, a variable
-- plain, a constant orange, a package the colour of imports, a keyword the
-- colour of keywords. Without nvim-web-devicons (no Nerd Font) the kind
-- stays a word. M.convert is the `convert` of vim.lsp.completion.enable;
-- the native code keeps everything it is not given: the word, the
-- deprecated strike, the documentation.

local M = {}

M.opts = {
    -- Longest detail shown next to a word; the rest is "…".
    menu_width = 48,
    -- Rows of the menu at most.
    pumheight = 12,
}

local kinds = vim.lsp.protocol.CompletionItemKind
local icons = require("icons").kind

-- Icon (lua/icons.lua, the set of the window bar and the symbol pickers)
-- and highlight group by the kind of an item.
local looks = {
    [kinds.Function] = { icons["function"], "CompletionKindFunction" },
    [kinds.Method] = { icons.method, "CompletionKindFunction" },
    [kinds.Constructor] = { icons.method, "CompletionKindFunction" },
    [kinds.Field] = { icons.field, "CompletionKindField" },
    [kinds.Property] = { icons.field, "CompletionKindField" },
    [kinds.Variable] = { icons.variable, "CompletionKindVariable" },
    [kinds.Reference] = { icons.variable, "CompletionKindVariable" },
    [kinds.Constant] = { icons.constant, "CompletionKindConstant" },
    [kinds.EnumMember] = { icons.constant, "CompletionKindConstant" },
    [kinds.Value] = { icons.constant, "CompletionKindConstant" },
    [kinds.Unit] = { icons.constant, "CompletionKindConstant" },
    [kinds.Struct] = { icons.struct, "CompletionKindType" },
    [kinds.Class] = { icons.struct, "CompletionKindType" },
    [kinds.TypeParameter] = { icons.struct, "CompletionKindType" },
    [kinds.Enum] = { icons.enum, "CompletionKindType" },
    [kinds.Interface] = { icons.interface, "CompletionKindType" },
    [kinds.Module] = { icons.module, "CompletionKindModule" },
    [kinds.Keyword] = { icons.keyword, "CompletionKindKeyword" },
    [kinds.Operator] = { icons.operator, "CompletionKindKeyword" },
    [kinds.Snippet] = { icons.text, "CompletionKindText" },
    [kinds.Text] = { icons.text, "CompletionKindText" },
    [kinds.File] = { icons.file, "CompletionKindText" },
    [kinds.Folder] = { icons.folder, "CompletionKindText" },
    [kinds.Event] = { icons.event, "CompletionKindFunction" },
}

-- Whether the kinds are drawn as icons: the same signal as the window bar.
function M.icons()
    return package.loaded["nvim-web-devicons"] ~= nil
end

-- The detail of an item as shown next to the word: a signature without
-- `func`, the type of a value as it is; cut to opts.menu_width with "…".
function M.menu(item)
    local detail = vim.tbl_get(item, "labelDetails", "description") or item.detail or ""
    detail = detail:gsub("^func%s*", ""):gsub("%s+", " ")
    if vim.fn.strdisplaywidth(detail) > M.opts.menu_width then
        local chars = vim.fn.split(detail, "\\zs")
        detail = table.concat(chars, "", 1, M.opts.menu_width - 1) .. "…"
    end
    return detail
end

-- The documentation popup of an item: its signature as a line of Go first
-- (`Println(a ...any) (n int, err error)`, `Name string`), then the doc
-- comment. The native code shows the documentation alone when the server
-- sends it with the item, and the signature only after a resolve it then
-- never asks for; here both are put together up front.
function M.info(item)
    local label = item.label .. (vim.tbl_get(item, "labelDetails", "detail") or "")
    local detail = (item.detail or ""):gsub("%s+", " ")
    local signature
    if detail ~= "" then
        if detail:match("^func%s*%(") then
            signature = label .. detail:gsub("^func%s*", "")
        else
            signature = label .. " " .. detail
        end
    end
    local doc = item.documentation
    if type(doc) == "table" then
        doc = doc.value
    end
    doc = doc and vim.trim(doc) or ""
    if not signature and doc == "" then
        return nil
    end
    local parts = {}
    if signature then
        table.insert(parts, "```go\n" .. signature .. "\n```")
    end
    if doc ~= "" then
        table.insert(parts, doc)
    end
    return table.concat(parts, "\n\n")
end

-- The fields of a |complete-items| entry this module decides; the rest is
-- the native one's.
function M.convert(item)
    local out = { menu = M.menu(item), info = M.info(item) }
    local look = looks[item.kind]
    if look then
        out.kind_hlgroup = look[2]
        if M.icons() then
            out.kind = look[1]
        end
    end
    return out
end

-- The documentation popup: wrapped at words with the indent of a list
-- kept, the height fitted to the rows that gives. The popup is a float
-- the native code fills once the documentation of the selected item
-- arrives from the server (no WinNew, no OptionSet comes for it), so
-- after each change of the selection the popup is looked for a few times
-- over half a second. Local values only: vim.wo[win] would set the
-- global ones too.
M.popup_delays_ms = { 0, 60, 150, 300, 500 }
local styled = {}

-- true when the popup is there (styled now or before). complete_info()
-- names the popup only when "selected" is asked for as well.
function M.style_popup()
    local win = vim.fn.complete_info({ "selected", "preview_winid" }).preview_winid
    if not win or win == 0 or not vim.api.nvim_win_is_valid(win) then
        return false
    end
    if not styled[win] then
        styled[win] = true
        for name, value in pairs({ linebreak = true, breakindent = true }) do
            vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
        end
    end
    vim.api.nvim_win_set_height(win, math.max(1, vim.api.nvim_win_text_height(win, {}).all))
    return true
end

local function style_popup_soon()
    for _, delay in ipairs(M.popup_delays_ms) do
        vim.defer_fn(function()
            if vim.fn.pumvisible() == 1 then
                M.style_popup()
            end
        end, delay)
    end
end

local function set_highlights()
    for group, link in pairs({
        CompletionKindFunction = "Function",
        CompletionKindField = next(vim.api.nvim_get_hl(0, { name = "@variable.member" })) and "@variable.member" or "Identifier",
        CompletionKindVariable = "Identifier",
        CompletionKindConstant = "Constant",
        CompletionKindType = "Type",
        CompletionKindModule = "Include",
        CompletionKindKeyword = "Keyword",
        CompletionKindText = "String",
    }) do
        vim.api.nvim_set_hl(0, group, { link = link, default = true })
    end
end

function M.setup(user_opts)
    M.opts = vim.tbl_deep_extend("force", M.opts, user_opts or {})
    vim.o.pumheight = M.opts.pumheight
    -- The icon first, then the word, then the detail: a column of kinds
    -- at the left edge of the menu, the words aligned after it.
    vim.o.completeitemalign = "kind,abbr,menu"
    set_highlights()

    local group = vim.api.nvim_create_augroup("completion_look", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })
    vim.api.nvim_create_autocmd("CompleteChanged", {
        group = group,
        callback = style_popup_soon,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(event)
            styled[tonumber(event.match)] = nil
        end,
    })
end

return M
