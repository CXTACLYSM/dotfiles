local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

local go_lsp = require("go_lsp")

local function normalize(path)
    local absolute = vim.fs.normalize(vim.fs.abspath(path))
    return vim.uv.fs_realpath(absolute) or absolute
end

local base = vim.fn.tempname()
local repo = base .. "/repo"
local module = repo .. "/module"
local nested = module .. "/nested"
local path = nested .. "/main.go"

vim.fn.mkdir(nested, "p")
vim.fn.mkdir(repo .. "/.git", "p")
vim.fn.writefile({ "go 1.23.0" }, repo .. "/go.work")
vim.fn.writefile({ "module example.com/root-test", "", "go 1.23.0" }, module .. "/go.mod")
vim.fn.writefile({ "package nested" }, path)

assert(go_lsp.root_for_path(path) == normalize(repo), "go.work priority failed")
vim.fn.delete(repo .. "/go.work")
assert(go_lsp.root_for_path(path) == normalize(module), "go.mod fallback failed")
vim.fn.delete(module .. "/go.mod")
assert(go_lsp.root_for_path(path) == normalize(repo), ".git fallback failed")
vim.fn.delete(repo .. "/.git", "rf")
assert(go_lsp.root_for_path(path) == normalize(nested), "directory fallback failed")

local config = go_lsp.config({
    settings = {
        gopls = {
            staticcheck = true,
        },
    },
})

assert(config.cmd_env.GOTOOLCHAIN == nil, "gopls must inherit the shell GOTOOLCHAIN policy")
assert(config.cmd_env.GOPROXY == nil, "gopls must not override GOPROXY")

local pinned = go_lsp.config({ cmd_env = { GOTOOLCHAIN = "local" } })
assert(vim.deep_equal(go_lsp.config({}).cmd, { "gopls", "-remote=auto" }) or vim.env.NVIM_GOPLS_REMOTE == "0",
    "gopls must use the shared daemon by default")
assert(vim.deep_equal(go_lsp.config({ remote = false }).cmd, { "gopls" }), "remote=false must run gopls in-process")
assert(vim.deep_equal(go_lsp.config({ remote = true }).cmd, { "gopls", "-remote=auto" }), "remote=true must forward")
assert(pinned.cmd_env.GOTOOLCHAIN == "local", "explicit toolchain pin was dropped")
assert(config.workspace_required == false, "standalone workspace support disabled")
assert(config.settings.gopls.semanticTokens == true, "semantic tokens disabled")
assert(config.settings.gopls.staticcheck == true, "gopls settings merge failed")

vim.fn.delete(base, "rf")
print("GO_LSP_ROOT_SMOKE_OK")
