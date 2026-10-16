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
    "",
    "- [x] done",
    "- [ ] open",
    "",
    "> [!NOTE]",
    "> body",
}, file)

vim.cmd.edit(file)
local buf = vim.api.nvim_get_current_buf()
assert(vim.bo[buf].filetype == "markdown", "markdown filetype")
wait_for(function()
    return marks(buf) > 0
end, "marks in the markdown buffer")
assert(vim.wo.conceallevel == 3, "raw marks hidden while drawn")
print(string.format("MARKDOWN_RENDER_OK marks=%d", marks(buf)))

-- render-markdown drops (not delays) an update that comes within its
-- debounce (100 ms) of the previous one; a person never presses Space m
-- that fast after a redraw, the test has to wait.
local function settle()
    vim.wait(250, function()
        return false
    end)
end

local toggle = vim.fn.maparg("<leader>m", "n", false, true)
assert(toggle.buffer == 1 and toggle.desc == "Markdown drawn / raw", "Space m in markdown buffers")
settle()
toggle.callback()
wait_for(function()
    return marks(buf) == 0
end, "raw view after Space m")
settle()
toggle.callback()
wait_for(function()
    return marks(buf) > 0
end, "drawn view after the second Space m")
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
