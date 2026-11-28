-- Markdown drawn for reading (render-markdown.nvim): headings, code blocks,
-- tables, lists, quotes and links are drawn over the text. The cursor line
-- and Insert mode show the raw markdown; a read-only `nvim -R` (the tmux
-- documentation popup) keeps every line drawn. Space M switches the buffer
-- between drawn and raw.
--
-- Space m shows the file as a page (md-render.nvim): the markdown is
-- rendered into a read-only buffer of its own ("README.md [render]",
-- filetype md-render) that takes the window in place of the source —
-- paragraphs reflowed to the width of the window (up to M.page_width),
-- tables boxed with their cells wrapped and no column narrower than its
-- longest word (M.fit_columns), headings marked by level (Nerd
-- Font glyphs: the page is for the terminal of the iTerm profile), no
-- line numbers; `za` or Enter fold a callout. Space m again brings the
-- source back, the cursor on the same line. The source buffer is never
-- touched, so render-markdown stays for editing. No network: a remote
-- image or a mermaid picture would need a Kitty-graphics terminal, which
-- iTerm2 is not, so md-render draws neither and asks nothing.
--
-- A ```mermaid block is drawn as a box diagram over its source
-- (lua/markdown_diagrams.lua on the engine of ascii-mermaid: flowcharts,
-- sequence, state, class and ER diagrams, gantt, pie, timeline). The
-- cursor in a block reveals its source; `nvim -R` never does. Space m
-- clears the diagrams with the rest of the drawing.

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
        -- Floats (K, signature help, the docs of completion) are scratch
        -- buffers sized by their text: there a code block is drawn as wide
        -- as its text, without pads, a minimum width and the bar with the
        -- language over it, so the float holds exactly its content. The
        -- cursor in a float (K again) keeps the drawing: a raw fence
        -- under it would take a row of a float sized without it.
        overrides = {
            buftype = {
                nofile = {
                    code = {
                        language = false,
                        min_width = 0,
                        left_pad = 0,
                        right_pad = 0,
                    },
                    anti_conceal = { enabled = false },
                    win_options = {
                        concealcursor = { rendered = "nc" },
                    },
                },
            },
        },
    })
end

M.diagrams = false

-- Widest rendered line of a page; a narrower window wraps to its width.
M.page_width = 100

-- md-render narrows the columns of a table wider than the page in
-- proportion to their widest cells, so a short column beside a long one
-- comes out narrower than its longest word, and the word is cut into
-- syllables ("edi" / "tor"). Such a table gets other widths here: every
-- column keeps at least its longest word, the rest of the width is shared
-- in proportion. Any other table is left to md-render as it is: one that
-- fits, one where no column falls short, one whose longest words alone
-- overflow the page.
function M.fit_columns(parsed, indent, max_width)
    local widths = parsed.col_widths
    if not max_width or #widths == 0 then
        return parsed
    end
    local sep = vim.api.nvim_strwidth("│")
    -- The line of a row: indent, then "│ " cell " " per column, then "│".
    local budget = max_width - vim.api.nvim_strwidth(indent) - #widths * (sep + 2) - sep
    local words, natural, least, wants = {}, 0, 0, 0
    for col, width in ipairs(widths) do
        local longest = 0
        local cells = { parsed.headers[col] }
        for _, row in ipairs(parsed.rows) do
            table.insert(cells, row[col])
        end
        for _, cell in ipairs(cells) do
            for word in (cell.text or ""):gmatch("%S+") do
                longest = math.max(longest, vim.api.nvim_strwidth(word))
            end
        end
        words[col] = math.min(longest, width)
        natural = natural + width
        least = least + words[col]
        -- A column wider than the page wants the page.
        wants = wants + math.min(width, budget)
    end
    if natural <= budget or least > budget then
        return parsed
    end
    -- The share md-render gives a column (markdown_table.lua); the
    -- rounding after it only adds.
    local short = false
    for col, width in ipairs(widths) do
        short = short or math.floor(math.min(width, budget) / wants * budget) < words[col]
    end
    if not short then
        return parsed
    end
    -- Over the longest words, each column gets a share of what is left in
    -- proportion to what it wants beyond them.
    wants = wants - least
    local share = wants > 0 and (budget - least) / wants or 0
    local fitted, used = {}, 0
    for col, width in ipairs(widths) do
        fitted[col] = words[col] + math.floor(share * (math.min(width, budget) - words[col]))
        used = used + fitted[col]
    end
    -- What the rounding left, a cell at a time, to the column that lacks most.
    while used < budget do
        local best, lack = nil, 0
        for col, width in ipairs(widths) do
            if width - fitted[col] > lack then
                best, lack = col, width - fitted[col]
            end
        end
        if not best then
            break
        end
        fitted[best] = fitted[best] + 1
        used = used + 1
    end
    return vim.tbl_extend("force", {}, parsed, { col_widths = fitted })
end

function M.setup()
    -- `nvim -R` is for reading: no raw cursor line there, and a diagram
    -- never gives way to its source.
    local reader = vim.tbl_contains(vim.v.argv, "-R")
    require("render-markdown").setup(M.config(reader))
    local diagrams = require("markdown_diagrams")
    if diagrams.available() then
        diagrams.setup({ reader = reader })
        M.diagrams = true
    end

    vim.g.md_render_max_width = M.page_width
    -- Scaled headings are a Kitty protocol found by querying the terminal;
    -- iTerm2 has none, so the query is not sent.
    require("md-render.text_size").setup({ enabled = false })
    -- A table is drawn with its cells wrapped, as a browser draws it.
    -- md-render's own default cuts a wide cell to "…" and waits for Enter
    -- on the table to wrap it; there is no setting for the default, so the
    -- renderer is asked for the wrapped form every time, with the widths of
    -- M.fit_columns (the version is pinned, nvim-pack-lock.json).
    local tables = require("md-render.markdown_table")
    local render = tables.render
    tables.render = function(parsed, indent, max_width, _, buf_dir)
        return render(M.fit_columns(parsed, indent, max_width), indent, max_width, true, buf_dir)
    end
end

-- The window between the source and its page (md-render.nvim), in place.
-- md-render sets the filetype of the page with autocommands off, so the
-- key back is mapped here, once the page is in the window.
function M.page()
    require("md-render.preview").toggle()
    local buf = vim.api.nvim_get_current_buf()
    if vim.b[buf].md_render and not vim.b[buf].markdown_page_keys then
        vim.b[buf].markdown_page_keys = true
        vim.keymap.set("n", "<leader>m", M.page, { buffer = buf, desc = "Markdown page / source" })
    end
end

function M.toggle()
    require("render-markdown").buf_toggle()
    local buf = vim.api.nvim_get_current_buf()
    vim.b[buf].markdown_raw = not vim.b[buf].markdown_raw
    if not M.diagrams then
        return
    end
    local diagrams = require("markdown_diagrams")
    if vim.b[buf].markdown_raw then
        diagrams.hide(buf)
    else
        diagrams.show(buf)
    end
end

return M
