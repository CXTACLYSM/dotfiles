local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

-- The diagnostics of the cursor line (lua/cursor_diagnostic.lua): at the
-- end of the line when they fit, wrapped under it when not, never wider
-- than the window; and the step of ]u / [u over the uses of a name
-- (lua/usages.lua).
local cursor_diagnostic = require("cursor_diagnostic")
local width = vim.fn.strdisplaywidth

-- Wrapping: at spaces, a word longer than a row cut, the lines of the
-- message start rows and keep their indent.
local rows = cursor_diagnostic.wrap("one two three four five six", 10)
assert(vim.deep_equal(rows, { "one two", "three four", "five six" }), vim.inspect(rows))
rows = cursor_diagnostic.wrap("a " .. string.rep("x", 25) .. " b", 10)
assert(vim.deep_equal(rows, { "a", string.rep("x", 10), string.rep("x", 10), "xxxxx b" }), vim.inspect(rows))
rows = cursor_diagnostic.wrap("impossible type assertion\n\t\thave M() int\n\t\twant M() string", 40)
assert(vim.deep_equal(rows, { "impossible type assertion", "    have M() int", "    want M() string" }), vim.inspect(rows))
rows = cursor_diagnostic.wrap("сообщение на русском длиннее строки", 12)
for _, row in ipairs(rows) do
    assert(width(row) <= 12, "a row of multibyte text fits: " .. row)
end
assert(table.concat(rows, " ") == "сообщение на русском длиннее строки", vim.inspect(rows))
assert(vim.deep_equal(cursor_diagnostic.wrap("trailing\n\n", 20), { "trailing" }), "no empty rows at the end")

local error_severity = vim.diagnostic.severity.ERROR
local long = "cannot use &model.Customer{…} (value of type *model.Customer) as model.Notifier value in variable"
    .. " declaration: *model.Customer does not implement model.Notifier (missing method Notify)"

-- The layout: at the end while it fits, under the line otherwise.
local layout = cursor_diagnostic.layout({ { message = "declared and not used: x", severity = error_severity } },
    { line_width = 10, indent = 4, text_width = 80 })
assert(layout.virt_text and not layout.virt_lines, "a short message at the end of the line")
assert(layout.virt_text[2][1] == "● declared and not used: x" and layout.virt_text[2][2] == "DiagnosticVirtualTextError",
    vim.inspect(layout))
layout = cursor_diagnostic.layout({ { message = long, severity = error_severity } },
    { line_width = 60, indent = 4, text_width = 80 })
assert(layout.virt_lines and not layout.virt_text, "a long message under the line")
local text = {}
for index, line in ipairs(layout.virt_lines) do
    local row_width = 0
    for _, chunk in ipairs(line) do
        row_width = row_width + width(chunk[1])
    end
    assert(row_width <= 80, "row " .. index .. " fits the window: " .. row_width)
    assert(line[1][1] == "    ", "rows start at the indent of the line")
    assert(line[2][1] == (index == 1 and "● " or "  "), "the mark on the first row only")
    assert(width(line[3][1]) == width(layout.virt_lines[1][3][1]), "the rows of a message are one block")
    table.insert(text, vim.trim(line[3][1]))
end
assert(table.concat(text, " ") == long, "the whole message, nothing cut: " .. table.concat(text, " "))
-- Two diagnostics: the more severe first, each with its mark.
layout = cursor_diagnostic.layout({
    { message = "unused write", severity = vim.diagnostic.severity.WARN },
    { message = long, severity = error_severity },
}, { line_width = 20, indent = 0, text_width = 60 })
assert(layout.virt_lines and #layout.virt_lines >= 3, "several rows")
-- A deep indent gives way to the text.
layout = cursor_diagnostic.layout({ { message = long, severity = error_severity } },
    { line_width = 70, indent = 60, text_width = 80 })
assert(#layout.virt_lines[1][1][1] <= 80 - 2 - cursor_diagnostic.opts.min_text, "indent capped: " .. #layout.virt_lines[1][1][1])
print("CURSOR_DIAGNOSTIC_LAYOUT_OK")

-- In a buffer: the handler draws on the cursor line of the window only.
cursor_diagnostic.setup()
vim.diagnostic.config({ virtual_text = false, cursor_diagnostic = { source = "if_many" } })
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "package main",
    "",
    "func main() {",
    "\tvar n Notifier = &Customer{}",
    "\tx := 5",
    "}",
})
local ns = vim.api.nvim_create_namespace("cursor_diagnostic_smoke")
vim.diagnostic.set(ns, buf, {
    { lnum = 3, col = 18, message = long, severity = error_severity, source = "compiler" },
    { lnum = 4, col = 1, message = "declared and not used: x", severity = error_severity, source = "compiler" },
})
local win = vim.api.nvim_get_current_win()
local info = vim.fn.getwininfo(win)[1]
local text_width = info.width - info.textoff

local function at(line)
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    return cursor_diagnostic.drawn(buf)
end

assert(at(1) == nil, "nothing on a line without diagnostics")
local drawn = at(5)
assert(drawn and drawn.line == 4 and drawn.virt_text, "the short message at the end: " .. vim.inspect(drawn))
assert(drawn.virt_text[2][1] == "● declared and not used: x", "one source: no source in front")
drawn = at(4)
assert(drawn and drawn.line == 3 and drawn.virt_lines, "the long one under its line: " .. vim.inspect(drawn))
for _, line in ipairs(drawn.virt_lines) do
    local row_width = 0
    for _, chunk in ipairs(line) do
        row_width = row_width + width(chunk[1])
    end
    assert(row_width <= text_width, "a row as wide as the window at most: " .. row_width .. " > " .. text_width)
end
assert(#vim.api.nvim_buf_get_extmarks(buf, cursor_diagnostic.namespace, 0, -1, {}) == 1, "the cursor line only")
assert(at(2) == nil, "gone when the cursor leaves")

-- Narrower window: the rows follow it.
at(4)
vim.cmd("vsplit")
vim.cmd("vertical resize 50")
vim.api.nvim_exec_autocmds("WinResized", {})
drawn = cursor_diagnostic.drawn(buf)
info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
for _, line in ipairs(drawn.virt_lines) do
    local row_width = 0
    for _, chunk in ipairs(line) do
        row_width = row_width + width(chunk[1])
    end
    assert(row_width <= info.width - info.textoff, "rewrapped for the narrower window")
end
vim.cmd("only")

-- Several sources: the source in front; disabled: nothing drawn.
local other = vim.api.nvim_create_namespace("cursor_diagnostic_smoke_other")
vim.diagnostic.set(other, buf, { { lnum = 0, col = 0, message = "package comment", severity = vim.diagnostic.severity.HINT, source = "stylecheck" } })
drawn = at(5)
assert(drawn.virt_text[2][1] == "● compiler: declared and not used: x", "sources named when there are several: "
    .. vim.inspect(drawn.virt_text))
vim.diagnostic.enable(false, { bufnr = buf })
assert(cursor_diagnostic.drawn(buf) == nil, "disabled diagnostics are not drawn")
vim.diagnostic.enable(true, { bufnr = buf })
assert(at(5) ~= nil, "drawn again once enabled")
vim.diagnostic.reset(ns, buf)
vim.diagnostic.reset(other, buf)
assert(at(5) == nil, "reset clears the drawing")
print("CURSOR_DIAGNOSTIC_BUFFER_OK")

-- A line at the bottom of the window: the rows under it would be off the
-- screen, so the window scrolls up by the rows that are missing; a line in
-- the middle leaves the view as it is; with 'scrolloff' the line keeps its
-- distance from the top.
local body = {}
for index = 1, 80 do
    body[index] = string.format("\tline%d := %d", index, index)
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
win = vim.api.nvim_get_current_win()
vim.wo[win].scrolloff = 0
local height = vim.fn.getwininfo(win)[1].height
assert(height >= 6, "the window has rows: " .. height)
local bottom = height
vim.diagnostic.set(ns, buf, {
    { lnum = bottom - 1, col = 1, message = long, severity = error_severity },
    { lnum = 2, col = 1, message = long, severity = error_severity },
})
-- nvim_win_text_height leaves out the virtual lines under its last row.
local function fits(lnum, extra)
    local view = vim.fn.getwininfo(win)[1]
    return vim.api.nvim_win_text_height(win, { start_row = view.topline - 1, end_row = lnum }).all + extra <= view.height
end
at(1)
assert(vim.fn.getwininfo(win)[1].topline == 1, "the view starts at the top")
drawn = at(bottom)
assert(drawn and drawn.virt_lines and #drawn.virt_lines > 1, "rows under the bottom line: " .. vim.inspect(drawn))
local topline = vim.fn.getwininfo(win)[1].topline
assert(topline > 1, "the window scrolled up for the rows: topline " .. topline)
assert(topline == #drawn.virt_lines + 1, "by the rows that were missing, no more: topline " .. topline)
assert(fits(bottom - 1, #drawn.virt_lines), "the line and its rows are on the screen")
assert(at(bottom - 2) == nil and vim.fn.getwininfo(win)[1].topline == topline, "the view stays where it is")
vim.cmd("normal! gg")
at(1)
assert(vim.fn.getwininfo(win)[1].topline == 1, "back at the top")
drawn = at(3)
assert(drawn and drawn.virt_lines and vim.fn.getwininfo(win)[1].topline == 1, "a line in the middle: no scroll")
-- 'scrolloff': the line comes no closer to the top than that, even when
-- the rows then do not all fit (a short split).
vim.diagnostic.set(ns, buf, {
    { lnum = 10, col = 1, message = string.rep(long .. " ", 4), severity = error_severity },
})
vim.cmd("split")
local short = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_height(short, 10)
vim.wo[short].scrolloff = 4
vim.cmd("normal! gg")
drawn = at(11)
local view = vim.fn.getwininfo(short)[1]
assert(drawn and drawn.virt_lines and #drawn.virt_lines > 10, "a message taller than the window: " .. vim.inspect(drawn))
assert(view.topline == 11 - 4, "scrolled as far as scrolloff allows, no further: topline " .. view.topline)
vim.cmd("only")
vim.diagnostic.reset(ns, buf)
print("CURSOR_DIAGNOSTIC_REVEAL_OK")

-- ]u / [u: the step from the cursor over the ranges of a name.
local usages = require("usages")
local function range(line, from, to)
    return { start = { line = line, character = from }, ["end"] = { line = line, character = to } }
end
local ranges = { range(1, 4, 9), range(3, 8, 13), range(5, 0, 5), range(5, 10, 15) }
local function step(line, character, count)
    local index, current = usages.step(ranges, { line = line, character = character }, count)
    return index, current
end
assert(step(1, 4, 1) == 2 and select(2, step(1, 4, 1)) == 1, "from the first to the second")
assert(step(1, 8, 1) == 2, "from the last character of the name")
assert(step(5, 12, 1) == 1, "past the end: around to the first")
assert(step(1, 6, -1) == 4, "before the first: around to the last")
assert(step(3, 8, 2) == 4, "a count")
assert(step(2, 0, 1) == 2 and select(2, step(2, 0, 1)) == nil, "between two: the next one")
assert(step(2, 0, -1) == 1, "between two: the previous one")
assert(step(0, 0, -1) == 4 and step(9, 0, 1) == 1, "outside all of them: around")
print("USAGES_STEP_OK")
