-- Semantic rename that finishes the job.
--
-- gopls renames across the whole workspace: a method or type in every
-- package that uses it, a package (from its `package` clause) together with
-- its import sites and directory. Neovim applies such an edit to the other
-- files only in hidden buffers, so on disk just the current file changed
-- and the build broke until every buffer was written. Here every file the
-- rename touched is written, buffers opened only for the rename are closed
-- again, and the changed places land in the quickfix list (]q / [q).
-- Local variables stay scope-aware: gopls renames only their own uses.

local M = {}

local function notify(message, level)
    vim.notify(message, level or vim.log.levels.INFO, { title = "rename" })
end

local function rename_client(bufnr)
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        if client:supports_method("textDocument/rename", bufnr) then
            return client
        end
    end
end

-- Edited positions per file and file moves from a WorkspaceEdit.
local function collect(edit)
    local edits, moves = {}, {}
    local function add(uri, list)
        local path = vim.uri_to_fname(uri)
        edits[path] = edits[path] or {}
        for _, text_edit in ipairs(list) do
            table.insert(edits[path], text_edit.range.start)
        end
    end
    for uri, list in pairs(edit.changes or {}) do
        add(uri, list)
    end
    for _, change in ipairs(edit.documentChanges or {}) do
        if change.textDocument then
            add(change.textDocument.uri, change.edits)
        elseif change.kind == "rename" then
            moves[vim.uri_to_fname(change.oldUri)] = vim.uri_to_fname(change.newUri)
        end
    end
    return edits, moves
end

-- A file's path after the moves of the same edit (file or its directory).
local function moved(path, moves)
    for old, new in pairs(moves) do
        if path == old then
            return new
        end
        if path:sub(1, #old + 1) == old .. "/" then
            return new .. path:sub(#old + 1)
        end
    end
    return path
end

-- gopls removes a moved package's old directory with a non-recursive
-- delete, which Neovim's file delete refuses for any directory. Take those
-- out of the edit and remove the directory only when it is empty: files the
-- move did not cover (testdata, assets) are never deleted.
local function split_directory_deletes(edit)
    local dirs = {}
    if not edit.documentChanges then
        return dirs
    end
    local kept = {}
    for _, change in ipairs(edit.documentChanges) do
        local path = change.kind == "delete" and vim.uri_to_fname(change.uri)
        local recursive = change.options and change.options.recursive
        if path and not recursive and vim.fn.isdirectory(path) == 1 then
            table.insert(dirs, path)
        else
            table.insert(kept, change)
        end
    end
    edit.documentChanges = kept
    return dirs
end

local function shown_in_window(bufnr)
    return #vim.fn.win_findbuf(bufnr) > 0
end

-- Apply a rename result, write what changed, report.
function M.apply(client, result, old_name, new_name)
    local before = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            before[bufnr] = vim.api.nvim_buf_get_changedtick(bufnr)
        end
    end

    local edits, moves = collect(result)
    local dirs = split_directory_deletes(result)
    local applied, apply_err = pcall(vim.lsp.util.apply_workspace_edit, result, client.offset_encoding)

    local kept_dirs = {}
    for _, dir in ipairs(dirs) do
        if not vim.uv.fs_rmdir(dir) then
            table.insert(kept_dirs, vim.fn.fnamemodify(dir, ":~:."))
        end
    end

    -- Write every buffer the edit changed or moved; close the ones that
    -- were loaded only for it.
    local written, failed = 0, {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
            local touched = before[bufnr] == nil
                or before[bufnr] ~= vim.api.nvim_buf_get_changedtick(bufnr)
            if touched and vim.bo[bufnr].modified then
                local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
                    vim.cmd("silent update")
                end)
                if ok then
                    written = written + 1
                else
                    table.insert(failed, vim.api.nvim_buf_get_name(bufnr) .. ": " .. tostring(err))
                end
            end
            if before[bufnr] == nil and not vim.bo[bufnr].modified and not shown_in_window(bufnr) then
                pcall(vim.api.nvim_buf_delete, bufnr, {})
            end
        end
    end

    -- Changed places, with paths after any directory move.
    local items, files = {}, 0
    for path, positions in pairs(edits) do
        files = files + 1
        local final = moved(path, moves)
        local lines = vim.fn.filereadable(final) == 1 and vim.fn.readfile(final) or {}
        for _, position in ipairs(positions) do
            table.insert(items, {
                filename = final,
                lnum = position.line + 1,
                col = position.character + 1,
                text = vim.trim(lines[position.line + 1] or ""),
            })
        end
    end
    table.sort(items, function(a, b)
        if a.filename ~= b.filename then
            return a.filename < b.filename
        end
        return a.lnum < b.lnum
    end)
    local title = string.format("rename %s → %s", old_name, new_name)
    vim.fn.setqflist({}, " ", { title = title, items = items })

    if not applied then
        table.insert(failed, 1, "edit not fully applied: " .. tostring(apply_err))
    end
    if #failed > 0 then
        notify("Rename incomplete (see :copen):\n" .. table.concat(failed, "\n"), vim.log.levels.ERROR)
        return
    end
    if #kept_dirs > 0 then
        notify("Old directory kept, it still has other files: " .. table.concat(kept_dirs, ", "), vim.log.levels.WARN)
    end
    notify(string.format(
        "%s → %s: %d place%s in %d file%s, saved%s (quickfix: ]q)",
        old_name,
        new_name,
        #items,
        #items == 1 and "" or "s",
        files,
        files == 1 and "" or "s",
        next(moves) and ", files moved" or ""
    ))
    return { places = #items, files = files, written = written }
end

-- Rename the symbol under the cursor to new_name (asked for when nil).
function M.rename(new_name)
    local bufnr = vim.api.nvim_get_current_buf()
    local client = rename_client(bufnr)
    if not client then
        notify("No LSP client with rename support", vim.log.levels.WARN)
        return
    end

    local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
    local old_name = vim.fn.expand("<cword>")

    local function run(name)
        if not name or name == "" or name == old_name then
            return
        end
        params.newName = name
        client:request("textDocument/rename", params, function(err, result)
            if err then
                notify("Rename failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
                return
            end
            if not result then
                notify("Nothing to rename here", vim.log.levels.WARN)
                return
            end
            M.apply(client, result, old_name, name)
        end, bufnr)
    end

    if new_name then
        run(new_name)
        return
    end

    -- prepareRename tells whether the position can be renamed (a builtin,
    -- a keyword or a comment cannot) and gives the current name.
    if not client:supports_method("textDocument/prepareRename", bufnr) then
        vim.ui.input({ prompt = "New name: ", default = old_name }, run)
        return
    end
    client:request("textDocument/prepareRename", params, function(err, result)
        if err or not result then
            notify("Cannot rename here" .. (err and (": " .. tostring(err.message or err)) or ""), vim.log.levels.WARN)
            return
        end
        if type(result) == "table" and result.placeholder then
            old_name = result.placeholder
        end
        vim.ui.input({ prompt = "New name: ", default = old_name }, run)
    end, bufnr)
end

return M
