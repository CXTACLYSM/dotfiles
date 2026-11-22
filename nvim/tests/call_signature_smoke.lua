local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

-- The signature line above a call (lua/call_signature.lua): the parameter
-- at the cursor found in the label (strings, repeated strings, UTF-16
-- offsets), the first sentence of the docs under it, the textual check of
-- "inside the parentheses" while the tree lags behind the typing.
local sig = require("call_signature")

-- The answer gopls gives for fmt.Printf with the cursor at the second
-- argument.
local printf = {
    activeSignature = 0,
    activeParameter = 1,
    signatures = {
        {
            label = "Printf(format string, a ...any) (n int, err error)",
            parameters = { { label = "format string" }, { label = "a ...any" } },
            documentation = {
                kind = "markdown",
                value = "Printf formats according to a format specifier and writes to standard output. It returns the number of bytes written and any write error encountered.",
            },
        },
    },
}
local rendered = sig.render(printf)
assert(rendered.lines[1] == printf.signatures[1].label, rendered.lines[1])
assert(rendered.lines[2] == "Printf formats according to a format specifier and writes to standard output.", rendered.lines[2])
assert(vim.deep_equal(rendered.active, { 22, 30 }) and printf.signatures[1].label:sub(23, 30) == "a ...any", vim.inspect(rendered.active))
printf.activeParameter = 0
rendered = sig.render(printf)
assert(printf.signatures[1].label:sub(rendered.active[1] + 1, rendered.active[2]) == "format string", vim.inspect(rendered.active))
print("CALL_SIGNATURE_RENDER_OK")

-- The same text twice: the second parameter is found after the first.
local s, e = sig.parameter_range("f(a int, a int)", { { label = "a int" }, { label = "a int" } }, 1)
assert(s == 9 and e == 14, s .. " " .. e)
-- Offsets instead of strings (UTF-16, as LSP counts).
s, e = sig.parameter_range("f(ж string, b int)", { { label = { 2, 10 } }, { label = { 12, 17 } } }, 0)
assert(("f(ж string, b int)"):sub(s + 1, e) == "ж string", ("f(ж string, b int)"):sub(s + 1, e))
assert(sig.parameter_range("f()", {}, 0) == nil, "no parameters")
-- The active parameter past the list (variadic calls): no highlight, the line stays.
assert(sig.render({ signatures = { { label = "f(a int)", parameters = { { label = "a int" } } } }, activeParameter = 3 }).active == nil)
assert(sig.render({ signatures = {} }) == nil and sig.render(nil) == nil, "nothing to show")
print("CALL_SIGNATURE_PARAMETERS_OK")

-- The doc line: the first sentence, marks dropped, long ones cut.
assert(sig.first_sentence({ kind = "markdown", value = "Marshal returns the JSON encoding of `v`.\n\nMarshal traverses…" }) == "Marshal returns the JSON encoding of v.")
assert(sig.first_sentence("One two three") == "One two three")
assert(sig.first_sentence(nil) == nil and sig.first_sentence("") == nil)
sig.opts.doc_width = 20
assert(sig.first_sentence("A very long first sentence that goes on and on.") == "A very long first s…")
sig.opts.doc_width = 100
print("CALL_SIGNATURE_DOC_OK")

-- Inside the parentheses by the text: an unclosed `(` outside strings.
assert(sig.inside_call(nil, "\tfmt.Println(o.ID, ") == true, "after a comma")
assert(sig.inside_call(nil, "\tfmt.Println(") == true, "right after the paren")
assert(sig.inside_call(nil, "\tfmt.Println(a) ") == false, "closed")
assert(sig.inside_call(nil, "\tx := 1") == false, "no call")
assert(sig.inside_call(nil, '\tfmt.Println("(') == false, "a paren inside a string")
assert(sig.inside_call(nil, '\tfmt.Println("(", ') == true, "a string argument closed")
assert(sig.inside_call(nil, "\tf(g(1), ") == true, "nested, the inner closed")
print("CALL_SIGNATURE_INSIDE_OK")

-- The float: above the cursor line, from the column of the call, the active
-- parameter marked, updated in place, closed on demand.
vim.cmd("enew!")
local buf = vim.api.nvim_get_current_buf()
local filler = {}
for _ = 1, 9 do
    table.insert(filler, "")
end
table.insert(filler, "\tfmt.Printf(")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, filler)
vim.api.nvim_win_set_cursor(0, { 10, 12 })
sig.setup()
printf.activeParameter = 0
sig.show(buf, sig.render(printf))
local win = assert(sig.window(), "the float is open")
-- nvim reports a cursor-relative float as window-relative, by its anchor:
-- the bottom-left corner sits on the cursor row, so the rows are above.
local config = vim.api.nvim_win_get_config(win)
local cursor_row = vim.fn.winline() - 1
assert(config.anchor == "SW" and config.row == cursor_row, "above the cursor line: " .. vim.inspect({ anchor = config.anchor, row = config.row, cursor = cursor_row }))
-- Not to the right of the cursor (headless nvim reports the anchor column
-- without the offset; the stand shows the float from the start of the call).
assert(config.col <= vim.fn.wincol() - 1, "not right of the cursor: " .. tostring(config.col) .. " cursor " .. vim.fn.wincol())
assert(config.focusable == false and config.height == 2, "two rows, not focusable")
assert(vim.w[win].call_signature, "marked as the signature float")
local float_buf = vim.api.nvim_win_get_buf(win)
assert(vim.api.nvim_buf_get_lines(float_buf, 0, 1, false)[1] == printf.signatures[1].label, "the signature line")
local marks = vim.api.nvim_buf_get_extmarks(float_buf, vim.api.nvim_create_namespace("call_signature"), 0, -1, { details = true })
local active
for _, mark in ipairs(marks) do
    if mark[4].hl_group == "LspSignatureActiveParameter" then
        active = { mark[3], mark[4].end_col }
    end
end
assert(vim.deep_equal(active, { 7, 20 }), "format string highlighted: " .. vim.inspect(active))
printf.activeParameter = 1
sig.show(buf, sig.render(printf))
assert(sig.window() == win, "updated in place, not reopened")
sig.close()
assert(sig.window() == nil and not vim.api.nvim_win_is_valid(win), "closed")
print("CALL_SIGNATURE_FLOAT_OK")

print("CALL_SIGNATURE_SMOKE_OK")
