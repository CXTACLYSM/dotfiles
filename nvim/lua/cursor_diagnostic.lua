-- The diagnostics of the cursor line, never cut at the edge of the window:
-- at the end of the line while they fit there (nothing moves), otherwise
-- under the line, wrapped to the width of the window, each with its own
-- mark:
--
--       var n model.Notifier = &model.Customer{}
--       ● cannot use &model.Customer{…} (value of type *model.Customer) as
--         model.Notifier value in variable declaration: *model.Customer does
--         not implement model.Notifier (missing method Notify)
--
-- A line near the bottom of the window would show the rows under it cut
-- by the edge of the window: the window then scrolls up by the rows that
-- are missing, so the whole message is on the screen.
--
-- The other lines keep their signs and underlines only. A diagnostic
-- handler (vim.diagnostic.handlers.cursor_diagnostic, switched on in
-- vim.diagnostic.config like virtual_text), drawn for the current window
-- again when the cursor goes to another line, the window changes size or
-- the server sends new diagnostics.

local M = {}

M.opts = {
    prefix = "●",
    -- Columns between the end of the line and the message.
    spacing = 2,
    -- "if_many": the source in front of the message when the buffer has
    -- diagnostics from several sources; true always, false never.
    source = "if_many",
    -- A message under the line starts at the indent of the line, unless
    -- fewer than this many columns would be left for it.
    min_text = 40,
}

local ns = vim.api.nvim_create_namespace("cursor_diagnostic")
local group = vim.api.nvim_create_augroup("cursor_diagnostic", { clear = true })

-- bufnr → { namespaces = { [namespace] = diagnostics }, lines = { [lnum] = diagnostics }, many = boolean }
local buffers = {}
-- bufnr → what is drawn: "win:line:width"
local drawn = {}

local highlights = {
    [vim.diagnostic.severity.ERROR] = "DiagnosticVirtualTextError",
    [vim.diagnostic.severity.WARN] = "DiagnosticVirtualTextWarn",
    [vim.diagnostic.severity.INFO] = "DiagnosticVirtualTextInfo",
    [vim.diagnostic.severity.HINT] = "DiagnosticVirtualTextHint",
}

local function display_width(text)
    return vim.fn.strdisplaywidth(text)
end

-- The head of `text` at most `width` columns wide, and the rest.
local function cut(text, width)
    local chars = vim.fn.split(text, "\\zs")
    local used = 0
    for index, char in ipairs(chars) do
        local char_width = display_width(char)
        if used + char_width > width and index > 1 then
            return table.concat(chars, "", 1, index - 1), table.concat(chars, "", index)
        end
        used = used + char_width
    end
    return text, ""
end

-- `text` in rows of at most `width` columns, broken at spaces; a word
-- longer than a row is cut. Each line of the text starts a row, and its
-- rows keep its indent (the have / want lines of gopls).
function M.wrap(text, width)
    width = math.max(width, 8)
    local rows = {}
    for paragraph in vim.gsplit(text, "\n", { plain = true }) do
        paragraph = paragraph:gsub("\t", "  "):gsub("%s+$", "")
        local indent = paragraph:match("^ *"):sub(1, math.floor(width / 2))
        local room = width - #indent
        local row, row_width = nil, 0
        for word in paragraph:gmatch("%S+") do
            local word_width = display_width(word)
            if row and row_width + 1 + word_width <= room then
                row = row .. " " .. word
                row_width = row_width + 1 + word_width
            else
                if row then
                    table.insert(rows, indent .. row)
                end
                while word_width > room do
                    local head
                    head, word = cut(word, room)
                    table.insert(rows, indent .. head)
                    word_width = display_width(word)
                end
                row, row_width = word, word_width
            end
        end
        table.insert(rows, indent .. (row or ""))
    end
    -- An empty line inside the message stays, empty lines at its end go.
    while #rows > 1 and vim.trim(rows[#rows]) == "" do
        table.remove(rows)
    end
    return rows
end

local function message(diagnostic, with_source)
    local text = diagnostic.message:gsub("\r", "")
    if with_source and diagnostic.source and diagnostic.source ~= "" then
        text = diagnostic.source .. ": " .. text
    end
    return text
end

-- The drawing for the diagnostics of a line (the most severe first):
-- { virt_text } at the end of the line when they fit there, else
-- { virt_lines } under it. opts: `line_width`, the width of the line on its
-- last screen row; `indent`, its indent; `text_width`, the columns of the
-- window for text; `source`, the source in front of each message.
function M.layout(diagnostics, opts)
    local prefix = M.opts.prefix
    local with_source = opts.source
    local chunks = { { string.rep(" ", M.opts.spacing) } }
    local eol_width = M.opts.spacing
    for index, diagnostic in ipairs(diagnostics) do
        local text = prefix .. " " .. message(diagnostic, with_source):gsub("\n%s*", "  ")
        if index > 1 then
            table.insert(chunks, { "  " })
            eol_width = eol_width + 2
        end
        table.insert(chunks, { text, highlights[diagnostic.severity] })
        eol_width = eol_width + display_width(text)
    end
    if opts.line_width + eol_width <= opts.text_width then
        return { virt_text = chunks }
    end

    local mark_width = display_width(prefix) + 1
    local indent = math.max(0, math.min(opts.indent, opts.text_width - mark_width - M.opts.min_text))
    local room = opts.text_width - indent - mark_width - 1
    local lines = {}
    for _, diagnostic in ipairs(diagnostics) do
        local hl = highlights[diagnostic.severity]
        local rows = M.wrap(message(diagnostic, with_source), room)
        -- One block per message: its rows padded to the widest, so the
        -- background of the highlight is even.
        local widest = 0
        for _, row in ipairs(rows) do
            widest = math.max(widest, display_width(row))
        end
        for index, row in ipairs(rows) do
            table.insert(lines, {
                { string.rep(" ", indent) },
                { index == 1 and (prefix .. " ") or string.rep(" ", mark_width), hl },
                { row .. string.rep(" ", widest - display_width(row)), hl },
            })
        end
    end
    return { virt_lines = lines }
end

-- The window the diagnostics of `bufnr` are drawn for: the current one
-- when it shows the buffer, else the first that does.
local function window_of(bufnr)
    local current = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(current) == bufnr then
        return current
    end
    local win = vim.fn.bufwinid(bufnr)
    return win ~= -1 and win or nil
end

-- The `extra` rows under line `lnum` (0-based) of `win` on the screen: a
-- line near the bottom of the window shows its message cut by the edge, so
-- the window scrolls up by the rows that are missing. The line itself
-- stays at least 'scrolloff' rows from the top, as after any scroll.
-- (nvim_win_text_height leaves out the virtual lines under its last row,
-- so they are counted here.)
function M.reveal(win, lnum, extra)
    local info = vim.fn.getwininfo(win)[1]
    local height = info.height
    local topline = info.topline
    local function rows(top)
        return vim.api.nvim_win_text_height(win, { start_row = top - 1, end_row = lnum }).all + extra
    end
    if topline > lnum + 1 or rows(topline) <= height then
        return false
    end
    local scrolloff = vim.wo[win].scrolloff
    if scrolloff < 0 then
        scrolloff = vim.go.scrolloff
    end
    local top_most = math.max(topline, lnum + 1 - math.min(scrolloff, math.floor((height - 1) / 2)))
    while topline < top_most and rows(topline) > height do
        topline = topline + 1
    end
    if topline == info.topline then
        return false
    end
    vim.api.nvim_win_call(win, function()
        vim.fn.winrestview({ topline = topline })
    end)
    return true
end

local function draw(bufnr, force)
    local state = buffers[bufnr]
    if not state or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    local win = window_of(bufnr)
    if not win then
        return
    end
    local lnum = vim.api.nvim_win_get_cursor(win)[1] - 1
    local info = vim.fn.getwininfo(win)[1]
    local text_width = info.width - info.textoff
    local key = table.concat({ win, lnum, text_width }, ":")
    if not force and drawn[bufnr] == key then
        return
    end
    drawn[bufnr] = key
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

    local diagnostics = state.lines[lnum]
    if not diagnostics or lnum >= vim.api.nvim_buf_line_count(bufnr) then
        return
    end
    -- nvim_win_call hands back one value.
    local view = vim.api.nvim_win_call(win, function()
        return {
            width = vim.fn.virtcol({ lnum + 1, "$" }) - 1,
            indent = vim.fn.indent(lnum + 1),
            leftcol = vim.fn.winsaveview().leftcol,
        }
    end)
    local line_width, indent, leftcol = view.width, view.indent, view.leftcol
    -- A wrapped line ends on its last screen row; with nowrap the window
    -- may be scrolled sideways.
    if vim.wo[win].wrap then
        if line_width > text_width then
            line_width = line_width % text_width
        end
    else
        line_width = line_width - leftcol
    end
    local layout = M.layout(diagnostics, {
        source = state.many,
        line_width = line_width,
        indent = indent,
        text_width = text_width,
    })
    vim.api.nvim_buf_set_extmark(bufnr, ns, lnum, 0, {
        virt_text = layout.virt_text,
        virt_text_pos = layout.virt_text and "eol" or nil,
        virt_lines = layout.virt_lines,
        hl_mode = "combine",
    })
    if layout.virt_lines then
        M.reveal(win, lnum, #layout.virt_lines)
    end
end

local function rebuild(bufnr)
    local state = buffers[bufnr]
    local lines, sources, count = {}, {}, 0
    for _, diagnostics in pairs(state.namespaces) do
        for _, diagnostic in ipairs(diagnostics) do
            lines[diagnostic.lnum] = lines[diagnostic.lnum] or {}
            table.insert(lines[diagnostic.lnum], diagnostic)
            if diagnostic.source and not sources[diagnostic.source] then
                sources[diagnostic.source] = true
                count = count + 1
            end
        end
    end
    for _, list in pairs(lines) do
        table.sort(list, function(a, b)
            if a.severity ~= b.severity then
                return a.severity < b.severity
            end
            return a.col < b.col
        end)
    end
    state.lines = lines
    local source = state.source
    if source == nil then
        source = M.opts.source
    end
    state.many = source == true or (source == "if_many" and count > 1)
    if next(state.namespaces) == nil then
        buffers[bufnr] = nil
        drawn[bufnr] = nil
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
        end
        return
    end
    draw(bufnr, true)
end

local function buffer_number(bufnr)
    return (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
end

M.handler = {
    show = function(namespace, bufnr, diagnostics, opts)
        bufnr = buffer_number(bufnr)
        local state = buffers[bufnr] or { namespaces = {}, lines = {}, many = false }
        buffers[bufnr] = state
        state.namespaces[namespace] = diagnostics
        local handler_opts = opts and opts.cursor_diagnostic
        if type(handler_opts) == "table" and handler_opts.source ~= nil then
            state.source = handler_opts.source
        end
        rebuild(bufnr)
    end,
    hide = function(namespace, bufnr)
        bufnr = buffer_number(bufnr)
        local state = buffers[bufnr]
        if state then
            state.namespaces[namespace] = nil
            rebuild(bufnr)
        end
    end,
}

-- What is drawn in `bufnr`: { line (0-based), virt_text, virt_lines } or nil.
function M.drawn(bufnr)
    local mark = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })[1]
    if not mark then
        return nil
    end
    return { line = mark[2], virt_text = mark[4].virt_text, virt_lines = mark[4].virt_lines }
end

M.namespace = ns

function M.setup(user_opts)
    M.opts = vim.tbl_deep_extend("force", M.opts, user_opts or {})
    vim.diagnostic.handlers.cursor_diagnostic = M.handler

    vim.api.nvim_clear_autocmds({ group = group })
    vim.api.nvim_create_autocmd({ "CursorMoved", "BufWinEnter", "WinEnter" }, {
        group = group,
        callback = function(event)
            if buffers[event.buf] then
                draw(event.buf, false)
            end
        end,
    })
    vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "OptionSet" }, {
        group = group,
        callback = function(event)
            if event.event == "OptionSet"
                and not vim.tbl_contains({ "wrap", "number", "relativenumber", "signcolumn", "numberwidth" }, event.match)
            then
                return
            end
            for bufnr in pairs(buffers) do
                draw(bufnr, true)
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        callback = function(event)
            buffers[event.buf] = nil
            drawn[event.buf] = nil
        end,
    })
end

return M
