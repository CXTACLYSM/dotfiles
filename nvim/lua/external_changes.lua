-- Files changed on disk by something else: the agent in the next tmux
-- window, a git checkout, a code generator.
--
-- Neovim notices such a change only when it gets the focus back or after a
-- shell command, and then either reloads without a word ('autoread') or
-- stops with a question. Here instead:
--
--   - the files of the loaded buffers, shown or not, are checked once a
--     second, so a buffer follows its file while the agent works beside it;
--   - a buffer without unsaved changes is reloaded, the lines that came
--     changed are highlighted for a few seconds and a notice counts them:
--     "service.go changed on disk: +12 ~3 -1" (many files at once, as
--     after a git checkout, make one notice);
--   - a buffer with unsaved changes is left as it is: no question in the
--     middle of typing, a warning and vim.b.disk_conflict (the status line
--     shows it) until the buffer is written or read again. :w still asks
--     before it overwrites the newer file;
--   - a file deleted under its buffer is reported, the buffer stays.
--
--     require("external_changes").setup()
--
-- 'autoread' is switched off: the reload is decided here, in
-- FileChangedShell, where the old text is still at hand to compare with.

local M = {}

M.opts = {
    -- How often the files are checked, ms; 0 leaves it to FocusGained.
    interval_ms = 1000,
    -- How long the changed lines stay highlighted, ms.
    flash_ms = 4000,
    -- A buffer longer than this is reloaded without the comparison.
    max_lines = 20000,
    -- More files than this reloaded by one check are reported in one line.
    max_notices = 3,
}

local namespace = vim.api.nvim_create_namespace("external_changes")
local before = {}
local generation = {}
-- Buffers whose file is gone: Neovim reports that at every check.
local gone = {}
local timer

-- What changed between two lists of lines: the hunks in the numbering of
-- the new text, { first = 1-based line, count = lines, kind = "add" |
-- "change" }, and the totals { added, changed, removed } in lines. A hunk
-- that only removes lines has no place in the new text and is counted only.
function M.hunks(old, new)
    local diff = vim.text and vim.text.diff or vim.diff
    local indices = diff(table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n", {
        result_type = "indices",
        algorithm = "histogram",
    })
    local hunks = {}
    local stats = { added = 0, changed = 0, removed = 0 }
    for _, hunk in ipairs(indices or {}) do
        local _, old_count, new_start, new_count = unpack(hunk)
        if new_count == 0 then
            stats.removed = stats.removed + old_count
        elseif old_count == 0 then
            stats.added = stats.added + new_count
            table.insert(hunks, { first = new_start, count = new_count, kind = "add" })
        else
            local changed = math.min(old_count, new_count)
            stats.changed = stats.changed + changed
            stats.added = stats.added + (new_count - changed)
            stats.removed = stats.removed + (old_count - changed)
            table.insert(hunks, { first = new_start, count = new_count, kind = "change" })
        end
    end
    return hunks, stats
end

-- "+12 ~3 -1"; the zero counts are left out.
function M.summary(stats)
    local parts = {}
    for _, item in ipairs({ { "+", stats.added }, { "~", stats.changed }, { "-", stats.removed } }) do
        if item[2] > 0 then
            table.insert(parts, item[1] .. item[2])
        end
    end
    return table.concat(parts, " ")
end

local function name_of(buf)
    return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
end

local function echo(id, text, group)
    local ok = pcall(vim.api.nvim_echo, { { text, group } }, true, { id = "external_changes." .. id })
    if not ok then
        vim.notify(text, group == "WarningMsg" and vim.log.levels.WARN or vim.log.levels.INFO)
    end
end

-- One notice per buffer: the next change of the same file replaces it
-- instead of piling up beside it. The notices of one check are shown
-- together, after it: the events come from a `silent checktime`, which
-- would swallow a message, and a git checkout under twenty open buffers is
-- one line ("20 files changed on disk"), not twenty. Warnings are never
-- folded.
local waiting = {}
local function notice(buf, text, group)
    table.insert(waiting, { buf = buf, text = text, group = group })
    if #waiting > 1 then
        return
    end
    vim.schedule(function()
        local batch = waiting
        waiting = {}
        local reloaded = 0
        for _, item in ipairs(batch) do
            if item.group ~= "WarningMsg" then
                reloaded = reloaded + 1
            end
        end
        local fold = reloaded > M.opts.max_notices
        for _, item in ipairs(batch) do
            if item.group == "WarningMsg" or not fold then
                echo(item.buf, item.text, item.group)
            end
        end
        if fold then
            echo("many", reloaded .. " files changed on disk", "Comment")
        end
    end)
end

-- Highlight the hunks in the buffer for opts.flash_ms.
function M.flash(buf, hunks)
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    local last = vim.api.nvim_buf_line_count(buf)
    for _, hunk in ipairs(hunks) do
        for line = hunk.first, math.min(hunk.first + hunk.count - 1, last) do
            vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
                line_hl_group = hunk.kind == "add" and "ExternalChangeAdd" or "ExternalChangeText",
                priority = 150,
            })
        end
    end
    generation[buf] = (generation[buf] or 0) + 1
    local mine = generation[buf]
    vim.defer_fn(function()
        if generation[buf] == mine and vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
        end
    end, M.opts.flash_ms)
end

local function on_changed(buf)
    local reason = vim.v.fcs_reason
    if reason ~= "deleted" then
        gone[buf] = nil
    end
    if reason == "changed" then
        if vim.api.nvim_buf_line_count(buf) <= M.opts.max_lines then
            before[buf] = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        end
        vim.v.fcs_choice = "reload"
    elseif reason == "conflict" then
        vim.v.fcs_choice = ""
        vim.b[buf].disk_conflict = true
        notice(
            buf,
            name_of(buf) .. " changed on disk and has unsaved changes here (:e! takes the file, :w! keeps the buffer)",
            "WarningMsg"
        )
        vim.cmd.redrawstatus()
    elseif reason == "deleted" then
        vim.v.fcs_choice = ""
        if not gone[buf] then
            gone[buf] = true
            notice(buf, name_of(buf) .. " was deleted on disk; the buffer is kept", "WarningMsg")
        end
    else
        -- Only the timestamp or the mode: nothing to read again.
        vim.v.fcs_choice = ""
    end
end

local function on_reloaded(buf)
    local old = before[buf]
    before[buf] = nil
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    if not old then
        return
    end
    local hunks, stats = M.hunks(old, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    local summary = M.summary(stats)
    if summary == "" then
        return
    end
    M.flash(buf, hunks)
    notice(buf, name_of(buf) .. " changed on disk: " .. summary, "Comment")
end

-- Compare the loaded buffers with their files now. Each buffer by its
-- number: a plain :checktime looks only at the buffers shown in a window,
-- and a file open on a tab behind would stay old (for gopls too) until it
-- is entered. Not while a command line or a prompt is open: Neovim would
-- put the check off anyway.
function M.check()
    if vim.fn.getcmdwintype() ~= "" then
        return
    end
    local mode = vim.api.nvim_get_mode()
    if mode.blocking or mode.mode:find("^[cr]") then
        return
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= "" then
            vim.cmd("silent! checktime " .. buf)
        end
    end
end

function M.highlights()
    vim.api.nvim_set_hl(0, "ExternalChangeAdd", { default = true, link = "DiffAdd" })
    vim.api.nvim_set_hl(0, "ExternalChangeText", { default = true, link = "DiffChange" })
end

function M.setup(opts)
    M.opts = vim.tbl_extend("force", M.opts, opts or {})
    vim.o.autoread = false
    M.highlights()

    local group = vim.api.nvim_create_augroup("external_changes", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = M.highlights })
    vim.api.nvim_create_autocmd("FileChangedShell", {
        group = group,
        callback = function(event)
            -- Whatever goes wrong here, the file must not change silently
            -- under an unsaved buffer: fall back to Neovim's own question.
            if not pcall(on_changed, event.buf) then
                vim.v.fcs_choice = "ask"
            end
        end,
    })
    vim.api.nvim_create_autocmd("FileChangedShellPost", {
        group = group,
        callback = function(event)
            pcall(on_reloaded, event.buf)
        end,
    })
    -- Written or read again: the buffer and the file agree.
    vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost" }, {
        group = group,
        callback = function(event)
            gone[event.buf] = nil
            if vim.b[event.buf].disk_conflict then
                vim.b[event.buf].disk_conflict = nil
                vim.cmd.redrawstatus()
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        callback = function(event)
            before[event.buf] = nil
            generation[event.buf] = nil
            gone[event.buf] = nil
        end,
    })

    if timer then
        timer:stop()
        timer:close()
        timer = nil
    end
    if M.opts.interval_ms > 0 then
        timer = vim.uv.new_timer()
        timer:start(M.opts.interval_ms, M.opts.interval_ms, vim.schedule_wrap(M.check))
        vim.api.nvim_create_autocmd("VimLeavePre", {
            group = group,
            callback = function()
                if timer then
                    timer:stop()
                end
            end,
        })
    end
end

return M
