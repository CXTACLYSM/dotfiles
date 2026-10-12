local expected_root = assert(os.getenv("NVIM_EXPECTED_ROOT"), "NVIM_EXPECTED_ROOT is required")
local required_go = assert(os.getenv("NVIM_REQUIRED_GO"), "NVIM_REQUIRED_GO is required")

local function real(path)
    return vim.uv.fs_realpath(path) or vim.fs.normalize(vim.fs.abspath(path))
end

local attached = vim.wait(20000, function()
    return #vim.lsp.get_clients({ bufnr = 0, name = "gopls" }) == 1
end, 50)
assert(attached, "gopls did not attach to newer-toolchain fixture")

local client = assert(vim.lsp.get_clients({ bufnr = 0, name = "gopls" })[1])
assert(real(client.config.root_dir) == real(expected_root), "newer-toolchain root mismatch")
assert(client.config.cmd_env.GOTOOLCHAIN == nil, "gopls must not pin GOTOOLCHAIN itself")
assert(vim.env.GOTOOLCHAIN == "local", "fixture must run under a shell-level GOTOOLCHAIN=local policy")

local diagnosed = vim.wait(15000, function()
    for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
        if diagnostic.message:find("GOTOOLCHAIN=local", 1, true)
            and diagnostic.message:find("requires go >= " .. required_go, 1, true)
        then
            return true
        end
    end
    return false
end, 50)
assert(diagnosed, "newer Go requirement did not produce a local-toolchain diagnostic")

print("TOOLCHAIN_POLICY_OK inherited_shell_policy=local clear_version_diagnostic=true required_go=" .. required_go)
