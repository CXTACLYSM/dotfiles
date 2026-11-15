-- Markdown read view with the full init.lua: drawn on open, no Nerd Font
-- glyphs anywhere in the config, callout titles cover their raw text,
-- Space m toggles the buffer, LSP hover floats are drawn too, the theme
-- colours the headings, and `nvim -R` keeps the cursor line drawn.
local view = require("markdown_view")

local function private_use(text)
    for _, code in ipairs(vim.fn.str2list(text)) do
        if (code >= 0xE000 and code <= 0xF8FF) or code >= 0xF0000 then
            return true
        end
    end
    return false
end

local function walk(value, path)
    if type(value) == "table" then
        for key, item in pairs(value) do
            walk(item, path .. "." .. tostring(key))
        end
    elseif type(value) == "string" then
        assert(not private_use(value), "Nerd Font glyph left in " .. path)
    end
end

local config = view.config(false)
walk(config, "config")
assert(config.sign.enabled == false, "no signs: the column belongs to git and diagnostics")
assert(config.latex.enabled == false, "no external LaTeX converter")
assert(config.anti_conceal.enabled == true, "raw cursor line while editing")
assert(view.config(true).anti_conceal.enabled == false, "nvim -R draws the cursor line too")
assert(config.checkbox.checked.icon == "☑" and config.checkbox.unchecked.icon == "☐", "plain checkboxes")
for name, callout in pairs(config.callout) do
    assert(not callout.rendered:find("^%s"), "callout " .. name .. " starts with its word")
    assert(
        vim.fn.strdisplaywidth(callout.rendered) >= vim.fn.strdisplaywidth(callout.raw),
        "callout " .. name .. " covers " .. callout.raw
    )
end
assert(view.strip_icons("\u{f0b21} Note") == "Note", "icon and its space go")
assert(view.strip_icons("▄") == "▄", "ordinary symbols stay")
local diagrams = require("markdown_diagrams")
assert(view.diagrams and diagrams.config.reader == false, "node is here, the diagrams are on, the cursor shows a source")
print("MARKDOWN_CONFIG_OK")

local ns = assert(vim.api.nvim_get_namespaces()["render-markdown.nvim"], "render-markdown namespace")

local function marks(buf)
    return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
end

local function wait_for(cond, what)
    assert(vim.wait(3000, cond, 20), "timed out: " .. what)
end

local file = vim.fn.tempname() .. ".md"
vim.fn.writefile({
    "# Title",
    "",
    "Text with `code` and a [link](https://example.com).",
    "",
    "```go",
    "x := 1",
    "```",
    "",
    "| a | b |",
    "|---|---|",
    "| 1 | 2 |",
    "| a long key in the first column | and a cell of prose that is far wider than any column a narrow window could give it, so that it has to wrap over several rows |",
    "",
    "- [x] done",
    "- [ ] open",
    "",
    "> [!NOTE]",
    "> body",
    "",
    "```mermaid",
    "graph LR",
    "    H[Handler] --> S[Service]",
    "    S --> R[(Postgres)]",
    "```",
    "",
    "after",
}, file)

vim.cmd.edit(file)
local buf = vim.api.nvim_get_current_buf()
assert(vim.bo[buf].filetype == "markdown", "markdown filetype")
wait_for(function()
    return marks(buf) > 0
end, "marks in the markdown buffer")
assert(vim.wo.conceallevel == 3, "raw marks hidden while drawn")
print(string.format("MARKDOWN_RENDER_OK marks=%d", marks(buf)))

-- Space m: the page (md-render) takes the window in place of the source:
-- a read-only buffer of its own, the table boxed with its cells wrapped
-- (nothing cut to "…"), the heading without its `#`, no line numbers;
-- Space m there brings the source back with its numbers, and the source
-- is untouched.
local page_win = vim.api.nvim_get_current_win()
local page_map = vim.fn.maparg("<leader>m", "n", false, true)
assert(page_map.buffer == 1 and page_map.desc == "Markdown page / source", "Space m in markdown buffers")
vim.api.nvim_win_set_cursor(page_win, { 11, 0 })
page_map.callback()
local page_buf = vim.api.nvim_get_current_buf()
assert(page_buf ~= buf and vim.b[page_buf].md_render and vim.bo[page_buf].filetype == "md-render",
    "the page is a buffer of md-render: " .. vim.inspect({ page_buf, vim.bo[page_buf].filetype }))
assert(vim.bo[page_buf].modifiable == false, "the page is read-only")
assert(vim.api.nvim_buf_get_name(page_buf):find("[render]", 1, true), "named after the source: " .. vim.api.nvim_buf_get_name(page_buf))
local page_text = table.concat(vim.api.nvim_buf_get_lines(page_buf, 0, -1, false), "\n")
assert(page_text:find("Title", 1, true) and not page_text:find("# Title", 1, true), "the heading without its #: " .. page_text)
assert(page_text:find("│", 1, true) and page_text:find("│ a ", 1, true), "the table boxed: " .. page_text)
assert(not page_text:find("…", 1, true) and page_text:find("several rows", 1, true),
    "a wide cell wraps instead of being cut: " .. page_text)
assert(vim.wo.number == false and vim.wo.relativenumber == false, "no line numbers on the page")
assert(vim.wo.winbar == "", "the page has no breadcrumbs bar")
assert(vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified == false, "the source is untouched")
local back_map = vim.fn.maparg("<leader>m", "n", false, true)
assert(back_map.buffer == 1 and back_map.desc == "Markdown page / source", "Space m in the page")
back_map.callback()
assert(vim.api.nvim_get_current_buf() == buf and vim.api.nvim_get_current_win() == page_win, "back to the source in the same window")
assert(vim.wo.number == true and vim.wo.relativenumber == true, "the numbers are back")
assert(vim.api.nvim_win_get_cursor(page_win)[1] == 11, "the cursor on the same line: " .. vim.api.nvim_win_get_cursor(page_win)[1])
assert(marks(buf) > 0, "render-markdown still draws the source")
print("MARKDOWN_PAGE_OK")

-- The mermaid block: node draws it, the lines come as overlays over the
-- source in box-drawing characters; the cursor inside reveals the source.
local diagram_ns = assert(vim.api.nvim_get_namespaces().markdown_diagrams, "markdown_diagrams namespace")
local function diagram_marks(b)
    return vim.api.nvim_buf_get_extmarks(b, diagram_ns, 0, -1, { details = true })
end
local function overlays(b)
    local found = {}
    for _, mark in ipairs(diagram_marks(b)) do
        if mark[4].virt_text then
            table.insert(found, { mark[2] + 1, mark[4].virt_text[1][1] })
        end
    end
    return found
end
assert(vim.wait(15000, function()
    return #diagram_marks(buf) > 0
end, 50), "the diagram is drawn (node)")
local drawn = overlays(buf)
local boxes = 0
for _, line in ipairs(drawn) do
    -- Lines 21–23 are the source between the fences (20 and 24).
    assert(line[1] >= 21 and line[1] <= 23, "the overlay stays on the source lines of the block: line " .. line[1])
    if line[2]:find("[┌└│─]") then
        boxes = boxes + 1
    end
end
assert(boxes > 0, "box-drawing characters in the diagram: " .. vim.inspect(drawn))
assert(table.concat(vim.tbl_map(function(line) return line[2] end, drawn), "\n"):find("Handler", 1, true),
    "the diagram names its nodes")
vim.api.nvim_win_set_cursor(0, { 21, 0 })
vim.cmd.doautocmd("CursorMoved")
assert(vim.wait(2000, function()
    return #overlays(buf) == 0
end, 20), "the cursor in the block reveals its source")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd.doautocmd("CursorMoved")
assert(vim.wait(2000, function()
    return #overlays(buf) == #drawn
end, 20), "the cursor out of the block draws it again")
-- A diagram taller than its block, at the very end of the file: the rows
-- that do not fit are virtual lines under the last source line, not under
-- the closing fence that render-markdown conceals.
local tail = vim.fn.tempname() .. ".md"
vim.fn.writefile({
    "# Tail",
    "",
    "```mermaid",
    "graph TD",
    "    A[Start] --> B{Ok?}",
    "    B -->|yes| C[Done]",
    "```",
}, tail)
vim.cmd.edit(tail)
local tail_buf = vim.api.nvim_get_current_buf()
assert(vim.wait(15000, function()
    return #diagram_marks(tail_buf) > 0
end, 50), "the tail diagram is drawn")
local rest
for _, mark in ipairs(diagram_marks(tail_buf)) do
    if mark[4].virt_lines then
        assert(mark[2] + 1 == 6, "the rest hangs under the last source line, not the fence: line " .. (mark[2] + 1))
        rest = mark[4].virt_lines
    end
end
assert(rest and #rest > 5 and rest[#rest][1][1]:find("└", 1, true), "the whole drawing: " .. vim.inspect(rest))
vim.cmd.bdelete(tail_buf)
vim.fn.delete(tail)
vim.cmd.buffer(buf)
print("MARKDOWN_DIAGRAM_OK")

-- render-markdown drops (not delays) an update that comes within its
-- debounce (100 ms) of the previous one; a person never presses Space m
-- that fast after a redraw, the test has to wait.
local function settle()
    vim.wait(250, function()
        return false
    end)
end

local toggle = vim.fn.maparg("<leader>M", "n", false, true)
assert(toggle.buffer == 1 and toggle.desc == "Markdown drawn / raw", "Space M in markdown buffers")
settle()
toggle.callback()
wait_for(function()
    return marks(buf) == 0 and #diagram_marks(buf) == 0
end, "raw view after Space m, the diagram gone with it")
-- Entering the buffer again does not draw the diagram back.
vim.cmd.doautocmd("BufEnter")
settle()
assert(#diagram_marks(buf) == 0, "a raw buffer stays raw on BufEnter")
settle()
toggle.callback()
wait_for(function()
    return marks(buf) > 0
end, "drawn view after the second Space m")
assert(vim.wait(15000, function()
    return #diagram_marks(buf) > 0
end, 50), "the diagram after the second Space m")
print("MARKDOWN_TOGGLE_OK")

local float_buf = vim.lsp.util.open_floating_preview({ "# Hover", "", "```go", "func F()", "```" }, "markdown", {})
wait_for(function()
    return marks(float_buf) > 0
end, "marks in a hover float")
print("MARKDOWN_HOVER_OK")

for _, group in ipairs({ "RenderMarkdownH1Bg", "RenderMarkdownH2Bg", "RenderMarkdownCode" }) do
    local hl = vim.api.nvim_get_hl(0, { name = group })
    assert(hl.link == nil and hl.bg ~= nil, group .. " comes from the theme, not a default link")
end
print("MARKDOWN_THEME_OK")

vim.fn.delete(file)
print("MARKDOWN_SMOKE_OK")
