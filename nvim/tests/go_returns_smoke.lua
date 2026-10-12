local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

-- `--clean` drops user directories from 'runtimepath'; the pinned Go parser
-- lives under the data directory that bootstrap.lua provisions.
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/site")

local go_returns = require("go_returns")

local source = {
    "package sample",
    "",
    "import (",
    '\t"context"',
    '\t"errors"',
    '\t"fmt"',
    ")",
    "",
    'var ErrLimit = errors.New("limit")',
    "",
    "type Task struct {",
    "\tID    string",
    "\tState int",
    "\tItems []int",
    "}",
    "",
    "type Service struct{}",
    "",
    "func (s *Service) Save(ctx context.Context, task Task) (Task, error) {",
    '\tif task.ID == "" {',
    '\t\treturn Task{}, errors.New("empty id")',
    "\t}",
    "\tif err := ctx.Err(); err != nil {",
    '\t\treturn Task{}, fmt.Errorf("ctx: %w", err)',
    "\t} else if task.State < 0 {",
    "\t\treturn Task{}, ErrLimit",
    "\t} else {",
    "\t\ttask.State = 1",
    "\t}",
    "\tswitch task.State {",
    "\tcase 1, 2:",
    "\t\tif len(task.Items) > 10 {",
    "\t\t\treturn Task{}, ErrLimit",
    "\t\t}",
    "\tcase 3:",
    "\t\treturn s.store(task)",
    "\tdefault:",
    '\t\tpanic("unreachable state")',
    "\t}",
    "\tfor i, item := range task.Items {",
    "\t\tif item < 0 {",
    '\t\t\treturn Task{}, fmt.Errorf("item %d", i)',
    "\t\t}",
    "\t}",
    "\tfor {",
    "\t\tselect {",
    "\t\tcase <-ctx.Done():",
    "\t\t\treturn Task{}, ctx.Err()",
    "\t\tdefault:",
    "\t\t}",
    "\t\tbreak",
    "\t}",
    "\tdefer func() {",
    "\t\tif r := recover(); r != nil {",
    "\t\t\treturn",
    "\t\t}",
    "\t}()",
    "\tgo func() { return }()",
    "\tswitch v := any(task).(type) {",
    "\tcase Task:",
    "\t\t_ = v",
    "\t}",
    "retry:",
    "\tif task.State > 5 {",
    "\t\tgoto retry",
    "\t}",
    "\treturn task, nil",
    "}",
    "",
    "func (s *Service) store(task Task) (Task, error) { return task, nil }",
    "",
    "func noop() {",
    '\tfmt.Println("x")',
    "}",
    "",
    "func named() (n int, err error) {",
    "\tif n > 0 {",
    "\t\treturn",
    "\t}",
    "\treturn 1, nil",
    "}",
}

vim.cmd("enew!")
vim.api.nvim_buf_set_lines(0, 0, -1, false, source)
vim.bo.filetype = "go"
assert(vim.treesitter.get_parser(0, "go"):parse(), "go parser unavailable")

local function graph(row, col, opts)
    local fn = assert(go_returns.enclosing_callable(0, row - 1, col), "no enclosing callable at " .. row)
    local root = go_returns.build(0, fn, opts)
    return go_returns.render(root, opts)
end

local function expect_lines(label, actual, expected)
    assert(vim.deep_equal(actual, expected), string.format(
        "%s: expected\n%s\ngot\n%s",
        label,
        table.concat(expected, "\n"),
        table.concat(actual, "\n")
    ))
end

-- Method with every control-flow form. Branches without exits are pruned,
-- nested func literals never contribute exits, defers stay visible.
local lines, meta, summary = graph(22, 3)
expect_lines("method return graph", lines, {
    "func (s *Service) Save(ctx context.Context, task Task) (Task, error)",
    '├─ if task.ID == ""                                                          :20',
    '│  └─ return Task{}, errors.New("empty id")                           [err]  :21',
    "├─ if err := ctx.Err(); err != nil                                           :23",
    '│  └─ return Task{}, fmt.Errorf("ctx: %w", err)                       [err]  :24',
    "├─ else if task.State < 0                                                    :25",
    "│  └─ return Task{}, ErrLimit                                         [err]  :26",
    "├─ switch task.State                                                         :30",
    "│  ├─ case 1, 2                                                              :31",
    "│  │  └─ if len(task.Items) > 10                                             :32",
    "│  │     └─ return Task{}, ErrLimit                                   [err]  :33",
    "│  ├─ case 3                                                                 :35",
    "│  │  └─ return s.store(task)                                         [pass] :36",
    "│  └─ default                                                                :37",
    '│     └─ panic("unreachable state")                                          :38',
    "├─ for i, item := range task.Items                                           :40",
    "│  └─ if item < 0                                                            :41",
    '│     └─ return Task{}, fmt.Errorf("item %d", i)                      [err]  :42',
    "├─ for                                                                       :45",
    "│  └─ select                                                                 :46",
    "│     └─ case <-ctx.Done()                                                   :47",
    "│        └─ return Task{}, ctx.Err()                                  [err]  :48",
    "├─ defer func() { … }()  (on every exit)                                     :53",
    "├─ retry: if task.State > 5                                                  :64",
    "│  └─ goto retry                                                             :65",
    "└─ return task, nil                                                   [ok]   :67",
})
assert(summary == "10 exits: 8 return, 1 panic, 1 goto", summary)
assert(meta[1].line == 19 and meta[3].line == 21 and meta[#meta].line == 67, "jump targets")
assert(meta[3].kind == "return" and meta[15].kind == "panic", "exit kinds")

-- Highlights carry the exit keyword and the tag column.
local function has_highlight(entry, group)
    for _, hl in ipairs(entry.highlights) do
        if hl[1] == group then
            return true
        end
    end
    return false
end
assert(has_highlight(meta[3], "DiagnosticError"), "err tag highlight")
assert(has_highlight(meta[#meta], "DiagnosticOk"), "ok tag highlight")
assert(has_highlight(meta[15], "DiagnosticWarn"), "panic highlight")
assert(has_highlight(meta[3], "Keyword"), "return keyword highlight")

-- Inside a func literal the graph belongs to the literal, and a callable
-- without results reports the implicit fall-through end.
local literal_lines = graph(55, 4)
expect_lines("func literal graph", literal_lines, {
    "func()  (literal)",
    "├─ if r := recover(); r != nil    :54",
    "│  └─ return                      :55",
    "└─ end of func (implicit return)  :57",
})

local void_lines, _, void_summary = graph(73, 2)
expect_lines("void function graph", void_lines, {
    "func noop()",
    "└─ end of func (implicit return)  :74",
})
assert(void_summary == "1 exit: 1 end", void_summary)

-- Named results: a bare return is tagged, a full return is classified.
local named_lines = graph(78, 3)
expect_lines("named results graph", named_lines, {
    "func named() (n int, err error)",
    "├─ if n > 0                              :77",
    "│  └─ return                     [named] :78",
    "└─ return 1, nil                 [ok]    :80",
})

-- Error-path filter drops [ok] returns and the implicit end, keeps panics,
-- gotos, pass-through returns and defers, and prunes emptied branches.
local method_fn = assert(go_returns.enclosing_callable(0, 21, 3))
local filtered = go_returns.filter_errors(go_returns.build(0, method_fn))
local filtered_lines, _, filtered_summary = go_returns.render(filtered)
assert(#filtered_lines == #lines - 1, "one [ok] return must be dropped: " .. #filtered_lines)
assert(not table.concat(filtered_lines, "\n"):find("[ok]", 1, true), "no [ok] leaf after the filter")
assert(filtered_lines[#filtered_lines]:find("goto retry", 1, true), "goto stays the last exit: " .. filtered_lines[#filtered_lines])
assert(filtered_lines[#filtered_lines - 1]:find("└─ retry: if", 1, true), "last branch connector is redrawn")
assert(filtered_summary == "9 exits: 7 return, 1 panic, 1 goto", filtered_summary)

local void_fn = assert(go_returns.enclosing_callable(0, 72, 2))
local void_filtered = go_returns.render(go_returns.filter_errors(go_returns.build(0, void_fn)))
assert(#void_filtered == 1, "void function has no error paths")

-- Pure ASCII connectors for terminals without box-drawing glyphs.
local ascii_lines = graph(73, 2, { pure_ascii = true })
expect_lines("ascii connectors", ascii_lines, {
    "func noop()",
    "`- end of func (implicit return)  :74",
})

-- Cursor outside any callable.
assert(go_returns.enclosing_callable(0, 10, 0) == nil, "top-level cursor must have no callable")

print("GO_RETURNS_SMOKE_OK")

-- Floating window: opens on the enclosing callable, Enter jumps to the
-- selected exit in the source window, q closes without moving.
local source_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(source_win, { 22, 3 })
go_returns.setup({})
assert(vim.fn.exists(":GoReturns") == 2, "GoReturns command missing")

local float, preview = go_returns.show()
assert(float, "return graph window did not open")
assert(vim.api.nvim_get_current_win() == float, "return graph window is not focused")
assert(vim.api.nvim_win_get_config(float).relative == "editor", "return graph must be a float")
assert(vim.bo[vim.api.nvim_win_get_buf(float)].filetype == "goreturns", "graph buffer filetype")

-- The preview on the right follows the selected node and never touches the
-- buffer list.
assert(preview and vim.api.nvim_win_is_valid(preview), "preview window must open next to the tree")
assert(vim.api.nvim_win_get_config(preview).col > vim.api.nvim_win_get_config(float).col, "preview must sit right of the tree")
assert(vim.api.nvim_win_get_cursor(preview)[1] == 19, "preview starts at the function signature")
vim.api.nvim_win_set_cursor(float, { 3, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(float) })
assert(vim.api.nvim_win_get_cursor(preview)[1] == 21, "preview must follow the selected return")
local preview_buf = vim.api.nvim_win_get_buf(preview)
assert(vim.bo[preview_buf].buftype == "nofile" and not vim.bo[preview_buf].buflisted, "preview is a scratch buffer")
assert(vim.api.nvim_buf_get_lines(preview_buf, 20, 21, false)[1] == source[21], "preview shows the source text")

vim.api.nvim_feedkeys(vim.keycode("<CR>"), "xt", false)
assert(not vim.api.nvim_win_is_valid(float), "Enter must close the graph")
assert(not vim.api.nvim_win_is_valid(preview), "Enter must close the preview too")
assert(vim.api.nvim_get_current_win() == source_win, "Enter must return to the source window")
assert(vim.api.nvim_win_get_cursor(source_win)[1] == 21, "Enter must jump to the selected return")

local reopened, reopened_preview = go_returns.show()
assert(reopened, "graph did not reopen")
vim.api.nvim_feedkeys("q", "xt", false)
assert(not vim.api.nvim_win_is_valid(reopened), "q must close the graph")
assert(not vim.api.nvim_win_is_valid(reopened_preview), "q must close the preview")

-- `e` inside the view switches to error paths and back, keeping the row.
local full_view = go_returns.show()
local full_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(full_view))
vim.api.nvim_win_set_cursor(full_view, { 5, 0 })
vim.api.nvim_feedkeys("e", "xt", false)
assert(not vim.api.nvim_win_is_valid(full_view), "e must replace the view")
local error_view = vim.api.nvim_get_current_win()
assert(vim.api.nvim_win_get_config(error_view).relative == "editor", "error view must be a float")
assert(vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(error_view)) == full_count - 1, "error view drops the [ok] leaf")
assert(vim.api.nvim_win_get_cursor(error_view)[1] == 5, "row is kept across the toggle")
vim.api.nvim_feedkeys("e", "xt", false)
local back_view = vim.api.nvim_get_current_win()
assert(vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(back_view)) == full_count, "e again restores all exits")
vim.api.nvim_feedkeys("q", "xt", false)
assert(vim.api.nvim_win_get_cursor(source_win)[1] == 21, "q must not move the cursor")

print("GO_RETURNS_UI_OK")
