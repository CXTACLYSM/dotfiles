-- grP: the rpc under the cursor in every repository. From an `rpc` line
-- of a .proto, from generated code, from a handler or from a client call
-- (`client.PlaceOrder(ctx, …)`; gopls leads to the generated method, as
-- grp does), the service and rpc are known; rg then searches the
-- repositories of Space ? for them: the handlers (`func (s *Server)
-- PlaceOrder(ctx …)`), the contracts (`rpc PlaceOrder(`), the calls
-- (`.PlaceOrder(ctx`) and the tests. Handlers come first: the service
-- that owns the rpc is the one with the handler. Enter opens the file,
-- also in another repository.
local M = {}

local go_proto = require("go_proto")
local repos_grep = require("repos_grep")

local function notify(text, level)
    vim.notify(text, level or vim.log.levels.INFO)
end

local function file_lines(path)
    return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
end

-- The rpc at the cursor: done({ service, name }) or done(nil, reason).
-- In a .proto: the rpc line or the rpc around; in Go: generated code
-- directly, else gopls's definition or implementation in generated code.
function M.rpc_at_cursor(root, done)
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if vim.bo[bufnr].filetype == "proto" then
        local target = go_proto.proto_target(lines, cursor[1] - 1)
        if target and target.kind == "rpc" then
            return done({ service = target.service, name = target.name })
        end
        return done(nil, "put the cursor on an rpc")
    end
    if vim.bo[bufnr].filetype ~= "go" then
        return done(nil, "grP works in Go and .proto files")
    end
    local function from(path, row, col)
        local target = go_proto.go_target(file_lines(path), row, col)
        if target and target.kind == "rpc" then
            done({ service = target.service, name = target.name })
            return true
        end
        return false
    end
    local here = vim.api.nvim_buf_get_name(bufnr)
    local target = go_proto.go_target(lines, cursor[1] - 1, cursor[2])
    if target and target.kind == "rpc" then
        return done({ service = target.service, name = target.name })
    end
    local client = vim.lsp.get_clients({ bufnr = bufnr, name = "gopls" })[1]
    if not client then
        return done(nil, "no gopls in this buffer")
    end
    local function places(result)
        local out = {}
        for _, item in ipairs(result and (vim.islist(result) and result or { result }) or {}) do
            local uri = item.uri or item.targetUri
            local range = item.targetSelectionRange or item.range
            if uri and range then
                local path = vim.uri_to_fname(uri)
                local line = file_lines(path)[range.start.line + 1] or ""
                table.insert(out, { path = path, row = range.start.line,
                    col = vim.str_byteindex(line, client.offset_encoding, range.start.character, false) })
            end
        end
        return out
    end
    local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
    client:request("textDocument/definition", params, function(_, result)
        local definition = places(result)[1]
        if definition and from(definition.path, definition.row, definition.col) then
            return
        end
        local at = definition or { path = here, row = cursor[1] - 1, col = cursor[2] }
        local line = file_lines(at.path)[at.row + 1] or ""
        client:request("textDocument/implementation", {
            textDocument = { uri = vim.uri_from_fname(at.path) },
            position = { line = at.row, character = vim.str_utfindex(line, client.offset_encoding, at.col, false) },
        }, function(err, implemented)
            for _, place in ipairs(not err and places(implemented) or {}) do
                if from(place.path, place.row, place.col) then
                    return
                end
            end
            done(nil, "not an rpc: neither generated from a .proto nor implementing a generated interface")
        end, bufnr)
    end, bufnr)
end

-- The rg command over `projects` for the rpc `name`: handlers, contracts
-- and calls; generated code, vendor and worktrees out.
function M.command(name, projects, home)
    local cmd = { "rg", "--line-number", "--no-heading", "--color=never", "--no-messages",
        "--glob", "*.go", "--glob", "*.proto",
        "--glob", "!*.pb.go", "--glob", "!*.pb.*.go", "--glob", "!*.connect.go", "--glob", "!*mock*",
        "--glob", "!**/vendor/**", "--glob", "!**/.worktrees/**", "--glob", "!**/.git/**",
        "-e", string.format([[^\s*rpc\s+%s\s*\(]], name),
        "-e", string.format([[func\s*\([^)]*\)\s*%s\s*\(]], name),
        "-e", string.format([[\.%s\s*\(]], name),
    }
    for _, project in ipairs(projects) do
        table.insert(cmd, vim.fs.relpath(home, project) or project)
    end
    return cmd
end

-- What a matching line is: "handler", "contract", "test" or "call".
function M.kind(path, line, name)
    if path:match("%.proto$") then
        return "contract"
    end
    if path:match("_test%.go$") then
        return "test"
    end
    if line:match("^%s*func%s*%(") and line:match("%)%s*" .. name .. "%s*%(") then
        return "handler"
    end
    return "call"
end

-- The matches as { kind, repo, path (from home), line, text }, handlers
-- first, then contracts, calls and tests, each group by repository.
function M.matches(output, name, projects, home)
    local rank = { handler = 1, contract = 2, call = 3, test = 4 }
    local out = {}
    for _, raw in ipairs(vim.split(output or "", "\n", { trimempty = true })) do
        local path, number, text = raw:match("^(.-):(%d+):(.*)$")
        if path then
            local repo = path
            for _, project in ipairs(projects) do
                local rel = vim.fs.relpath(home, project) or project
                if path:sub(1, #rel + 1) == rel .. "/" then
                    repo = vim.fs.basename(project)
                    break
                end
            end
            table.insert(out, { kind = M.kind(path, text, name), repo = repo, path = path, line = tonumber(number), text = vim.trim(text) })
        end
    end
    table.sort(out, function(a, b)
        if rank[a.kind] ~= rank[b.kind] then
            return rank[a.kind] < rank[b.kind]
        end
        if a.repo ~= b.repo then
            return a.repo < b.repo
        end
        if a.path ~= b.path then
            return a.path < b.path
        end
        return a.line < b.line
    end)
    return out
end

function M.find(rpc)
    local home = vim.env.HOME
    local projects = repos_grep.projects(repos_grep.roots())
    if #projects == 0 then
        return notify("No repositories under $DEV_PROJECT_ROOTS (~/workspace, ~/Projects)", vim.log.levels.WARN)
    end
    local title = string.format(" %s.%s · %d repositories ", rpc.service or "?", rpc.name, #projects)
    vim.system(M.command(rpc.name, projects, home), { cwd = home, text = true }, vim.schedule_wrap(function(result)
        local matches = M.matches(result.stdout, rpc.name, projects, home)
        if #matches == 0 then
            return notify(string.format("%s: nothing in %d repositories", rpc.name, #projects))
        end
        local fzf = require("fzf-lua")
        local utils = fzf.utils
        local paint = { handler = utils.ansi_codes.green, contract = utils.ansi_codes.magenta, call = utils.ansi_codes.blue, test = utils.ansi_codes.grey }
        local width = 0
        for _, match in ipairs(matches) do
            width = math.max(width, #match.repo)
        end
        local entries, handlers = {}, 0
        for _, match in ipairs(matches) do
            if match.kind == "handler" then
                handlers = handlers + 1
            end
            table.insert(entries, string.format("%-8s %s%s  %s%s%s:%d:1:",
                paint[match.kind](match.kind), match.repo, string.rep(" ", width - #match.repo),
                utils.ansi_codes.grey(match.text:sub(1, 80)), utils.nbsp, match.path, match.line))
        end
        fzf.fzf_exec(entries, {
            prompt = "Rpc> ",
            cwd = home,
            previewer = "builtin",
            file_icons = false,
            git_icons = false,
            actions = fzf.defaults.actions.files,
            fzf_opts = { ["--ansi"] = true, ["--no-sort"] = true, ["--delimiter"] = utils.nbsp, ["--with-nth"] = "{1}" },
            winopts = { title = title .. string.format("· %d handler%s ", handlers, handlers == 1 and "" or "s") },
        })
    end))
end

function M.show(root)
    M.rpc_at_cursor(root, function(rpc, reason)
        if not rpc then
            return notify(reason)
        end
        M.find(rpc)
    end)
end

return M
