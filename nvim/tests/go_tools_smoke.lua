local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

-- The Go tools by their paths from go-tools.env (lua/go_tools.lua).
local tools = require("go_tools")

-- No file: the names, PATH decides.
vim.env.DOTFILES_GO_TOOLS = vim.fn.tempname() .. "-missing.env"
tools.reset()
assert(vim.deep_equal(tools.load(), {}), "no file, nothing loaded")
assert(tools.path("gopls") == "gopls" and tools.path("dlv") == "dlv", "bare names without the file")
assert(tools.describe() == nil, "nothing to describe")

-- The file: a path that exists is used, a path that is gone falls back.
local file = vim.fn.tempname() .. ".env"
vim.fn.writefile({
    "# written by install.sh",
    "GO=/usr/local/go/bin/go",
    "GO_VERSION=go1.22.5",
    "GO_FROM=other",
    "GOPLS=/bin/sh",
    'GOFUMPT="/bin/ls"',
    "DLV=/nonexistent/dlv",
    "  # indented comment",
    "",
    "BROKEN LINE",
}, file)
vim.env.DOTFILES_GO_TOOLS = file
tools.reset()
local env = tools.load()
assert(env.GO == "/usr/local/go/bin/go" and env.GO_VERSION == "go1.22.5", vim.inspect(env))
assert(env["BROKEN LINE"] == nil and env["#"] == nil, "comments and junk are skipped")
assert(tools.path("gopls") == "/bin/sh", "the path from the file")
assert(tools.path("gofumpt") == "/bin/ls", "quotes are stripped")
assert(tools.path("dlv") == "dlv", "a path that is gone falls back to the name")
assert(tools.path("gofmt") == "gofmt", "a tool the file does not name")
assert(tools.describe() == "go1.22.5 (other)", tools.describe())

-- The default location.
vim.env.DOTFILES_GO_TOOLS = nil
vim.env.XDG_CONFIG_HOME = "/x/config"
assert(tools.file() == "/x/config/dotfiles-local/go-tools.env", tools.file())
vim.env.XDG_CONFIG_HOME = nil
assert(tools.file() == vim.env.HOME .. "/.config/dotfiles-local/go-tools.env", tools.file())

vim.fn.delete(file)
print("GO_TOOLS_OK")
