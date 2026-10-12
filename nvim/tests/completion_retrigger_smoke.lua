local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

local retrigger = require("completion_retrigger")
local opts = vim.tbl_deep_extend("force", retrigger.defaults, {})
local triggers = { "." }

local function expect(before, want, label)
    local got, reason = retrigger.should_retrigger(before, opts, triggers)
    assert(got == want, string.format("%s: %q -> %s (%s)", label or "", before, tostring(got), tostring(reason)))
    return reason
end

-- Member access needs one character after the dot by default.
expect("\tm.", false, "bare dot stays quiet")
assert(expect("\tm.S", true, "one character after the dot") == "member")
assert(expect("\tm.Sa", true, "partial member") == "member")
local on_dot = vim.tbl_deep_extend("force", retrigger.defaults, { member_min_length = 0 })
assert(select(2, retrigger.should_retrigger("\tm.", on_dot, triggers)) == "member", "member_min_length = 0 opens on the dot")
assert(expect("\treturn s.store.Sa", true, "chained") == "member")
assert(expect("\tf().Sa", true, "call result") == "member")
assert(expect("\titems[0].ID", true, "index result") == "member")
assert(expect("\tpkg.Type{}.Fi", true, "composite literal") == "member")

-- Numbers and non-access dots do not.
expect("\tx := 1.", false, "float literal")
expect("\tx := 1.5", false, "float digits")
expect("\tx := 3.", false, "float literal end")
expect("\t.", false, "leading dot")
expect("\treturn ", false, "no context")
expect("\tfmt.Println(\"hi", false, "inside string literal text")

-- Bare identifiers are manual by default and configurable.
expect("\tfmt", false, "keyword disabled")
local keyword_opts = vim.tbl_deep_extend("force", retrigger.defaults, { keyword_min_length = 2 })
assert(select(2, retrigger.should_retrigger("\tfmt", keyword_opts, triggers)) == "keyword", "keyword enabled")
assert(retrigger.should_retrigger("\tf", keyword_opts, triggers) == false, "keyword below minimum")
assert(select(2, retrigger.should_retrigger("\tfoo(b", keyword_opts, triggers)) == "keyword", "one char after (")
assert(select(2, retrigger.should_retrigger("\tfoo(a, b", keyword_opts, triggers)) == "keyword", "one char after comma")
assert(select(2, retrigger.should_retrigger("\tx := &T", keyword_opts, triggers)) == "keyword", "one char after &")
assert(retrigger.should_retrigger("\t123", keyword_opts, triggers) == false, "numbers never")
assert(select(2, retrigger.should_retrigger("\tx := Ta", keyword_opts, triggers)) == "keyword", "type name")
assert(select(2, retrigger.should_retrigger("\tt := Task{I", keyword_opts, triggers)) == "keyword", "struct field, one char")
assert(select(2, retrigger.should_retrigger("\tif er", keyword_opts, triggers)) == "keyword", "identifier after keyword")
assert(select(2, retrigger.should_retrigger("\tfoo(&ba", keyword_opts, triggers)) == "keyword", "argument")
assert(select(2, retrigger.should_retrigger('\t"net/ht', keyword_opts, triggers)) == "import", "import path")
assert(retrigger.should_retrigger('\t"n', keyword_opts, triggers) == false, "import path below minimum")
assert(retrigger.should_retrigger("\tx := 0x", keyword_opts, triggers) == false, "hex literal")

-- Member access is immediate; identifiers and import paths wait for a pause.
local delay_opts = { debounce_ms = 60, keyword_debounce_ms = 400 }
assert(retrigger.delay_for("member", delay_opts) == 60, "member delay")
assert(retrigger.delay_for("keyword", delay_opts) == 400, "keyword delay")
assert(retrigger.delay_for("import", delay_opts) == 400, "import delay")
assert(retrigger.delay_for("keyword", { debounce_ms = 60 }) == 60, "keyword delay falls back")

-- Server trigger characters are merged with the defaults on attach and
-- taken away from the native autotrigger, once per client.
vim.cmd("enew!")
local fake_client = { id = 7, server_capabilities = { completionProvider = { triggerCharacters = { ".", ":" } } } }
local entry = retrigger.attach(vim.api.nvim_get_current_buf(), fake_client)
assert(vim.deep_equal(entry.trigger_chars, { ".", ":" }), vim.inspect(entry.trigger_chars))
assert(vim.deep_equal(fake_client.server_capabilities.completionProvider.triggerCharacters, {}), "native triggers must be cleared")
assert(vim.deep_equal(retrigger.take_over_triggers(fake_client), { ".", ":" }), "originals are remembered per client")
assert(vim.deep_equal(retrigger.take_over_triggers({ id = 8, server_capabilities = {} }), {}), "no completion provider")
assert(retrigger.should_retrigger("\tpkg:x", opts, entry.trigger_chars) == true, "server trigger char after an owner")
assert(retrigger.should_retrigger("\tpkg:x", opts, triggers) == false, "unknown char is not a trigger")
assert(retrigger.should_retrigger("\tpkg.x", opts, entry.trigger_chars) == true, "dot still works")

-- A pending identifier request is cancelled by the next change when that
-- change no longer warrants one: `fmt` then `.` must not open the full
-- member list at the bare dot.
retrigger.setup({ keyword_min_length = 2, keyword_debounce_ms = 400, member_min_length = 1 })
vim.cmd("enew!")
local timer_buf = vim.api.nvim_get_current_buf()
retrigger.attach(timer_buf, { id = 9, server_capabilities = { completionProvider = { triggerCharacters = { "." } } } })
vim.cmd("startinsert")
local function type_line(text)
    vim.api.nvim_buf_set_lines(timer_buf, 0, -1, false, { text })
    vim.api.nvim_win_set_cursor(0, { 1, #text })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = timer_buf })
end
type_line("\tfmt")
assert(retrigger.pending(timer_buf), "identifier request must be scheduled after 'fmt'")
type_line("\tfmt.")
assert(not retrigger.pending(timer_buf), "the dot must cancel the pending identifier request")
type_line("\tfmt.P")
assert(retrigger.pending(timer_buf), "one character after the dot schedules a member request")
type_line("\tfmt.")
assert(not retrigger.pending(timer_buf), "Backspace to the bare dot cancels it again")
vim.cmd("stopinsert")

print("COMPLETION_RETRIGGER_SMOKE_OK")
