-- The signature of the call the cursor is in, one line above it while the
-- arguments are typed:
--
--       Printf(format string, a ...any) (n int, err error)
--       Printf formats according to a format specifier and writes to…
--     fmt.Printf(|
--
-- The parameter the cursor is at is highlighted (LspSignatureActiveParameter)
-- and follows the cursor through the commas; under the signature, the first
-- sentence of the doc comment. The float opens when the cursor is inside
-- the parentheses of a call in Insert mode (the Tree-sitter argument_list,
-- or an unclosed `(` on the line while the tree is still broken), updates
-- in place, closes when the cursor leaves the call or Insert mode, and
-- stays away while the completion menu is open — the menu has its own
-- documentation. Ctrl-S keeps the full native signature help.

local M = {}

M.opts = {
    -- Quiet time after a keystroke before the server is asked.
    debounce_ms = 80,
    -- Longest doc line under the signature; the rest is "…".
    doc_width = 100,
}

local ns = vim.api.nvim_create_namespace("call_signature")
local method = "textDocument/signatureHelp"

-- bufnr → { client, timer }
local state = {}
-- The open float: { win, buf, bufnr } or nil.
local float = nil

local function stop_timer(entry)
    if entry.timer then
        entry.timer:stop()
        entry.timer:close()
        entry.timer = nil
    end
end

-- Whether the cursor stands inside the arguments of a call: by the tree,
-- or by an unclosed `(` after a name on the line when the tree has not
-- caught up with the typing. Strings are skipped in the textual check.
function M.inside_call(bufnr, line_before_cursor)
    if bufnr then
        local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, ignore_injections = true })
        while ok and node do
            local kind = node:type()
            if kind == "argument_list" or kind == "special_argument_list" then
                return true
            end
            if kind == "block" or kind == "function_declaration" or kind == "method_declaration" then
                break
            end
            node = node:parent()
        end
    end
    if not line_before_cursor then
        return false
    end
    local depth, quote = 0, nil
    local i = 1
    while i <= #line_before_cursor do
        local c = line_before_cursor:sub(i, i)
        if quote then
            if c == "\\" then
                i = i + 1
            elseif c == quote then
                quote = nil
            end
        elseif c == '"' or c == "`" or c == "'" then
            quote = c
        elseif c == "(" then
            depth = depth + 1
        elseif c == ")" then
            depth = math.max(0, depth - 1)
        end
        i = i + 1
    end
    return depth > 0 and quote == nil
end

-- Byte range of parameter `index` (0-based) in `label`: the parameter
-- label is a string found in the signature (the same text twice: after
-- the previous parameter) or a pair of UTF-16 offsets.
function M.parameter_range(label, parameters, index)
    local from = 1
    for i, parameter in ipairs(parameters or {}) do
        local text = parameter.label
        local start_col, end_col
        if type(text) == "table" then
            start_col = vim.str_byteindex(label, "utf-16", text[1], false)
            end_col = vim.str_byteindex(label, "utf-16", text[2], false)
        else
            local s, e = label:find(text, from, true)
            if not s then
                return nil
            end
            start_col, end_col = s - 1, e
        end
        if i - 1 == index then
            return start_col, end_col
        end
        from = end_col + 1
    end
    return nil
end

-- The first sentence of a doc comment, markdown marks dropped, cut to
-- opts.doc_width.
function M.first_sentence(documentation)
    local text = type(documentation) == "table" and documentation.value or documentation
    if not text or text == "" then
        return nil
    end
    text = text:gsub("```.-```", ""):gsub("[`*_]", ""):gsub("%s+", " ")
    text = vim.trim(text)
    local sentence = text:match("^(.-%.)%s") or text
    if vim.fn.strdisplaywidth(sentence) > M.opts.doc_width then
        sentence = table.concat(vim.fn.split(sentence, "\\zs"), "", 1, M.opts.doc_width - 1) .. "…"
    end
    return sentence ~= "" and sentence or nil
end

-- Lines of the float and the highlight of the active parameter:
-- { lines, active = { start_col, end_col } or nil } or nil without a signature.
function M.render(result)
    local signatures = result and result.signatures or {}
    if #signatures == 0 then
        return nil
    end
    local signature = signatures[(result.activeSignature or 0) + 1] or signatures[1]
    local active = signature.activeParameter or result.activeParameter or 0
    local lines = { signature.label }
    local doc = M.first_sentence(signature.documentation)
    if doc then
        table.insert(lines, doc)
    end
    local start_col, end_col = M.parameter_range(signature.label, signature.parameters, active)
    return { lines = lines, active = start_col and { start_col, end_col } or nil }
end

function M.close()
    if float then
        if vim.api.nvim_win_is_valid(float.win) then
            vim.api.nvim_win_close(float.win, true)
        end
        float = nil
    end
end

-- The float, or nil (for tests).
function M.window()
    return float and vim.api.nvim_win_is_valid(float.win) and float.win or nil
end

-- Draw `rendered` above the cursor line, starting at the column of the call
-- when it fits; an open float is updated in place.
function M.show(bufnr, rendered)
    -- As wide as the widest line, at most the screen; a longer line is cut
    -- here rather than wrapped (no window option is set on the float: an
    -- OptionSet would make other modules redraw).
    local limit = math.max(20, vim.o.columns - 4)
    local lines, width = {}, 0
    for index, line in ipairs(rendered.lines) do
        if vim.fn.strdisplaywidth(line) > limit then
            line = table.concat(vim.fn.split(line, "\\zs"), "", 1, limit - 1) .. "…"
        end
        lines[index] = line
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    rendered = { lines = lines, active = rendered.active }
    local height = #lines
    local cursor_col = vim.api.nvim_win_get_cursor(0)[2]
    local line = vim.api.nvim_get_current_line():sub(1, cursor_col)
    -- The name of the call, for the column: `fmt.Printf(a, |` → "fmt".
    local call_start = line:match("()[%w_%.]+%b()%s*$") or line:match("()[%w_%.]+%(") or (cursor_col + 1)
    local col = math.min(0, call_start - 1 - cursor_col)
    local config = {
        relative = "cursor",
        anchor = "SW",
        row = 0,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        focusable = false,
        noautocmd = true,
    }
    if not float or not vim.api.nvim_win_is_valid(float.win) then
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].bufhidden = "wipe"
        local win = vim.api.nvim_open_win(buf, false, config)
        vim.w[win].call_signature = true
        float = { win = win, buf = buf, bufnr = bufnr }
    else
        config.noautocmd = nil
        vim.api.nvim_win_set_config(float.win, config)
    end
    vim.bo[float.buf].modifiable = true
    vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, rendered.lines)
    vim.bo[float.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(float.buf, ns, 0, -1)
    if rendered.active then
        vim.api.nvim_buf_set_extmark(float.buf, ns, 0, rendered.active[1], {
            end_col = rendered.active[2],
            hl_group = "LspSignatureActiveParameter",
        })
    end
    if #rendered.lines > 1 then
        vim.api.nvim_buf_set_extmark(float.buf, ns, 1, 0, { line_hl_group = "CallSignatureDoc" })
    end
end

local function line_before_cursor()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    return vim.api.nvim_get_current_line():sub(1, col)
end

-- Insert mode, or Select mode on a placeholder of the snippet (Tab).
local function typing()
    return vim.fn.mode():match("^[is]") ~= nil
end

local function request(bufnr)
    local entry = state[bufnr]
    if not entry or vim.api.nvim_get_current_buf() ~= bufnr then
        return
    end
    if not typing() then
        M.close()
        return
    end
    if vim.fn.pumvisible() == 1 or not M.inside_call(bufnr, line_before_cursor()) then
        M.close()
        return
    end
    local client = entry.client
    local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
    local cursor = vim.api.nvim_win_get_cursor(0)
    client:request(method, params, function(err, result)
        if err or vim.api.nvim_get_current_buf() ~= bufnr or not typing() or vim.fn.pumvisible() == 1 then
            return
        end
        if not vim.deep_equal(vim.api.nvim_win_get_cursor(0), cursor) then
            return
        end
        local rendered = M.render(result)
        if not rendered then
            M.close()
            return
        end
        M.show(bufnr, rendered)
    end, bufnr)
end

local function schedule(bufnr)
    local entry = state[bufnr]
    if not entry then
        return
    end
    stop_timer(entry)
    entry.timer = vim.uv.new_timer()
    entry.timer:start(M.opts.debounce_ms, 0, vim.schedule_wrap(function()
        stop_timer(entry)
        request(bufnr)
    end))
end

-- Attach to a buffer of a client that answers signatureHelp.
function M.attach(bufnr, client)
    local entry = state[bufnr] or {}
    entry.client = client
    state[bufnr] = entry
    local group = vim.api.nvim_create_augroup("call_signature_" .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd({ "CursorMovedI", "TextChangedI", "InsertEnter", "CompleteDone" }, {
        group = group,
        buffer = bufnr,
        callback = function()
            schedule(bufnr)
        end,
    })
    -- Tab to the next placeholder leaves Insert for Select mode: the
    -- signature stays while the snippet is active.
    vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
        group = group,
        buffer = bufnr,
        callback = function(event)
            if event.event == "InsertLeave" and vim.snippet.active() then
                schedule(bufnr)
                return
            end
            stop_timer(entry)
            M.close()
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        buffer = bufnr,
        callback = function()
            stop_timer(entry)
            state[bufnr] = nil
        end,
    })
    return entry
end

function M.setup(user_opts)
    M.opts = vim.tbl_deep_extend("force", M.opts, user_opts or {})
    vim.api.nvim_set_hl(0, "CallSignatureDoc", { link = "Comment", default = true })
    -- init.lua ends the snippet on Esc and says so: the call is done with.
    vim.api.nvim_create_autocmd("User", {
        group = vim.api.nvim_create_augroup("call_signature", { clear = true }),
        pattern = "PlaceholdersDone",
        callback = M.close,
    })
end

return M
