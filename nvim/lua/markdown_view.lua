-- Markdown drawn for reading (render-markdown.nvim): headings, code blocks,
-- tables, lists, quotes and links are drawn over the text. The cursor line
-- and Insert mode show the raw markdown; a read-only `nvim -R` (the tmux
-- documentation popup) keeps every line drawn. Space m switches the buffer
-- between drawn and raw.

local M = {}

-- Nerd Font icons live in the Unicode Private Use Areas and come out as
-- boxes in a regular terminal font. They are stripped from every default:
-- callout titles keep their words, links lose the site icons, and the few
-- marks that matter get plain Unicode in M.config.
function M.strip_icons(value)
    if type(value) == "table" then
        local out = {}
        for key, item in pairs(value) do
            out[key] = M.strip_icons(item)
        end
        return out
    end
    if type(value) ~= "string" then
        return value
    end
    local plain = value
        :gsub("\238[\128-\191][\128-\191]", "")         -- U+E000–U+EFFF
        :gsub("\239[\128-\163][\128-\191]", "")         -- U+F000–U+F8FF
        :gsub("\243[\176-\191][\128-\191][\128-\191]", "") -- U+F0000–U+FFFFF
        :gsub("\244[\128-\143][\128-\191][\128-\191]", "") -- U+100000–U+10FFFF
    return plain == value and value or vim.trim(plain)
end

function M.config(reader)
    local defaults = M.strip_icons(require("render-markdown").default)
    -- A callout title is drawn over `[!NOTE]` without hiding it: without
    -- the icon "Note" is shorter, so it is padded to cover the raw text.
    for _, callout in pairs(defaults.callout) do
        local gap = vim.fn.strdisplaywidth(callout.raw) - vim.fn.strdisplaywidth(callout.rendered)
        callout.rendered = callout.rendered .. string.rep(" ", math.max(gap, 0))
    end
    return vim.tbl_deep_extend("force", defaults, {
        -- The sign column belongs to git hunks and diagnostics.
        sign = { enabled = false },
        -- Formulas would run an external converter (utftex, latex2text).
        latex = { enabled = false },
        heading = {
            -- `#` marks are hidden and the level shows by colour; the first
            -- level gets a band above and below, like a title.
            position = "inline",
            icons = { "" },
            border = { true, false },
            border_virtual = true,
            left_pad = 1,
        },
        code = {
            language_icon = false,
            width = "block",
            min_width = 60,
            left_pad = 2,
            right_pad = 2,
        },
        checkbox = {
            unchecked = { icon = "☐" },
            checked = { icon = "☑" },
            custom = { todo = { rendered = "◐" } },
        },
        anti_conceal = { enabled = not reader },
    })
end

function M.setup()
    -- `nvim -R` is for reading: no raw cursor line there.
    require("render-markdown").setup(M.config(vim.tbl_contains(vim.v.argv, "-R")))
end

function M.toggle()
    require("render-markdown").buf_toggle()
end

return M
