-- Space gm on a type: implement an interface. The interfaces of the project
-- are listed (the AST helper, as Alt-k in Space sS); the chosen one lands
-- as `var _ Iface = (*Type)(nil)` after the type, and gopls writes every
-- missing method above it with its signature, a doc comment and a
-- `panic("unimplemented")` body to fill in (its "Declare missing methods"
-- fix). An interface
-- of another package is typed with its package (`:GoImpl io.Reader`): the
-- assertion stays as the documented promise that the type satisfies it.
local M = {}

local ts = vim.treesitter

-- The type declaration around the cursor: name, the row after which to
-- insert (0-based, end of the declaration), or the word under the cursor
-- with the current row.
function M.type_at_cursor(buffer, row, col)
    local ok, parser = pcall(ts.get_parser, buffer, "go")
    if ok and parser then
        local tree = parser:parse()[1]
        local node = tree and tree:root():named_descendant_for_range(row, col, row, col)
        while node do
            if node:type() == "type_spec" then
                local name = node:field("name")[1]
                local declaration = node:parent()
                local _, _, end_row = declaration:range()
                return ts.get_node_text(name, buffer), end_row
            end
            node = node:parent()
        end
    end
    local word = vim.fn.expand("<cword>")
    if word == "" or not word:match("^[%a_][%w_]*$") then
        return nil
    end
    return word, row
end

-- The assertion line and the row it is written at.
function M.assertion(interface, type_name)
    return string.format("var _ %s = (*%s)(nil)", interface, type_name)
end

-- The "declare missing methods" action among the code actions.
function M.missing_methods_action(actions)
    for _, action in ipairs(actions or {}) do
        local title = (action.title or ""):lower()
        if title:find("missing method", 1, true) or title:find("implement", 1, true) then
            return action
        end
    end
    return nil
end

local function notify(text, level)
    vim.notify(text, level or vim.log.levels.INFO)
end

-- Insert the assertion after `row`, write the buffer, and once gopls
-- reports the type as incomplete apply its fix; done(err) at the end.
function M.implement(buffer, interface, type_name, row, done)
    local line = M.assertion(interface, type_name)
    vim.api.nvim_buf_set_lines(buffer, row + 1, row + 1, false, { "", line })
    local target = row + 2
    vim.api.nvim_buf_call(buffer, function()
        vim.cmd.write()
    end)
    local client = vim.lsp.get_clients({ bufnr = buffer, name = "gopls" })[1]
    if not client then
        notify("gopls is not attached: the assertion is written, the methods are not", vim.log.levels.WARN)
        if done then
            done("no gopls")
        end
        return
    end
    local attempts = 0
    local function try()
        attempts = attempts + 1
        -- The fix wants the range of the "does not implement" diagnostic
        -- (the `(*T)(nil)` expression), not the whole line.
        local diagnostics = vim.diagnostic.get(buffer, { lnum = target })
        if #diagnostics == 0 then
            if attempts < 40 then
                vim.defer_fn(try, 250)
                return
            end
            notify(string.format("%s already satisfies %s, or gopls reported nothing", type_name, interface))
            if done then
                done("no diagnostic")
            end
            return
        end
        local first = diagnostics[1]
        local params = {
            textDocument = { uri = vim.uri_from_bufnr(buffer) },
            range = {
                start = { line = first.lnum, character = first.col },
                ["end"] = { line = first.end_lnum or first.lnum, character = first.end_col or first.col },
            },
            context = { diagnostics = vim.lsp.diagnostic.from(diagnostics), only = { "quickfix" } },
        }
        client:request("textDocument/codeAction", params, function(_, actions)
            local action = M.missing_methods_action(actions)
            if not action then
                if attempts < 40 then
                    vim.defer_fn(try, 250)
                    return
                end
                notify(string.format("%s already satisfies %s, or gopls gave no fix", type_name, interface))
                if done then
                    done("no fix")
                end
                return
            end
            -- The write (and the formatting on save) outside the LSP
            -- callback, once the edit has landed.
            local function finish()
                vim.schedule(function()
                    vim.api.nvim_buf_call(buffer, function()
                        pcall(vim.cmd.write)
                    end)
                    notify(string.format("%s: methods of %s declared", type_name, interface))
                    if done then
                        done(nil)
                    end
                end)
            end
            local function apply(resolved)
                if resolved.edit then
                    vim.lsp.util.apply_workspace_edit(resolved.edit, client.offset_encoding)
                end
                if resolved.command then
                    -- gopls.apply_fix with ResolveEdits answers with the
                    -- edit instead of applying it through the server.
                    client:exec_cmd(resolved.command, { bufnr = buffer }, function(err, result)
                        if err then
                            notify("gopls could not apply the fix: " .. tostring(err.message or err), vim.log.levels.WARN)
                            if done then
                                done("apply")
                            end
                            return
                        end
                        if type(result) == "table" and (result.changes or result.documentChanges) then
                            vim.lsp.util.apply_workspace_edit(result, client.offset_encoding)
                        end
                        finish()
                    end)
                else
                    finish()
                end
            end
            if action.edit or action.command then
                apply(action)
            else
                client:request("codeAction/resolve", action, function(err, resolved)
                    if err or not resolved then
                        notify("gopls could not resolve the fix", vim.log.levels.WARN)
                        if done then
                            done("resolve")
                        end
                        return
                    end
                    apply(resolved)
                end, buffer)
            end
        end, buffer)
    end
    vim.defer_fn(try, 250)
end

-- The interfaces of the project in a picker, then implement the chosen
-- one for the type under the cursor.
function M.pick(root)
    local buffer = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local type_name, row = M.type_at_cursor(buffer, cursor[1] - 1, cursor[2])
    if not type_name then
        notify("Put the cursor on a type", vim.log.levels.INFO)
        return
    end
    local categories = require("categories")
    categories.declarations({ root = root, category = "all" }, function(list, err)
        if not list then
            notify("Interfaces need the AST helper (./install.sh builds it): " .. tostring(err), vim.log.levels.WARN)
            return
        end
        local fzf = require("fzf-lua")
        local lines, by_line = {}, {}
        for _, declaration in ipairs(list) do
            if declaration.kind == "interface" and declaration.name ~= type_name then
                local shown = string.format("%s  %s", declaration.name, fzf.utils.ansi_codes.grey(declaration.path))
                table.insert(lines, shown)
                by_line[fzf.utils.strip_ansi_coloring(shown)] = declaration
            end
        end
        if #lines == 0 then
            notify("No interfaces in the project; :GoImpl pkg.Iface takes one by name", vim.log.levels.INFO)
            return
        end
        fzf.fzf_exec(lines, {
            prompt = "Implement> ",
            winopts = { title = string.format(" %s implements… ", type_name), fullscreen = false, height = 0.5, width = 0.6 },
            fzf_opts = { ["--no-multi"] = true },
            actions = {
                ["default"] = function(selected)
                    local declaration = by_line[fzf.utils.strip_ansi_coloring(selected[1] or "")]
                    if declaration then
                        M.implement(buffer, M.qualified(declaration, buffer, root), type_name, row)
                    end
                end,
            },
        })
    end)
end

-- The name of an interface as written from `buffer`: bare in the same
-- folder, `pkg.Name` otherwise (gopls adds the import with the fix).
function M.qualified(declaration, buffer, root)
    local own = vim.fs.dirname(vim.api.nvim_buf_get_name(buffer))
    local dir = vim.fs.dirname(root .. "/" .. declaration.path)
    if vim.fs.normalize(own) == vim.fs.normalize(dir) then
        return declaration.name
    end
    local package = declaration.package or vim.fs.basename(dir)
    return package .. "." .. declaration.name
end

-- :GoImpl io.Reader — by name.
function M.by_name(interface)
    local buffer = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local type_name, row = M.type_at_cursor(buffer, cursor[1] - 1, cursor[2])
    if not type_name then
        notify("Put the cursor on a type", vim.log.levels.INFO)
        return
    end
    M.implement(buffer, interface, type_name, row)
end

return M
