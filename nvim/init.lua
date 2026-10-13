vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- The project search root is the directory from which `nvim .` started.
-- File/grep pickers keep using this root even after buffer navigation.
local project_root = vim.fn.getcwd()

-- ============================================================
-- Options
-- ============================================================

local opt = vim.opt

opt.number = true
opt.relativenumber = true
opt.mouse = ""
opt.termguicolors = true

opt.expandtab = true
opt.shiftwidth = 4
opt.tabstop = 4
opt.softtabstop = 4

opt.ignorecase = true
opt.smartcase = true

opt.splitright = true
opt.splitbelow = true

opt.scrolloff = 8
opt.sidescrolloff = 8

opt.signcolumn = "yes"
opt.cursorline = true

opt.undofile = true
opt.swapfile = false

opt.updatetime = 250
opt.timeoutlen = 1000

-- Native completion works better with this.
opt.completeopt = { "menuone", "noselect", "popup" }

-- System clipboard.
opt.clipboard = "unnamedplus"


-- ============================================================
-- Basic keymaps
-- ============================================================

local map = vim.keymap.set

-- Escape terminal / insert muscle memory.
map("i", "jk", "<Esc>", { desc = "Normal mode" })

-- Predictable insert-mode pairs without an additional plugin.
require("pairs").setup()

-- Better window navigation.
map("n", "<C-h>", "<C-w>h")
map("n", "<C-j>", "<C-w>j")
map("n", "<C-k>", "<C-w>k")
map("n", "<C-l>", "<C-w>l")

-- Keep selection while indenting.
map("v", "<", "<gv")
map("v", ">", ">gv")

-- Clear search highlight.
map("n", "<Esc>", "<cmd>nohlsearch<CR>")

-- Scope-aware rename: for a local Go variable, gopls changes only that
-- declaration and its semantic uses, not equal text in another scope.
local function rename_symbol()
    vim.lsp.buf.rename()
end

map("n", "grn", rename_symbol, {
    desc = "LSP rename symbol",
})

map("n", "<leader>rn", rename_symbol, {
    desc = "LSP rename symbol",
})

-- Diagnostics.
map("n", "<leader>d", vim.diagnostic.open_float, {
    desc = "Diagnostic",
})

-- Keep diagnostics quiet while coding.
-- Signs/underlines stay visible; details are shown on demand with <leader>d.
vim.diagnostic.config({
    virtual_text = false,
    virtual_lines = false,
    signs = true,
    underline = true,
    severity_sort = true,
    update_in_insert = false,
    float = {
        border = "rounded",
        source = true,
    },
})


-- ============================================================
-- Plugins
-- ============================================================

vim.pack.add({
    "https://github.com/neovim/nvim-lspconfig",
    "https://github.com/ibhagwan/fzf-lua",
    {
        src = "https://github.com/catppuccin/nvim",
        name = "catppuccin",
    },
    "https://github.com/nvim-treesitter/nvim-treesitter",
    -- Function / type / parameter text objects and motions on the AST.
    "https://github.com/nvim-treesitter/nvim-treesitter-textobjects",
    -- Git hunks, staging and blame for the current buffer.
    "https://github.com/lewis6991/gitsigns.nvim",
    -- Debug Adapter Protocol client; delve is the Go adapter.
    "https://github.com/mfussenegger/nvim-dap",
})


-- ============================================================
-- Theme
-- ============================================================

require("catppuccin").setup({
    flavour = "mocha",
    transparent_background = false,
    term_colors = false,
    no_italic = true,
    auto_integrations = true,
})

vim.cmd.colorscheme("catppuccin-mocha")


-- ============================================================
-- Tree-sitter
-- ============================================================

require("nvim-treesitter").setup({})

-- Files over 1 MiB or 10k lines (generated code) skip Tree-sitter, semantic
-- tokens and reference highlights; gopls still attaches.
local big_file = require("big_file")

big_file.setup({
    max_bytes = 1024 * 1024,
    max_lines = 10000,
})

vim.api.nvim_create_autocmd("FileType", {
    pattern = { "go", "gomod", "gosum", "gowork" },
    callback = function(event)
        if not big_file.is_marked(event.buf) then
            vim.treesitter.start(event.buf)
        end
    end,
})

-- Text objects and motions on the Go AST (nvim-treesitter-textobjects):
-- af / if function, ac / ic type declaration, aa / ia argument or parameter,
-- ab / ib block; ]f / [f jump to the next / previous function start,
-- ]F / [F to its end, ]a / [a to the next / previous parameter.
require("nvim-treesitter-textobjects").setup({
    select = {
        lookahead = true,
        include_surrounding_whitespace = false,
    },
    move = {
        set_jumps = true,
    },
})

local ts_select = require("nvim-treesitter-textobjects.select")
local ts_move = require("nvim-treesitter-textobjects.move")

for lhs, capture in pairs({
    af = "@function.outer",
    ["if"] = "@function.inner",
    ac = "@class.outer",
    ic = "@class.inner",
    aa = "@parameter.outer",
    ia = "@parameter.inner",
    ab = "@block.outer",
    ib = "@block.inner",
}) do
    map({ "x", "o" }, lhs, function()
        ts_select.select_textobject(capture, "textobjects")
    end, {
        desc = "Text object " .. capture,
    })
end

for lhs, spec in pairs({
    ["]f"] = { "goto_next_start", "@function.outer" },
    ["[f"] = { "goto_previous_start", "@function.outer" },
    ["]F"] = { "goto_next_end", "@function.outer" },
    ["[F"] = { "goto_previous_end", "@function.outer" },
    ["]a"] = { "goto_next_start", "@parameter.inner" },
    ["[a"] = { "goto_previous_start", "@parameter.inner" },
}) do
    map({ "n", "x", "o" }, lhs, function()
        ts_move[spec[1]](spec[2], "textobjects")
    end, {
        desc = spec[1] .. " " .. spec[2],
    })
end

-- Jump to the start of the nearest enclosing Go callable.
-- Handles named functions, methods, and anonymous func literals.
local go_callable_nodes = {
    function_declaration = true,
    method_declaration = true,
    func_literal = true,
}

local function jump_to_enclosing_go_function()
    if vim.bo.filetype ~= "go" then
        vim.notify(
            "Enclosing-function jump is available in Go buffers",
            vim.log.levels.INFO
        )
        return
    end

    local node = vim.treesitter.get_node()

    while node do
        if go_callable_nodes[node:type()] then
            local row, col = node:start()

            -- Explicitly add the current location to the jumplist,
            -- so Ctrl-o returns to where we came from.
            vim.cmd("normal! m'")

            vim.api.nvim_win_set_cursor(0, { row + 1, col })
            vim.cmd("normal! zz")
            return
        end

        node = node:parent()
    end

    vim.notify(
        "No enclosing Go function or method",
        vim.log.levels.INFO
    )
end

map("n", "<leader>cf", jump_to_enclosing_go_function, {
    desc = "Current enclosing Go function",
})

-- Graph views live next to the native `gr*` LSP family (grr references,
-- gri implementation, grn rename): a tree on the left, the code of the
-- selected node on the right, Enter jumps into it, q closes.
--
-- gre: exits of the enclosing Go callable, every branch that leads to a
--      `return`, `panic`, terminal call or `goto`, with line numbers.
-- grc: callers of the symbol under the cursor through gopls call hierarchy,
--      transitively with bounded depth; interface methods also list `impl`.
-- gro: outgoing calls of the symbol under the cursor.
local go_returns = require("go_returns")

go_returns.setup({
    pure_ascii = false,
    max_label = 72,
    show_defer = true,
})

map("n", "gre", function()
    go_returns.show()
end, {
    desc = "Return graph of the enclosing Go function",
})

local go_calls = require("go_calls")

go_calls.setup({
    max_depth = 3,
    max_children = 12,
    max_nodes = 160,
})

map("n", "grc", function()
    go_calls.show("in")
end, {
    desc = "Call graph: callers of the symbol under the cursor",
})

map("n", "gro", function()
    go_calls.show("out")
end, {
    desc = "Call graph: callees of the symbol under the cursor",
})


-- ============================================================
-- Git hunks and blame
-- ============================================================

-- Signs share the sign column with diagnostics. Mappings are buffer-local
-- and appear only in git-tracked buffers.
require("gitsigns").setup({
    signcolumn = true,
    numhl = false,
    linehl = false,
    current_line_blame = false,
    attach_to_untracked = false,
    update_debounce = 200,
    max_file_length = 40000,
    preview_config = {
        border = "rounded",
    },
    on_attach = function(bufnr)
        local gitsigns = require("gitsigns")

        local function buffer_map(mode, lhs, rhs, desc)
            map(mode, lhs, rhs, { buffer = bufnr, desc = desc })
        end

        buffer_map("n", "]c", function()
            if vim.wo.diff then
                vim.cmd.normal({ "]c", bang = true })
            else
                gitsigns.nav_hunk("next")
            end
        end, "Next git hunk")

        buffer_map("n", "[c", function()
            if vim.wo.diff then
                vim.cmd.normal({ "[c", bang = true })
            else
                gitsigns.nav_hunk("prev")
            end
        end, "Previous git hunk")

        buffer_map("n", "<leader>hs", gitsigns.stage_hunk, "Stage hunk")
        buffer_map("n", "<leader>hr", gitsigns.reset_hunk, "Reset hunk")
        buffer_map("v", "<leader>hs", function()
            gitsigns.stage_hunk({ vim.fn.line("."), vim.fn.line("v") })
        end, "Stage selected lines")
        buffer_map("v", "<leader>hr", function()
            gitsigns.reset_hunk({ vim.fn.line("."), vim.fn.line("v") })
        end, "Reset selected lines")
        buffer_map("n", "<leader>hS", gitsigns.stage_buffer, "Stage buffer")
        buffer_map("n", "<leader>hp", gitsigns.preview_hunk_inline, "Preview hunk")
        buffer_map("n", "<leader>hb", function()
            gitsigns.blame_line({ full = true })
        end, "Blame line")
        buffer_map("n", "<leader>hB", gitsigns.toggle_current_line_blame, "Toggle line blame")
        buffer_map("n", "<leader>hd", gitsigns.diffthis, "Diff against index")
        buffer_map("n", "<leader>hq", function()
            gitsigns.setqflist("all")
        end, "All hunks to quickfix")
        buffer_map({ "o", "x" }, "ih", gitsigns.select_hunk, "Hunk text object")
    end,
})


-- ============================================================
-- Debugging (nvim-dap + delve)
-- ============================================================

-- Space t is the debug prefix ("trace"): tb breakpoint, tB conditional
-- breakpoint, tc continue or start, tn step over, ti step into, to step
-- out, tt debug the test under the cursor, tp debug a package main, tl run
-- the last configuration, tx terminate, tr REPL, ts scopes sidebar,
-- tf frames, th evaluate the expression under the cursor or selection.
local go_debug = require("go_debug")

go_debug.setup({
    dlv = "dlv",
    build_flags = {},
    output_mode = "remote",
})

local dap = require("dap")
local dap_widgets = require("dap.ui.widgets")

map("n", "<leader>tb", dap.toggle_breakpoint, { desc = "Debug: toggle breakpoint" })
map("n", "<leader>tB", function()
    local condition = vim.fn.input("Breakpoint condition: ")
    if condition ~= "" then
        dap.set_breakpoint(condition)
    end
end, { desc = "Debug: conditional breakpoint" })
map("n", "<leader>tc", dap.continue, { desc = "Debug: continue / start" })
map("n", "<leader>tn", dap.step_over, { desc = "Debug: step over" })
map("n", "<leader>ti", dap.step_into, { desc = "Debug: step into" })
map("n", "<leader>to", dap.step_out, { desc = "Debug: step out" })
map("n", "<leader>tt", go_debug.debug_nearest_test, { desc = "Debug: test under cursor" })
map("n", "<leader>tp", go_debug.debug_package, { desc = "Debug: package main" })
map("n", "<leader>tl", dap.run_last, { desc = "Debug: run last configuration" })
map("n", "<leader>tx", dap.terminate, { desc = "Debug: terminate" })
map("n", "<leader>tr", dap.repl.toggle, { desc = "Debug: REPL" })
map("n", "<leader>ts", function()
    dap_widgets.sidebar(dap_widgets.scopes).toggle()
end, { desc = "Debug: scopes sidebar" })
map("n", "<leader>tf", function()
    dap_widgets.centered_float(dap_widgets.frames)
end, { desc = "Debug: stack frames" })
map({ "n", "v" }, "<leader>th", dap_widgets.hover, { desc = "Debug: evaluate under cursor" })


-- ============================================================
-- Change tree
-- ============================================================

-- What changed against HEAD and what depends on it: changed Go
-- declarations (git diff + AST helper) expanded through gopls into callers,
-- references, tests, implementations and the code they use. Space ct builds
-- and opens the tree; Space cT toggles building it after every :w (off by
-- default). See lua/change_tree.lua.
local change_tree = require("change_tree")

change_tree.setup({
    auto = false,
})

map("n", "<leader>ct", change_tree.open, {
    desc = "Change tree: build and show",
})

map("n", "<leader>cT", change_tree.toggle_auto, {
    desc = "Change tree: toggle build after save",
})


-- ============================================================
-- FZF
-- ============================================================

local fzf = require("fzf-lua")

-- fzf-lua's default symbol icons are Nerd Font private-use glyphs and render
-- as `?` in a plain terminal font. Use ordinary Unicode characters that Menlo
-- and SF Mono carry, and keep the kind name next to the glyph.
local symbol_icons = {
    File = "≡",
    Module = "▣",
    Namespace = "▣",
    Package = "▣",
    Class = "◆",
    Struct = "▦",
    Interface = "◇",
    Method = "ƒ",
    Function = "ƒ",
    Constructor = "ƒ",
    Field = "▪",
    Property = "▫",
    Variable = "∙",
    Constant = "π",
    String = "“",
    Number = "#",
    Boolean = "⊤",
    Array = "[]",
    Object = "{}",
    Key = "∷",
    Null = "∅",
    Enum = "▤",
    EnumMember = "▸",
    Event = "↯",
    Operator = "±",
    TypeParameter = "τ",
}

fzf.setup({
    -- Preview to the right of the list while the picker is wider than 80
    -- columns (nvim from about 90); only in a very narrow window does it
    -- move below the list.
    winopts = {
        width = 0.9,
        preview = {
            flip_columns = 80,
        },
    },
    lsp = {
        symbols = {
            -- 1 = "<icon> <kind>", so the word stays readable even if a glyph
            -- is missing from the terminal font.
            symbol_style = 1,
            symbol_icons = symbol_icons,
        },
    },
})

-- Always execute a fresh file scan rooted at the directory where `nvim .`
-- started. This avoids stale/resumed picker state and cwd drift.
map("n", "<leader>f", function()
    fzf.files({
        cwd = project_root,
        resume = false,
        hidden = true,
        no_ignore = false,
    })
end, {
    desc = "Find project files",
})

-- Same search, but include files ignored by .gitignore.
map("n", "<leader>F", function()
    fzf.files({
        cwd = project_root,
        resume = false,
        hidden = true,
        no_ignore = true,
    })
end, {
    desc = "Find all project files",
})

map("n", "<leader>/", function()
    fzf.live_grep({
        cwd = project_root,
        resume = false,
    })
end, {
    desc = "Grep project",
})

map("n", "<leader>b", "<cmd>FzfLua buffers<CR>", {
    desc = "Buffers",
})

map("n", "<leader>ss", "<cmd>FzfLua lsp_document_symbols<CR>", {
    desc = "Document symbols",
})

map("n", "<leader>sS", "<cmd>FzfLua lsp_live_workspace_symbols<CR>", {
    desc = "Live workspace symbols",
})

-- Override Neovim's native `grr` references list with fzf-lua.
-- The picker merges `textDocument/references` with
-- `textDocument/implementation`, so `grr` on an interface method also lists
-- every concrete method that satisfies it. Entries are prefixed `impl`
-- (or `iface` when the cursor is on a concrete method) and `ref`.
map("n", "grr", function()
    require("go_refs").open()
end, {
    desc = "LSP references and implementations with preview",
})


-- ============================================================
-- LSP
-- ============================================================

require("go_lsp").setup({
    settings = {
        gopls = {
            gofumpt = true,
            staticcheck = true,

            -- Large-repository scope. Vendored and generated trees are not
            -- workspace packages; excluding them keeps the initial load and
            -- file watching proportional to the code you edit.
            directoryFilters = {
                "-**/node_modules",
                "-**/vendor",
                "-**/testdata",
                "-**/.git",
            },

            -- `Space sS` searches workspace packages only, not every
            -- dependency in the module cache.
            symbolScope = "workspace",

            -- Build tags for the project go here, e.g. { "-tags=integration" }.
            buildFlags = {},

            analyses = {
                unusedparams = true,
                unusedwrite = true,
                nilness = true,
                unusedvariable = true,
            },

            -- Inlay hints are computed on demand only: Space ih toggles them
            -- per buffer, quiet mode stays the default.
            hints = {
                assignVariableTypes = true,
                compositeLiteralFields = true,
                constantValues = true,
                functionTypeParameters = true,
                parameterNames = true,
                rangeVariableTypes = true,
            },
        },
    },
})


-- ============================================================
-- LSP completion
-- ============================================================

local lsp_document_highlight = vim.api.nvim_create_augroup(
    "lsp_document_highlight",
    { clear = false }
)

-- Jump between semantic references to the symbol under the cursor
-- in the current buffer. Uses the same LSP documentHighlight data
-- as the automatic reference highlighting below.
local function jump_document_reference(direction)
    local bufnr = vim.api.nvim_get_current_buf()

    for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        if client:supports_method("textDocument/documentHighlight") then
            local params = vim.lsp.util.make_position_params(
                0,
                client.offset_encoding
            )

            local response = client:request_sync(
                "textDocument/documentHighlight",
                params,
                1000,
                bufnr
            )

            local references = response and response.result or nil
            if not references or #references == 0 then
                return
            end

            table.sort(references, function(a, b)
                local ap = a.range.start
                local bp = b.range.start

                if ap.line == bp.line then
                    return ap.character < bp.character
                end

                return ap.line < bp.line
            end)

            local cursor = params.position

            local function before(a, b)
                return a.line < b.line
                    or (
                        a.line == b.line
                        and a.character < b.character
                    )
            end

            local function inside(range, pos)
                return not before(pos, range.start)
                    and before(pos, range["end"])
            end

            local target = nil

            if direction > 0 then
                for index, reference in ipairs(references) do
                    if inside(reference.range, cursor) then
                        local next_index = index + 1
                        if next_index > #references then
                            next_index = 1
                        end

                        target = references[next_index]
                        break
                    end

                    if before(cursor, reference.range.start) then
                        target = reference
                        break
                    end
                end

                target = target or references[1]
            else
                for index = #references, 1, -1 do
                    local reference = references[index]

                    if inside(reference.range, cursor) then
                        local prev_index = index - 1
                        if prev_index < 1 then
                            prev_index = #references
                        end

                        target = references[prev_index]
                        break
                    end

                    if before(reference.range.start, cursor) then
                        target = reference
                        break
                    end
                end

                target = target or references[#references]
            end

            vim.lsp.util.show_document(
                {
                    uri = params.textDocument.uri,
                    range = target.range,
                },
                client.offset_encoding,
                {
                    focus = true,
                    reuse_win = true,
                }
            )

            return
        end
    end
end

-- Reference navigation in the current file.
-- ]r = next semantic reference, [r = previous semantic reference.
map("n", "]r", function()
    jump_document_reference(1)
end, {
    desc = "Next LSP reference",
})

map("n", "[r", function()
    jump_document_reference(-1)
end, {
    desc = "Previous LSP reference",
})

-- The completion menu never opens on zero typed characters. The re-trigger
-- module takes the `.` trigger away from the native autotrigger and opens
-- the menu itself: members from the first character after the dot
-- (`fmt.P`, not `fmt.`), bare identifiers (locals, types, functions,
-- keywords, unimported packages) from the second, one character in argument
-- and field positions (`Task{I`), import paths inside `import` strings. It
-- also reopens the menu after a typo or Backspace (`m.Sav` -> Backspace ->
-- `m.Sa`). Strings and comments stay quiet; Ctrl-Space still works at any
-- point, including on a bare `fmt.`.
--
-- Member access completes right away; bare identifiers wait for a pause in
-- typing (keyword_debounce_ms), so the menu does not flicker while you type
-- in rhythm and appears as soon as you slow down. 3000 turns it into a
-- "hint when I stop to think" mode.
local completion_retrigger = require("completion_retrigger")

completion_retrigger.setup({
    debounce_ms = 60,
    keyword_debounce_ms = 400,
    member_min_length = 1,
    keyword_min_length = 2,
})

vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(event)
        local client = assert(
            vim.lsp.get_client_by_id(event.data.client_id)
        )

        if client:supports_method("textDocument/completion") then
            -- attach() first: it removes the server trigger characters that
            -- enable() would otherwise hand to the native autotrigger.
            completion_retrigger.attach(event.buf, client)
            vim.lsp.completion.enable(
                true,
                client.id,
                event.buf,
                { autotrigger = true }
            )
        end

        if big_file.is_marked(event.buf) then
            pcall(vim.lsp.semantic_tokens.enable, false, {
                bufnr = event.buf,
                client_id = client.id,
            })
            return
        end

        -- Highlight all references to the symbol under the cursor after
        -- a short pause. Clear them immediately when moving or editing.
        if client:supports_method("textDocument/documentHighlight") then
            vim.api.nvim_clear_autocmds({
                group = lsp_document_highlight,
                buffer = event.buf,
            })

            vim.api.nvim_create_autocmd("CursorHold", {
                group = lsp_document_highlight,
                buffer = event.buf,
                callback = vim.lsp.buf.document_highlight,
            })

            vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter" }, {
                group = lsp_document_highlight,
                buffer = event.buf,
                callback = vim.lsp.buf.clear_references,
            })
        end
    end,
})

map("i", "<C-Space>", function()
    vim.lsp.completion.get()
end, {
    desc = "Completion",
})

-- Inlay hints per buffer, off by default.
map("n", "<leader>ih", function()
    local enabled = vim.lsp.inlay_hint.is_enabled({ bufnr = 0 })
    vim.lsp.inlay_hint.enable(not enabled, { bufnr = 0 })
end, {
    desc = "Toggle inlay hints",
})


-- ============================================================
-- Quickfix workflow
-- ============================================================

-- Project-wide problem lists. Native ]q / [q walk the quickfix list and
-- ]d / [d walk diagnostics in the buffer.
map("n", "<leader>q", function()
    vim.diagnostic.setqflist({ open = true })
end, {
    desc = "Workspace diagnostics to quickfix",
})

map("n", "<leader>sd", "<cmd>FzfLua diagnostics_workspace<CR>", {
    desc = "Search workspace diagnostics",
})

map("n", "<leader>sq", "<cmd>FzfLua quickfix<CR>", {
    desc = "Search quickfix list",
})

-- Build/vet into quickfix and tests into the tmux `tests` window of the
-- current `dev` session (quickfix outside tmux).
local go_tasks = require("go_tasks")

go_tasks.setup({
    build_command = "go build ./... && go vet ./...",
    test_flags = { "-count=1" },
})


-- ============================================================
-- Go
-- ============================================================

vim.api.nvim_create_autocmd("FileType", {
    pattern = "go",
    callback = function(event)
        -- Go convention.
        vim.bo[event.buf].expandtab = false
        vim.bo[event.buf].shiftwidth = 4
        vim.bo[event.buf].tabstop = 4

        map("n", "<leader>gf", function()
            vim.lsp.buf.format({
                async = false,
                name = "gopls",
            })
        end, {
            buffer = event.buf,
            desc = "Go format",
        })

        map("n", "<leader>gi", function()
            vim.lsp.buf.code_action({
                context = {
                    only = { "source.organizeImports" },
                },
                apply = true,
            })
        end, {
            buffer = event.buf,
            desc = "Go organize imports",
        })

        map("n", "<leader>gb", go_tasks.build, {
            buffer = event.buf,
            desc = "Go build + vet to quickfix",
        })

        map("n", "<leader>gt", function()
            go_tasks.test("nearest")
        end, {
            buffer = event.buf,
            desc = "Go test nearest function or package",
        })

        map("n", "<leader>gT", function()
            go_tasks.test("all")
        end, {
            buffer = event.buf,
            desc = "Go test whole module",
        })
    end,
})
