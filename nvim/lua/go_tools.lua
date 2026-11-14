-- The Go tools install.sh chose for the go in PATH (go/go-tools): gopls,
-- gofumpt and dlv by their full paths from
-- ~/.config/dotfiles-local/go-tools.env. On a machine whose go is not the
-- one of Homebrew the tools are built by that go and live outside PATH;
-- the file is how the editor finds them. Without the file, or for a path
-- that is gone, the name is used and PATH decides, as before.
--
-- The file is `KEY=value` lines (GOPLS=, GOFUMPT=, DLV=, GO=, GO_VERSION=,
-- GO_FROM=) with # comments; DOTFILES_GO_TOOLS names another file.

local M = {}

local loaded

function M.file()
    return vim.env.DOTFILES_GO_TOOLS
        or ((vim.env.XDG_CONFIG_HOME or (vim.env.HOME .. "/.config")) .. "/dotfiles-local/go-tools.env")
end

-- The pairs of the file; {} without it.
function M.load()
    if loaded then
        return loaded
    end
    loaded = {}
    local ok, lines = pcall(vim.fn.readfile, M.file())
    if not ok then
        return loaded
    end
    for _, line in ipairs(lines) do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key and not line:match("^%s*#") then
            value = value:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
            loaded[key] = value
        end
    end
    return loaded
end

-- Forget the file (tests, or after install.sh rewrote it).
function M.reset()
    loaded = nil
end

-- The command to run for the tool: the path from the file when it is
-- there and executable, the bare name otherwise.
function M.path(name)
    local value = M.load()[name:upper()]
    if value and value ~= "" and vim.fn.executable(value) == 1 then
        return value
    end
    return name
end

-- What the file says about go itself, for messages: "go1.22.5 (other)".
function M.describe()
    local env = M.load()
    if not env.GO_VERSION then
        return nil
    end
    return env.GO_VERSION .. (env.GO_FROM and (" (" .. env.GO_FROM .. ")") or "")
end

return M
