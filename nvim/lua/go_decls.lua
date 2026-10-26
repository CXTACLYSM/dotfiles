-- Top-level Go declarations of a project by kind, for exploring it in
-- Space sS (Alt-k): structs, interfaces, other types, functions, methods,
-- constants and package variables. The AST helper (nvim/tools/goindex)
-- parses the files in parallel; the answer is kept per file until the file
-- changes on disk, so switching kinds and categories parses nothing again.

local M = {}

M.kinds = { "struct", "interface", "type", "func", "method", "const", "var" }

-- Absolute path → { stamp, declarations }.
local cache = {}

local function stamp(path)
    local stat = vim.uv.fs_stat(path)
    return stat and string.format("%d:%d:%d", stat.size, stat.mtime.sec, stat.mtime.nsec) or nil
end

-- Declarations of the Go files `paths` (relative to `root`) in the order
-- of `paths`, each file in source order: done(list) or done(nil, err).
function M.collect(root, paths, done)
    local stale, stamps = {}, {}
    for _, rel in ipairs(paths) do
        local current = stamp(root .. "/" .. rel)
        stamps[rel] = current
        local cached = cache[root .. "/" .. rel]
        if current and not (cached and cached.stamp == current) then
            table.insert(stale, rel)
        end
    end

    local function finish()
        local list = {}
        for _, rel in ipairs(paths) do
            local cached = cache[root .. "/" .. rel]
            if cached then
                vim.list_extend(list, cached.declarations)
            end
        end
        done(list)
    end

    if #stale == 0 then
        return finish()
    end
    require("change_tree.go_index").declarations(root, stale, function(result, err)
        if not result then
            return done(nil, err)
        end
        local by_path = {}
        for _, rel in ipairs(stale) do
            by_path[rel] = {}
        end
        for _, declaration in ipairs(result) do
            table.insert(by_path[declaration.path], declaration)
        end
        for rel, declarations in pairs(by_path) do
            cache[root .. "/" .. rel] = { stamp = stamps[rel], declarations = declarations }
        end
        finish()
    end)
end

-- Number of declarations of each kind.
function M.counts(list)
    local counts = {}
    for _, declaration in ipairs(list) do
        counts[declaration.kind] = (counts[declaration.kind] or 0) + 1
    end
    return counts
end

-- What the picker shows for a declaration: "(*Service) Create" for a
-- method, the name otherwise.
function M.label(declaration)
    if declaration.receiver and declaration.receiver ~= "" then
        return string.format("(%s) %s", declaration.receiver, declaration.name)
    end
    return declaration.name
end

function M.clear_cache()
    cache = {}
end

return M
