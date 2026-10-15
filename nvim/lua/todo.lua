-- TODO comments: every one in the project in a picker with a preview
-- (Space st), the next / previous one in the file (]t / [t).
--
-- A TODO is a comment that starts with a tag: `// TODO: …`,
-- `// FIXME(name): …`, `-- XXX …` in SQL, `# HACK …` in shell and YAML.
-- `context.TODO()` and a tag in the middle of a sentence are not.
-- The tags themselves are coloured by the Tree-sitter comment parser.

local M = {}

M.tags = { "TODO", "FIXME", "HACK", "XXX", "BUG" }

local markers = [[(//|#|--|/\*|^\s*\*)\s*]]

-- The same pattern for ripgrep (Rust regex) and for Vim search.
function M.rg_pattern()
    return markers .. "(" .. table.concat(M.tags, "|") .. [[)\b]]
end

function M.vim_pattern()
    return [[\v]] .. markers .. [[\zs<(]] .. table.concat(M.tags, "|") .. ")>"
end

function M.pick(cwd)
    local fzf = require("fzf-lua")
    fzf.grep({
        cwd = cwd,
        search = M.rg_pattern(),
        no_esc = true,
        rg_glob = false,
        resume = false,
        prompt = "TODO> ",
        rg_opts = fzf.defaults.grep.rg_opts:gsub("%-e$", "--glob=!vendor/** -e"),
        winopts = { title = " TODO · FIXME · HACK · XXX · BUG " },
    })
end

-- ]t / [t with a count; the jump is in the jumplist.
function M.jump(forward)
    for _ = 1, vim.v.count1 do
        if vim.fn.search(M.vim_pattern(), forward and "sW" or "sbW") == 0 then
            vim.notify("No TODO " .. (forward and "below" or "above"), vim.log.levels.INFO, { title = "todo" })
            return
        end
    end
end

return M
