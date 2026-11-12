-- A ```mermaid block drawn as a box diagram over its source.
--
-- The drawing comes from the engine of ascii-mermaid: a bundled script run
-- by node, one process per block, asynchronously (require("ascii-mermaid.
-- render")); the blocks are found by its detection on the markdown tree.
-- The placing is done here, not by the plugin: its display puts the part
-- of a drawing that does not fit the block under the closing fence, and
-- render-markdown conceals that line (code.border = "hide"), so a diagram
-- at the end of a file lost its tail. Here the first rows overlay the
-- source lines and the rest are virtual lines under the last source line,
-- which is never concealed.
--
-- The cursor inside a block lifts the drawing and shows the source to
-- edit; in a reader (`nvim -R`, the documentation popup of tmux) the
-- drawing stays. M.hide / M.show follow Space m (lua/markdown_view.lua).
-- Without node nothing is drawn and the blocks stay code.

local M = {}

M.config = {
    reader = false,
    debounce_ms = 500,
    -- Options of the engine.
    engine = { useAscii = false, paddingX = 2, paddingY = 1 },
}

local ns = vim.api.nvim_create_namespace("markdown_diagrams")

-- [buf] = { blocks = { [first] = entry }, raw = bool, inside = first|nil, timer }
-- entry: hash, lines (nil while the engine runs), first and last source
-- line (0-based), marks, shown.
local state = {}

local function of(buf)
    if not state[buf] then
        state[buf] = { blocks = {}, raw = false }
    end
    return state[buf]
end

function M.available()
    return vim.fn.executable("node") == 1
end

local function lift(buf, entry)
    for _, id in ipairs(entry.marks) do
        pcall(vim.api.nvim_buf_del_extmark, buf, ns, id)
    end
    entry.marks = {}
    entry.shown = false
end

-- The rows over the source lines, padded to the window so the right edge
-- of the source never shows through; the rest under the last source line.
local function place(buf, entry)
    if entry.shown or not entry.lines then
        return
    end
    local win = vim.fn.bufwinid(buf)
    local width = win ~= -1 and vim.api.nvim_win_get_width(win) or 120
    local marks = {}
    local rows = entry.last - entry.first + 1
    for i = 0, rows - 1 do
        local text = entry.lines[i + 1] and ("  " .. entry.lines[i + 1]) or " "
        local gap = width - vim.fn.strdisplaywidth(text)
        if gap > 0 then
            text = text .. string.rep(" ", gap)
        end
        marks[#marks + 1] = vim.api.nvim_buf_set_extmark(buf, ns, entry.first + i, 0, {
            virt_text = { { text, "MarkdownDiagram" } },
            virt_text_pos = "overlay",
        })
    end
    if #entry.lines > rows then
        local rest = {}
        for i = rows + 1, #entry.lines do
            rest[#rest + 1] = { { "  " .. entry.lines[i], "MarkdownDiagram" } }
        end
        marks[#marks + 1] = vim.api.nvim_buf_set_extmark(buf, ns, entry.last, 0, { virt_lines = rest })
    end
    entry.marks = marks
    entry.shown = true
end

local function covered(entry, first)
    return not M.config.reader and first == entry.first
end

-- Find the blocks, draw the new ones, drop the ones that are gone.
function M.draw(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local s = of(buf)
    if s.raw then
        return
    end
    local seen = {}
    for _, block in ipairs(require("ascii-mermaid.detect").find_blocks(buf)) do
        local first, last = block.start_line + 1, block.end_line - 1
        if last >= first and #vim.trim(block.content) > 0 then
            seen[first] = true
            local hash = vim.fn.sha256(block.content)
            local entry = s.blocks[first]
            if entry and entry.hash == hash and entry.last == last then
                if not covered(entry, s.inside) then
                    place(buf, entry)
                end
            else
                if entry then
                    lift(buf, entry)
                end
                entry = { hash = hash, first = first, last = last, marks = {}, shown = false }
                s.blocks[first] = entry
                require("ascii-mermaid.render").render(block.content, M.config.engine, function(lines, err)
                    if s.blocks[first] ~= entry or not vim.api.nvim_buf_is_valid(buf) then
                        return
                    end
                    if err or not lines or #lines == 0 then
                        s.blocks[first] = nil
                        if err then
                            vim.notify(err:gsub("^ascii%-mermaid: ", "mermaid: "), vim.log.levels.WARN)
                        end
                        return
                    end
                    entry.lines = lines
                    if not s.raw and not covered(entry, s.inside) then
                        place(buf, entry)
                    end
                end)
            end
        end
    end
    for first, entry in pairs(s.blocks) do
        if not seen[first] then
            lift(buf, entry)
            s.blocks[first] = nil
        end
    end
end

-- The cursor entering a block shows its source, leaving it draws again.
function M.cursor(buf)
    local s = state[buf]
    if not s or s.raw or M.config.reader then
        return
    end
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local inside
    for first, entry in pairs(s.blocks) do
        if row >= first - 1 and row <= entry.last + 1 then
            inside = first
            break
        end
    end
    if inside == s.inside then
        return
    end
    if s.inside and s.blocks[s.inside] then
        place(buf, s.blocks[s.inside])
    end
    if inside then
        lift(buf, s.blocks[inside])
    end
    s.inside = inside
end

function M.clear(buf)
    local s = state[buf]
    if not s then
        return
    end
    for _, entry in pairs(s.blocks) do
        lift(buf, entry)
    end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    s.blocks = {}
    s.inside = nil
end

-- Space m: the raw text hides the diagrams, the drawn view brings them back.
function M.hide(buf)
    of(buf).raw = true
    M.clear(buf)
end

function M.show(buf)
    of(buf).raw = false
    M.draw(buf)
end

function M.drawn(buf)
    return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0
end

local function debounced(buf)
    local s = of(buf)
    if s.timer then
        s.timer:stop()
    end
    s.timer = vim.defer_fn(function()
        s.timer = nil
        M.draw(buf)
    end, M.config.debounce_ms)
end

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    if not M.available() then
        return
    end
    local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
    vim.api.nvim_set_hl(0, "MarkdownDiagram", { default = true, fg = normal.fg })
    local group = vim.api.nvim_create_augroup("markdown_diagrams", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = "markdown",
        callback = function(event)
            local buf = event.buf
            vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
                group = group,
                buffer = buf,
                callback = function()
                    M.draw(buf)
                end,
            })
            vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
                group = group,
                buffer = buf,
                callback = function()
                    debounced(buf)
                end,
            })
            vim.api.nvim_create_autocmd("CursorMoved", {
                group = group,
                buffer = buf,
                callback = function()
                    M.cursor(buf)
                end,
            })
            vim.api.nvim_create_autocmd("BufDelete", {
                group = group,
                buffer = buf,
                callback = function()
                    if state[buf] and state[buf].timer then
                        state[buf].timer:stop()
                    end
                    state[buf] = nil
                end,
            })
            M.draw(buf)
        end,
    })
end

return M
