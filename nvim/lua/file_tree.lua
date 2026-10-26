-- Space f as a tree. With an empty query the files of the project are
-- folders that open and close in place, so the arrows step from folder to
-- folder instead of through every file:
--
--   →      open the folder under the cursor; on an open one, its first entry
--   ←      close the folder under the cursor; on an entry, go to its folder
--   Enter  open the file; on a folder, open or close it
--
-- A folder with a single folder inside is one line (pkg/api/order/v1/).
-- Folders come first, each with its number of files and the first sentence
-- of its Go package comment (`// Package order …`). Groups of quick files
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

local M = {}

M.prompts = { tree = "Tree> ", flat = "Files> " }

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

-- Groups of quick files above the tree: { name, mark, paths, numbered };
-- files that are not listed (another category) and empty groups are left
-- out. A group is a folder "@name/" that starts open.
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
        if node.count > 0 then
            table.insert(state.groups, node)
            state.by_path[node.path] = node
            state.expanded[node.path] = true
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

-- Painters by highlight group; text stays plain without the group.
local function painters()
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

-- The visible lines: the groups, then the tree. state.position: path →
-- line number (a file in a group is not counted, its place is the tree);
-- state.first_quick: the line of the first file of a group.
function M.tree_lines(state)
    local paint = painters()
    local separator = nbsp()
    local lines, position = {}, {}
    state.first_quick = nil
    for _, group in ipairs(state.groups) do
        local open = state.expanded[group.path]
        table.insert(lines, (open and "▾ " or "▸ ") .. paint.Special(group.mark .. " " .. group.name)
            .. " " .. paint.Comment(tostring(group.count)) .. separator .. group.path)
        position[group.path] = #lines
        for index, file in ipairs(open and group.children or {}) do
            local dir = file.path:match("^(.*/)[^/]*$") or ""
            local number = group.numbered and (paint.Number(tostring(index)) .. " ") or "  "
            table.insert(lines, "  " .. number .. file.name .. " " .. paint.Comment(dir)
                .. separator .. "@" .. group.group .. separator .. file.path)
            state.first_quick = state.first_quick or #lines
        end
    end
    local function walk(node, depth)
        for _, child in ipairs(node.children) do
            local indent = string.rep("  ", depth)
            local shown
            if child.dir then
                local doc = state.docs[child.path]
                shown = indent .. (state.expanded[child.path] and "▾ " or "▸ ")
                    .. paint.Directory(child.name .. "/") .. " " .. paint.Comment(tostring(child.count))
                    .. (doc and (" " .. paint.Comment("· " .. doc)) or "")
            else
                shown = indent .. "  " .. child.name
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

-- Every file with its folder dimmed, for the fuzzy search.
function M.flat_lines(paths)
    local paint = painters()
    local separator = nbsp()
    local lines = {}
    for _, rel in ipairs(paths) do
        local dir, name = rel:match("^(.*/)([^/]*)$")
        table.insert(lines, (dir and (paint.Comment(dir) .. name) or rel) .. separator .. rel)
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

-- A folder previews as the tree inside it; anything else as a file.
local function previewer(state)
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
                table.insert(content, { { file.path } })
            end
            return { do_not_cache = true, content = content, title = string.format(" %s · %d files ", node.name, node.count) }
        end
        if state.docs[node.path] then
            table.insert(content, { { state.docs[node.path], "Comment" } })
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
                    table.insert(content, { { indent .. child.name } })
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
-- (see M.set_groups), no_ignore (package comments of ignored files too).
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
            M.set_docs(state, documented.stdout)
            M.set_groups(state, opts.groups)
            if current and state.by_path[current] and not flat then
                M.reveal(state, current)
                state.revealed = current
            end
            local tree = M.tree_lines(state)
            local all = M.flat_lines(paths)
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
        prompt = flat and M.prompts.flat or M.prompts.tree,
        previewer = previewer(state),
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
