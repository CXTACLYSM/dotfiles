-- Shared floating view for the return graph and the call graph:
-- a tree on the left, a live source preview on the right, like the fzf-lua
-- `grr` picker. Moving the cursor in the tree scrolls the preview to the
-- selected node; Enter (and other per-entry keys) jump into the code.
--
-- The preview is a scratch buffer filled with the target file's lines and
-- Tree-sitter highlighting, so previewing never loads files into the
-- buffer list or attaches LSP clients.

local M = {}

M.defaults = {
    -- The tree takes its natural width; the preview gets the rest but at
    -- least this fraction of the available width, so a wide tree is capped
    -- rather than the preview squeezed out.
    preview_ratio = 0.35,
    min_tree_width = 30,
    min_preview_width = 24,
    preview_context = 6,
}

local namespace = vim.api.nvim_create_namespace("graph_view")
local preview_namespace = vim.api.nvim_create_namespace("graph_view_preview")

-- ============================================================
-- Target helpers
-- ============================================================

-- A target is { bufnr = number } or { path = string }, plus line (1-based)
-- and col (0-based).
local function target_lines(target)
    local bufnr = target.bufnr
    if not bufnr and target.path then
        local existing = vim.fn.bufnr(target.path)
        if existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) then
            bufnr = existing
        end
    end

    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
            vim.bo[bufnr].filetype,
            vim.api.nvim_buf_get_name(bufnr)
    end

    if target.path then
        local ok, lines = pcall(vim.fn.readfile, target.path)
        if ok then
            local filetype = vim.filetype.match({ filename = target.path }) or ""
            return lines, filetype, target.path
        end
    end

    return {}, "", ""
end

local function target_path(target)
    if target.path then
        return target.path
    end
    if target.bufnr and vim.api.nvim_buf_is_valid(target.bufnr) then
        return vim.api.nvim_buf_get_name(target.bufnr)
    end
    return ""
end

-- ============================================================
-- Preview
-- ============================================================

local function fill_preview(state, target)
    local buf = state.preview_buf
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
    end

    local path = target and target_path(target) or ""
    local lines, filetype = {}, ""
    if target then
        lines, filetype = target_lines(target)
    end

    if state.preview_path ~= path then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        state.preview_path = path

        pcall(vim.treesitter.stop, buf)
        if filetype ~= "" then
            local language = vim.treesitter.language.get_lang(filetype) or filetype
            pcall(vim.treesitter.start, buf, language)
        end
    end

    local win = state.preview_win
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end

    vim.api.nvim_buf_clear_namespace(buf, preview_namespace, 0, -1)
    local title = " " .. (path ~= "" and vim.fs.basename(path) or "preview") .. " "

    if target and target.line and #lines > 0 then
        local line = math.max(1, math.min(target.line, #lines))
        vim.api.nvim_buf_set_extmark(buf, preview_namespace, line - 1, 0, {
            line_hl_group = "Visual",
            priority = 200,
        })
        vim.api.nvim_win_set_cursor(win, { line, math.min(target.col or 0, #(lines[line] or "")) })
        vim.api.nvim_win_call(win, function()
            vim.cmd("normal! zz")
        end)
        title = title .. line .. " "
    end

    pcall(vim.api.nvim_win_set_config, win, { title = title, title_pos = "left" })
end

-- ============================================================
-- Layout
-- ============================================================

local function layout(lines, footer, title, opts)
    local natural = 0
    for _, line in ipairs(lines) do
        natural = math.max(natural, vim.fn.strdisplaywidth(line))
    end
    natural = math.max(natural, vim.fn.strdisplaywidth(footer) + 2, vim.fn.strdisplaywidth(title) + 2) + 2

    local total = vim.o.columns - 4
    local height = math.max(math.min(#lines, vim.o.lines - 6), 3)

    -- The preview needs its own border column pair plus a usable body.
    local preferred_preview = math.max(opts.min_preview_width, math.floor(total * opts.preview_ratio))
    local tree_width = math.min(natural, total - preferred_preview - 2)
    local with_preview = tree_width >= math.min(opts.min_tree_width, natural)
    local preview_width = 0
    if with_preview then
        preview_width = total - tree_width - 2
    else
        tree_width = math.min(natural, total)
    end

    local row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0)
    local col = math.floor((vim.o.columns - (tree_width + (with_preview and preview_width + 2 or 0))) / 2)

    return {
        height = height,
        row = row,
        tree = { width = tree_width, col = col },
        preview = with_preview and { width = preview_width, col = col + tree_width + 2 } or nil,
    }
end

-- ============================================================
-- Open
-- ============================================================

-- spec = {
--   title = string, footer = string, filetype = string,
--   lines = { string }, entries = { { highlights = {{hl, start, stop}},
--                                    preview = target?, jumps = { key = target } } },
--   source_win = number?,
--   keys = { [lhs] = function(ctx) end }?  -- ctx = { row, close, win }
--   cursor_row = number?,
--   folds = { { first, last } }?,  -- 1-based rows of groups that fold
--   folded = boolean?,             -- start with the groups closed
-- }
-- A row without a target for the pressed key (a group header) opens or
-- closes its fold instead; zM / zR / za work as in a file.
-- Returns the tree window and the preview window (nil when there is no room).
function M.open(spec, user_opts)
    local opts = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
    local state = { source_win = spec.source_win or vim.api.nvim_get_current_win() }

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, spec.lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = spec.filetype or "graphview"

    for index, entry in ipairs(spec.entries) do
        for _, hl in ipairs(entry.highlights or {}) do
            vim.api.nvim_buf_set_extmark(buf, namespace, index - 1, hl[2], {
                end_col = hl[3],
                hl_group = hl[1],
            })
        end
    end

    local geometry = layout(spec.lines, spec.footer or "", spec.title or "", opts)

    if geometry.preview then
        local preview_buf = vim.api.nvim_create_buf(false, true)
        vim.bo[preview_buf].bufhidden = "wipe"
        vim.bo[preview_buf].buftype = "nofile"
        vim.bo[preview_buf].swapfile = false
        vim.bo[preview_buf].modifiable = false
        state.preview_buf = preview_buf

        state.preview_win = vim.api.nvim_open_win(preview_buf, false, {
            relative = "editor",
            width = geometry.preview.width,
            height = geometry.height,
            row = geometry.row,
            col = geometry.preview.col,
            style = "minimal",
            border = "rounded",
            title = " preview ",
            title_pos = "left",
            focusable = false,
        })
        vim.wo[state.preview_win].number = true
        vim.wo[state.preview_win].cursorline = false
        vim.wo[state.preview_win].wrap = false
        vim.wo[state.preview_win].scrolloff = opts.preview_context
        vim.wo[state.preview_win].signcolumn = "no"
    end

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = geometry.tree.width,
        height = geometry.height,
        row = geometry.row,
        col = geometry.tree.col,
        style = "minimal",
        border = "rounded",
        title = " " .. (spec.title or "") .. " ",
        title_pos = "left",
        footer = spec.footer and (" " .. spec.footer .. " ") or nil,
        footer_pos = spec.footer and "right" or nil,
    })
    vim.wo[win].cursorline = true
    vim.wo[win].wrap = false
    state.win = win

    local closing = false
    local function close()
        if closing then
            return
        end
        closing = true
        if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
            vim.api.nvim_win_close(state.preview_win, true)
        end
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    local function current_entry()
        return spec.entries[vim.api.nvim_win_get_cursor(win)[1]]
    end

    local function refresh_preview()
        local entry = current_entry()
        fill_preview(state, entry and entry.preview or nil)
    end

    local function jump(target)
        close()
        if not target then
            return
        end

        local source_win = state.source_win
        if vim.api.nvim_win_is_valid(source_win) then
            vim.api.nvim_set_current_win(source_win)
        end

        local bufnr = target.bufnr
        if not bufnr and target.path then
            bufnr = vim.fn.bufadd(target.path)
        end
        if not bufnr then
            return
        end

        vim.cmd("normal! m'")
        if vim.api.nvim_get_current_buf() ~= bufnr then
            vim.fn.bufload(bufnr)
            vim.bo[bufnr].buflisted = true
            vim.api.nvim_set_current_buf(bufnr)
        end

        local last_line = vim.api.nvim_buf_line_count(bufnr)
        local line = math.max(1, math.min(target.line or 1, last_line))
        local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
        vim.api.nvim_win_set_cursor(0, { line, math.min(target.col or 0, math.max(#text - 1, 0)) })
        vim.cmd("normal! zz")
    end

    for _, key in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", key, close, { buffer = buf, nowait = true })
    end

    local keys = {}
    for _, entry in ipairs(spec.entries) do
        for key in pairs(entry.jumps or {}) do
            keys[key] = true
        end
    end
    for key in pairs(keys) do
        vim.keymap.set("n", key, function()
            local entry = current_entry()
            local target = entry and entry.jumps and entry.jumps[key] or nil
            if target then
                jump(target)
            elseif vim.fn.foldlevel(vim.api.nvim_win_get_cursor(win)[1]) > 0 then
                vim.cmd("normal! za")
            end
        end, { buffer = buf, nowait = true })
    end

    -- View-level keys (change depth, flip direction, filter) get the current
    -- row and a close function; they usually close and reopen the view.
    for key, handler in pairs(spec.keys or {}) do
        vim.keymap.set("n", key, function()
            handler({
                row = vim.api.nvim_win_get_cursor(win)[1],
                close = close,
                win = win,
            })
        end, { buffer = buf, nowait = true })
    end

    if spec.folds then
        vim.wo[win].foldmethod = "manual"
        vim.wo[win].foldenable = true
        vim.wo[win].foldtext = ""
        vim.wo[win].fillchars = "eob: ,fold: "
        vim.api.nvim_win_call(win, function()
            for _, fold in ipairs(spec.folds) do
                if fold[2] > fold[1] then
                    vim.cmd(string.format("%d,%dfold", fold[1], fold[2]))
                end
            end
            vim.cmd(spec.folded and "normal! zM" or "normal! zR")
        end)
    end

    if spec.cursor_row then
        local row = math.max(1, math.min(spec.cursor_row, #spec.lines))
        vim.api.nvim_win_set_cursor(win, { row, 0 })
    end

    local group = vim.api.nvim_create_augroup("graph_view_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd("CursorMoved", {
        group = group,
        buffer = buf,
        callback = refresh_preview,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        pattern = tostring(win),
        once = true,
        callback = function()
            vim.schedule(close)
        end,
    })

    refresh_preview()
    return win, state.preview_win
end

return M
