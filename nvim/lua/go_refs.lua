-- `grr` for Go: references and implementations in one fzf-lua picker.
--
-- gopls `textDocument/references` on an interface method returns the
-- interface declaration and the call sites that dispatch through the
-- interface, but not the concrete methods that satisfy it. Those come from
-- `textDocument/implementation`. This module asks for both and shows them in
-- a single list with a prefix per relation, so `grr` on `Store.Save` lists
-- every `(*Memory).Save`, `(Postgres).Save` and every caller at once.
--
-- On a concrete method the implementation provider returns the interface
-- methods it satisfies; the prefix is then `iface` instead of `impl`.

local M = {}

local function first_field(node, name)
    local values = node:field(name)
    return values and values[1] or nil
end

-- Classify the symbol under the cursor from the Tree-sitter AST only.
-- Returns "interface", "concrete_method", or "other".
function M.context(bufnr, row, col)
    local ok, node = pcall(vim.treesitter.get_node, {
        bufnr = bufnr,
        pos = { row, col },
    })
    if not ok or not node then
        return "other"
    end

    local start = node
    while node do
        local kind = node:type()

        if kind == "interface_type" then
            return "interface"
        end

        if kind == "type_spec" then
            local type_node = first_field(node, "type")
            if type_node and type_node:type() == "interface_type" then
                return "interface"
            end
        end

        if kind == "method_declaration" then
            local name = first_field(node, "name")
            if name and name:equal(start) then
                return "concrete_method"
            end
            return "other"
        end

        if kind == "function_declaration" or kind == "func_literal" then
            return "other"
        end

        node = node:parent()
    end

    return "other"
end

-- fzf-lua `lsp_finder` options for the classified context.
function M.finder_opts(context, fzf_utils)
    local function paint(color, text)
        if fzf_utils and fzf_utils.ansi_codes and fzf_utils.ansi_codes[color] then
            return fzf_utils.ansi_codes[color](text)
        end
        return text
    end

    local implementation_label = context == "concrete_method" and "iface" or "impl "
    local title
    if context == "interface" then
        title = " implementations + references "
    elseif context == "concrete_method" then
        title = " references + satisfied interfaces "
    else
        title = " references + implementations "
    end

    return {
        providers = {
            { "implementations", prefix = paint("green", implementation_label) },
            { "references", prefix = paint("blue", "ref  ") },
        },
        includeDeclaration = true,
        ignore_current_line = false,
        winopts = {
            title = title,
        },
    }
end

function M.open()
    local bufnr = vim.api.nvim_get_current_buf()
    if #vim.lsp.get_clients({ bufnr = bufnr }) == 0 then
        vim.notify("No LSP client attached", vim.log.levels.INFO)
        return
    end

    local fzf = require("fzf-lua")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local context = M.context(bufnr, cursor[1] - 1, cursor[2])
    fzf.lsp_finder(M.finder_opts(context, fzf.utils))
end

return M
