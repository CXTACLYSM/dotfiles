-- The whole init.lua after startup: gopls settings, commands, mappings,
-- portable symbol icons and the change tree defaults.
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
}) do
    assert(has_map("n", lhs), "missing normal mapping " .. lhs)
end

for _, lhs in ipairs({ "af", "if", "aa", "ia", "ac", "ic" }) do
    assert(has_map("x", lhs) and has_map("o", lhs), "missing text object " .. lhs)
end

assert(vim.fn.maparg("<leader>cr", "n") == "", "<leader>cr stays free")
assert((vim.fn.maparg("grr", "n", false, true).desc or ""):find("implementations", 1, true), "grr merges implementations")
assert(has_map("i", "(") and has_map("i", "<BS>"), "insert-mode pairs")

assert(type(require("dap").adapters.delve) == "function", "delve adapter")
assert(require("big_file").opts.max_lines == 10000, "big file threshold")

local retrigger = require("completion_retrigger").opts
assert(retrigger.keyword_min_length == 2, "keyword completion from the 2nd character")
assert(retrigger.keyword_debounce_ms == 400, "keyword pause")
assert(retrigger.member_min_length == 1, "member completion from the 1st character")

local symbols = require("fzf-lua.config").globals.lsp.symbols
assert(symbols.symbol_style == 1, "icon plus kind name")
assert(symbols.symbol_icons.Function == "ƒ" and symbols.symbol_icons.Constant == "π", "portable symbol icons")
for kind, icon in pairs(symbols.symbol_icons) do
    for _, code in ipairs(vim.fn.str2list(icon)) do
        assert(code < 0xE000 or code > 0xF8FF, "private-use glyph for " .. kind)
    end
end

local change_tree = require("change_tree")
assert(change_tree.opts.auto == false, "build after save is off by default")
change_tree.toggle_auto()
assert(change_tree.opts.auto == true, "toggle turns it on")
change_tree.toggle_auto()
assert(change_tree.opts.auto == false, "toggle turns it off again")

print("FULL_INIT_OK")
