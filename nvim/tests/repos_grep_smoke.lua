local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

-- Space ?: the roots from $DEV_PROJECT_ROOTS or the defaults, the
-- repositories under them, and the picker options (rg from the home
-- folder over the repositories, worktrees and vendor out).
local repos_grep = require("repos_grep")

local function same(got, want, what)
    assert(vim.deep_equal(got, want), what .. ": " .. vim.inspect(got) .. " ~= " .. vim.inspect(want))
end

local home = vim.fn.tempname()
vim.fn.mkdir(home .. "/workspace/billing/.git", "p")
vim.fn.mkdir(home .. "/workspace/order", "p")
vim.fn.mkdir(home .. "/workspace/.hidden", "p")
vim.fn.writefile({ "" }, home .. "/workspace/notes.txt")
vim.fn.mkdir(home .. "/Projects/lib", "p")
vim.fn.mkdir(home .. "/solo/.git", "p")

same(repos_grep.roots(nil, home), { home .. "/workspace", home .. "/Projects" }, "default roots that exist")
same(repos_grep.roots("~/solo " .. home .. "/none  ~/workspace", home), { home .. "/solo", home .. "/workspace" },
    "$DEV_PROJECT_ROOTS, ~ expanded, missing folders skipped")
same(repos_grep.projects({ home .. "/workspace", home .. "/Projects", home .. "/solo" }),
    { home .. "/Projects/lib", home .. "/solo", home .. "/workspace/billing", home .. "/workspace/order" },
    "folders under a root, a root that is a repository itself, no files or hidden folders")

local spec = repos_grep.spec({ home .. "/workspace/billing", home .. "/workspace/order" }, home)
same(spec.search_paths, { "workspace/billing", "workspace/order" }, "paths from the home folder")
assert(spec.cwd == home and spec.no_esc and spec.resume == false, "rg runs from the home folder")
assert(spec.rg_opts:find("!%*%*/%.worktrees/%*%*") and spec.rg_opts:find("!%*%*/vendor/%*%*") and spec.rg_opts:match("%-e$"),
    "worktrees and vendor out, the pattern last: " .. spec.rg_opts)
assert(spec.winopts.title == " grep · 2 repositories ", "the title counts the repositories")
vim.fn.delete(home, "rf")
print("REPOS_GREP_OK")
