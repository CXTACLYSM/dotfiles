-- Space f as a tree on the fixture verify.sh writes, as if opened from
-- internal/order/service.go: the tree (folders first, counts, one line for
-- a chain of single folders, package comments, marks by kind of file, the
-- names of changed files coloured), the groups of pinned, changed and
-- recent files, ← → Enter in the tree and in the search, the
-- switch between tree and search, the picker options (the binds, the
-- revealed file), the preview of a folder, and the same keys
-- pressed in a real fzf. verify.sh opens README.md: without gopls, whose
-- progress redraws crash a headless Neovim. The screen keeps its headless
-- size too: after a resize the redraw fzf-lua asks for while it highlights
-- the terminal (nvim__redraw) dies with SIGBUS in grid_clear_line.
local file_tree = require("file_tree")
local fzf = require("fzf-lua")
-- The plain marks first; the devicons glyphs are checked at the end.
file_tree.plain = true
local root = vim.fn.getcwd()
local source = root .. "/internal/order/service.go"

local function same(got, want, what)
    assert(vim.deep_equal(got, want), what .. ": " .. vim.inspect(got) .. " ~= " .. vim.inspect(want))
end

local function plain(line)
    return fzf.utils.strip_ansi_coloring(line):gsub(fzf.utils.nbsp .. ".*$", "")
end

local paths = {
    "README.md",
    "api/order/v1/order.proto",
    "cmd/app/main.go",
    "go.mod",
    "internal/order/repo/pg.go",
    "internal/order/service.go",
    "internal/order/service_test.go",
    "internal/user/user.go",
    "pkg/api/order/v1/order.pb.go",
}

-- The tree.
local state = file_tree.new_state(paths)
state.tree_file = vim.fn.tempname()
same(vim.tbl_map(function(node)
    return node.name
end, state.root.children), { "api/order/v1", "cmd/app", "internal", "pkg/api/order/v1", "README.md", "go.mod" },
    "folders first, chains of single folders in one line")
assert(state.by_path["internal/"].count == 4 and state.by_path["api/order/v1/"].count == 1, "file counts")
same(vim.tbl_map(plain, file_tree.tree_lines(state)), {
    "▸ api/order/v1/ 1", "▸ cmd/app/ 1", "▸ internal/ 4", "▸ pkg/api/order/v1/ 1", "≡ README.md", "▣ go.mod",
}, "closed tree")
assert(file_tree.path_of(file_tree.tree_lines(state)[3]) == "internal/", "path after the separator")
file_tree.reveal(state, "internal/order/service.go")
local lines = file_tree.tree_lines(state)
same(vim.tbl_map(plain, lines), {
    "▸ api/order/v1/ 1", "▸ cmd/app/ 1", "▾ internal/ 4", "  ▾ order/ 3", "    ▸ repo/ 1",
    "    ▪ service.go", "    ▪ service_test.go", "  ▸ user/ 1", "▸ pkg/api/order/v1/ 1", "≡ README.md", "▣ go.mod",
}, "revealed file")
assert(file_tree.new_state({ "internal/order/a.go", "internal/order/b.go" }).expanded["internal/order/"],
    "a single top folder starts open")
print("FILE_TREE_BUILD_OK")

-- Kinds of files by name, their marks plain Unicode of one column.
for name, kind in pairs({
    ["internal/order/service.go"] = "go",
    ["cmd/app/main.go"] = "go",
    ["internal/order/service_test.go"] = "test",
    ["pkg/api/order/v1/order.pb.go"] = "generated",
    ["pkg/api/order/v1/order_grpc.pb.go"] = "generated",
    ["pkg/api/order/v1/order.pb.validate.go"] = "generated",
    ["internal/order/mocks/store_mock.go"] = "generated",
    ["internal/db/query.sql.go"] = "generated",
    ["internal/order/status_string.go"] = "generated",
    ["internal/di/wire_gen.go"] = "generated",
    ["api/order/v1/order.proto"] = "proto",
    ["migrations/001_init.sql"] = "sql",
    ["README.md"] = "doc",
    ["docs/adr/0001.markdown"] = "doc",
    ["config.yaml"] = "config",
    ["buf.gen.yaml"] = "config",
    [".env.local"] = "config",
    ["testdata/golden.json"] = "config",
    ["Makefile"] = "build",
    ["build/Dockerfile.dev"] = "build",
    ["deploy/docker-compose.yml"] = "build",
    ["scripts/run.sh"] = "build",
    ["go.mod"] = "module",
    ["go.work.sum"] = "module",
    ["LICENSE"] = false,
}) do
    assert((file_tree.kind(name) or false) == kind, name .. " -> " .. tostring(file_tree.kind(name)))
end
for _, kind in pairs(file_tree.kinds) do
    for _, code in ipairs(vim.fn.str2list(kind.mark)) do
        assert(code < 0xE000 or code > 0xF8FF, "private-use glyph in " .. kind.hl)
    end
    assert(vim.fn.strdisplaywidth(kind.mark) == 1, "one column: " .. kind.mark)
    assert(vim.fn.hlexists(kind.hl) == 1, "highlight group " .. kind.hl)
end
assert(plain(file_tree.tree_lines(file_tree.new_state({ "a.pb.go" }))[1]) == "▫ a.pb.go", "a generated file")
print("FILE_TREE_KINDS_OK")

-- Keys.
local function line_of(path)
    for _, line in ipairs(file_tree.tree_lines(state)) do
        if file_tree.path_of(line) == path then
            return line
        end
    end
    error("not shown: " .. path)
end
local reload = "reload%-sync%(cat '[^']+'%)%+pos%((%d+)%)"

assert(file_tree.key(state, "left", "", line_of("internal/order/service.go")) == "pos(4)", "← on a file: its folder")
local at = file_tree.key(state, "left", "", line_of("internal/order/")):match(reload)
assert(at == "4" and not state.expanded["internal/order/"], "← on an open folder closes it in place")
assert(file_tree.key(state, "left", "", line_of("internal/order/")) == "pos(3)", "← on a closed folder: its parent")
assert(file_tree.key(state, "left", "", line_of("internal/")):match(reload) == "3", "← closes the top folder")
assert(file_tree.key(state, "left", "", line_of("internal/")) == "", "← on a closed top folder: nothing")
assert(file_tree.key(state, "right", "", line_of("internal/")):match(reload) == "3", "→ opens in place")
assert(file_tree.key(state, "right", "", line_of("internal/")) == "pos(4)", "→ on an open folder: its first entry")
assert(file_tree.key(state, "right", "", line_of("README.md")) == "", "→ on a file: nothing")
assert(file_tree.key(state, "enter", "", line_of("cmd/app/")):match(reload) and state.expanded["cmd/app/"],
    "Enter on a folder opens it")
assert(file_tree.key(state, "enter", "", line_of("cmd/app/")):match(reload) and not state.expanded["cmd/app/"],
    "Enter again closes it")
assert(file_tree.key(state, "enter", "", line_of("go.mod")) == "print(_open)+accept", "Enter on a file opens it")
assert(file_tree.key(state, "enter", "", "") == "", "Enter with nothing listed")
assert(file_tree.key(state, "right", "ser", line_of("internal/")) == "forward-char"
    and file_tree.key(state, "left", "ser", "x") == "backward-char", "with a query the arrows move in the prompt")
local written = fzf.utils.strip_ansi_coloring(table.concat(vim.fn.readfile(state.tree_file), "\n"))
assert(written:find("▾ internal/", 1, true), "the tree file follows the keys")
print("FILE_TREE_KEYS_OK")

-- The switch between tree and search, run by fzf's shell.
state.flat_file = "/flat file"
local change = file_tree.change_command(state)
for _, shell in ipairs({ "sh", vim.o.shell }) do
    local function run(prompt, query)
        local result = vim.system({ shell, "-c", change }, {
            env = { FZF_PROMPT = prompt, FZF_QUERY = query },
            text = true,
        }):wait()
        assert(result.code == 0, shell .. ": " .. (result.stderr or ""))
        return vim.trim(result.stdout)
    end
    assert(run("Tree> ", "ser") == "change-prompt(Files> )+reload(cat '/flat file')", shell .. ": typing")
    assert(run("Files> ", "") == "change-prompt(Tree> )+reload-sync(cat '" .. state.tree_file .. "')+first",
        shell .. ": cleared")
    assert(run("Tree> ", "") == "" and run("Files> ", "se") == "", shell .. ": no reload otherwise")
    assert(run("Tree ·N> ", "ser") == "change-prompt(Files ·N> )+reload(cat '/flat file')", shell .. ": typing in normal mode")
    assert(run("Files ·N> ", "") == "change-prompt(Tree ·N> )+reload-sync(cat '" .. state.tree_file .. "')+first",
        shell .. ": cleared in normal mode")
end
local flat = file_tree.flat_lines({ "internal/order/service.go", "go.mod", "LICENSE" })
assert(plain(flat[1]) == "▪ internal/order/service.go" and file_tree.path_of(flat[2]) == "go.mod"
    and plain(flat[3]) == "  LICENSE", "search lines: " .. plain(flat[1]) .. " / " .. plain(flat[3]))
print("FILE_TREE_SWITCH_OK")

-- Groups of quick files and package comments.
local quick = file_tree.new_state(paths)
quick.tree_file = vim.fn.tempname()
file_tree.set_docs(quick, table.concat({
    "internal/order/service.go:// Package order handles orders. Twice.",
    "internal/order/doc.go:// Package order manages purchases.",
    "internal/user/user.go:// Package user",
    "go.mod:// Package root",
}, "\n"))
same(quick.docs, { ["internal/order/"] = "manages purchases." }, "doc.go wins, an empty comment is none")
local statuses = { ["cmd/app/main.go"] = "M", ["internal/user/user.go"] = "?" }
quick.changes = statuses
file_tree.set_groups(quick, {
    { name = "pinned", mark = "◆", paths = { "internal/order/service.go", "gone.go" }, numbered = true },
    { name = "changed", mark = "●", paths = { "cmd/app/main.go", "internal/user/user.go" }, statuses = statuses },
    { name = "recent", mark = "★", paths = { "go.mod" } },
    { name = "empty", mark = "·", paths = {} },
})
local quick_lines = file_tree.tree_lines(quick)
same(vim.tbl_map(plain, vim.list_slice(quick_lines, 1, 8)), {
    "▾ ◆ pinned 1", "  1 ▪ service.go internal/order/", "▾ ● changed 2", "  M ▪ main.go cmd/app/", "  ? ▪ user.go internal/user/",
    "▾ ★ recent 1", "    ▣ go.mod ", "▸ api/order/v1/ 1",
}, "groups head the tree, changed files with their status")
assert(quick.first_quick == 2, "the cursor starts on the first pinned file")
local _, _, changed_paint = fzf.utils.ansi_from_hl("FileTreeChanged", "")
local _, _, added_paint = fzf.utils.ansi_from_hl("FileTreeAdded", "")
assert(quick_lines[4]:find(changed_paint("main.go"), 1, true) and quick_lines[5]:find(added_paint("user.go"), 1, true),
    "changed names coloured: modified blue, new green")
local in_tree
for _, line in ipairs(quick_lines) do
    if file_tree.path_of(line) == "cmd/app/main.go" and not file_tree.group_of(line) then
        in_tree = line
    end
end
assert(in_tree == nil, "a closed folder hides its files")
file_tree.reveal(quick, "cmd/app/main.go")
for _, line in ipairs(file_tree.tree_lines(quick)) do
    if file_tree.path_of(line) == "cmd/app/main.go" and not file_tree.group_of(line) then
        in_tree = line
    end
end
assert(in_tree and in_tree:find(changed_paint("main.go"), 1, true), "the changed name is coloured in the tree too")
assert(file_tree.flat_lines({ "cmd/app/main.go" }, statuses)[1]:find(changed_paint("main.go"), 1, true), "and in the search")
local unpinned = file_tree.new_state(paths)
file_tree.set_groups(unpinned, {
    { name = "changed", mark = "●", paths = { "cmd/app/main.go" }, statuses = statuses },
    { name = "recent", mark = "★", paths = { "go.mod" } },
})
file_tree.tree_lines(unpinned)
assert(unpinned.first_quick == 4, "without pins the cursor starts on the first recent file, below changed")
quick_lines = file_tree.tree_lines(quick)
assert(file_tree.group_of(quick_lines[2]) == "pinned" and file_tree.path_of(quick_lines[2]) == "internal/order/service.go",
    "a quick file line")
assert(file_tree.key(quick, "right", "", quick_lines[2]) == "", "→ on a quick file: nothing")
assert(file_tree.key(quick, "enter", "", quick_lines[2]) == "print(_open)+accept", "Enter opens it")
local revealed = tonumber(file_tree.key(quick, "left", "", quick_lines[2]):match(reload))
quick_lines = file_tree.tree_lines(quick)
assert(file_tree.path_of(quick_lines[revealed]) == "internal/order/service.go" and not file_tree.group_of(quick_lines[revealed]),
    "← shows it in the tree")
local order_line
for _, line in ipairs(quick_lines) do
    if file_tree.path_of(line) == "internal/order/" then
        order_line = plain(line)
    end
end
assert(order_line == "  ▾ order/ 3 · manages purchases.", "package comment of a folder: " .. tostring(order_line))
assert(file_tree.key(quick, "left", "", quick_lines[1]):match(reload) == "1" and not quick.expanded["@pinned/"],
    "a group closes like a folder")
assert(file_tree.collapsed["@pinned/"], "a closed group is remembered")
local again = file_tree.new_state(paths)
file_tree.set_groups(again, { { name = "pinned", mark = "◆", paths = { "go.mod" }, numbered = true } })
assert(not again.expanded["@pinned/"], "and starts closed next time")
quick_lines = file_tree.tree_lines(quick)
assert(file_tree.key(quick, "enter", "", quick_lines[1]):match(reload) and quick.expanded["@pinned/"]
    and not file_tree.collapsed["@pinned/"], "Enter opens it again and forgets")
-- A group with `closed` starts closed (Space f: changed and recent) and
-- stays open once the user opened it.
local folded = file_tree.new_state(paths)
folded.tree_file = vim.fn.tempname()
file_tree.set_groups(folded, {
    { name = "pinned", mark = "◆", paths = { "go.mod" }, numbered = true },
    { name = "recent", mark = "★", paths = { "README.md" }, closed = true },
})
same(vim.tbl_map(plain, vim.list_slice(file_tree.tree_lines(folded), 1, 3)),
    { "▾ ◆ pinned 1", "  1 ▣ go.mod ", "▸ ★ recent 1" }, "a closed group shows its line only")
assert(folded.first_quick == 2, "the cursor starts on the pinned file")
local folded_lines = file_tree.tree_lines(folded)
assert(file_tree.key(folded, "enter", "", folded_lines[3]):match(reload) and folded.expanded["@recent/"]
    and file_tree.collapsed["@recent/"] == false, "Enter opens a closed group and remembers")
local reopened = file_tree.new_state(paths)
file_tree.set_groups(reopened, { { name = "recent", mark = "★", paths = { "README.md" }, closed = true } })
assert(reopened.expanded["@recent/"], "and it starts open next time")
file_tree.collapsed["@recent/"] = nil
print("FILE_TREE_QUICK_OK")

-- Esc: a normal mode where j / k move, h / l fold, i types again; before
-- it the same letters are typed.
local modal = file_tree.new_state(paths)
modal.tree_file = vim.fn.tempname()
assert(file_tree.mode_key(modal, "j", "", "") == "put(j)" and file_tree.mode_key(modal, "k", "ser", "") == "put(k)", "letters are typed")
assert(file_tree.mode_key(modal, "esc", "", "") == "change-prompt(Tree ·N> )" and modal.normal, "Esc: normal mode in the tree")
assert(file_tree.mode_key(modal, "j", "", "") == "down" and file_tree.mode_key(modal, "k", "", "") == "up", "j / k move")
assert(file_tree.mode_key(modal, "g", "", "") == "first", "g: the first line")
local modal_lines = file_tree.tree_lines(modal)
assert(file_tree.mode_key(modal, "l", "", modal_lines[1]):match("^reload%-sync") and modal.expanded[file_tree.path_of(modal_lines[1])],
    "l opens the folder like →")
assert(file_tree.mode_key(modal, "h", "", modal_lines[1]):match("^reload%-sync") and not modal.expanded[file_tree.path_of(modal_lines[1])],
    "h closes it like ←")
assert(file_tree.mode_key(modal, "i", "ser", "") == "change-prompt(Files> )" and not modal.normal, "i types again, the prompt of the search")
assert(file_tree.mode_key(modal, "esc", "ser", "") == "change-prompt(Files ·N> )", "Esc in the search")
assert(file_tree.mode_key(modal, "q", "ser", "") == "abort" and file_tree.mode_key(modal, "esc", "ser", "") == "abort", "q and a second Esc close")
-- The exported API of a package for the preview of a folder.
local function row_text(row)
    return table.concat(vim.tbl_map(function(segment)
        return segment[1]
    end, row))
end
local declarations = {
    { kind = "struct", name = "Service" },
    { kind = "method", name = "Create", receiver = "*Service" },
    { kind = "method", name = "helper", receiver = "*Service" },
    { kind = "func", name = "New" },
    { kind = "func", name = "newService" },
    { kind = "const", name = "Default" },
    { kind = "struct", name = "cache" },
    { kind = "method", name = "Do", receiver = "cache" },
    { kind = "interface", name = "Repository" },
    { kind = "method", name = "Save", receiver = "Store[K, V]" },
    { kind = "type", name = "Store" },
    { kind = "var", name = "ErrNotFound" },
}
local icons = require("fzf-lua.config").globals.lsp.symbols.symbol_icons
local i = { s = icons.Struct, m = icons.Method, i = icons.Interface, c = icons.Class, f = icons.Function,
    k = icons.Constant, v = icons.Variable }
same(vim.tbl_map(row_text, file_tree.api_lines(declarations, 60)),
    { i.s .. " Service", "  " .. i.m .. " Create", i.i .. " Repository", i.c .. " Store", "  " .. i.m .. " Save",
        i.f .. " New", i.k .. " Default", i.v .. " ErrNotFound" },
    "exported types with their methods, then functions, constants and variables")
same(vim.tbl_map(row_text, file_tree.api_lines(declarations, 3)),
    { i.s .. " Service", "  " .. i.m .. " Create", i.i .. " Repository", "… 5 more" }, "the rest counted")
assert(file_tree.api_lines(declarations, 60)[1][1][2] == "@type" and file_tree.api_lines(declarations, 60)[6][1][2] == "@function",
    "icons coloured by kind")
print("FILE_TREE_API_OK")

-- The picker options, fzf stubbed.
local function opened_line(opened, path)
    for _, line in ipairs(file_tree.tree_lines(opened)) do
        if file_tree.path_of(line) == path then
            return line
        end
    end
    error("not shown: " .. path)
end
local real_exec = fzf.fzf_exec
local picked
fzf.fzf_exec = function(contents, opts)
    picked = { contents = contents, opts = opts }
end
local function load_lines()
    local got, done = {}, false
    picked.contents(function(line)
        if line == nil then
            done = true
        else
            table.insert(got, line)
        end
    end)
    assert(vim.wait(5000, function()
        return done
    end, 20), "no file list")
    return got
end

local opened = file_tree.open({
    cwd = root,
    cmd = { "fd", "--type", "f", "." },
    current = source,
    title = " files · all ",
    actions = { ["alt-c"] = function() end },
    groups = { { name = "recent", mark = "★", paths = { "go.mod", "README.md" } } },
    changes = { ["internal/order/service.go"] = "M" },
    declarations = function(node)
        if node.path == "internal/order/" then
            return { { kind = "func", name = "Service" }, { kind = "func", name = "private" } }
        end
        return nil
    end,
})
local opts = picked.opts
assert(opts.winopts.title == " files · all ", "the title")
assert(require("fzf-lua.config").globals.winopts.fullscreen == true, "pickers take the whole screen")
assert(opts.prompt == "Tree ·N> " and opened.normal and opts.fzf_opts["--with-nth"] == "{1}",
    "tree prompt in normal mode, paths hidden")
for _, key in ipairs({ "right", "left", "enter", "change", "load" }) do
    assert(opts.keymap.fzf[key]:match("^transform:"), "bind " .. key)
end
for _, key in ipairs(file_tree.mode_keys) do
    assert(opts.keymap.fzf[key]:match("^transform:"), "bind " .. key)
end
assert(opts.actions._open and opts.actions.enter == nil and opts.actions["alt-c"], "Enter goes through the tree")
assert(opts.actions["alt-i"] == nil, "no fzf-lua files toggles")
local shown = vim.tbl_map(plain, load_lines())
assert(vim.tbl_contains(shown, "    ▪ service.go") and vim.tbl_contains(shown, "  ▸ user/ 1 · keeps accounts."),
    "the current file revealed, package comments from rg: " .. vim.inspect(shown))
assert(shown[1] == "▾ ★ recent 2" and opened.first_quick == 2, "recent files first, the cursor on them")
assert(opened.revealed == "internal/order/service.go", "the current file revealed")
local group = opts.previewer._ctor().parse_entry({}, opened_line(opened, "@recent/"))
same(vim.tbl_map(row_text, group.content), { "▣ go.mod", "≡ README.md" }, "a group previews its files")
assert(#vim.fn.readfile(opened.flat_file) == 9, "every file for the search")
assert(opened_line(opened, "internal/order/service.go"):find(changed_paint("service.go"), 1, true),
    "the changed file of the picker is coloured")

local folder = opts.previewer._ctor().parse_entry({}, line_of("internal/order/"))
assert(folder.title == " internal/order/ · 3 files " and folder.do_not_cache, "folder preview title")
same(vim.tbl_map(row_text, folder.content),
    { icons.Function .. " Service", "", "repo/ 1", "  ▪ pg.go", "▪ service.go", "▪ service_test.go" },
    "folder preview: the exported API, then the files")
assert(folder.content[5][1][2] == "FileTreeGo" and folder.content[6][1][2] == "FileTreeTest", "marks coloured by kind")
local user = opts.previewer._ctor().parse_entry({}, line_of("internal/user/"))
same(vim.tbl_map(row_text, user.content), { "keeps accounts.", "", "▪ user.go" }, "a folder without declarations: comment and files")

file_tree.open({ cwd = root, cmd = { "fd", "--type", "f", "." }, query = "serv", current = source })
assert(picked.opts.prompt == "Files> " and picked.opts.query == "serv", "a query starts in the search, typing")
local searched = vim.tbl_map(plain, load_lines())
assert(#searched == 9 and vim.tbl_contains(searched, "▪ internal/order/service.go"), "search lines are marked paths")
fzf.fzf_exec = real_exec
print("FILE_TREE_PICKER_OK")

-- The keys in a real fzf (in a terminal of this headless Neovim).
local function term()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].buftype == "terminal" then
            return win, buf
        end
    end
end
local function screen()
    local _, buf = term()
    return buf and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") or ""
end
local function wait_screen(what, plain_text)
    assert(vim.wait(10000, function()
        return screen():find(plain_text, 1, true) ~= nil
    end, 50), what .. ":\n" .. screen())
    vim.wait(200)
end
local function press(keys)
    local _, buf = term()
    vim.api.nvim_chan_send(vim.bo[buf].channel, keys)
end
local right, left, down, enter, backspace = "\27[C", "\27[D", "\27[B", "\r", "\127"

file_tree.open({
    cwd = root,
    cmd = { "fd", "--type", "f", "." },
    current = source,
    title = " files · all ",
    groups = { { name = "recent", mark = "★", paths = { "go.mod" } } },
})
wait_screen("recent files first", "★ recent 1")
press(enter)
assert(vim.wait(10000, function()
    return vim.api.nvim_buf_get_name(0):match("/go%.mod$") ~= nil
end, 50), "the cursor starts on the first quick file: " .. vim.api.nvim_buf_get_name(0))

file_tree.open({ cwd = root, cmd = { "fd", "--type", "f", "." }, current = source, title = " files · all " })
wait_screen("tree with the current file", "    ▪ service.go")
-- Normal mode from the start: j is a move, not a letter; i types, Esc
-- returns to normal.
wait_screen("the normal mode in the prompt", "Tree ·N>")
press("j")
vim.wait(300)
assert(not screen():find("Tree ·N> j", 1, true) and screen():find("11/11", 1, true), "j moved instead of typing:\n" .. screen())
press("i")
wait_screen("i: typing", "Tree> ")
press("\27")
wait_screen("Esc: normal again", "Tree ·N>")
press("i")
wait_screen("i: typing again", "Tree> ")
press(left)
press(left)
wait_screen("← ← closes internal/order/", "  ▸ order/ 3")
press("pg")
wait_screen("typing searches every file", "Files> pg")
wait_screen("the search shows paths", "internal/order/repo/pg.go")
press(backspace .. backspace)
wait_screen("a cleared query brings the tree back", "Tree>")
assert(screen():find("  ▸ order/ 3", 1, true), "the tree is as it was:\n" .. screen())
press(right)
wait_screen("→ on the first folder opens it", "▾ api/order/v1/ 1")
press(down .. enter)
assert(vim.wait(10000, function()
    return vim.api.nvim_buf_get_name(0):match("api/order/v1/order%.proto$") ~= nil
end, 50), "Enter on a file opens it: " .. vim.api.nvim_buf_get_name(0))
print("FILE_TREE_FZF_OK")

-- Any other picker has the same normal mode (lua/picker_mode.lua), run
-- by fzf's shell: a list starts in it, i types, Esc returns, l accepts,
-- Esc Esc closes without hiding.
local picker_mode = require("picker_mode")
local accepted
local function list_picker()
    accepted = nil
    fzf.fzf_exec({ "alpha", "beta", "gamma" }, {
        prompt = picker_mode.prompt("List"),
        actions = { enter = function(selected) accepted = selected[1] end },
    })
end
list_picker()
wait_screen("a list starts in the normal mode", "List ·N>")
press("j")
vim.wait(300)
assert(not screen():find("List ·N> j", 1, true), "j moved instead of typing:\n" .. screen())
press("i")
wait_screen("i: typing", "List> ")
press("b")
wait_screen("the letters are typed", "List> b")
press("\27")
wait_screen("Esc: the normal mode keeps the query", "List ·N> b")
press("l")
assert(vim.wait(5000, function() return accepted ~= nil end, 50), "l accepts")
assert(accepted:find("beta", 1, true), "the filtered line is accepted: " .. accepted)
list_picker()
wait_screen("the list again", "List ·N>")
press("\27")
assert(vim.wait(5000, function() return term() == nil end, 50), "Esc in the normal mode closes the picker")
assert(vim.fn.maparg("<Esc>", "t") == "", "no hide keymap on Esc")
print("PICKER_MODE_FZF_OK")

print("FILE_TREE_SMOKE_OK")

-- With nvim-web-devicons loaded every file shows its glyph; the colour
-- stays the kind's (a test stays green, generated code dim) and is the
-- icon's own for a file of no kind.
file_tree.plain = false
local devicons = require("nvim-web-devicons")
local go_glyph, go_hl = devicons.get_icon("service.go", nil, { default = true })
local lock_glyph, lock_hl = devicons.get_icon("LICENSE", nil, { default = true })
assert(go_glyph and go_glyph ~= "" and lock_glyph and lock_glyph ~= "", "glyphs by name")
same({ file_tree.icon("internal/order/service_test.go") }, { go_glyph, "FileTreeTest", false }, "a test keeps its colour")
same({ file_tree.icon("a.pb.go") }, { go_glyph, "FileTreeGenerated", true }, "generated code stays dim")
same({ file_tree.icon("LICENSE") }, { lock_glyph, lock_hl, false }, "a file of no kind takes the icon's colour")
assert(go_hl ~= "FileTreeTest", "the icon's own group differs from the kind's")
same(vim.tbl_map(plain, file_tree.tree_lines(file_tree.new_state({ "a.go", "LICENSE" }))),
    { lock_glyph .. " LICENSE", go_glyph .. " a.go" }, "glyphs in the tree")
local closed_mark, open_mark = file_tree.folder_marks()
assert(closed_mark == " " and open_mark == " ", "Nerd Font folders with devicons")
local with_folder = file_tree.new_state({ "x/a.go", "b.go" })
assert(plain(file_tree.tree_lines(with_folder)[1]) == closed_mark .. "x/ 1", "a closed folder's glyph")
with_folder.expanded["x/"] = true
assert(plain(file_tree.tree_lines(with_folder)[1]) == open_mark .. "x/ 1", "an open folder's glyph")
assert(plain(file_tree.flat_lines({ "x/a.go" })[1]) == go_glyph .. " x/a.go", "glyph in the search")
same(file_tree.preview_file("", "a.go", "a.go"), { { go_glyph, "FileTreeGo" }, { " a.go" } }, "glyph in the preview")
print("FILE_TREE_ICONS_OK")
