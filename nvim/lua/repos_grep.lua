-- Space ?: live grep over every repository at once, the ones the tmux
-- `projects` popup knows: the folders directly under $DEV_PROJECT_ROOTS
-- (space-separated; ~/workspace and ~/Projects by default). Lines carry the
-- path from the home folder (workspace/billing/internal/…), so the
-- repository is visible; task worktrees (.worktrees/) and vendor/ stay
-- out, as does whatever .gitignore hides. Alt-c of Space / does not apply:
-- the whole set of repositories is the category.
local M = {}

-- The roots: $DEV_PROJECT_ROOTS or the defaults, those that exist.
function M.roots(env, home)
    env = env or vim.env.DEV_PROJECT_ROOTS
    home = home or vim.env.HOME
    local roots = {}
    for _, root in ipairs(env and vim.split(env, "%s+", { trimempty = true }) or { home .. "/workspace", home .. "/Projects" }) do
        root = vim.fs.normalize((root:gsub("^~", home)))
        if vim.fn.isdirectory(root) == 1 then
            table.insert(roots, root)
        end
    end
    return roots
end

-- The repositories: every folder directly under a root, not hidden,
-- sorted; a root that is itself a git repository counts whole.
function M.projects(roots)
    local projects = {}
    for _, root in ipairs(roots) do
        if vim.uv.fs_stat(root .. "/.git") then
            table.insert(projects, root)
        else
            for name, kind in vim.fs.dir(root) do
                if kind == "directory" and name:sub(1, 1) ~= "." then
                    table.insert(projects, root .. "/" .. name)
                end
            end
        end
    end
    table.sort(projects)
    return projects
end

-- The picker options: rg from the home folder over the repositories.
function M.spec(projects, home)
    home = home or vim.env.HOME
    local paths = {}
    for _, project in ipairs(projects) do
        table.insert(paths, vim.fs.relpath(home, project) or project)
    end
    return {
        cwd = home,
        resume = false,
        no_esc = true,
        search = "",
        search_paths = paths,
        rg_opts = "--column --line-number --no-heading --color=always --smart-case --max-columns=4096"
            .. " --glob '!**/.worktrees/**' --glob '!**/vendor/**' --glob '!**/.git/**' -e",
        winopts = { title = string.format(" grep · %d repositories ", #projects) },
    }
end

function M.live_grep()
    local projects = M.projects(M.roots())
    if #projects == 0 then
        vim.notify("No repositories under $DEV_PROJECT_ROOTS (~/workspace, ~/Projects)", vim.log.levels.WARN)
        return
    end
    require("fzf-lua").live_grep(M.spec(projects))
end

return M
