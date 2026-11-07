local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

-- Space j: the JSON object out of a log line (prefix skipped, nested
-- braces kept), drawn with sorted keys and indentation, the caller in a
-- line, and the float with Enter on the caller.
local json_log = require("json_log")

local function same(got, want, what)
    assert(vim.deep_equal(got, want), what .. ": " .. vim.inspect(got) .. " ~= " .. vim.inspect(want))
end

local line = '2026-11-07T15:00:00Z INFO {"level":"info","msg":"order placed","order":{"id":42,"items":["a","b"]},'
    .. '"caller":"internal/order/service.go:17","ok":true,"none":null}'
local value = json_log.extract(line)
assert(value and value.msg == "order placed" and value.order.id == 42, "the object after the prefix")
assert(json_log.extract("plain text without braces") == nil, "no JSON")
assert(json_log.extract("broken {not json} here") == nil, "braces that do not decode")
assert(json_log.extract('{"a":1} trailing').a == 1, "trailing text after the object")

same(json_log.pretty(value), {
    "{",
    '  "caller": "internal/order/service.go:17",',
    '  "level": "info",',
    '  "msg": "order placed",',
    '  "none": null,',
    '  "ok": true,',
    '  "order": {',
    '    "id": 42,',
    '    "items": [',
    '      "a",',
    '      "b"',
    "    ]",
    "  }",
    "}",
}, "keys sorted, nesting indented")
same(json_log.pretty({ list = {}, object = vim.empty_dict() }), { "{", '  "list": [],', '  "object": {}', "}" }, "empty containers")

local path, number = json_log.caller('  "caller": "internal/order/service.go:17",')
assert(path == "internal/order/service.go" and number == 17, "caller path and line")
assert(json_log.caller('  "msg": "no caller"') == nil, "no caller")

-- The float on a buffer with the line; Enter on the caller opens it.
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/internal/order", "p")
vim.fn.writefile(vim.fn.range(1, 30), root .. "/internal/order/service.go")
assert(json_log.resolve("internal/order/service.go", root) == root .. "/internal/order/service.go", "under the root")
assert(json_log.resolve("order/service.go", root) == root .. "/internal/order/service.go", "by the end of the path")
assert(json_log.resolve("nowhere.go", root) == nil, "not in the project")
vim.cmd("enew!")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
local origin = vim.api.nvim_get_current_win()
local win = json_log.show(root)
assert(win and vim.api.nvim_win_is_valid(win) and vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "json", "the float")
assert(vim.api.nvim_win_get_config(win).relative ~= "editor", "next to the cursor")
vim.api.nvim_win_set_cursor(win, { 2, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
assert(not vim.api.nvim_win_is_valid(win), "Enter closes the float")
assert(vim.api.nvim_get_current_win() == origin and vim.api.nvim_buf_get_name(0):find("service.go", 1, true)
    and vim.api.nvim_win_get_cursor(0)[1] == 17, "and opens the caller at its line")
vim.fn.delete(root, "rf")
print("JSON_LOG_OK")
