local M = {}

local function normalize(path)
    if not path or path == "" then
        return nil
    end

    local absolute = vim.fs.normalize(vim.fs.abspath(path))
    return vim.uv.fs_realpath(absolute) or absolute
end

local function containing_directory(path)
    path = normalize(path)
    if not path then
        return normalize(vim.fn.getcwd())
    end

    local stat = vim.uv.fs_stat(path)
    if stat and stat.type == "directory" then
        return path
    end

    return vim.fs.dirname(path) or normalize(vim.fn.getcwd())
end

function M.root_for_path(path)
    path = normalize(path)
    if not path then
        return normalize(vim.fn.getcwd())
    end

    -- Marker priority is intentional: an enclosing go.work owns its modules,
    -- then a module owns its files, then a repository is the broad fallback.
    return normalize(vim.fs.root(path, "go.work"))
        or normalize(vim.fs.root(path, "go.mod"))
        or normalize(vim.fs.root(path, ".git"))
        or containing_directory(path)
end

function M.root_for_buffer(bufnr)
    return M.root_for_path(vim.api.nvim_buf_get_name(bufnr))
end

function M.root_dir(bufnr, on_dir)
    on_dir(M.root_for_buffer(bufnr))
end

function M.config(opts)
    opts = opts or {}

    local settings = vim.tbl_deep_extend("force", {
        gopls = {
            semanticTokens = true,
        },
    }, opts.settings or {})

    -- Do not pin GOTOOLCHAIN here. gopls runs `go list` in the module
    -- directory, and `go.mod` may require a newer toolchain than the system
    -- `go` (auto-switch through the module cache, as in the shell). Forcing
    -- "local" makes packages.Load fail with "go.mod requires go >= X", which
    -- disables references, highlights and semantic tokens. The shell policy
    -- is inherited; pass `cmd_env = { GOTOOLCHAIN = "local" }` to pin it.
    local cmd_env = vim.tbl_extend("force", {}, opts.cmd_env or {})

    -- One gopls daemon per user serves every Neovim in every tmux window:
    -- the workspace is indexed once instead of once per editor. The daemon
    -- exits a minute after its last client leaves. Set NVIM_GOPLS_REMOTE=0
    -- (or `remote = false`) for an isolated in-process gopls, as verify.sh
    -- does for its throwaway fixtures.
    local remote = opts.remote
    if remote == nil then
        remote = vim.env.NVIM_GOPLS_REMOTE ~= "0"
    end
    local cmd = opts.cmd or (remote and { "gopls", "-remote=auto" } or { "gopls" })

    return {
        cmd = cmd,
        cmd_env = cmd_env,
        filetypes = { "go", "gomod", "gowork" },
        root_dir = M.root_dir,
        workspace_required = false,
        settings = settings,
    }
end

function M.setup(opts)
    vim.lsp.config("gopls", M.config(opts))
    vim.lsp.enable("gopls")
end

return M
