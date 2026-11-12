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

-- One rounded border for every floating window: documentation, peeks,
-- the completion popup, diagnostics.
opt.winborder = "rounded"

-- The file is named in the window bar (breadcrumbs) and the tab line
-- (bufferline); the status line keeps the flags and the position only.
opt.statusline = " %h%w%m%r%=%-14.(%l,%c%V%) %P "

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

-- Semantic rename through gopls across the workspace: methods and types in
-- every package, a package (on its `package` clause) with its imports and
-- directory; a local variable only in its own scope. Every touched file is
-- written and the changed places go to the quickfix list (lua/go_rename.lua).
local function rename_symbol()
    require("go_rename").rename()
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

-- Keep diagnostics quiet while coding: signs and underlines everywhere, the
-- message only at the end of the line the cursor is on (no lines shift);
-- the full text with <leader>d.
vim.diagnostic.config({
    virtual_text = {
        current_line = true,
        source = "if_many",
        spacing = 2,
        prefix = "●",
    },
    virtual_lines = false,
    -- Nerd Font glyphs (nf-fa: times-circle, warning, info-circle,
    -- lightbulb). Written as \u{…} escapes: characters of the Private Use
    -- Area are easily lost from a source file on the way through editors
    -- and tools, and an empty text here means no sign at all.
    signs = {
        text = {
            [vim.diagnostic.severity.ERROR] = "\u{f057}",
            [vim.diagnostic.severity.WARN] = "\u{f071}",
            [vim.diagnostic.severity.INFO] = "\u{f05a}",
            [vim.diagnostic.severity.HINT] = "\u{f0eb}",
        },
    },
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
    -- Markdown drawn for reading: headings, code blocks, tables, lists.
    "https://github.com/MeanderingProgrammer/render-markdown.nvim",
    -- The engine that draws a ```mermaid block as a box diagram: a bundled
    -- TypeScript script run by node, no browser and no network. The placing
    -- in the buffer is lua/markdown_diagrams.lua.
    "https://github.com/kais-radwan/ascii-mermaid",
    -- File icons by name and extension (Nerd Font glyphs): the file tree,
    -- Space f and the other fzf-lua pickers draw them.
    "https://github.com/nvim-tree/nvim-web-devicons",
    -- File tree in a panel on the left (Space e); plenary and nui are its
    -- libraries.
    "https://github.com/nvim-lua/plenary.nvim",
    "https://github.com/MunifTanjim/nui.nvim",
    "https://github.com/nvim-neo-tree/neo-tree.nvim",
    -- The keys that continue a prefix (Space, g, ], …) shown after a pause.
    "https://github.com/folke/which-key.nvim",
    -- s + two characters + a label jumps anywhere on the screen.
    "https://github.com/folke/flash.nvim",
    -- ys / cs / ds: add, change and delete the quotes or brackets around.
    "https://github.com/kylechui/nvim-surround",
    -- Formatters by file type, run on save (gofumpt for Go).
    "https://github.com/stevearc/conform.nvim",
    -- Open buffers as tabs at the top, with icons and diagnostics.
    "https://github.com/akinsho/bufferline.nvim",
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
    -- The compiled theme is cached by this table only, so a newly added
    -- plugin's colours appear after its integration is named here.
    integrations = {
        render_markdown = true,
        neotree = true,
        which_key = true,
        nvim_web_devicons = true,
    },
})

vim.cmd.colorscheme("catppuccin-mocha")

-- File icons: a glyph by name or extension, a plain one for the rest.
require("nvim-web-devicons").setup({
    default = true,
})


-- ============================================================
-- File panel (neo-tree)
-- ============================================================

-- Space e opens the panel on the left on the current file and closes it;
-- it follows the open file. The keys repeat the Space f tree: ← → close
-- and open the folder, Enter opens the file; . sets the root to the folder
-- under the cursor and Backspace goes back up. Dotfiles are shown,
-- ignored files are hidden (H toggles).
require("neo-tree").setup({
    close_if_last_window = true,
    popup_border_style = "rounded",
    enable_git_status = true,
    enable_diagnostics = false,
    sort_case_insensitive = true,
    default_component_configs = {
        indent = {
            with_expanders = true,
            expander_collapsed = "▸",
            expander_expanded = "▾",
        },
        git_status = {
            symbols = {
                added = "A",
                modified = "M",
                deleted = "D",
                renamed = "R",
                untracked = "?",
                ignored = "",
                unstaged = "",
                staged = "",
                conflict = "!",
            },
        },
    },
    window = {
        position = "left",
        width = 36,
        mappings = {
            -- Space stays the leader inside the panel too.
            ["<space>"] = "none",
            ["<Right>"] = "open",
            ["<Left>"] = "close_node",
            ["l"] = "open",
            ["h"] = "close_node",
            ["<CR>"] = "open",
            ["s"] = "open_vsplit",
            ["S"] = "open_split",
            ["."] = "set_root",
            ["<BS>"] = "navigate_up",
            ["H"] = "toggle_hidden",
            ["R"] = "refresh",
            ["a"] = "add",
            ["d"] = "delete",
            ["r"] = "rename",
            ["y"] = "copy_to_clipboard",
            ["x"] = "cut_to_clipboard",
            ["p"] = "paste_from_clipboard",
            ["q"] = "close_window",
            ["?"] = "show_help",
        },
    },
    filesystem = {
        follow_current_file = {
            enabled = true,
            leave_dirs_open = true,
        },
        use_libuv_file_watcher = true,
        filtered_items = {
            visible = false,
            hide_dotfiles = false,
            hide_gitignored = true,
            hide_by_name = { ".git", ".DS_Store" },
        },
        window = {
            mappings = {
                -- / filters the tree; Ctrl-h drops the filter (also Ctrl-x).
                ["<C-h>"] = "clear_filter",
            },
            fuzzy_finder_mappings = {
                -- In the filter box: Ctrl-h closes it and drops the filter.
                ["<C-h>"] = "close_clear_filter",
            },
        },
    },
})

map("n", "<leader>e", "<cmd>Neotree toggle reveal left<CR>", {
    desc = "File panel",
})


-- ============================================================
-- Tabs of open buffers (bufferline)
-- ============================================================

-- A file changed on disk by the agent (or git, or a generator) is read
-- again within a second when the buffer has no unsaved changes; the lines
-- that came changed are highlighted for a few seconds. A buffer with
-- unsaved changes is never touched: a warning and a mark
-- (vim.b.disk_conflict) instead of a question in the middle of typing
-- (lua/external_changes.lua).
require("external_changes").setup()

-- The open files as tabs at the top, with their icons, a dot when not
-- saved and the count of errors; the panel pushes them right. ]b / [b
-- go to the next and previous tab, Space x closes the buffer, Space X
-- the others.
require("bufferline").setup({
    options = {
        mode = "buffers",
        diagnostics = "nvim_lsp",
        diagnostics_indicator = function(count, level)
            return (level:match("error") and "\u{f057} " or "\u{f071} ") .. count
        end,
        show_buffer_close_icons = false,
        show_close_icon = false,
        always_show_bufferline = false,
        separator_style = "thin",
        offsets = {
            { filetype = "neo-tree", text = "", separator = true },
        },
    },
    highlights = require("catppuccin.special.bufferline").get_theme(),
})

-- Neovim starts in an empty [No Name] buffer. Opening a file in that
-- window reuses it, but a file opened in a split (peek, quickfix, Ctrl-v
-- in a picker) leaves it behind as a tab once its window is closed, so
-- an empty unnamed buffer that no window shows any more is dropped.
vim.api.nvim_create_autocmd({ "BufEnter", "WinClosed" }, {
    group = vim.api.nvim_create_augroup("drop_empty_buffer", { clear = true }),
    callback = function()
        vim.schedule(function()
            local dropped = false
            for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_is_valid(buffer)
                    and vim.bo[buffer].buflisted
                    and vim.bo[buffer].buftype == ""
                    and not vim.bo[buffer].modified
                    and vim.api.nvim_buf_get_name(buffer) == ""
                    and vim.fn.bufwinid(buffer) == -1
                    and vim.api.nvim_buf_line_count(buffer) == 1
                    and vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1] == ""
                then
                    vim.api.nvim_buf_delete(buffer, {})
                    dropped = true
                end
            end
            if dropped then
                vim.cmd.redrawtabline()
            end
        end)
    end,
})

map("n", "]b", "<cmd>BufferLineCycleNext<CR>", { desc = "Next tab" })
map("n", "[b", "<cmd>BufferLineCyclePrev<CR>", { desc = "Previous tab" })
map("n", "<leader>x", function()
    local buffer = vim.api.nvim_get_current_buf()
    vim.cmd.bprevious()
    pcall(vim.api.nvim_buf_delete, buffer, { force = false })
end, { desc = "Close the buffer" })
map("n", "<leader>X", "<cmd>BufferLineCloseOthers<CR>", { desc = "Close the other buffers" })


-- ============================================================
-- Keys after a prefix (which-key)
-- ============================================================

local which_key = require("which-key")

which_key.setup({
    preset = "helix",
    delay = 400,
})

-- ============================================================
-- Jumps (flash) and surroundings (nvim-surround)
-- ============================================================

-- s, then two characters of the target, then the label shown next to it:
-- the cursor lands there (also as a motion: ds + target deletes up to
-- it). S in normal mode picks a Tree-sitter node around the cursor by its
-- label; in Visual S stays nvim-surround's. f / t show labels when the
-- character repeats. r in an operator (yr …) acts on a far place without
-- moving.
local flash = require("flash")

flash.setup({
    modes = {
        search = { enabled = false },
        char = { jump_labels = true },
    },
})

map({ "n", "x", "o" }, "s", flash.jump, { desc = "Jump (flash)" })
map("n", "S", flash.treesitter, { desc = "Select a Tree-sitter node (flash)" })
map("o", "r", flash.remote, { desc = "Remote operator (flash)" })
map({ "o", "x" }, "R", flash.treesitter_search, { desc = "Tree-sitter search (flash)" })

-- ysiw" wraps the word in quotes, cs"' changes them, ds" deletes them,
-- yss) the line; in Visual S" wraps the selection.
require("nvim-surround").setup({})


-- ============================================================
-- Formatting on save (conform)
-- ============================================================

-- Go is written by gofumpt on every save (it is gofmt with stricter
-- rules, the same gopls uses for Space gf); :FormatOnSave turns the
-- save step off and on for this session, Space gf formats by hand. Other
-- file types are left as they are.
local conform = require("conform")

conform.setup({
    formatters_by_ft = {
        go = { "gofumpt" },
    },
    default_format_opts = {
        lsp_format = "fallback",
    },
    format_on_save = function(buffer)
        if vim.g.format_on_save == false or vim.bo[buffer].filetype ~= "go" then
            return nil
        end
        return { timeout_ms = 2000 }
    end,
})

vim.api.nvim_create_user_command("FormatOnSave", function()
    vim.g.format_on_save = vim.g.format_on_save == false
    vim.notify("Format on save: " .. (vim.g.format_on_save == false and "off" or "on"))
end, { desc = "Toggle formatting on save" })

which_key.add({
    { "<leader>c", group = "Code / change tree" },
    { "<leader>g", group = "Go" },
    { "<leader>h", group = "Git hunks" },
    { "<leader>r", group = "Rename" },
    { "<leader>s", group = "Search" },
    { "<leader>t", group = "Debug" },
})


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

-- Folds follow the syntax tree: zM leaves only the declarations (an outline
-- of the file), zR opens everything again; files open unfolded. Big files
-- keep manual folds, like they keep regex-free highlighting.
opt.foldtext = ""
opt.fillchars:append({ fold = " " })

-- SQL and .proto files too; SQL inside Go strings comes from
-- after/queries/go/injections.scm.
vim.api.nvim_create_autocmd("FileType", {
    pattern = { "go", "gomod", "gosum", "gowork", "sql", "proto" },
    callback = function(event)
        if not big_file.is_marked(event.buf) then
            vim.treesitter.start(event.buf)
            vim.opt_local.foldmethod = "expr"
            vim.opt_local.foldexpr = "v:lua.vim.treesitter.foldexpr()"
            vim.opt_local.foldlevel = 99
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
    -- @class.outer in Go is a struct or an interface declaration.
    ["]s"] = { "goto_next_start", "@class.outer" },
    ["[s"] = { "goto_previous_start", "@class.outer" },
}) do
    map({ "n", "x", "o" }, lhs, function()
        ts_move[spec[1]](spec[2], "textobjects")
    end, {
        desc = spec[1] .. " " .. spec[2],
    })
end

-- Jumps between the Go keywords: ] next, [ previous, with a count, as
-- motions too (d]e, v]m). The nodes are in after/queries/go/moves.scm.
for key, spec in pairs({
    m = { "method", "method" },
    e = { "err", "if err != nil" },
    R = { "return", "return" },
    g = { "go", "go (goroutine)" },
    G = { "defer", "defer" },
    l = { "loop", "for" },
    w = { "switch", "switch / select" },
    k = { "case", "case" },
    i = { "interface", "interface" },
    v = { "var", "var / const of the file" },
    T = { "test", "func Test…" },
}) do
    local capture = "@" .. spec[1] .. ".outer"
    map({ "n", "x", "o" }, "]" .. key, function()
        ts_move.goto_next_start(capture, "moves")
    end, { desc = "Next " .. spec[2] })
    map({ "n", "x", "o" }, "[" .. key, function()
        ts_move.goto_previous_start(capture, "moves")
    end, { desc = "Previous " .. spec[2] })
end

-- Over the syntax tree (lua/code_nav.lua): Alt-j / Alt-k the next and
-- previous node of the same level (statement to statement), Alt-h the
-- parent, Alt-l into the first child, [S / ]S the start and end of the
-- declaration around the cursor.
local code_nav = require("code_nav")

map({ "n", "x", "o" }, "<M-j>", function() code_nav.sibling(1) end, { desc = "Next node of the level" })
map({ "n", "x", "o" }, "<M-k>", function() code_nav.sibling(-1) end, { desc = "Previous node of the level" })
map({ "n", "x", "o" }, "<M-h>", code_nav.parent, { desc = "Parent node" })
map({ "n", "x", "o" }, "<M-l>", code_nav.child, { desc = "First child node" })
map({ "n", "x", "o" }, "[S", function() code_nav.declaration(false) end, { desc = "Start of the declaration around" })
map({ "n", "x", "o" }, "]S", function() code_nav.declaration(true) end, { desc = "End of the declaration around" })

-- In a .proto the same jumps over the contract, by its syntax tree
-- (after/queries/proto/moves.scm): ]p / [p an rpc, ]M / [M a message,
-- ]s / [s a message or an enum.
vim.api.nvim_create_autocmd("FileType", {
    pattern = "proto",
    group = vim.api.nvim_create_augroup("proto_moves", { clear = true }),
    callback = function(event)
        for key, spec in pairs({
            p = { "@rpc.outer", "rpc" },
            M = { "@message.outer", "message" },
            s = { "@type.outer", "message or enum" },
        }) do
            vim.keymap.set({ "n", "x", "o" }, "]" .. key, function()
                ts_move.goto_next_start(spec[1], "moves")
            end, { buffer = event.buf, desc = "Next " .. spec[2] })
            vim.keymap.set({ "n", "x", "o" }, "[" .. key, function()
                ts_move.goto_previous_start(spec[1], "moves")
            end, { buffer = event.buf, desc = "Previous " .. spec[2] })
        end
    end,
})

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
-- Navigation
-- ============================================================

-- gp / gP / gI: the definition / type definition / implementation of the
-- symbol under the cursor in a float next to it (whole declaration with its
-- doc comment). The key again focuses the float; inside, the same keys go
-- one level deeper on the name under the cursor and Backspace comes back;
-- Enter opens the line, q closes. gI on a call through an interface skips
-- mocks and test files when one real implementation remains, several open
-- a picker. Replaces the rarely used native gp / gP (put and move) and gI
-- (insert at column 1).
local peek = require("peek")

map("n", "gp", peek.definition, {
    desc = "Peek definition",
})

map("n", "gP", peek.type_definition, {
    desc = "Peek type definition",
})

map("n", "gI", peek.implementation, {
    desc = "Peek implementation",
})

-- grp between the .proto contracts and Go: on an rpc its handler (without
-- the generated Unimplemented… and mocks), on a message / field / enum the
-- generated code; in Go, from a handler, a message, a getter or a client
-- call back to the .proto (lua/go_proto.lua).
map("n", "grp", function()
    require("go_proto").jump(project_root)
end, {
    desc = "Between the .proto and Go",
})

-- grq: a grpcurl request for the rpc under the cursor (in a .proto, or in
-- Go on a handler or a client call), typed into the `rpc` window of the
-- tmux session with a JSON template of the request message
-- (lua/grpc_request.lua).
map("n", "grq", function()
    require("grpc_request").request(project_root)
end, {
    desc = "grpcurl request for the rpc under the cursor",
})

-- K on a variable, parameter or field of a struct type: the hover with that
-- struct below it and every project type its fields name, transitively, so
-- the fields are at hand without going to the definition (lua/go_hover.lua).
-- Replaces the native K of gopls buffers; K again focuses the float.
local go_hover = require("go_hover")

vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(event)
        local client = vim.lsp.get_client_by_id(event.data.client_id)
        if client and client.name == "gopls" then
            map("n", "K", go_hover.hover, {
                buffer = event.buf,
                desc = "Hover with the fields of struct types",
            })
        end
    end,
})

-- Pinned files of the task (lua/pins.lua): Space p pins the current file
-- or unpins it, Alt-1…9 open them, Space P lists them (Ctrl-x unpins,
-- Alt-↑ / Alt-↓ reorder). They are kept per project across restarts and
-- head the Space f tree with the recent files.
local pins = require("pins")

pins.setup()

map("n", "<leader>p", function()
    pins.toggle(project_root)
end, {
    desc = "Pin / unpin the current file",
})

map("n", "<leader>P", function()
    pins.pick(project_root)
end, {
    desc = "Pinned files",
})

for number = 1, pins.max do
    map("n", "<M-" .. number .. ">", function()
        pins.jump(project_root, number)
    end, {
        desc = "Pinned file " .. number,
    })
end

-- Window bar: ◆2 for a pinned file, file › type › method › closure around
-- the cursor.
require("breadcrumbs").setup({
    pin = function(path)
        return pins.number(project_root, path)
    end,
})

-- Space ga: file ↔ its test; a missing test file starts with the package
-- clause and the testing import.
map("n", "<leader>ga", function()
    require("go_alt").toggle()
end, {
    desc = "Go file / test file",
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

-- Space cp: the .proto contracts changed against main, breaking first
-- (lua/proto_diff.lua).
map("n", "<leader>cp", function()
    require("proto_diff").show(project_root)
end, {
    desc = "Changed .proto contracts against main",
})

-- Space ce: where the errors of the function under the cursor go: the
-- callers labelled wraps / passes / gRPC status (lua/err_flow.lua).
map("n", "<leader>ce", function()
    require("err_flow").show()
end, {
    desc = "Error flow of the function",
})

-- grP: the rpc under the cursor in every repository: handlers,
-- contracts, calls (lua/rpc_owner.lua).
map("n", "grP", function()
    require("rpc_owner").show(project_root)
end, {
    desc = "Rpc in every repository",
})

map("n", "<leader>cT", change_tree.toggle_auto, {
    desc = "Change tree: toggle build after save",
})


-- ============================================================
-- FZF
-- ============================================================

local fzf = require("fzf-lua")

-- The symbol icons are fzf-lua's Nerd Font glyphs (the JetBrainsMono NF of
-- the iTerm2 profile); the kind name stays next to the glyph.
-- Every picker has a normal mode as Space f (lua/picker_mode.lua): Esc
-- leaves typing, j / k move, l or Enter opens, q or Esc closes, i types
-- again. The lists (Space ss, Space b, grr, Space p, Space ,) start in
-- it; the live searches start typing. fzf-lua's "hide" of Esc is off so
-- Esc reaches fzf.
local picker_mode = require("picker_mode")

fzf.setup({
    defaults = { no_hide = true },
    keymap = { fzf = vim.tbl_extend("force", { true }, picker_mode.binds()) },
    -- Every picker takes the whole screen (F2 shrinks it to 90% and back);
    -- the short lists without a preview (categories, kinds) stay small.
    -- Preview to the right of the list while the picker is wider than 80
    -- columns; only in a very narrow window does it move below the list.
    winopts = {
        fullscreen = true,
        width = 0.9,
        preview = {
            flip_columns = 80,
        },
    },
    lsp = {
        symbols = {
            -- 1 = "<icon> <kind>": the word next to the glyph.
            symbol_style = 1,
        },
    },
})

-- Files, grep and workspace symbols by category: all, rpc (contracts and
-- generated code), tests, internal and each of its folders. Every picker
-- opens on `all`; Alt-c inside lists the categories and keeps the typed
-- query (lua/categories.lua).
local categories = require("categories")

-- Always execute a fresh file scan rooted at the directory where `nvim .`
-- started. This avoids stale/resumed picker state and cwd drift. The files
-- open full screen as a tree of folders (← → to close / open, typing
-- searches every file, lua/file_tree.lua).
map("n", "<leader>f", function()
    categories.files(project_root)
end, {
    desc = "Find project files by category",
})

-- Same search, but include files ignored by .gitignore.
map("n", "<leader>F", function()
    categories.files(project_root, { no_ignore = true })
end, {
    desc = "Find all project files by category",
})

-- Space ?: the same search over every repository under ~/workspace and
-- ~/Projects ($DEV_PROJECT_ROOTS, the folders of the tmux projects popup).
map("n", "<leader>?", function()
    require("repos_grep").live_grep()
end, {
    desc = "Grep every repository",
})

-- Space j: the JSON of the log line under the cursor, pretty, in a float;
-- Enter on `path.go:N` inside opens the caller (lua/json_log.lua).
map("n", "<leader>j", function()
    require("json_log").show(project_root)
end, {
    desc = "JSON of the log line",
})

map("n", "<leader>/", function()
    categories.live_grep(project_root)
end, {
    desc = "Grep project by category",
})

-- The word under the cursor (whole word) or the selection, across the project.
map("n", "<leader>*", function()
    categories.grep(project_root, fzf.utils.rg_escape_cword(vim.fn.expand("<cword>")), true)
end, {
    desc = "Grep word under cursor by category",
})

map("x", "<leader>*", function()
    categories.grep(project_root, fzf.utils.get_visual_selection(), false)
end, {
    desc = "Grep selection by category",
})

-- The same domain in other layers: files of the other folders named like
-- the folder of the current file (internal/service/order/, api/order/v1/ …)
-- and files with the same name elsewhere (lua/related.lua).
map("n", "<leader>,", function()
    require("related").pick(project_root)
end, {
    desc = "Related files: the same domain in other layers",
})

-- Files of the current package: the directory of the current file.
map("n", "<leader>.", function()
    fzf.files({
        cwd = vim.fn.expand("%:p:h"),
        resume = false,
        hidden = true,
    })
end, {
    desc = "Files of the current package",
})

-- TODO comments: all of them in the project / the next and previous in the
-- file (replaces the tag-match ]t / [t, unused with LSP navigation).
local todo = require("todo")

map("n", "<leader>st", function()
    todo.pick(project_root)
end, {
    desc = "TODO comments of the project",
})

map("n", "]t", function()
    todo.jump(true)
end, {
    desc = "Next TODO comment",
})

map("n", "[t", function()
    todo.jump(false)
end, {
    desc = "Previous TODO comment",
})

-- Every SQL query of the project (Go strings, query builders, .sql files)
-- grouped by table; Tab regroups by statement kind or by file.
map("n", "<leader>sQ", function()
    require("sql_nav").open(project_root)
end, {
    desc = "SQL queries of the project",
})

map("n", "<leader>b", function()
    fzf.buffers({ prompt = picker_mode.prompt("") })
end, {
    desc = "Buffers",
})

map("n", "<leader>ss", function()
    fzf.lsp_document_symbols({ prompt = picker_mode.prompt("") })
end, {
    desc = "Document symbols",
})

-- gopls answers at most 100 symbols; for internal the query is narrowed on
-- the server so generated code does not take them all.
map("n", "<leader>sS", function()
    categories.symbols(project_root)
end, {
    desc = "Live workspace symbols by category",
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
-- Markdown
-- ============================================================

-- README, docs and LSP hover drawn for reading, mermaid diagrams drawn as
-- box art over their blocks (lua/markdown_view.lua); Space m shows the raw
-- text of the buffer and back.
local markdown_view = require("markdown_view")

markdown_view.setup()

vim.api.nvim_create_autocmd("FileType", {
    pattern = "markdown",
    callback = function(event)
        map("n", "<leader>m", markdown_view.toggle, {
            buffer = event.buf,
            desc = "Markdown drawn / raw",
        })
    end,
})


-- ============================================================
-- Go
-- ============================================================

local go_cover = require("go_cover")
go_cover.setup()

-- :GoImpl io.Reader — the type under the cursor implements an interface
-- named with its package.
vim.api.nvim_create_user_command("GoImpl", function(opts)
    require("go_impl").by_name(opts.args)
end, { nargs = 1, desc = "Implement the named interface for the type under the cursor" })

vim.api.nvim_create_autocmd("FileType", {
    pattern = "go",
    callback = function(event)
        -- Go convention.
        vim.bo[event.buf].expandtab = false
        vim.bo[event.buf].shiftwidth = 4
        vim.bo[event.buf].tabstop = 4

        map("n", "<leader>gf", function()
            conform.format({ async = false })
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

        -- Space gc: the test coverage of the package as bars in the sign
        -- column, again to clear; Space gC clears every file
        -- (lua/go_cover.lua).
        map("n", "<leader>gc", go_cover.toggle, {
            buffer = event.buf,
            desc = "Go test coverage of the package",
        })

        map("n", "<leader>gC", go_cover.clear, {
            buffer = event.buf,
            desc = "Clear coverage",
        })

        -- Space gm on a type: pick an interface of the project, gopls
        -- declares its missing methods (lua/go_impl.lua).
        map("n", "<leader>gm", function()
            require("go_impl").pick(project_root)
        end, {
            buffer = event.buf,
            desc = "Go implement an interface",
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
