-- Navigation end to end on main.go of the fixture verify.sh writes:
-- breadcrumbs in the window bar, Tree-sitter folds, peek of a definition /
-- a struct field / a type / a local name, Enter from the peek float, the
-- second gp focusing it, and the file ↔ test toggle.
local attached = vim.wait(20000, function()
    return #vim.lsp.get_clients({ bufnr = 0, name = "gopls" }) == 1
end, 50)
assert(attached, "gopls did not attach")
vim.wait(1500)

local source_win = vim.api.nvim_get_current_win()
local source_buf = vim.api.nvim_get_current_buf()
local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)

-- 1-based line and 0-based byte column of `needle` on the line containing `on`.
local function at(on, needle)
    for index, line in ipairs(lines) do
        if line:find(on, 1, true) then
            local col = line:find(needle, 1, true)
            assert(col, needle .. " not on line " .. index)
            return index, col - 1
        end
    end
    error("no line containing " .. on)
end

-- Breadcrumbs.
local breadcrumbs = require("breadcrumbs")
local function scopes(on, needle)
    local row, col = at(on, needle)
    return table.concat(breadcrumbs.scopes(source_buf, row - 1, col), " › ")
end
assert(scopes("return s.prefix + label", "label") == "(*Service) Describe › func", "closure scope: " .. scopes("return s.prefix + label", "label"))
assert(scopes("Total int", "Total") == "Order › Total", "struct field scope: " .. scopes("Total int", "Total"))
assert(scopes('return "hello, " + name', "name") == "greeting", "function scope")
assert(#breadcrumbs.scopes(source_buf, 1, 0) == 0, "no scope between declarations")
assert(vim.wo[source_win].winbar:find("breadcrumbs", 1, true), "file window has the bar")
local bar = breadcrumbs.render()
assert(bar:find("main.go", 1, true), "bar shows the file: " .. bar)
vim.cmd("copen")
assert(vim.wo.winbar == "", "quickfix window has no bar")
vim.cmd("cclose")
vim.api.nvim_set_current_win(source_win)
print("BREADCRUMBS_OK")

-- Folds.
assert(vim.wo[source_win].foldmethod == "expr" and vim.wo[source_win].foldlevel == 99, "Tree-sitter folds, open")
local body_row = at('return "hello, " + name', "return")
vim.cmd("normal! zM")
assert(vim.fn.foldclosed(body_row) ~= -1, "zM folds function bodies")
vim.cmd("normal! zR")
assert(vim.fn.foldclosed(body_row) == -1, "zR opens them again")
print("FOLDS_OK")

-- Peek.
local peek = require("peek")

local function float_of(buf)
    local win
    vim.wait(10000, function()
        win = vim.b[buf].lsp_floating_preview
        return win ~= nil and vim.api.nvim_win_is_valid(win)
    end, 50)
    assert(win and vim.api.nvim_win_is_valid(win), "peek float did not open")
    return win
end

local function peek_at(kind, on, needle)
    vim.api.nvim_set_current_win(source_win)
    local row, col = at(on, needle)
    vim.api.nvim_win_set_cursor(source_win, { row, col })
    peek[kind]()
    local win = float_of(source_buf)
    local buf = vim.api.nvim_win_get_buf(win)
    return win, buf, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function marked_line(buf)
    local namespace = vim.api.nvim_get_namespaces()["peek"]
    local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {})
    assert(#marks == 1, "one marked line")
    return vim.api.nvim_buf_get_lines(buf, marks[1][2], marks[1][2] + 1, false)[1]
end

local function close(win)
    if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
    end
    vim.api.nvim_set_current_win(source_win)
end

-- A function: its doc comment and whole body; title names file and line.
local win, buf, text = peek_at("definition", 'fmt.Println(greeting("x")', "greeting")
assert(text:find("^// greeting builds a greeting%.") and text:find("func greeting(name string) string {", 1, true)
    and text:find("}%s*$"), "function with its doc comment:\n" .. text)
assert(not text:find("type Service", 1, true), "only that declaration:\n" .. text)
local title = vim.api.nvim_win_get_config(win).title
title = type(title) == "table" and title[1][1] or title
local greeting_row = at("func greeting(", "greeting")
assert(title:find("definition · main.go:" .. greeting_row, 1, true), "title: " .. vim.inspect(title))

-- The same key again focuses the float.
peek.definition()
assert(vim.api.nvim_get_current_win() == win, "second gp focuses the float")

-- Enter jumps to the definition in the source window.
local enter = vim.fn.maparg("<CR>", "n", false, true)
assert(enter.callback, "Enter is mapped in the float")
enter.callback()
assert(vim.api.nvim_get_current_win() == source_win, "back in the source window")
assert(vim.api.nvim_win_get_cursor(source_win)[1] == greeting_row, "cursor on the definition")
assert(not vim.api.nvim_win_is_valid(win), "float closed after the jump")
print("PEEK_DEFINITION_OK")

-- A struct field: the whole struct with the field line marked.
win, buf, text = peek_at("definition", "o.Total)", "Total")
assert(text:find("type Order struct {", 1, true) and text:find("ID    int", 1, true), "whole struct:\n" .. text)
assert(vim.trim(marked_line(buf)) == "Total int", "field line marked: " .. marked_line(buf))
close(win)

-- The type of a variable.
win, buf, text = peek_at("type_definition", "var o Order", "o Order")
assert(text:find("type Order struct {", 1, true), "type definition:\n" .. text)
close(win)

-- A local name: a few lines around its declaration, not the whole function.
win, buf, text = peek_at("definition", "return s.prefix + label", "label")
assert(text:find("label := fmt.Sprintf", 1, true), "local declaration:\n" .. text)
assert(not text:find("func main", 1, true) and select(2, text:gsub("\n", "")) <= 6, "only the context:\n" .. text)
assert(marked_line(buf):find("label :=", 1, true), "local line marked")
close(win)
print("PEEK_OK")

-- File ↔ test.
local go_alt = require("go_alt")
assert(go_alt.target("/x/a.go") == "/x/a_test.go" and go_alt.target("/x/a_test.go") == "/x/a.go", "pairing")
assert(go_alt.target("/x/README.md") == nil, "non-Go file")
local main_path = vim.api.nvim_buf_get_name(source_buf)
go_alt.toggle()
local test_buf = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(test_buf):match("main_test%.go$"), "opened the test file")
local test_lines = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)
assert(test_lines[1] == "package main" and test_lines[3] == 'import "testing"', "new test file skeleton")
assert(vim.bo[test_buf].modified, "new test file is not written by itself")
go_alt.toggle()
assert(vim.api.nvim_buf_get_name(0) == main_path, "back to the source file")
print("GO_ALT_OK")

print("NAV_SMOKE_OK")
