-- Navigation end to end on main.go of the fixture verify.sh writes:
-- breadcrumbs in the window bar, Tree-sitter folds, peek of a definition /
-- a struct field / a type / a local name / an implementation (the mock set
-- aside, two real ones in a picker), going deeper inside the float and back,
-- Enter from the float, the second gp focusing it, and file ↔ test.
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

local function title_of(win)
    local title = vim.api.nvim_win_get_config(win).title
    return type(title) == "table" and title[1][1] or title or ""
end

local function footer_of(win)
    local footer = vim.api.nvim_win_get_config(win).footer
    return type(footer) == "table" and footer[1][1] or footer or ""
end

-- The float once its title contains `pattern`.
local function float_with(pattern)
    local win
    vim.wait(10000, function()
        win = peek.float()
        return win ~= nil and title_of(win):find(pattern, 1, true) ~= nil
    end, 50)
    assert(win and title_of(win):find(pattern, 1, true), "no peek float with " .. pattern
        .. (win and (": " .. title_of(win)) or ""))
    return win
end

local function contents(win)
    return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
end

local function peek_at(kind, on, needle)
    vim.api.nvim_set_current_win(source_win)
    local row, col = at(on, needle)
    vim.api.nvim_win_set_cursor(source_win, { row, col })
    peek[kind]()
    local win = float_with(({ definition = "definition", type_definition = "type", implementation = "implementation" })[kind])
    return win, vim.api.nvim_win_get_buf(win), contents(win)
end

-- A buffer-local key of the float, as if pressed.
local function press(lhs)
    local map = vim.fn.maparg(lhs, "n", false, true)
    assert(map.callback, lhs .. " is mapped here")
    map.callback()
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
local greeting_row = at("func greeting(", "greeting")
assert(title_of(win):find("definition · main.go:" .. greeting_row, 1, true), "title: " .. title_of(win))
assert(footer_of(win):find("gp again", 1, true), "unfocused footer: " .. footer_of(win))

-- The same key again focuses the float.
peek.definition()
assert(vim.api.nvim_get_current_win() == win, "second gp focuses the float")
vim.wait(200, function()
    return footer_of(win):find("open", 1, true) ~= nil
end)
assert(footer_of(win):find("⏎ open", 1, true), "focused footer lists the keys: " .. footer_of(win))

-- Enter jumps to the definition in the source window.
press("<CR>")
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

-- gI on a call through an interface: the generated mock is set aside.
local save_row = at("func (memoryStore) Save", "Save")
win, buf, text = peek_at("implementation", "return s.Save(o)", "Save")
assert(title_of(win):find("implementation · main.go:" .. save_row .. " · +1 in mocks/tests", 1, true),
    "title: " .. title_of(win))
assert(text:find("^// Save keeps the order in memory%.") and text:find("func (memoryStore) Save", 1, true),
    "the real implementation with its comment:\n" .. text)
close(win)

-- Deeper inside the float and back: persist → (gI on s.Save) → memoryStore.Save.
local persist_row = at("func persist(", "persist")
win = peek_at("definition", "_ = persist(", "persist")
assert(title_of(win):find("definition · main.go:" .. persist_row, 1, true), "persist peeked")
peek.definition()
assert(vim.api.nvim_get_current_win() == win, "focused")
local call_line = at("return s.Save(o)", "Save") - persist_row + 1
vim.api.nvim_win_set_cursor(win, { call_line, select(2, at("return s.Save(o)", "Save")) })
press("gI")
float_with("‹ implementation · main.go:" .. save_row)
assert(peek.float() == win, "the same float shows the next level")
assert(contents(win):find("func (memoryStore) Save", 1, true), "deeper level shown")
assert(footer_of(win):find("⌫ back", 1, true), "Backspace offered: " .. footer_of(win))
press("<BS>")
float_with("definition · main.go:" .. persist_row)
assert(vim.api.nvim_win_get_cursor(win)[1] == call_line, "cursor restored on the way back")
press("<CR>")
assert(vim.api.nvim_get_current_win() == source_win and not peek.float(), "Enter leaves the float")
assert(vim.api.nvim_win_get_cursor(source_win)[1] == at("return s.Save(o)", "Save"), "Enter opens the line under the cursor")
print("PEEK_DEEPER_OK")

-- Two real implementations: a picker instead of a guess.
local fzf = require("fzf-lua")
local real_exec, picked = fzf.fzf_exec, nil
fzf.fzf_exec = function(entries, opts)
    picked = { entries = entries, opts = opts }
end
vim.api.nvim_win_set_cursor(source_win, { at('n.Notify("hi")', "Notify") })
peek.implementation()
vim.wait(10000, function()
    return picked ~= nil
end, 50)
fzf.fzf_exec = real_exec
assert(picked and #picked.entries == 2, "two implementations in the picker: " .. vim.inspect(picked))
local listed = table.concat(picked.entries, "\n")
assert(listed:find("main.go:%d+:%d+: func %(emailNotifier%) Notify") and listed:find("func (smsNotifier) Notify", 1, true),
    "entries: " .. listed)
assert(not peek.float(), "no float for several implementations")
assert(peek._is_double("/x/mocks/store.go") and peek._is_double("/x/store_mock.go")
    and peek._is_double("/x/store_test.go") and not peek._is_double("/x/store.go"), "mock detection")
print("PEEK_IMPLEMENTATION_OK")

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
