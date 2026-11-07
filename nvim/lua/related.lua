-- Space ,: the same domain in other layers. For internal/app/order/handler.go
-- the domain is the folder `order`: the picker lists the files of every
-- other folder named order (internal/service/order/, internal/repo/order/,
-- api/order/v1/ …), then the files named handler.go in other packages, the
-- same layer in other domains, marked `· same name`. Folder names that say
-- nothing about the domain (v1, internal, pkg, cmd, api, app, handler,
-- service, repository …) are skipped upwards, so for api/order/v1/order.proto
-- the domain is order too; a file whose folders are all generic uses its own
-- name. Full screen with a preview, the marks of the file tree; Enter opens.

local M = {}

-- Folder names that are layers or structure, not domains.
M.generic = {
    "v%d+", "internal", "pkg", "cmd", "api", "apis", "app", "apps", "src", "lib", "libs", "proto", "protos", "gen",
    "generated", "test", "tests", "testdata", "mock", "mocks", "fake", "fakes", "handler", "handlers", "service",
    "services", "usecase", "usecases", "repository", "repositories", "repo", "repos", "storage", "store", "model",
    "models", "domain", "entity", "entities", "transport", "delivery", "grpc", "http", "rest", "server", "client",
    "clients", "adapter", "adapters", "port", "ports", "config", "configs", "migrations", "docs",
}

local function notify(message)
    vim.notify(message, vim.log.levels.INFO, { title = "related" })
end

local function generic(name)
    for _, pattern in ipairs(M.generic) do
        if name:match("^" .. pattern .. "$") then
            return true
        end
    end
    return false
end

-- The name of a file without its extensions and _test: handler_test.go →
-- handler, order.pb.go → order; a name that is only an extension (.env)
-- stays.
function M.stem(rel)
    local name = rel:match("[^/]+$") or rel
    local stem = name:gsub("%..*$", "")
    if stem == "" then
        return name
    end
    return (stem:gsub("_test$", ""))
end

-- The domain of a file and where it comes from: the deepest folder whose
-- name is not generic ("folder"), else the stem of the file ("file").
function M.domain(rel)
    local dir = rel:match("^(.*)/[^/]*$")
    if dir then
        local parts = vim.split(dir, "/", { plain = true })
        for index = #parts, 1, -1 do
            if not generic(parts[index]) then
                return parts[index], "folder"
            end
        end
    end
    return M.stem(rel), "file"
end

-- Lines for the picker, "<mark> name  dir/[ · same name]<nbsp>path": the
-- files of other folders of the domain, then files with the same name in
-- other folders. Also the domain and the two counts.
function M.lines(root, rel, paths)
    local file_tree = require("file_tree")
    local utils = require("fzf-lua").utils
    local paint = file_tree.painters()
    local domain, from = M.domain(rel)
    local dir = rel:match("^(.*/)[^/]*$") or ""
    local stem = M.stem(rel)
    local by_domain, by_name = {}, {}
    for _, path in ipairs(paths) do
        local folder = path:match("^(.*/)[^/]*$") or ""
        if path ~= rel and folder ~= dir then
            if from == "folder" and ("/" .. folder):find("/" .. domain .. "/", 1, true) then
                table.insert(by_domain, path)
            elseif M.stem(path) == stem then
                table.insert(by_name, path)
            end
        end
    end
    table.sort(by_domain)
    table.sort(by_name)
    local lines = {}
    local function add(path, note)
        local folder, name = path:match("^(.*/)([^/]*)$")
        table.insert(lines, file_tree.shown_file(paint, name or path, path) .. "  "
            .. paint.Comment((folder or "") .. (note or "")) .. utils.nbsp .. path)
    end
    for _, path in ipairs(by_domain) do
        add(path)
    end
    for _, path in ipairs(by_name) do
        add(path, " · same name")
    end
    return lines, domain, #by_domain, #by_name
end

function M.pick(root)
    local current = vim.api.nvim_buf_get_name(0)
    local rel = current ~= "" and vim.fs.relpath(root, current)
    if not rel then
        notify("Open a file of the project first")
        return
    end
    local categories = require("categories")
    local listed = vim.system(categories.files_command({ category = "all", hidden = true }), { cwd = root, text = true }):wait(10000)
    local paths = vim.split(listed.stdout or "", "\n", { trimempty = true })
    local lines, domain, in_folders, same_name = M.lines(root, rel, paths)
    if #lines == 0 then
        notify(string.format("Nothing else about %s", domain))
        return
    end
    local fzf = require("fzf-lua")
    local actions = {}
    for name, action in pairs(fzf.defaults.actions.files) do
        if not (type(action) == "table" and action.reuse) then
            actions[name] = action
        end
    end
    fzf.fzf_exec(lines, {
        cwd = root,
        prompt = "Related> ",
        previewer = "builtin",
        file_icons = false,
        git_icons = false,
        fzf_opts = {
            ["--ansi"] = true,
            ["--multi"] = true,
            ["--no-sort"] = true,
            ["--tiebreak"] = "index",
            ["--delimiter"] = fzf.utils.nbsp,
            ["--with-nth"] = "{1}",
        },
        winopts = { title = string.format(" related · %s · %d in other folders · %d same name ", domain, in_folders, same_name) },
        actions = actions,
    })
end

return M
