-- Space f as a tree. Esc switches typing off: j k h l move and fold, i
-- types again (M.mode_key). With an empty query the files of the project are
-- folders that open and close in place, so the arrows step from folder to
-- folder instead of through every file:
--
--   →      open the folder under the cursor; on an open one, its first entry
--   ←      close the folder under the cursor; on an entry, go to its folder
--   Enter  open the file; on a folder, open or close it
--
-- A folder with a single folder inside is one line (pkg/api/order/v1/).
-- Folders come first, each with its number of files and the first sentence
-- of its Go package comment (`// Package order …`). Every file carries the
-- icon of its type (M.icon: nvim-web-devicons, or a plain mark without it). Groups of quick files
-- head the tree, open, with the cursor on their first file: pinned (◆) and
-- recent (★); ← on one of them shows it in the tree. The file of the
-- current buffer is revealed on open. Typing turns the list into the usual
-- fuzzy search over every file; clearing the query brings the tree back as
-- it was. The preview of a folder lists what is inside it.
--
-- The picker is fzf-lua's with fzf doing the work: the tree and the flat
-- list are two files that `reload` swaps when the query becomes empty or
-- not (the prompt tells which one is shown), ← / → / Enter go to Lua
-- through `transform`, which rewrites the tree file and answers with
-- `reload-sync` and the new cursor `pos`. Each line is "shown<nbsp>path";
-- fzf shows the first part, actions and the preview read the path (the
-- last part; a file of a group has "@group" between them).
--
-- Files carry a mark for their kind in the column of the folder arrows,
-- coloured by the theme (M.kinds): ▪ Go written by hand, green for a test,
-- ▫ generated Go, dimmed with its name, ◇ .proto, ▤ .sql, ≡ markdown,
-- ∷ yaml / json / toml / env, $ Makefile, Dockerfile, compose and shell,
-- ▣ go.mod / go.sum / go.work. Plain Unicode, no Nerd Font; the kind comes
-- from the file name alone.
--
-- Files changed against HEAD (opts.changes, from git status) keep their
-- mark and get a coloured name: new ones green, modified ones blue; the
-- group ● changed lists them with their status letter. The preview of a
-- folder shows the exported API of its Go package before the files
-- (opts.declarations): types with their methods, functions, constants and
-- variables. A group closed with ← stays closed while Neovim runs.

local M = {}

M.prompts = { tree = "Tree> ", flat = "Files> ", tree_normal = "Tree ·N> ", flat_normal = "Files ·N> " }

-- Esc leaves typing for a normal mode (·N in the prompt): j / k move,
-- h / l close and open like ← / →, g the first line, Enter opens, q or
-- Esc closes; i returns to typing. In typing mode the same letters are
-- typed (fzf tells no G from g, so there is no G). M.mode_key answers
-- fzf for one of these keys.
local normal_actions = { j = "down", k = "up", g = "first", q = "abort" }
M.mode_keys = { "esc", "i", "j", "k", "h", "l", "g", "q" }

function M.mode_key(state, key, query, line)
    local function prompt(normal)
        local flat = query ~= ""
        local name = (flat and "flat" or "tree") .. (normal and "_normal" or "")
        return "change-prompt(" .. M.prompts[name] .. ")"
    end
    if key == "esc" then
        if state.normal then
            return "abort"
        end
        state.normal = true
        return prompt(true)
    end
    if not state.normal then
        return "put(" .. key .. ")"
    end
    if key == "i" then
        state.normal = false
        return prompt(false)
    end
    if key == "h" then
        return M.key(state, "left", query, line)
    end
    if key == "l" then
        return M.key(state, "right", query, line)
    end
    return normal_actions[key] or ""
end

-- Groups closed (true) or opened (false) by the user ("@recent/" → true),
-- kept for this session over the group's own start (see M.set_groups).
M.collapsed = {}

-- The group the cursor starts on: the first file of the first of these
-- that is shown, so Space f, Enter still returns to the previous file.
M.cursor_groups = { "pinned", "recent", "changed" }

local function nbsp()
    return require("fzf-lua").utils.nbsp
end

-- ============================================================
-- Tree
-- ============================================================

-- Folders: { name, path ("a/b/"), dir = true, count, children, parent };
-- files: { name, path, parent }. Folders first, then names.
function M.build(paths)
    local root = { name = "", path = "", dir = true, count = 0, children = {}, dirs = {} }
    for _, rel in ipairs(paths) do
        local node = root
        node.count = node.count + 1
        local parts = vim.split(rel, "/", { plain = true })
        for index = 1, #parts - 1 do
            local name = parts[index]
            local child = node.dirs[name]
            if not child then
                child = { name = name, path = node.path .. name .. "/", dir = true, count = 0, children = {}, dirs = {}, parent = node }
                node.dirs[name] = child
                table.insert(node.children, child)
            end
            child.count = child.count + 1
            node = child
        end
        table.insert(node.children, { name = parts[#parts], path = rel, parent = node })
    end

    local function finish(node)
        -- A folder whose only entry is a folder becomes one line.
        for index, child in ipairs(node.children) do
            while child.dir and #child.children == 1 and child.children[1].dir do
                local inner = child.children[1]
                inner.name = child.name .. "/" .. inner.name
                inner.parent = node
                child = inner
            end
            node.children[index] = child
        end
        table.sort(node.children, function(a, b)
            if (a.dir or false) ~= (b.dir or false) then
                return a.dir or false
            end
            return a.name < b.name
        end)
        for _, child in ipairs(node.children) do
            if child.dir then
                finish(child)
            end
        end
        node.dirs = nil
    end
    finish(root)
    return root
end

-- The tree of sorted `paths` with every node by its path, all folders
-- closed but a single top one.
function M.new_state(paths)
    local state = {
        paths = paths,
        root = M.build(paths),
        by_path = {},
        expanded = {},
        position = {},
        groups = {},
        docs = {},
        changes = {},
        first_quick_of = {},
    }
    local function walk(node)
        for _, child in ipairs(node.children) do
            state.by_path[child.path] = child
            if child.dir then
                walk(child)
            end
        end
    end
    walk(state.root)
    -- A single top folder (a folder category) starts open.
    if #state.root.children == 1 and state.root.children[1].dir then
        state.expanded[state.root.children[1].path] = true
    end
    return state
end

-- Groups of quick files above the tree: { name, mark, paths, numbered,
-- statuses (path → letter shown instead of a number), closed }; files that
-- are not listed (another category) and empty groups are left out. A group
-- is a folder "@name/" that starts open, or closed with `closed`, unless
-- the user closed or opened it before.
function M.set_groups(state, groups)
    state.groups = {}
    for _, group in ipairs(groups or {}) do
        local node = { name = group.name, mark = group.mark, path = "@" .. group.name .. "/", dir = true, group = group.name, children = {} }
        for _, rel in ipairs(group.paths) do
            local file = state.by_path[rel]
            if file and not file.dir then
                table.insert(node.children, file)
            end
        end
        node.count = #node.children
        node.numbered = group.numbered
        node.statuses = group.statuses
        if node.count > 0 then
            table.insert(state.groups, node)
            state.by_path[node.path] = node
            local closed = M.collapsed[node.path]
            if closed == nil then
                closed = group.closed or false
            end
            if not closed then
                state.expanded[node.path] = true
            end
        end
    end
end

-- Package comments by folder ("internal/order/" → "Package order …"),
-- from rg output "path:// Package x …"; doc.go wins.
function M.set_docs(state, output)
    local from = {}
    for line in (output or ""):gmatch("[^\n]+") do
        local file, text = line:match("^(.-):// (Package [%w_]+.*)$")
        local dir = file and file:match("^(.*/)[^/]+$")
        if dir and (not state.docs[dir] or file:match("/doc%.go$")) and from[dir] ~= "doc" then
            -- The first sentence, without "Package name".
            local doc = text:gsub("^Package [%w_]+%s*", "")
            doc = doc:match("^(.-%.)%s") or doc
            if doc ~= "" then
                state.docs[dir] = doc
                from[dir] = file:match("/doc%.go$") and "doc" or "file"
            end
        end
    end
end

-- ============================================================
-- Kinds of files
-- ============================================================

-- The mark and highlight group of each kind. The groups link to the
-- theme's own (blue functions, green strings, …), so the marks follow it.
M.kinds = {
    go = { mark = "▪", hl = "FileTreeGo", link = "Function" },
    test = { mark = "▪", hl = "FileTreeTest", link = "String" },
    generated = { mark = "▫", hl = "FileTreeGenerated", link = "NonText", dim = true },
    proto = { mark = "◇", hl = "FileTreeProto", link = "Keyword" },
    sql = { mark = "▤", hl = "FileTreeSql", link = "Number" },
    doc = { mark = "≡", hl = "FileTreeDoc", link = "Comment" },
    config = { mark = "∷", hl = "FileTreeConfig", link = "Type" },
    build = { mark = "$", hl = "FileTreeBuild", link = "Character" },
    module = { mark = "▣", hl = "FileTreeModule", link = "Label" },
}

-- Generated Go by name: protoc (*.pb.go, *.pb.validate.go, *.pb.gw.go),
-- connect, twirp, mocks, sqlc (*.sql.go), stringer, wire and other
-- *_gen.go / *.gen.go, controller-gen (zz_generated…).
local generated_go = {
    "%.pb%.go$", "%.pb%.[%w_]+%.go$", "%.connect%.go$", "%.twirp%.go$",
    "mock", "%.sql%.go$", "_string%.go$", "_gen%.go$", "%.gen%.go$", "^zz_generated",
}

-- The kind of a file by its name, or nil for any other file.
function M.kind(rel)
    local name = (rel:match("[^/]+$") or rel):lower()
    if name == "makefile" or name == "gnumakefile" or name:match("%.mk$") or name:match("^dockerfile")
        or name:match("%.dockerfile$") or name:match("compose.*%.ya?ml$") or name:match("%.sh$") then
        return "build"
    end
    if name == "go.mod" or name == "go.sum" or name == "go.work" or name == "go.work.sum" then
        return "module"
    end
    if name:match("%.go$") then
        if name:match("_test%.go$") then
            return "test"
        end
        for _, pattern in ipairs(generated_go) do
            if name:match(pattern) then
                return "generated"
            end
        end
        return "go"
    end
    if name:match("%.proto$") then
        return "proto"
    end
    if name:match("%.sql$") then
        return "sql"
    end
    if name:match("%.md$") or name:match("%.markdown$") then
        return "doc"
    end
    if name:match("%.ya?ml$") or name:match("%.json$") or name:match("%.toml$")
        or name:match("^%.env") or name:match("%.env$") then
        return "config"
    end
    return nil
end

-- Names of files changed against HEAD: new (A added, ? untracked) and
-- modified (everything else: M, D, R, C …).
M.statuses = {
    added = { hl = "FileTreeAdded", link = "Added" },
    changed = { hl = "FileTreeChanged", link = "Changed" },
}

function M.status_hl(status)
    return (status == "A" or status == "?") and M.statuses.added.hl or M.statuses.changed.hl
end

local highlighted = false

-- The highlight groups of the kinds and statuses, once; a colorscheme
-- that defines them itself wins (default = true).
function M.define_highlights()
    if highlighted then
        return
    end
    highlighted = true
    for _, kind in pairs(M.kinds) do
        vim.api.nvim_set_hl(0, kind.hl, { link = kind.link, default = true })
    end
    for _, status in pairs(M.statuses) do
        vim.api.nvim_set_hl(0, status.hl, { link = status.link, default = true })
    end
end

-- Painters by highlight group; text stays plain without the group.
function M.painters()
    M.define_highlights()
    local utils = require("fzf-lua").utils
    return setmetatable({}, {
        __index = function(cache, group)
            local _, _, paint = utils.ansi_from_hl(group, "")
            cache[group] = paint or function(text)
                return text
            end
            return cache[group]
        end,
    })
end

local painters = M.painters

-- The icon of a file: glyph, highlight group, dim. With nvim-web-devicons
-- loaded (init.lua; a Nerd Font in the terminal) the glyph is its icon by
-- name or extension; without it the plain mark of the kind. The colour is
-- the kind's (tests, generated code and so on keep their meaning) or, for
-- a file of no kind, the icon's own. Nil for a file of no kind without
-- devicons.
-- M.plain = true keeps the plain marks even with devicons loaded (tests).
M.plain = false

function M.icon(rel)
    local kind = M.kinds[M.kind(rel)]
    local devicons = not M.plain and package.loaded["nvim-web-devicons"]
    if devicons then
        local glyph, hl = devicons.get_icon(rel:match("[^/]+$") or rel, nil, { default = true })
        if glyph then
            return glyph, kind and kind.hl or hl, kind and kind.dim or false
        end
    end
    if kind then
        return kind.mark, kind.hl, kind.dim or false
    end
    return nil
end

-- The marks of a closed and an open folder: Nerd Font folders with
-- devicons, else triangles.
function M.folder_marks()
    if not M.plain and package.loaded["nvim-web-devicons"] then
        return " ", " "
    end
    return "▸ ", "▾ "
end

-- "▪ service.go": the painted icon, then the name; a generated file is
-- dimmed whole. Two spaces stand for no icon, so the names stay aligned.
-- With a git `status` the name takes the colour of the status instead.
function M.shown_file(paint, name, rel, status)
    local glyph, hl, dim = M.icon(rel)
    local shown = status and paint[M.status_hl(status)](name) or name
    if not glyph then
        return "  " .. shown
    end
    if dim and not status then
        return paint[hl](glyph .. " " .. name)
    end
    return paint[hl](glyph) .. " " .. shown
end

-- The same for the preview: segments { text, highlight }.
function M.preview_file(indent, name, rel)
    local glyph, hl, dim = M.icon(rel)
    if not glyph then
        return { { indent .. "  " .. name } }
    end
    if dim then
        return { { indent .. glyph .. " " .. name, hl } }
    end
    return { { indent .. glyph, hl }, { " " .. name } }
end

-- The visible lines: the groups, then the tree. state.position: path →
-- line number (a file in a group is not counted, its place is the tree);
-- state.first_quick: the line the cursor starts on (M.cursor_groups).
function M.tree_lines(state)
    local paint = painters()
    local separator = nbsp()
    local closed_mark, open_mark = M.folder_marks()
    local lines, position = {}, {}
    state.first_quick = nil
    state.first_quick_of = {}
    for _, group in ipairs(state.groups) do
        local open = state.expanded[group.path]
        table.insert(lines, paint.Directory(open and open_mark or closed_mark) .. paint.Special(group.mark .. " " .. group.name)
            .. " " .. paint.Comment(tostring(group.count)) .. separator .. group.path)
        position[group.path] = #lines
        for index, file in ipairs(open and group.children or {}) do
            local dir = file.path:match("^(.*/)[^/]*$") or ""
            local number = "  "
            if group.numbered then
                number = paint.Number(tostring(index)) .. " "
            elseif group.statuses then
                local status = group.statuses[file.path] or " "
                number = paint[M.status_hl(status)](status) .. " "
            end
            table.insert(lines, "  " .. number .. M.shown_file(paint, file.name, file.path, state.changes[file.path])
                .. " " .. paint.Comment(dir) .. separator .. "@" .. group.group .. separator .. file.path)
            state.first_quick_of[group.group] = state.first_quick_of[group.group] or #lines
        end
    end
    for _, name in ipairs(M.cursor_groups) do
        state.first_quick = state.first_quick or state.first_quick_of[name]
    end
    for _, group in ipairs(state.groups) do
        state.first_quick = state.first_quick or state.first_quick_of[group.group]
    end
    local function walk(node, depth)
        for _, child in ipairs(node.children) do
            local indent = string.rep("  ", depth)
            local shown
            if child.dir then
                local doc = state.docs[child.path]
                shown = indent .. paint.Directory((state.expanded[child.path] and open_mark or closed_mark) .. child.name .. "/") .. " " .. paint.Comment(tostring(child.count))
                    .. (doc and (" " .. paint.Comment("· " .. doc)) or "")
            else
                shown = indent .. M.shown_file(paint, child.name, child.path, state.changes[child.path])
            end
            table.insert(lines, shown .. separator .. child.path)
            position[child.path] = #lines
            if child.dir and state.expanded[child.path] then
                walk(child, depth + 1)
            end
        end
    end
    walk(state.root, 0)
    state.position = position
    return lines
end

-- Every file with its mark and its folder dimmed, for the fuzzy search;
-- `changes` colours the changed names.
function M.flat_lines(paths, changes)
    local paint = painters()
    local separator = nbsp()
    local lines = {}
    for _, rel in ipairs(paths) do
        local dir, name = rel:match("^(.*/)([^/]*)$")
        local glyph, hl, dim = M.icon(rel)
        local status = changes and changes[rel]
        local shown = dir and (paint.Comment(dir) .. (status and paint[M.status_hl(status)](name) or name)) or rel
        if glyph and dim and not status then
            shown = paint[hl](glyph .. " " .. rel)
        elseif glyph then
            shown = paint[hl](glyph) .. " " .. shown
        else
            shown = "  " .. shown
        end
        table.insert(lines, shown .. separator .. rel)
    end
    return lines
end

-- The path of a picker line: its last part.
function M.path_of(line)
    local separator = nbsp()
    local at = line and line:find(separator, 1, true)
    while at do
        local next_at = line:find(separator, at + #separator, true)
        if not next_at then
            return line:sub(at + #separator)
        end
        at = next_at
    end
    return nil
end

-- The group of a line of a quick file, or nil.
function M.group_of(line)
    local separator = nbsp()
    return line and line:match(separator .. "@([^" .. separator:sub(1, 1) .. "]+)" .. separator)
end

-- Open every folder above `rel`.
function M.reveal(state, rel)
    local node = state.by_path[rel]
    node = node and node.parent
    while node and node.path ~= "" do
        state.expanded[node.path] = true
        node = node.parent
    end
end

local function write(file, lines)
    local out = assert(io.open(file, "w"))
    out:write(table.concat(lines, "\n"), "\n")
    out:close()
end

-- Rewrite the tree file and answer fzf with it and the cursor on `path`.
local function reload_at(state, path)
    write(state.tree_file, M.tree_lines(state))
    return string.format("reload-sync(cat %s)+pos(%d)",
        vim.fn.shellescape(state.tree_file), state.position[path] or 1)
end

-- ←, → and Enter: the fzf actions for the query and the current line.
function M.key(state, key, query, line)
    local path = M.path_of(line)
    local node = path and state.by_path[path]
    -- A file of a group: ← shows it in the tree, → does nothing.
    if node and query == "" and key ~= "enter" and M.group_of(line) then
        if key == "right" then
            return ""
        end
        M.reveal(state, path)
        return reload_at(state, path)
    end
    if key == "enter" then
        if node and node.dir then
            state.expanded[path] = not state.expanded[path] or nil
            if node.group then
                M.collapsed[path] = not state.expanded[path]
            end
            return reload_at(state, path)
        end
        return node and "print(_open)+accept" or ""
    end
    -- With a query the arrows move in the prompt.
    if query ~= "" then
        return key == "right" and "forward-char" or "backward-char"
    end
    if not node then
        return ""
    end
    if key == "right" then
        if not node.dir then
            return ""
        end
        if not state.expanded[path] then
            state.expanded[path] = true
            return reload_at(state, path)
        end
        return string.format("pos(%d)", state.position[path] + 1)
    end
    if node.dir and state.expanded[path] then
        state.expanded[path] = nil
        if node.group then
            M.collapsed[path] = true
        end
        return reload_at(state, path)
    end
    local parent = node.parent
    if parent and parent.path ~= "" then
        return string.format("pos(%d)", state.position[parent.path])
    end
    return ""
end

-- fzf's `change`: the flat list once there is a query, the tree again
-- when it is cleared. The prompt says which one is loaded.
function M.change_command(state)
    return string.format([[case "$FZF_PROMPT" in ]]
        .. [["%s") [ -n "$FZF_QUERY" ] && echo "change-prompt(%s)+reload(cat %s)" ;; ]]
        .. [[*) [ -z "$FZF_QUERY" ] && echo "change-prompt(%s)+reload-sync(cat %s)+first" ;; esac; true]],
        M.prompts.tree, M.prompts.flat, vim.fn.shellescape(state.flat_file),
        M.prompts.tree, vim.fn.shellescape(state.tree_file))
end

-- ============================================================
-- Preview
-- ============================================================

-- The exported API of a Go package from its declarations (go_decls):
-- exported types with their exported methods, then functions, constants
-- and variables; at most `limit` rows, the rest counted. Rows for the
-- preview: { { icon, highlight }, { name } }.
function M.api_lines(declarations, limit)
    local icons = require("fzf-lua.config").globals.lsp.symbols.symbol_icons or {}
    local look = {
        struct = { "Struct", "@type" },
        interface = { "Interface", "@type" },
        type = { "Class", "@type" },
        func = { "Function", "@function" },
        method = { "Method", "@function.method" },
        const = { "Constant", "@constant" },
        var = { "Variable", "@variable" },
    }
    local function exported(name)
        return name:match("^%u") ~= nil
    end
    local types, methods, rest = {}, {}, {}
    for _, declaration in ipairs(declarations) do
        local kind = declaration.kind
        if (kind == "struct" or kind == "interface" or kind == "type") and exported(declaration.name) then
            table.insert(types, declaration)
            methods[declaration.name] = {}
        end
    end
    for _, declaration in ipairs(declarations) do
        local kind = declaration.kind
        if kind == "method" then
            local receiver = (declaration.receiver or ""):gsub("^%*", ""):gsub("%[.*$", "")
            if exported(declaration.name) and methods[receiver] then
                table.insert(methods[receiver], declaration)
            end
        elseif (kind == "func" or kind == "const" or kind == "var") and exported(declaration.name) then
            table.insert(rest, declaration)
        end
    end
    local rows, total = {}, 0
    local function add(indent, declaration)
        total = total + 1
        if #rows < limit then
            local shape = look[declaration.kind]
            table.insert(rows, { { indent .. (icons[shape[1]] or declaration.kind) .. " ", shape[2] }, { declaration.name } })
        end
    end
    for _, declaration in ipairs(types) do
        add("", declaration)
        for _, method in ipairs(methods[declaration.name]) do
            add("  ", method)
        end
    end
    for _, declaration in ipairs(rest) do
        add("", declaration)
    end
    if total > #rows then
        table.insert(rows, { { string.format("… %d more", total - #rows), "Comment" } })
    end
    return rows
end

-- A folder previews as its package comment, the exported API of the
-- package (`declarations(node)` gives the declarations of its Go files, or
-- nil) and the tree inside it; anything else as a file.
local function previewer(state, declarations)
    local builtin = require("fzf-lua.previewer.builtin").buffer_or_file
    local Preview = builtin:extend()

    function Preview:parse_entry(entry_str, cb)
        local path = M.path_of(entry_str)
        local node = path and state.by_path[path]
        if not (node and node.dir) then
            return Preview.super.parse_entry(self, entry_str, cb)
        end
        local content = {}
        if node.group then
            for _, file in ipairs(node.children) do
                table.insert(content, M.preview_file("", file.path, file.path))
            end
            return { do_not_cache = true, content = content, title = string.format(" %s · %d files ", node.name, node.count) }
        end
        if state.docs[node.path] then
            table.insert(content, { { state.docs[node.path], "Comment" } })
            table.insert(content, { { "" } })
        end
        local api = declarations and declarations(node)
        if api and #api > 0 then
            vim.list_extend(content, M.api_lines(api, 60))
            table.insert(content, { { "" } })
        end
        local function walk(dir, depth)
            for _, child in ipairs(dir.children) do
                if #content >= 500 then
                    return
                end
                local indent = string.rep("  ", depth)
                if child.dir then
                    table.insert(content, { { indent .. child.name .. "/", "Directory" }, { " " .. child.count, "Comment" } })
                    walk(child, depth + 1)
                else
                    table.insert(content, M.preview_file(indent, child.name, child.path))
                end
            end
        end
        walk(node, 0)
        return {
            do_not_cache = true,
            content = content,
            title = string.format(" %s · %d files ", node.path, node.count),
        }
    end

    return vim.tbl_extend("force", {}, require("fzf-lua.config").globals.previewers.builtin, {
        _ctor = function()
            return Preview
        end,
    })
end

-- ============================================================
-- Picker
-- ============================================================

-- opts: cwd, cmd (the file list, run in cwd), query, title, actions (more
-- fzf-lua actions), current (absolute path of the file to reveal), groups
-- (see M.set_groups), no_ignore (package comments of ignored files too),
-- changes (path → git status letter), declarations (function(node) → the
-- declarations of the Go files of a folder, for its preview).
function M.open(opts)
    local fzf = require("fzf-lua")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    -- Filled when the file list arrives; the handlers see it through here.
    local state = M.new_state({})
    state.tree_file = dir .. "/tree"
    state.flat_file = dir .. "/flat"
    local query = opts.query or ""
    local flat = query ~= ""

    local actions = {}
    for key, action in pairs(fzf.defaults.actions.files) do
        -- The fd / rg toggles (Alt-i, Alt-h, Alt-f) reopen fzf-lua's files.
        if not (type(action) == "table" and action.reuse) and key ~= "enter" then
            actions[key] = action
        end
    end
    -- Enter goes through M.key; files open with this one.
    actions._open = fzf.defaults.actions.files.enter
    for key, action in pairs(opts.actions or {}) do
        actions[key] = action
    end

    local keymap = { fzf = {} }
    for _, key in ipairs({ "right", "left", "enter" }) do
        keymap.fzf[key] = "transform:" .. fzf.shell.stringify_data(function(fields)
            return M.key(state, key, fields[1] or "", fields[2] or "")
        end, {}, "{q} {}")
    end
    for _, key in ipairs(M.mode_keys) do
        keymap.fzf[key] = "transform:" .. fzf.shell.stringify_data(function(fields)
            return M.mode_key(state, key, fields[1] or "", fields[2] or "")
        end, {}, "{q} {}")
    end
    keymap.fzf.change = "transform:" .. M.change_command(state)
    -- Once loaded, the cursor goes to the first quick file, or to the
    -- revealed one.
    keymap.fzf.load = "transform:" .. fzf.shell.stringify_data(function()
        local at = state.first_quick or (state.revealed and state.position[state.revealed])
        return (at and not flat and string.format("pos(%d)+", at) or "") .. "unbind(load)"
    end, {}, "")

    local current = opts.current and vim.fs.relpath(opts.cwd, opts.current)

    local docs_cmd = {
        "rg", "--no-heading", "--with-filename", "--no-line-number", "--max-count", "1",
        "--glob", "*.go", "--glob", "!*_test.go", "-e", "^// Package [A-Za-z0-9_]+",
    }
    if opts.no_ignore then
        table.insert(docs_cmd, "--no-ignore")
    end

    fzf.fzf_exec(function(cb)
        local listed, documented
        local function build()
            if not listed or not documented then
                return
            end
            local paths = vim.split(listed.stdout or "", "\n", { trimempty = true })
            table.sort(paths)
            for key, value in pairs(M.new_state(paths)) do
                state[key] = value
            end
            state.changes = opts.changes or {}
            M.set_docs(state, documented.stdout)
            M.set_groups(state, opts.groups)
            if current and state.by_path[current] and not flat then
                M.reveal(state, current)
                state.revealed = current
            end
            local tree = M.tree_lines(state)
            local all = M.flat_lines(paths, state.changes)
            write(state.tree_file, tree)
            write(state.flat_file, all)
            for _, line in ipairs(flat and all or tree) do
                cb(line)
            end
            cb(nil)
        end
        vim.system(opts.cmd, { cwd = opts.cwd, text = true }, vim.schedule_wrap(function(result)
            listed = result
            build()
        end))
        local ok = pcall(vim.system, docs_cmd, { cwd = opts.cwd, text = true }, vim.schedule_wrap(function(result)
            documented = result
            build()
        end))
        if not ok then
            documented = {}
        end
    end, {
        cwd = opts.cwd,
        query = query,
        -- Esc is the normal mode here (M.mode_key), not fzf-lua's hide.
        no_hide = true,
        prompt = flat and M.prompts.flat or M.prompts.tree,
        previewer = previewer(state, opts.declarations),
        actions = actions,
        keymap = keymap,
        fzf_opts = {
            ["--ansi"] = true,
            ["--multi"] = true,
            ["--scheme"] = "path",
            ["--delimiter"] = nbsp(),
            ["--with-nth"] = "{1}",
        },
        winopts = { title = opts.title },
    })
    return state
end

return M
