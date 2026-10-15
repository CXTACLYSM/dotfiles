-- Peek: the definition (or the type definition) of the symbol under the
-- cursor in a float next to it, without leaving the current place.
--
-- The float shows the whole declaration with its doc comment; for a struct
-- field or an interface method, the whole type with that line marked; for a
-- local variable, a few lines around it. Enter jumps there (jumplist and
-- tagstack, so Ctrl-o / Ctrl-t come back), q closes, moving the cursor in
-- the source window closes it, and pressing the key again focuses the float
-- to scroll a long body.

local M = {}

M.opts = {
    max_width = 110,
    max_height = 24,
    -- Lines around a declaration that is a single line (a local variable).
    context = 3,
    -- Longest declaration copied into the float.
    max_lines = 400,
}

local namespace = vim.api.nvim_create_namespace("peek")

-- Node types that are a declaration worth showing whole.
local declarations = {
    function_declaration = true,
    method_declaration = true,
    type_declaration = true,
    const_declaration = true,
    var_declaration = true,
    import_declaration = true,
    package_clause = true,
}

local function notify(message, level)
    vim.notify(message, level or vim.log.levels.INFO, { title = "peek" })
end

local function file_lines(path)
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines or nil
end

-- Rows (0-based, inclusive) of the declaration around `row`: a function,
-- a type with all its fields (a struct field or an interface method shows
-- its whole type), a const/var block. nil for a local name (the search stops
-- at a function body) and when the language has no parser.
local function declaration_rows(text, lang, row, col)
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    if not ok or not parser then
        return nil
    end
    local tree = parser:parse()[1]
    if not tree then
        return nil
    end
    local node = tree:root():named_descendant_for_range(row, col, row, col)
    while node do
        local type = node:type()
        if type == "block" then
            return nil
        end
        if declarations[type] then
            local start_row, _, end_row, end_col = node:range()
            -- A range ending at column 0 stops before that line.
            if end_col == 0 and end_row > start_row then
                end_row = end_row - 1
            end
            return start_row, end_row
        end
        node = node:parent()
    end
    return nil
end

-- First row of the doc comment directly above `row`.
local function comment_start(lines, row)
    local first = row
    while first > 0 and vim.trim(lines[first]):sub(1, 2) == "//" do
        first = first - 1
    end
    return first
end

local function relative(path)
    local cwd = vim.fn.getcwd()
    return vim.fs.relpath(cwd, path) or vim.fn.fnamemodify(path, ":~")
end

local function location_of(result)
    local location = result
    if vim.islist(result) then
        location = result[1]
    end
    if not location then
        return nil, 0
    end
    local uri = location.uri or location.targetUri
    local range = location.targetSelectionRange or location.range or location.targetRange
    return { uri = uri, range = range }, vim.islist(result) and #result or 1
end

local function open(client, location, count, kind)
    local path = vim.uri_to_fname(location.uri)
    local lines = file_lines(path)
    if not lines or #lines == 0 then
        notify("Cannot read " .. path, vim.log.levels.WARN)
        return
    end

    local row = location.range.start.line
    local text_line = lines[row + 1] or ""
    local col = vim.str_byteindex(text_line, client.offset_encoding, location.range.start.character, false)

    local filetype = vim.filetype.match({ filename = path }) or ""
    local lang = vim.treesitter.language.get_lang(filetype) or filetype
    local first, last = declaration_rows(table.concat(lines, "\n"), lang, row, col)
    if not first then
        first, last = row, row
    end
    if first == last then
        first = math.max(0, first - M.opts.context)
        last = math.min(#lines - 1, last + M.opts.context)
    else
        first = comment_start(lines, first)
    end
    last = math.min(last, first + M.opts.max_lines - 1)

    local shown = vim.list_slice(lines, first + 1, last + 1)
    local title = string.format(" %s · %s:%d%s ",
        kind,
        relative(path),
        row + 1,
        count > 1 and string.format(" (1/%d)", count) or "")

    local source_win = vim.api.nvim_get_current_win()
    local bufnr, win = vim.lsp.util.open_floating_preview(shown, nil, {
        focus_id = "peek_" .. kind,
        border = "rounded",
        title = title,
        title_pos = "left",
        wrap = false,
        max_width = math.min(M.opts.max_width, vim.o.columns - 4),
        max_height = math.min(M.opts.max_height, math.floor(vim.o.lines * 0.6)),
    })
    if not win or not vim.api.nvim_win_is_valid(win) or win == source_win then
        return
    end

    -- Real line numbers of the file next to the slice.
    vim.wo[win].number = true
    vim.wo[win].statuscolumn = "%=%{v:lnum + " .. first .. "} "
    vim.wo[win].cursorline = false
    if lang ~= "" and pcall(vim.treesitter.language.add, lang) then
        pcall(vim.treesitter.start, bufnr, lang)
    end

    -- Mark the defining line and keep it in view.
    local target = row - first
    vim.api.nvim_buf_set_extmark(bufnr, namespace, target, 0, {
        line_hl_group = "CursorLine",
    })
    pcall(vim.api.nvim_win_set_cursor, win, { target + 1, 0 })

    vim.keymap.set("n", "<CR>", function()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
        if vim.api.nvim_win_is_valid(source_win) then
            vim.api.nvim_set_current_win(source_win)
        end
        vim.lsp.util.show_document(location, client.offset_encoding, { focus = true })
        vim.cmd("normal! zz")
    end, { buffer = bufnr, nowait = true, desc = "Jump to the peeked definition" })

    return bufnr, win
end

local function peek(method, kind)
    local bufnr = vim.api.nvim_get_current_buf()
    local client
    for _, candidate in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        if candidate:supports_method(method, bufnr) then
            client = candidate
            break
        end
    end
    if not client then
        notify("No LSP client for " .. kind, vim.log.levels.INFO)
        return
    end

    -- Pressing the key again while its float is open focuses it.
    local existing = vim.b[bufnr].lsp_floating_preview
    if existing and vim.api.nvim_win_is_valid(existing) and vim.w[existing]["peek_" .. kind] then
        vim.api.nvim_set_current_win(existing)
        return
    end

    local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
    client:request(method, params, function(err, result)
        if err then
            notify(kind .. " failed: " .. tostring(err.message or err), vim.log.levels.WARN)
            return
        end
        local location, count = location_of(result)
        if not location or not location.uri or not location.range then
            notify("No " .. kind .. " found")
            return
        end
        open(client, location, count, kind)
    end, bufnr)
end

function M.definition()
    peek("textDocument/definition", "definition")
end

function M.type_definition()
    peek("textDocument/typeDefinition", "type")
end

M._declaration_rows = declaration_rows
M._comment_start = comment_start

return M
