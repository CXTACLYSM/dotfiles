-- Space cp: the .proto contracts changed against main, judged before the
-- review. The working tree is compared with the merge base of HEAD and
-- main (origin/main, main or master; HEAD~ without one): every changed
-- declaration in a picker, the breaking ones first — a removed rpc,
-- message, field or enum value, a field whose number or type changed, an
-- rpc whose request or response changed, a service removed. A renamed
-- field (same number, new name) keeps the wire but breaks JSON and the
-- generated Go, so it is marked too. Added declarations and other edits
-- are listed after. Enter opens the line in the working file; a removed
-- declaration opens where its parent begins.
local M = {}

local go_proto = require("go_proto")

local function lines_of(cmd, cwd)
    local result = vim.system(cmd, { cwd = cwd, text = true }):wait()
    if result.code ~= 0 then
        return nil, vim.trim(result.stderr or "")
    end
    return vim.split(result.stdout or "", "\n", { trimempty = true })
end

-- The commit to compare with: the merge base with the main branch, or
-- the parent of HEAD.
function M.base(root)
    for _, branch in ipairs({ "origin/main", "main", "origin/master", "master" }) do
        local out = lines_of({ "git", "merge-base", "HEAD", branch }, root)
        if out and out[1] then
            return out[1], branch
        end
    end
    local out = lines_of({ "git", "rev-parse", "--verify", "--quiet", "HEAD~" }, root)
    return out and out[1] or "HEAD", "HEAD~"
end

-- The .proto files that differ between `base` and the working tree:
-- { path (relative), status (A, D, M, R) }.
function M.changed_files(root, base)
    local out = lines_of({ "git", "diff", "--name-status", "--find-renames", base, "--", "*.proto", "**/*.proto" }, root) or {}
    local files = {}
    for _, line in ipairs(out) do
        local status, path, renamed = line:match("^(%a)%d*\t([^\t]+)\t?(.*)$")
        if status then
            table.insert(files, { path = renamed ~= "" and renamed or path, old_path = path, status = status })
        end
    end
    local untracked = lines_of({ "git", "ls-files", "--others", "--exclude-standard", "--", "*.proto", "**/*.proto" }, root) or {}
    for _, path in ipairs(untracked) do
        table.insert(files, { path = path, old_path = path, status = "A" })
    end
    return files
end

-- The number and the type of a field line: `repeated string names = 3;`
-- → 3, "repeated string"; `map<string, int64> totals = 4` → 4, "map<string, int64>".
function M.field_detail(line)
    local clean = line:gsub("//.*$", ""):gsub("%[.*%]", "")
    local type_text, name, number = clean:match("^%s*(.-)%s*([%w_]+)%s*=%s*(%d+)")
    if not number then
        return nil
    end
    type_text = type_text:gsub("^optional%s+", ""):gsub("%s+", " ")
    return tonumber(number), vim.trim(type_text), name
end

-- The request and response of an rpc line, spaces squeezed.
function M.rpc_signature(line)
    local request, response = line:match("rpc%s+[%w_]+%s*%(%s*(.-)%s*%)%s*returns%s*%(%s*(.-)%s*%)")
    if not request then
        return nil
    end
    return request:gsub("%s+", " ") .. " → " .. response:gsub("%s+", " ")
end

-- Enum values: `NAME = 2;` inside an enum block, with their numbers.
local function enum_values(lines, declarations)
    local values = {}
    for _, declaration in ipairs(declarations) do
        if declaration.kind == "enum" then
            local depth = 0
            for row = declaration.row + 1, #lines do
                local line = lines[row]:gsub("//.*$", "")
                local name, number = line:match("^%s*([%u][%w_]*)%s*=%s*(%d+)")
                if name and depth == 1 then
                    values[declaration.path .. "." .. name] = { number = tonumber(number), row = row - 1, enum = declaration }
                end
                depth = depth + select(2, line:gsub("{", "")) - select(2, line:gsub("}", ""))
                if depth == 0 and row > declaration.row + 1 then
                    break
                end
            end
        end
    end
    return values
end

local function key_of(declaration)
    if declaration.kind == "field" then
        return "field " .. declaration.path .. "." .. declaration.name
    end
    if declaration.kind == "rpc" then
        return "rpc " .. (declaration.service or "") .. "." .. declaration.name
    end
    return declaration.kind .. " " .. declaration.path
end

local function parent_row(declarations, declaration)
    local parent = nil
    for _, candidate in ipairs(declarations) do
        if candidate.kind ~= "field" and candidate.row < declaration.row
            and ((declaration.kind == "field" and candidate.path == declaration.path)
                or (declaration.kind == "rpc" and candidate.kind == "service" and candidate.name == declaration.service)
                or (declaration.kind ~= "field" and declaration.kind ~= "rpc" and candidate.kind == "message"
                    and declaration.path:sub(1, #candidate.path + 1) == candidate.path .. ".")) then
            parent = candidate
        end
    end
    return parent and parent.row or 0
end

-- The changes between two versions of a .proto: each { severity
-- ("breaking", "warning", "added", "changed"), what, detail, row (in the
-- new file, 0-based) }.
function M.compare(old_lines, new_lines)
    local old_declarations = go_proto.proto_declarations(old_lines)
    local new_declarations = go_proto.proto_declarations(new_lines)
    local old_by, new_by = {}, {}
    for _, declaration in ipairs(old_declarations) do
        old_by[key_of(declaration)] = declaration
    end
    for _, declaration in ipairs(new_declarations) do
        new_by[key_of(declaration)] = declaration
    end
    local changes = {}
    local function add(severity, what, detail, row)
        table.insert(changes, { severity = severity, what = what, detail = detail, row = row })
    end

    -- Renames: a field of the same message and number with a new name.
    local renamed = {}
    for key, declaration in pairs(old_by) do
        if declaration.kind == "field" and not new_by[key] then
            local number = M.field_detail(old_lines[declaration.row + 1])
            for new_key, candidate in pairs(new_by) do
                if candidate.kind == "field" and candidate.path == declaration.path and not old_by[new_key] then
                    local new_number = M.field_detail(new_lines[candidate.row + 1])
                    if number and number == new_number then
                        renamed[key], renamed[new_key] = true, true
                        add("warning", key, string.format("renamed to %s (number %d kept: wire ok, JSON and Go break)",
                            candidate.name, number), candidate.row)
                    end
                end
            end
        end
    end

    for key, declaration in pairs(old_by) do
        local current = new_by[key]
        if not current and not renamed[key] then
            local parent = nil
            for _, candidate in ipairs(new_declarations) do
                if candidate.kind ~= "field" and (
                    (declaration.kind == "field" and candidate.path == declaration.path)
                    or (declaration.kind == "rpc" and candidate.kind == "service" and candidate.name == declaration.service)) then
                    parent = candidate
                end
            end
            add("breaking", key, "removed", parent and parent.row or 0)
        elseif current then
            if declaration.kind == "field" then
                local old_number, old_type = M.field_detail(old_lines[declaration.row + 1])
                local new_number, new_type = M.field_detail(new_lines[current.row + 1])
                if old_number ~= new_number then
                    add("breaking", key, string.format("number %s → %s", old_number, new_number), current.row)
                elseif old_type ~= new_type then
                    add("breaking", key, string.format("type %s → %s", old_type, new_type), current.row)
                end
            elseif declaration.kind == "rpc" then
                local old_signature = M.rpc_signature(old_lines[declaration.row + 1])
                local new_signature = M.rpc_signature(new_lines[current.row + 1])
                if old_signature ~= new_signature then
                    add("breaking", key, string.format("%s → %s", old_signature, new_signature), current.row)
                end
            end
        end
    end

    local old_values = enum_values(old_lines, old_declarations)
    local new_values = enum_values(new_lines, new_declarations)
    for key, value in pairs(old_values) do
        local current = new_values[key]
        if not current then
            add("breaking", "enum value " .. key, "removed", (new_by["enum " .. value.enum.path] or {}).row or 0)
        elseif current.number ~= value.number then
            add("breaking", "enum value " .. key, string.format("number %d → %d", value.number, current.number), current.row)
        end
    end
    for key, value in pairs(new_values) do
        if not old_values[key] then
            add("added", "enum value " .. key, "", value.row)
        end
    end

    for key, declaration in pairs(new_by) do
        if not old_by[key] and not renamed[key] then
            local detail = ""
            if declaration.kind == "field" then
                local number, type_text = M.field_detail(new_lines[declaration.row + 1])
                detail = number and string.format("%s = %d", type_text, number) or ""
            elseif declaration.kind == "rpc" then
                detail = M.rpc_signature(new_lines[declaration.row + 1]) or ""
            end
            add("added", key, detail, declaration.row)
        end
    end

    -- Other edited lines inside a declaration (options, comments): one
    -- note per declaration, when nothing else was said about it.
    local said = {}
    for _, change in ipairs(changes) do
        said[change.what] = true
    end
    local old_text = table.concat(old_lines, "\n")
    for _, declaration in ipairs(new_declarations) do
        local key = key_of(declaration)
        if old_by[key] and not said[key] and declaration.kind ~= "field" then
            local line = vim.trim(new_lines[declaration.row + 1])
            if not old_text:find(line, 1, true) then
                add("changed", key, "line edited", declaration.row)
                said[key] = true
            end
        end
    end

    local rank = { breaking = 1, warning = 2, changed = 3, added = 4 }
    table.sort(changes, function(a, b)
        if rank[a.severity] ~= rank[b.severity] then
            return rank[a.severity] < rank[b.severity]
        end
        if a.row ~= b.row then
            return a.row < b.row
        end
        return a.what < b.what
    end)
    return changes
end

-- Every change of every changed .proto against the base: { path,
-- severity, what, detail, row }.
function M.collect(root)
    local base, branch = M.base(root)
    local all = {}
    for _, file in ipairs(M.changed_files(root, base)) do
        local old_lines = file.status == "A" and {} or (lines_of({ "git", "show", base .. ":" .. file.old_path }, root) or {})
        local new_lines = file.status == "D" and {} or (vim.fn.filereadable(root .. "/" .. file.path) == 1
            and vim.fn.readfile(root .. "/" .. file.path) or {})
        if file.status == "D" then
            table.insert(all, { path = file.path, severity = "breaking", what = "file " .. file.path, detail = "removed", row = 0 })
        else
            for _, change in ipairs(M.compare(old_lines, new_lines)) do
                change.path = file.path
                table.insert(all, change)
            end
        end
    end
    local rank = { breaking = 1, warning = 2, changed = 3, added = 4 }
    table.sort(all, function(a, b)
        if rank[a.severity] ~= rank[b.severity] then
            return rank[a.severity] < rank[b.severity]
        end
        if a.path ~= b.path then
            return a.path < b.path
        end
        return a.row < b.row
    end)
    return all, branch
end

local marks = {
    breaking = { "✗", "DiagnosticError" },
    warning = { "!", "DiagnosticWarn" },
    changed = { "~", "DiagnosticInfo" },
    added = { "+", "DiagnosticOk" },
}

function M.show(root)
    local changes, branch = M.collect(root)
    if #changes == 0 then
        vim.notify("No .proto changes against " .. branch, vim.log.levels.INFO)
        return
    end
    local fzf = require("fzf-lua")
    local utils = fzf.utils
    local paint = {}
    for severity, mark in pairs(marks) do
        local _, _, fn = utils.ansi_from_hl(mark[2], "")
        paint[severity] = fn or function(text)
            return text
        end
    end
    local width = 0
    for _, change in ipairs(changes) do
        width = math.max(width, #change.what)
    end
    local entries = {}
    local breaking = 0
    for _, change in ipairs(changes) do
        if change.severity == "breaking" then
            breaking = breaking + 1
        end
        table.insert(entries, string.format("%s %s%s  %s%s%s:%d:1:",
            paint[change.severity](marks[change.severity][1] .. " " .. change.what),
            string.rep(" ", width - #change.what),
            utils.ansi_codes.grey(change.detail),
            change.detail ~= "" and " " or "",
            utils.nbsp,
            change.path, change.row + 1))
    end
    fzf.fzf_exec(entries, {
        prompt = "Contracts> ",
        cwd = root,
        previewer = "builtin",
        file_icons = false,
        git_icons = false,
        actions = fzf.defaults.actions.files,
        fzf_opts = { ["--ansi"] = true, ["--no-sort"] = true, ["--delimiter"] = utils.nbsp, ["--with-nth"] = "{1}" },
        winopts = { title = string.format(" .proto against %s · %d breaking of %d ", branch, breaking, #changes) },
    })
end

return M
