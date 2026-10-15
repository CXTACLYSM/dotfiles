-- Peek: the definition, type definition or implementation of the symbol
-- under the cursor in a float next to it, without leaving the current place.
--
-- The float shows the whole declaration with its doc comment; for a struct
-- field or an interface method, the whole type with that line marked; for a
-- local name, a few lines around it.
--
-- Inside the float the same keys go one level deeper on the name under the
-- cursor (gp definition, gP type, gI implementation) and Backspace comes
-- back, so a chain like handler → service → repository reads in one place.
-- Enter opens the line under the cursor in the editor (jumplist and
-- tagstack, so Ctrl-o / Ctrl-t come back), q closes. Moving the cursor in
-- the source window closes the float; the key pressed again focuses it.
--
-- gI on a call through an interface shows the implementation. Mocks and
-- test files are set aside when one real implementation remains; with
-- several real ones a picker with a preview opens instead.

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

local methods = {
    definition = "textDocument/definition",
    type = "textDocument/typeDefinition",
    implementation = "textDocument/implementation",
}

local keys = {
    definition = "gp",
    type = "gP",
    implementation = "gI",
}

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

-- The open float, or nil:
-- { win, buf, source_win, source_buf, client, kind, view, stack, anchor,
--   below, lang, group }
local state = nil

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
    return vim.fs.relpath(vim.fn.getcwd(), path) or vim.fn.fnamemodify(path, ":~")
end

-- Mocks, fakes and test files: implementations that are rarely the one
-- you are looking for.
local function is_double(path)
    local lower = path:lower()
    return lower:match("_test%.go$") ~= nil
        or lower:match("/mocks?/") ~= nil
        or lower:match("/fakes?/") ~= nil
        or lower:match("mock[^/]*%.go$") ~= nil
end

-- Location | Location[] | LocationLink[] → { { uri, range } }.
local function locations(result)
    if not result then
        return {}
    end
    if not vim.islist(result) then
        result = { result }
    end
    local list = {}
    for _, item in ipairs(result) do
        local uri = item.uri or item.targetUri
        local range = item.targetSelectionRange or item.range or item.targetRange
        if uri and range then
            table.insert(list, { uri = uri, range = range })
        end
    end
    return list
end

local function client_for(bufnr, method)
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        if client:supports_method(method, bufnr) then
            return client
        end
    end
    return nil
end

-- ============================================================
-- Views
-- ============================================================

-- What the float shows for one location: the lines, where they start in
-- the file, and the target name.
local function build_view(client, location, kind, note)
    local path = vim.uri_to_fname(location.uri)
    local lines = file_lines(path)
    if not lines or #lines == 0 then
        return nil, "Cannot read " .. path
    end

    local encoding = client.offset_encoding
    local row = math.min(location.range.start.line, #lines - 1)
    local text_line = lines[row + 1] or ""
    local col = vim.str_byteindex(text_line, encoding, location.range.start.character, false)
    local end_col = col
    local stop = location.range["end"]
    if stop and stop.line == location.range.start.line then
        end_col = vim.str_byteindex(text_line, encoding, stop.character, false)
    end

    local filetype = vim.filetype.match({ filename = path }) or ""
    local lang = vim.treesitter.language.get_lang(filetype) or filetype
    local first, last = declaration_rows(table.concat(lines, "\n"), lang, row, col)
    if first then
        -- A declaration, one line or many, with its doc comment.
        first = comment_start(lines, first)
    else
        -- A local name: the lines around it.
        first = math.max(0, row - M.opts.context)
        last = math.min(#lines - 1, row + M.opts.context)
    end
    last = math.min(last, first + M.opts.max_lines - 1)
    if row > last then
        first = math.max(0, row - M.opts.context)
        last = math.min(#lines - 1, row + M.opts.context)
    end

    return {
        uri = location.uri,
        path = path,
        kind = kind,
        note = note,
        lang = lang,
        lines = vim.list_slice(lines, first + 1, last + 1),
        first = first,
        row = row,
        col = col,
        end_col = end_col,
    }
end

-- File position of the cursor in the float.
local function float_position(s)
    local cursor = vim.api.nvim_win_get_cursor(s.win)
    local line = s.view.lines[cursor[1]] or ""
    return {
        line = s.view.first + cursor[1] - 1,
        character = vim.str_utfindex(line, s.client.offset_encoding, math.min(cursor[2], #line), false),
    }, cursor
end

-- ============================================================
-- Float
-- ============================================================

local function close()
    local s = state
    if not s then
        return
    end
    state = nil
    pcall(vim.api.nvim_del_augroup_by_id, s.group)
    if vim.api.nvim_win_is_valid(s.win) then
        vim.api.nvim_win_close(s.win, true)
    end
end

local function close_and_return()
    local s = state
    close()
    if s and vim.api.nvim_win_is_valid(s.source_win) then
        vim.api.nvim_set_current_win(s.source_win)
    end
end

local function title_of(s)
    local view = s.view
    return string.format(" %s%s · %s:%d%s ",
        #s.stack > 0 and (string.rep("‹", math.min(#s.stack, 3)) .. " ") or "",
        view.kind,
        relative(view.path),
        view.row + 1,
        view.note and (" · " .. view.note) or "")
end

local function footer_of(s)
    if vim.api.nvim_get_current_win() ~= s.win then
        return string.format(" %s again: focus ", keys[s.kind])
    end
    return string.format(" ⏎ open · gp gP gI deeper%s · q close ", #s.stack > 0 and " · ⌫ back" or "")
end

-- Size and place of the float for the current view. The side (below or
-- above the cursor line) is chosen once, so going deeper does not make the
-- float jump.
local function geometry(s)
    local lines = s.view.lines
    local width = 0
    vim.api.nvim_buf_call(s.buf, function()
        for _, line in ipairs(lines) do
            width = math.max(width, vim.fn.strdisplaywidth(line))
        end
    end)
    local number_width = math.max(#tostring(s.view.first + #lines), 3) + 2
    width = math.max(width + number_width + 1,
        vim.fn.strdisplaywidth(title_of(s)) + 2,
        vim.fn.strdisplaywidth(footer_of(s)) + 2)
    width = math.min(width, M.opts.max_width, vim.o.columns - 2)

    local max_height = math.min(M.opts.max_height, math.floor(vim.o.lines * 0.6))
    local rows = vim.o.lines - vim.o.cmdheight
    local below_space = rows - s.anchor.row - 3
    local above_space = s.anchor.row - 2
    if s.below == nil then
        s.below = below_space >= max_height or below_space >= above_space
    end

    local height
    local row
    if s.below then
        height = math.max(1, math.min(#lines, max_height, below_space))
        row = s.anchor.row + 1
    else
        height = math.max(1, math.min(#lines, max_height, above_space))
        row = s.anchor.row - height - 2
    end

    return {
        relative = "editor",
        row = math.max(0, row),
        col = math.max(0, math.min(s.anchor.col, vim.o.columns - width - 2)),
        width = width,
        height = height,
    }
end

local function refresh_frame(s)
    local config = geometry(s)
    config.title = title_of(s)
    config.title_pos = "left"
    config.footer = footer_of(s)
    config.footer_pos = "right"
    vim.api.nvim_win_set_config(s.win, config)
end

local function render(s)
    local view = s.view
    vim.bo[s.buf].modifiable = true
    vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, view.lines)
    vim.bo[s.buf].modifiable = false

    if s.lang ~= view.lang then
        pcall(vim.treesitter.stop, s.buf)
        s.lang = nil
        if view.lang ~= "" and pcall(vim.treesitter.language.add, view.lang)
            and pcall(vim.treesitter.start, s.buf, view.lang)
        then
            s.lang = view.lang
        end
    end

    -- Mark the target line and its name.
    local target = view.row - view.first
    vim.api.nvim_buf_clear_namespace(s.buf, namespace, 0, -1)
    local named = view.end_col > view.col
    vim.api.nvim_buf_set_extmark(s.buf, namespace, target, named and view.col or 0, {
        end_col = named and view.end_col or nil,
        hl_group = named and "LspReferenceText" or nil,
        line_hl_group = "CursorLine",
    })

    refresh_frame(s)
    -- Real line numbers of the file next to the slice.
    vim.wo[s.win].statuscolumn = "%=%{v:lnum + " .. view.first .. "} "
    pcall(vim.api.nvim_win_set_cursor, s.win, view.cursor or { target + 1, view.col })
end

local drill, back, open_here

local function open_float(client, view, kind, source_win, source_buf)
    close()

    local cursor = vim.api.nvim_win_get_cursor(source_win)
    local screen = vim.fn.screenpos(source_win, cursor[1], cursor[2] + 1)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false

    local s = {
        buf = buf,
        source_win = source_win,
        source_buf = source_buf,
        client = client,
        kind = kind,
        view = view,
        stack = {},
        anchor = { row = math.max(screen.row - 1, 0), col = math.max(screen.col - 1, 0) },
    }
    -- A placeholder frame; render() sizes and titles it.
    s.win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = 1,
        height = 1,
        style = "minimal",
        border = "rounded",
        focusable = true,
    })
    vim.wo[s.win].number = true
    vim.wo[s.win].wrap = false
    vim.wo[s.win].cursorline = false
    vim.wo[s.win].foldenable = false
    state = s
    render(s)

    local function map(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
    end
    map("gp", function()
        drill("definition")
    end, "Peek: definition of the name under the cursor")
    map("gP", function()
        drill("type")
    end, "Peek: type of the name under the cursor")
    map("gI", function()
        drill("implementation")
    end, "Peek: implementation of the name under the cursor")
    map("<BS>", back, "Peek: back")
    map("<CR>", open_here, "Peek: open this line in the editor")
    map("q", close_and_return, "Peek: close")
    map("<Esc>", close_and_return, "Peek: close")

    s.group = vim.api.nvim_create_augroup("peek_" .. s.win, { clear = true })
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertCharPre" }, {
        group = s.group,
        buffer = source_buf,
        callback = function()
            if state == s and vim.api.nvim_get_current_win() ~= s.win then
                close()
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufEnter", {
        group = s.group,
        callback = function(event)
            if state == s and event.buf ~= s.buf and event.buf ~= s.source_buf then
                close()
            end
        end,
    })
    vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
        group = s.group,
        buffer = buf,
        callback = function()
            vim.schedule(function()
                if state == s and vim.api.nvim_win_is_valid(s.win) then
                    vim.api.nvim_win_set_config(s.win, { footer = footer_of(s), footer_pos = "right" })
                end
            end)
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = s.group,
        pattern = tostring(s.win),
        once = true,
        callback = function()
            if state == s then
                state = nil
                pcall(vim.api.nvim_del_augroup_by_id, s.group)
            end
        end,
    })
end

-- ============================================================
-- Requests
-- ============================================================

-- Several implementations: a picker with a preview, real ones first.
local function pick(client, real, doubles)
    close_and_return()
    local entries = {}
    local function add(location, tag)
        local path = vim.uri_to_fname(location.uri)
        local lines = file_lines(path) or {}
        local line = lines[location.range.start.line + 1] or ""
        local col = vim.str_byteindex(line, client.offset_encoding, location.range.start.character, false)
        local shown = vim.fs.relpath(vim.fn.getcwd(), path) or path
        table.insert(entries, string.format("%s:%d:%d: %s%s",
            shown, location.range.start.line + 1, col + 1, tag, vim.trim(line)))
    end
    for _, location in ipairs(real) do
        add(location, "")
    end
    for _, location in ipairs(doubles) do
        add(location, "[mock/test] ")
    end

    local fzf = require("fzf-lua")
    fzf.fzf_exec(entries, {
        prompt = "Implementations> ",
        cwd = vim.fn.getcwd(),
        previewer = "builtin",
        actions = fzf.defaults.actions.files,
        fzf_opts = { ["--no-sort"] = true },
        winopts = { title = string.format(" %d implementations ", #entries) },
    })
end

-- Ask the server and hand one location to `done(location, note)`; several
-- implementations go to the picker.
local function request(client, kind, params, bufnr, done)
    client:request(methods[kind], params, function(err, result)
        if err then
            notify(kind .. " failed: " .. tostring(err.message or err), vim.log.levels.WARN)
            return
        end
        local list = locations(result)
        if #list == 0 then
            notify("No " .. kind .. " found")
            return
        end
        if kind ~= "implementation" then
            done(list[1], #list > 1 and string.format("1/%d", #list) or nil)
            return
        end

        local real, doubles = {}, {}
        for _, location in ipairs(list) do
            table.insert(is_double(vim.uri_to_fname(location.uri)) and doubles or real, location)
        end
        if #real == 1 then
            done(real[1], #doubles > 0 and string.format("+%d in mocks/tests", #doubles) or nil)
        elseif #real == 0 and #doubles == 1 then
            done(doubles[1], nil)
        else
            pick(client, real, doubles)
        end
    end, bufnr)
end

-- One level deeper on the name under the cursor in the float.
drill = function(kind)
    local s = state
    if not s then
        return
    end
    local position, cursor = float_position(s)
    local params = { textDocument = { uri = s.view.uri }, position = position }
    request(s.client, kind, params, s.source_buf, function(location, note)
        if state ~= s then
            return
        end
        local view, err = build_view(s.client, location, kind, note)
        if not view then
            notify(err, vim.log.levels.WARN)
            return
        end
        s.view.cursor = cursor
        table.insert(s.stack, s.view)
        s.view = view
        render(s)
    end)
end

back = function()
    local s = state
    if not s or #s.stack == 0 then
        return
    end
    s.view = table.remove(s.stack)
    render(s)
end

-- Enter: the file of the current view at the cursor, in the source window.
open_here = function()
    local s = state
    if not s then
        return
    end
    local position = float_position(s)
    local uri = s.view.uri
    close_and_return()
    vim.lsp.util.show_document(
        { uri = uri, range = { start = position, ["end"] = position } },
        s.client.offset_encoding,
        { focus = true }
    )
    vim.cmd("normal! zz")
end

local function peek(kind)
    local win = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_get_current_buf()

    -- The same key again while its float is open focuses it.
    if state and state.source_win == win and vim.api.nvim_win_is_valid(state.win) then
        if state.kind == kind then
            vim.api.nvim_set_current_win(state.win)
            return
        end
        close()
    end

    local client = client_for(bufnr, methods[kind])
    if not client then
        notify("No LSP client for " .. kind)
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(win)
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    local params = vim.lsp.util.make_position_params(win, client.offset_encoding)
    request(client, kind, params, bufnr, function(location, note)
        -- Too late: the cursor or the text moved while the server answered.
        if not vim.api.nvim_win_is_valid(win)
            or vim.api.nvim_get_current_win() ~= win
            or vim.api.nvim_win_get_buf(win) ~= bufnr
            or not vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor)
            or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick
        then
            return
        end
        local view, err = build_view(client, location, kind, note)
        if not view then
            notify(err, vim.log.levels.WARN)
            return
        end
        open_float(client, view, kind, win, bufnr)
    end)
end

function M.definition()
    peek("definition")
end

function M.type_definition()
    peek("type")
end

function M.implementation()
    peek("implementation")
end

-- The open float window, or nil.
function M.float()
    return state and vim.api.nvim_win_is_valid(state.win) and state.win or nil
end

M.close = close
M._declaration_rows = declaration_rows
M._comment_start = comment_start
M._is_double = is_double

return M
