-- The whole init.lua after startup: gopls settings, commands, mappings,
-- diagnostics, Tree-sitter parsers, portable symbol icons, full-screen
-- pickers and graph views, and the change tree defaults.
local cfg = vim.lsp.config.gopls
assert(cfg.cmd_env.GOTOOLCHAIN == nil, "gopls must inherit the shell GOTOOLCHAIN policy")
assert(cfg.cmd_env.GOPROXY == nil, "gopls must inherit the shell GOPROXY")
assert(vim.deep_equal(cfg.cmd, { "gopls" }), "fixtures run an in-process gopls")
local gopls = cfg.settings.gopls
assert(gopls.symbolScope == "workspace", "symbolScope")
assert(vim.tbl_contains(gopls.directoryFilters, "-**/vendor"), "directoryFilters")
assert(gopls.analyses.nilness == true, "nilness analysis")
assert(gopls.hints.parameterNames == true, "inlay hints configured")
assert(gopls.semanticTokens == true, "semantic tokens")

for _, name in ipairs({
    "GoBuild", "GoTest", "GoReturns", "GoCallers", "GoCallees",
    "GoDebugTest", "GoDebug", "DapContinue", "DapToggleBreakpoint", "Gitsigns",
    "ChangeTree", "ChangeTreeAuto", "ChangeTreeCancel",
    "ChangeTreeText", "ChangeTreeLedger", "ChangeTreeTrace", "ChangeTreeIndex",
    "Neotree", "FormatOnSave", "GoImpl", "BufferLineCycleNext",
}) do
    assert(vim.fn.exists(":" .. name) == 2, "missing command :" .. name)
end

local function has_map(mode, lhs)
    return next(vim.fn.maparg(lhs, mode, false, true)) ~= nil
end

for _, lhs in ipairs({
    "<leader>tb", "<leader>tc", "<leader>tn", "<leader>ti", "<leader>to",
    "<leader>tt", "<leader>tr", "<leader>ts", "<leader>th",
    "<leader>q", "<leader>sd", "<leader>sq", "<leader>ih", "]q", "[q",
    "]f", "[f", "]a", "[a", "]s", "[s",
    "]m", "[m", "]e", "[e", "]R", "[R", "]g", "[g", "]G", "[G", "]l", "[l",
    "]w", "[w", "]k", "[k", "]i", "[i", "]v", "[v", "]T", "[T",
    "<M-j>", "<M-k>", "<M-h>", "<M-l>", "[S", "]S",
    "gre", "grc", "gro", "<leader>ct", "<leader>cT",
    "gp", "gP", "gI", "<leader>ga", "<leader>*", "<leader>.", "<leader>,",
    "<leader>st", "]t", "[t", "<leader>sQ",
    "<leader>f", "<leader>F", "<leader>/", "<leader>sS", "grp", "grq", "<leader>p", "<leader>P", "<M-1>",
    "<leader>e", "<leader>?", "<leader>j", "<leader>cp", "<leader>ce", "grP",
    "]b", "[b", "<leader>x", "<leader>X",
}) do
    assert(has_map("n", lhs), "missing normal mapping " .. lhs)
end

for _, lhs in ipairs({ "af", "if", "aa", "ia", "ac", "ic", "ab", "ib" }) do
    assert(has_map("x", lhs) and has_map("o", lhs), "missing text object " .. lhs)
end

assert(vim.fn.maparg("<leader>cr", "n") == "", "<leader>cr stays free")
assert((vim.fn.maparg("grr", "n", false, true).desc or ""):find("implementations", 1, true), "grr merges implementations")
assert(has_map("i", "(") and has_map("i", "<BS>"), "insert-mode pairs")
assert(has_map("x", "<leader>*"), "grep selection")
assert(#vim.api.nvim_get_autocmds({ group = "breadcrumbs" }) > 0, "breadcrumbs attach to windows")

-- Jumps between the Go keywords land on the statements (after/queries/go/moves.scm).
do
    local file = vim.fn.tempname() .. ".go"
    vim.fn.writefile({
        "package main",                                       -- 1
        "",
        "const limit = 3",                                    -- 3
        "",
        "type Store interface{ Get(id int) (string, error) }", -- 5
        "",
        "type Repo struct{ s Store }",                        -- 7
        "",
        "func (r *Repo) Get(id int) (string, error) {",       -- 9
        "\tdefer func() {}()",                                -- 10
        "\tgo func() {}()",                                   -- 11
        "\tfor i := 0; i < limit; i++ {",                     -- 12
        "\t\tswitch i {",                                     -- 13
        "\t\tcase 1:",                                        -- 14
        "\t\t\treturn \"\", nil",                             -- 15
        "\t\t}",
        "\t}",
        "\tv, err := r.s.Get(id)",                            -- 18
        "\tif err != nil {",                                  -- 19
        "\t\treturn \"\", err",                                -- 20
        "\t}",
        "\treturn v, nil",                                    -- 22
        "}",
        "",
        "func TestRepo(t *testing.T) {}",                     -- 25
    }, file)
    vim.cmd.edit(file)
    local function lines_of(key)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        local reached = {}
        for _ = 1, 5 do
            local before = vim.fn.line(".")
            vim.cmd("normal " .. key)
            if vim.fn.line(".") == before then
                break
            end
            table.insert(reached, vim.fn.line("."))
        end
        return table.concat(reached, ",")
    end
    for key, expected in pairs({
        ["]s"] = "5,7", ["]i"] = "5", ["]v"] = "3", ["]m"] = "9", ["]f"] = "9,10,11,25",
        ["]G"] = "10", ["]g"] = "11", ["]l"] = "12", ["]w"] = "13", ["]k"] = "14",
        ["]R"] = "15,20,22", ["]e"] = "19", ["]T"] = "25",
    }) do
        assert(lines_of(key) == expected, key .. " reaches " .. lines_of(key) .. ", not " .. expected)
    end
    vim.api.nvim_win_set_cursor(0, { 23, 0 })
    vim.cmd("normal [e")
    assert(vim.fn.line(".") == 19, "[e goes back to the error check")
    vim.cmd("normal 2[R")
    assert(vim.fn.line(".") == 15, "a count: 2[R")

    -- Over the tree: siblings are the statements of the block, the parent
    -- the block then the method, the child the first statement.
    local function at(line, col)
        vim.api.nvim_win_set_cursor(0, { line, col or 0 })
    end
    local function pos()
        local cursor = vim.api.nvim_win_get_cursor(0)
        return cursor[1] .. ":" .. cursor[2]
    end
    -- <M-j> is one key code, not Esc then j.
    local function alt(letter, count)
        vim.cmd("normal " .. (count or "") .. vim.api.nvim_replace_termcodes("<M-" .. letter .. ">", true, false, true))
    end
    at(18, 4)
    alt("j")
    assert(pos() == "19:1", "Alt-j: the next statement, not the next word: " .. pos())
    alt("j")
    assert(pos() == "22:1", "Alt-j: over the if to the return: " .. pos())
    alt("k", 2)
    assert(pos() == "18:1", "2 Alt-k back: " .. pos())
    at(19, 12)
    alt("h")
    assert(pos() == "19:11", "Alt-h from inside nil: nil: " .. pos())
    alt("h")
    assert(pos() == "19:4", "Alt-h: the condition: " .. pos())
    alt("h")
    assert(pos() == "19:1", "Alt-h: the if: " .. pos())
    alt("h")
    assert(pos() == "9:43", "Alt-h: the block of the method: " .. pos())
    alt("h")
    assert(pos() == "9:0", "Alt-h: the method: " .. pos())
    at(19, 12)
    alt("h", 5)
    assert(pos() == "9:0", "5 Alt-h: the same in one go: " .. pos())
    alt("l")
    assert(pos() == "9:5", "Alt-l: into the receiver: " .. pos())
    at(9, 43)
    alt("l")
    assert(pos() == "10:1", "Alt-l from the block: the first statement: " .. pos())
    at(20, 10)
    vim.cmd("normal [S")
    assert(pos() == "9:0", "[S: the start of the method around: " .. pos())
    at(20, 10)
    vim.cmd("normal ]S")
    assert(pos() == "23:0", "]S: its end: " .. pos())
    at(14, 2)
    alt("j")
    assert(pos() == "14:2", "Alt-j on the only case stays: " .. pos())
    alt("l")
    assert(pos() == "14:7", "Alt-l into the case: its value: " .. pos())
    at(10, 1)
    alt("l")
    assert(pos() == "10:7", "Alt-l from the first statement goes into it, not over the list: " .. pos())

    vim.cmd("bwipeout!")
    vim.fn.delete(file)
end

-- In a .proto, by its syntax tree: ]p rpc, ]M message, ]s message or enum.
do
    local file = vim.fn.tempname() .. ".proto"
    vim.fn.writefile({
        "syntax = \"proto3\";",
        "",
        "enum Status {",
        "  OK = 0;",
        "}",
        "",
        "message Order {",
        "  int64 id = 1;",
        "}",
        "",
        "message Empty {}",
        "",
        "service Orders {",
        "  rpc Get(Order) returns (Order);",
        "  rpc List(Empty) returns (Order);",
        "}",
    }, file)
    vim.cmd.edit(file)
    assert(vim.bo.filetype == "proto", "proto filetype: " .. vim.bo.filetype)
    assert(vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()], "Tree-sitter runs in .proto")
    local function lines_of(key)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        local reached = {}
        for _ = 1, 5 do
            local before = vim.fn.line(".")
            vim.cmd("normal " .. key)
            if vim.fn.line(".") == before then
                break
            end
            table.insert(reached, vim.fn.line("."))
        end
        return table.concat(reached, ",")
    end
    assert(lines_of("]p") == "14,15", "]p: the rpcs: " .. lines_of("]p"))
    assert(lines_of("]M") == "7,11", "]M: the messages: " .. lines_of("]M"))
    assert(lines_of("]s") == "3,7,11", "]s: enums and messages: " .. lines_of("]s"))
    vim.api.nvim_win_set_cursor(0, { 16, 0 })
    vim.cmd("normal 2[p")
    assert(vim.fn.line(".") == 14, "2[p back")
    vim.cmd("bwipeout!")
    vim.fn.delete(file)
end

-- The empty start buffer leaves the tabs once no window shows it.
do
    local empty = vim.api.nvim_get_current_buf()
    assert(vim.api.nvim_buf_get_name(empty) == "", "starts in an empty buffer")
    local file = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "x" }, file)
    vim.cmd("vsplit " .. vim.fn.fnameescape(file))
    vim.wait(50)
    assert(vim.api.nvim_buf_is_valid(empty) and vim.bo[empty].buflisted, "a shown empty buffer stays")
    vim.cmd.only()
    vim.wait(200, function() return not vim.api.nvim_buf_is_valid(empty) end)
    assert(not vim.api.nvim_buf_is_valid(empty), "[No Name] tab is dropped")
    local listed = vim.tbl_filter(function(b) return vim.bo[b].buflisted end, vim.api.nvim_list_bufs())
    assert(#listed == 1, "one tab: the file")
    vim.fn.delete(file)
end

local diagnostics = vim.diagnostic.config()
assert(type(diagnostics.virtual_text) == "table" and diagnostics.virtual_text.current_line == true,
    "diagnostic text only on the cursor line")
assert(diagnostics.virtual_lines == false, "no diagnostic lines that shift the text")
for _, language in ipairs({ "go", "sql", "comment" }) do
    assert(pcall(vim.treesitter.language.add, language), "parser " .. language)
end
local injections = vim.treesitter.query.get("go", "injections")
assert(injections and vim.tbl_contains(injections.captures, "injection.content"), "Go injections")
local found_sql = false
for _, file in ipairs(vim.treesitter.query.get_files("go", "injections")) do
    found_sql = found_sql or file:find("after/queries/go/injections.scm", 1, true) ~= nil
end
assert(found_sql, "SQL injection query for Go strings is on the runtimepath")

assert(type(require("dap").adapters.delve) == "function", "delve adapter")
assert(require("big_file").opts.max_lines == 10000, "big file threshold")

local retrigger = require("completion_retrigger").opts
assert(retrigger.keyword_min_length == 2, "keyword completion from the 2nd character")
assert(retrigger.keyword_debounce_ms == 400, "keyword pause")
assert(retrigger.member_min_length == 1, "member completion from the 1st character")

local symbols = require("fzf-lua.config").globals.lsp.symbols
assert(symbols.symbol_style == 1, "icon plus kind name")
assert(symbols.symbol_icons.Function == "󰊕" and symbols.symbol_icons.Struct == "󰆼", "fzf-lua's Nerd Font symbol icons")
for kind, icon in pairs(symbols.symbol_icons) do
    assert(vim.fn.strdisplaywidth(icon) == 1, "one column for " .. kind)
    for _, code in ipairs(vim.fn.str2list(icon)) do
        assert((code >= 0xE000 and code <= 0xF8FF) or code >= 0xF0000, "a Nerd Font glyph for " .. kind)
    end
end

assert(require("fzf-lua.config").globals.winopts.fullscreen == true, "pickers take the whole screen")
local tree_win, preview_win = require("graph_view").open({
    title = " graph ",
    lines = { "root", "  child" },
    entries = { {}, {} },
})
for _, win in ipairs({ tree_win, preview_win }) do
    assert(win, "graph view window")
    local frame = vim.api.nvim_win_get_config(win)
    assert(frame.height == vim.o.lines - vim.o.cmdheight - 2 and frame.row == 0,
        "graph view on the whole screen: " .. vim.inspect(frame))
end
vim.api.nvim_win_close(preview_win, true)
vim.api.nvim_win_close(tree_win, true)

local change_tree = require("change_tree")
assert(change_tree.opts.auto == false, "build after save is off by default")
change_tree.toggle_auto()
assert(change_tree.opts.auto == true, "toggle turns it on")
change_tree.toggle_auto()
assert(change_tree.opts.auto == false, "toggle turns it off again")

print("FULL_INIT_OK")

-- Icons and the panel: devicons knows Go by name, which-key is set up and
-- names the prefixes, neo-tree keeps Space as the leader in its window.
local glyph = require("nvim-web-devicons").get_icon("main.go", nil, { default = true })
assert(glyph and glyph ~= "", "devicons glyph for a Go file")
assert(require("nvim-web-devicons").get_icon("no-such-kind", nil, {}) ~= nil, "a default icon for a file of no known type")
require("neo-tree").ensure_config()
local neotree = require("neo-tree.setup").config
local mappings = neotree.window.mappings
assert(mappings["<space>"] == "none" and mappings["<Right>"] == "open" and mappings["<Left>"] == "close_node",
    "neo-tree keys: " .. vim.inspect(mappings))
local tree_window = neotree.filesystem.window
-- neo-tree keeps the filter box keys in lower case.
assert(tree_window.mappings["<C-h>"] == "clear_filter" and tree_window.fuzzy_finder_mappings["<c-h>"] == "close_clear_filter"
    and tree_window.fuzzy_finder_mappings["<esc>"] == "close", "Ctrl-h drops the filter, the other filter keys stay")

-- Every picker: the normal mode binds and no hiding on Esc.
local fzf_globals = require("fzf-lua.config").globals
assert(fzf_globals.defaults.no_hide == true, "Esc is not fzf-lua's hide")
for _, key in ipairs({ "esc", "i", "j", "k", "g", "q", "l", "h" }) do
    assert((fzf_globals.keymap.fzf[key] or ""):match("^transform:"), "picker bind " .. key)
end
assert(fzf_globals.keymap.fzf["ctrl-f"] == "half-page-down", "the default fzf binds stay")
assert(neotree.filesystem.follow_current_file.enabled, "the panel follows the current file")
-- flash on s, nvim-surround on ys / cs / ds with Visual S, conform runs
-- gofumpt on Go only and leaves other file types alone.
for _, lhs in ipairs({ "s", "S", "ys", "cs", "ds" }) do
    assert(has_map("n", lhs), "missing normal mapping " .. lhs)
end
assert(vim.fn.maparg("S", "x"):find("surround", 1, true), "Visual S is nvim-surround's")
assert(vim.fn.maparg("s", "x") ~= "" and vim.fn.maparg("r", "o") ~= "", "flash in Visual and as a motion")
local conform = require("conform")
assert(vim.deep_equal(conform.formatters_by_ft.go, { "gofumpt" }), "gofumpt for Go")
assert(conform.formatters_by_ft.lua == nil, "Lua is not formatted")
-- The status line stays Neovim's own.
assert(not vim.o.statusline:find("%%f") and not vim.o.statusline:find("%%F") and vim.o.statusline:find("%l", 1, true)
    and vim.o.winborder == "rounded", "the status line without the file name, rounded floating windows")
local signs = vim.diagnostic.config().signs.text
assert(signs[vim.diagnostic.severity.ERROR] == "" and signs[vim.diagnostic.severity.HINT] == "", "diagnostic glyphs")
local wk_ok = pcall(require("which-key").add, { { "<leader>z", group = "probe" } })
assert(wk_ok, "which-key accepts a group")
print("INIT_ICONS_OK")
