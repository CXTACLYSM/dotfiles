local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

local pairer = require("pairs")
pairer.setup()
vim.o.showmode = false
vim.cmd("filetype plugin indent on")

local function keys(value)
    vim.api.nvim_feedkeys(vim.keycode(value), "xt", false)
    vim.wait(50)
end

local function reset(line, col)
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { line or "" })
    vim.api.nvim_win_set_cursor(0, { 1, col or 0 })
end

local function expect(label, expected)
    local actual = vim.api.nvim_get_current_line()
    assert(actual == expected, string.format(
        "%s: expected %q, got %q",
        label,
        expected,
        actual
    ))
end

local function expect_lines(label, expected)
    local actual = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert(vim.deep_equal(actual, expected), string.format(
        "%s: expected %s, got %s",
        label,
        vim.inspect(expected),
        vim.inspect(actual)
    ))
end

for _, item in ipairs({
    { "paren", "(", "()" },
    { "brace", "{", "{}" },
    { "bracket", "[", "[]" },
    { "double quote", '"', '""' },
    { "single quote", "'", "''" },
    { "backtick", "`", "``" },
}) do
    reset()
    keys("i" .. item[2] .. "<Esc>")
    expect(item[1], item[3])
end

for _, item in ipairs({
    { "paren backspace", "(", "" },
    { "brace backspace", "{", "" },
    { "bracket backspace", "[", "" },
    { "double quote backspace", '"', "" },
    { "single quote backspace", "'", "" },
    { "backtick backspace", "`", "" },
}) do
    reset()
    keys("i" .. item[2] .. "<BS><Esc>")
    expect(item[1], item[3])
end

reset("foo()", 3)
keys("a)<Esc>")
expect("skip existing closer", "foo()")
assert(vim.api.nvim_win_get_cursor(0)[2] == 4, "closer was not skipped")

for _, item in ipairs({
    { "nested parens", "outer(inner())" },
    { "nested braces", "{{}}" },
    { "nested brackets", "map[input[i]]" },
}) do
    reset()
    keys("i" .. item[2] .. "<Esc>")
    expect(item[1], item[2])
end

for _, source in ipairs({
    "func foo() {}",
    "if err != nil {}",
    "map[string]int{}",
    "[]byte{}",
    '"string"',
    "'r'",
    "`raw string`",
}) do
    reset()
    keys("i" .. source .. "<Esc>")
    expect("Go pair sample", source)
end

reset("\\", 0)
keys("a\"<Esc>")
expect("escaped double quote", '\\"')

reset("\\", 0)
keys("a'<Esc>")
expect("escaped single quote", "\\'")

-- An escaped quote immediately before an automatically inserted quote is
-- content. It must not trigger the quote skip-over path.
reset()
keys([[i"<Esc>]])
keys([[a\<Esc>]])
keys([[a"<Esc>]])
expect("escaped double quote before pair closer", [["\""]])

reset()
keys("i'<Esc>")
keys("a\\<Esc>")
keys("a'<Esc>")
expect("escaped single quote before pair closer", "'\\''")

-- Enter inside an empty Go block keeps the closing brace aligned and leaves
-- the cursor on an indented line in the middle.
reset()
vim.bo.filetype = "go"
keys("ifunc main() {<CR>x<Esc>")
expect_lines("newline inside braces", {
    "func main() {",
    "\tx",
    "}",
})
assert(vim.api.nvim_win_get_cursor(0)[1] == 2, "cursor left the block body")

reset()
keys("ifirst<CR>second<Esc>")
expect_lines("ordinary newline", { "first", "second" })

reset()
keys("i(<Esc>u")
expect("single-step undo", "")

reset("x x", 0)
keys("i(<Esc>w.")
expect("dot repeat", "()()x x")

reset()
vim.api.nvim_put({ "map[string]int{} []byte{} \"paste\"" }, "c", true, true)
expect("paste is literal", 'map[string]int{} []byte{} "paste"')

print("PAIRS_SMOKE_OK")
