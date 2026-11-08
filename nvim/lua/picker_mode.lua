-- A normal mode for every fzf-lua picker, as in Space f: Esc leaves
-- typing for a normal mode (·N in the prompt) where j / k move, g is the
-- first line, l or Enter accepts, q or Esc closes and i types again. A
-- picker opened with M.prompt() starts in it; a picker that needs a
-- query first (live grep, workspace symbols) starts typing.
--
-- fzf keeps no state of its own, so the mode lives in the prompt and
-- every key is a one-line shell `transform` that reads $FZF_PROMPT: no
-- round trip to Neovim. Space f has its own keys (lua/file_tree.lua) on
-- top of these. With a mark of "·N> " a prompt "Symbols> " becomes
-- "Symbols ·N> " and "> " becomes "·N> ".

local M = {}

M.mark = "·N> "

-- The prompt of a picker that starts in the normal mode: "Symbols" →
-- "Symbols ·N> ", "" → "·N> ".
function M.prompt(base)
    return (base ~= "" and base .. " " or "") .. M.mark
end

-- transform: one branch in the normal mode, the other while typing.
local function either(normal, typing)
    return string.format([[transform:case "$FZF_PROMPT" in *"%s") %s ;; *) %s ;; esac]], M.mark, normal, typing)
end

local to_normal = [[p="${FZF_PROMPT%> }"; echo "change-prompt(${p:+$p }]] .. M.mark .. [[)"]]
local to_typing = [[p="${FZF_PROMPT%]] .. M.mark .. [[}"; echo "change-prompt(${p% }> )"]]

-- The keys of the normal mode and what they do; typing keeps the letter.
M.actions = { j = "down", k = "up", g = "first", q = "abort", l = "print(enter)+accept", h = "" }

-- fzf-lua keymap.fzf entries for fzf.setup.
function M.binds()
    local binds = {
        esc = either("echo abort", to_normal),
        i = either(to_typing, [[echo "put(i)"]]),
    }
    for key, action in pairs(M.actions) do
        binds[key] = either(string.format([[echo "%s"]], action), string.format([[echo "put(%s)"]], key))
    end
    return binds
end

-- M.binds() run as fzf would, for the tests: the action for a key with a
-- prompt, by `shell`.
function M.run(shell, key, prompt)
    local bind = M.binds()[key]:gsub("^transform:", "")
    local result = vim.system({ shell, "-c", bind }, { env = { FZF_PROMPT = prompt }, text = true }):wait()
    assert(result.code == 0, shell .. ": " .. (result.stderr or ""))
    return vim.trim(result.stdout)
end

return M
