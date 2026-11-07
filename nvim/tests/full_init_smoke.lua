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
    "]f", "[f", "]a", "[a",
    "gre", "grc", "gro", "<leader>ct", "<leader>cT",
    "gp", "gP", "gI", "<leader>ga", "<leader>*", "<leader>.", "<leader>,",
    "<leader>st", "]t", "[t", "<leader>sQ",
    "<leader>f", "<leader>F", "<leader>/", "<leader>sS", "grp", "grq", "<leader>p", "<leader>P", "<M-1>",
    "<leader>e", "<leader>?", "<leader>j", "<leader>cp", "<leader>ce", "grP",
    "]b", "[b", "<leader>x", "<leader>X",
}) do
    assert(has_map("n", lhs), "missing normal mapping " .. lhs)
end

for _, lhs in ipairs({ "af", "if", "aa", "ia", "ac", "ic" }) do
    assert(has_map("x", lhs) and has_map("o", lhs), "missing text object " .. lhs)
end

assert(vim.fn.maparg("<leader>cr", "n") == "", "<leader>cr stays free")
assert((vim.fn.maparg("grr", "n", false, true).desc or ""):find("implementations", 1, true), "grr merges implementations")
assert(has_map("i", "(") and has_map("i", "<BS>"), "insert-mode pairs")
assert(has_map("x", "<leader>*"), "grep selection")
assert(#vim.api.nvim_get_autocmds({ group = "breadcrumbs" }) > 0, "breadcrumbs attach to windows")

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
