-- Own the "when does the completion menu open" decision.
--
-- `vim.lsp.completion` with `autotrigger = true` requests completion the
-- moment a server trigger character (`.` for gopls) is typed, which lists
-- every member of `fmt.` before a single letter narrows it, and never
-- reopens the menu once a typo or Backspace closed it. This module takes
-- the trigger characters away from the native handler (`take_over_triggers`)
-- and decides itself on |TextChangedI|, which fires exactly when text
-- changes in Insert mode while no menu is visible: a member-access context
-- such as `m.S` needs `member_min_length` characters after the dot, bare
-- identifiers `keyword_min_length`, argument and field positions
-- `argument_min_length`. The bare dot itself is probed: the server is
-- asked quietly, and the menu opens at once when the owner has methods or
-- fields (a struct, an interface, a value), not for a package. The native
-- handler keeps one job: re-requesting an incomplete list while the menu
-- is open.

local M = {}

M.defaults = {
    -- Delay before the repeated request in a member-access context (`m.Sa`),
    -- so fast typing sends one request.
    debounce_ms = 60,
    -- Quiet time before a bare identifier or import path completes. Longer
    -- than the gap between keystrokes while typing in rhythm, so the menu
    -- shows up only when you slow down; nil falls back to debounce_ms.
    keyword_debounce_ms = 400,
    -- Characters that end an access expression; the server's own trigger
    -- characters are merged in on attach and taken away from the native
    -- autotrigger.
    trigger_chars = { "." },
    -- Characters typed after a trigger character before the menu opens:
    -- 1 keeps `fmt.` quiet until `fmt.P`; 0 opens on the dot itself.
    member_min_length = 1,
    -- On the bare dot the server is asked quietly, and the menu opens at
    -- once when the owner has methods or fields — a struct, an interface,
    -- a value (`o.` lists its fields and methods); a package (`fmt.`)
    -- waits for the first letter as above.
    probe_members = true,
    -- Minimum identifier length to trigger without a preceding trigger
    -- character; nil keeps bare identifiers manual (Ctrl-Space).
    keyword_min_length = nil,
    -- In argument and field positions (after `(`, `{`, `,`, `&`, `*`, `!`)
    -- a single character is enough: `Task{I` lists the fields.
    argument_min_length = 1,
    -- Ignore text changes this soon after a completion was accepted, so the
    -- inserted item does not immediately reopen the menu.
    accept_grace_ms = 300,
}

M.opts = vim.deepcopy(M.defaults)

-- Decide from the text before the cursor whether completion should be
-- requested again. Returns true and the reason ("member" or "keyword").
function M.should_retrigger(before_cursor, opts, trigger_chars)
    opts = opts or M.opts
    trigger_chars = trigger_chars or opts.trigger_chars

    local word = before_cursor:match("[%w_]*$") or ""
    local head = before_cursor:sub(1, #before_cursor - #word)

    for _, char in ipairs(trigger_chars) do
        if head:sub(-#char) == char then
            -- `1.` is a float literal, not member access; `x.` and `x).` are.
            local owner = head:sub(1, -#char - 1)
            if owner:match("[%w_%)%]%}]$") and not owner:match("^%d+$") and not owner:match("[^%w_]%d+$") then
                if #word >= (opts.member_min_length or 0) then
                    return true, "member"
                end
                if #word == 0 and opts.probe_members then
                    return true, "probe"
                end
            end
            return false
        end
    end

    -- Import path being typed: `"net/ht` completes to net/http.
    if opts.keyword_min_length and before_cursor:match('"[%w_%./%-]*$') then
        local quoted = before_cursor:match('"([%w_%./%-]*)$')
        if #quoted >= opts.keyword_min_length then
            return true, "import"
        end
    end

    if opts.keyword_min_length and #word > 0 and not word:match("^%d") then
        local minimum = opts.keyword_min_length
        if head:match("[%(%{,&%*!]%s*$") then
            minimum = math.min(minimum, opts.argument_min_length or minimum)
        end
        if #word >= minimum then
            return true, "keyword"
        end
    end

    return false
end

-- Delay for a re-trigger reason: member access and the probe of a dot stay
-- immediate, bare identifiers and import paths wait for a pause in typing.
function M.delay_for(reason, opts)
    opts = opts or M.opts
    if reason == "member" or reason == "probe" then
        return opts.debounce_ms
    end
    return opts.keyword_debounce_ms or opts.debounce_ms
end

-- Kinds of a completion item that make the owner of a dot an object:
-- its methods and fields. A package offers functions, types and values.
local member_kinds = {}
for _, name in ipairs({ "Method", "Field", "Property" }) do
    member_kinds[vim.lsp.protocol.CompletionItemKind[name]] = true
end

-- Whether a completion answer lists methods or fields.
function M.has_members(items)
    for _, item in ipairs(items or {}) do
        if member_kinds[item.kind] then
            return true
        end
    end
    return false
end

local function line_before_cursor()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    return line:sub(1, col)
end

-- Strings and comments never complete, except the path string of an
-- `import` spec, where gopls completes package paths.
local function inside_string_or_comment(bufnr)
    local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, ignore_injections = false })
    local literal = false
    while ok and node do
        local kind = node:type()
        if kind == "import_spec" then
            return false
        end
        if kind:find("string", 1, true) or kind:find("comment", 1, true) or kind == "rune_literal" then
            literal = true
        end
        node = node:parent()
    end
    return literal
end

local state = {}

local function buffer_state(bufnr)
    local entry = state[bufnr]
    if not entry then
        entry = { timer = nil, accepted_at = 0, trigger_chars = {} }
        state[bufnr] = entry
    end
    return entry
end

local function stop_timer(entry)
    if entry.timer then
        entry.timer:stop()
        entry.timer:close()
        entry.timer = nil
    end
end

-- Still in Insert mode in `bufnr`, no menu open: the moment a request may
-- be sent or its answer shown.
local function ready(bufnr)
    return vim.api.nvim_get_current_buf() == bufnr and vim.fn.mode() == "i" and vim.fn.pumvisible() == 0
end

-- The probe of a bare dot: the server is asked for the completion, and
-- the menu opens (the native request) only when the answer has methods
-- or fields and nothing was typed meanwhile.
local function probe(bufnr, entry)
    local client = entry and entry.client
    if not client or not ready(bufnr) then
        return
    end
    local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
    local before = line_before_cursor()
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    client:request("textDocument/completion", params, function(err, result)
        local items = not err and result and (result.items or result) or nil
        if not M.has_members(items) or not ready(bufnr) then
            return
        end
        if vim.api.nvim_buf_get_changedtick(bufnr) ~= tick or line_before_cursor() ~= before then
            return
        end
        vim.lsp.completion.get()
    end, bufnr)
end

local function request(bufnr)
    if not ready(bufnr) then
        return
    end
    -- The line may have changed while the timer ran; decide on what is
    -- there now, not on what was there when the timer started.
    local entry = state[bufnr]
    local trigger_chars = entry and entry.trigger_chars or M.opts.trigger_chars
    local should, reason = M.should_retrigger(line_before_cursor(), M.opts, trigger_chars)
    if not should then
        return
    end
    if reason == "probe" then
        probe(bufnr, entry)
        return
    end
    vim.lsp.completion.get()
end

-- Whether a delayed request is pending for the buffer (for tests).
function M.pending(bufnr)
    local entry = state[bufnr]
    return entry ~= nil and entry.timer ~= nil
end

local function on_text_changed(bufnr)
    local entry = buffer_state(bufnr)

    -- Any change invalidates a request scheduled for the previous text:
    -- `fmt` + `.` must not fire the identifier request at `fmt.`.
    stop_timer(entry)

    if vim.uv.now() - entry.accepted_at < M.opts.accept_grace_ms then
        return
    end

    local should, reason = M.should_retrigger(line_before_cursor(), M.opts, entry.trigger_chars)
    if not should or inside_string_or_comment(bufnr) then
        return
    end

    -- Every keystroke restarts the timer, so the request goes out only after
    -- typing stops for the reason's delay.
    entry.timer = vim.uv.new_timer()
    entry.timer:start(M.delay_for(reason, M.opts), 0, vim.schedule_wrap(function()
        stop_timer(entry)
        request(bufnr)
    end))
end

local taken_triggers = {}

-- Take the server's trigger characters away from the native autotrigger:
-- `vim.lsp.completion.enable` reads them from the client capabilities, so
-- clearing them before it runs leaves the native InsertCharPre handler with
-- only the incomplete-list re-request. Returns the original characters.
-- Must run before `vim.lsp.completion.enable` for the same client.
function M.take_over_triggers(client)
    local provider = client.server_capabilities and client.server_capabilities.completionProvider
    if type(provider) ~= "table" then
        return {}
    end
    if taken_triggers[client.id] == nil then
        taken_triggers[client.id] = vim.deepcopy(provider.triggerCharacters or {})
        provider.triggerCharacters = {}
    end
    return taken_triggers[client.id]
end

-- Attach to a buffer for a client that supports completion.
function M.attach(bufnr, client)
    local entry = buffer_state(bufnr)
    entry.client = client
    local server_triggers = M.take_over_triggers(client)
    for _, char in ipairs(vim.list_extend(vim.deepcopy(M.opts.trigger_chars), server_triggers)) do
        if not vim.tbl_contains(entry.trigger_chars, char) then
            table.insert(entry.trigger_chars, char)
        end
    end

    local group = vim.api.nvim_create_augroup("completion_retrigger_" .. bufnr, { clear = true })

    vim.api.nvim_create_autocmd("TextChangedI", {
        group = group,
        buffer = bufnr,
        callback = function()
            on_text_changed(bufnr)
        end,
    })

    vim.api.nvim_create_autocmd("CompleteDone", {
        group = group,
        buffer = bufnr,
        callback = function()
            local completed = vim.v.completed_item
            if completed and completed.word and completed.word ~= "" then
                buffer_state(bufnr).accepted_at = vim.uv.now()
            end
        end,
    })

    vim.api.nvim_create_autocmd({ "InsertLeave", "BufWipeout" }, {
        group = group,
        buffer = bufnr,
        callback = function()
            local current = state[bufnr]
            if current then
                stop_timer(current)
            end
        end,
    })

    return entry
end

function M.setup(user_opts)
    M.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts or {})
end

return M
