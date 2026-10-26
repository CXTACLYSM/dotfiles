-- Space f as a tree on the fixture verify.sh writes, as if opened from
-- internal/order/service.go: the tree (folders first, counts, one line for
-- a chain of single folders, package comments), the groups of pinned and
-- recent files, ← → Enter in the tree and in the search, the
-- switch between tree and search, the picker options (the binds, the
-- revealed file), the preview of a folder, and the same keys
-- pressed in a real fzf. verify.sh opens README.md: without gopls, whose
-- progress redraws crash a resized headless Neovim.
vim.o.columns, vim.o.lines = 140, 40
local file_tree = require("file_tree")
local fzf = require("fzf-lua")
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
    "▸ api/order/v1/ 1", "▸ cmd/app/ 1", "▸ internal/ 4", "▸ pkg/api/order/v1/ 1", "  README.md", "  go.mod",
}, "closed tree")
assert(file_tree.path_of(file_tree.tree_lines(state)[3]) == "internal/", "path after the separator")
file_tree.reveal(state, "internal/order/service.go")
local lines = file_tree.tree_lines(state)
same(vim.tbl_map(plain, lines), {
    "▸ api/order/v1/ 1", "▸ cmd/app/ 1", "▾ internal/ 4", "  ▾ order/ 3", "    ▸ repo/ 1",
    "      service.go", "      service_test.go", "  ▸ user/ 1", "▸ pkg/api/order/v1/ 1", "  README.md", "  go.mod",
}, "revealed file")
assert(file_tree.new_state({ "internal/order/a.go", "internal/order/b.go" }).expanded["internal/order/"],
    "a single top folder starts open")
print("FILE_TREE_BUILD_OK")

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
end
local flat = file_tree.flat_lines({ "internal/order/service.go", "go.mod" })
assert(plain(flat[1]) == "internal/order/service.go" and file_tree.path_of(flat[2]) == "go.mod", "search lines")
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
file_tree.set_groups(quick, {
    { name = "pinned", mark = "◆", paths = { "internal/order/service.go", "gone.go" }, numbered = true },
    { name = "recent", mark = "★", paths = { "go.mod" } },
    { name = "empty", mark = "·", paths = {} },
})
local quick_lines = file_tree.tree_lines(quick)
same(vim.tbl_map(plain, vim.list_slice(quick_lines, 1, 5)), {
    "▾ ◆ pinned 1", "  1 service.go internal/order/", "▾ ★ recent 1", "    go.mod ", "▸ api/order/v1/ 1",
}, "groups head the tree")
assert(quick.first_quick == 2, "the cursor starts on the first quick file")
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
print("FILE_TREE_QUICK_OK")

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
})
local opts = picked.opts
assert(opts.winopts.title == " files · all ", "the title")
assert(require("fzf-lua.config").globals.winopts.fullscreen == true, "pickers take the whole screen")
assert(opts.prompt == "Tree> " and opts.fzf_opts["--with-nth"] == "{1}", "tree prompt, paths hidden")
for _, key in ipairs({ "right", "left", "enter", "change", "load" }) do
    assert(opts.keymap.fzf[key]:match("^transform:"), "bind " .. key)
end
assert(opts.actions._open and opts.actions.enter == nil and opts.actions["alt-c"], "Enter goes through the tree")
assert(opts.actions["alt-i"] == nil, "no fzf-lua files toggles")
local shown = vim.tbl_map(plain, load_lines())
assert(vim.tbl_contains(shown, "      service.go") and vim.tbl_contains(shown, "  ▸ user/ 1 · keeps accounts."),
    "the current file revealed, package comments from rg: " .. vim.inspect(shown))
assert(shown[1] == "▾ ★ recent 2" and opened.first_quick == 2, "recent files first, the cursor on them")
assert(opened.revealed == "internal/order/service.go", "the current file revealed")
local group = opts.previewer._ctor().parse_entry({}, opened_line(opened, "@recent/"))
same(vim.tbl_map(function(row)
    return row[1][1]
end, group.content), { "go.mod", "README.md" }, "a group previews its files")
assert(#vim.fn.readfile(opened.flat_file) == 9, "every file for the search")

local folder = opts.previewer._ctor().parse_entry({}, line_of("internal/order/"))
assert(folder.title == " internal/order/ · 3 files " and folder.do_not_cache, "folder preview title")
same(vim.tbl_map(function(row)
    return row[1][1]
end, folder.content), { "repo/", "  pg.go", "service.go", "service_test.go" }, "folder preview")

file_tree.open({ cwd = root, cmd = { "fd", "--type", "f", "." }, query = "serv", current = source })
assert(picked.opts.prompt == "Files> " and picked.opts.query == "serv", "a query starts in the search")
local searched = vim.tbl_map(plain, load_lines())
assert(#searched == 9 and vim.tbl_contains(searched, "internal/order/service.go"), "search lines are paths")
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
wait_screen("tree with the current file", "      service.go")
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

print("FILE_TREE_SMOKE_OK")
