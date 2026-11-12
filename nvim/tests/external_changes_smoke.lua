local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

-- Files changed on disk under their buffers (lua/external_changes.lua).
local external = require("external_changes")

-- What changed, in the lines of the new text.
local hunks, stats = external.hunks({ "one", "two", "three", "four" }, { "one", "TWO", "three", "four", "five", "six" })
assert(vim.deep_equal(hunks, { { first = 2, count = 1, kind = "change" }, { first = 5, count = 2, kind = "add" } }), vim.inspect(hunks))
assert(vim.deep_equal(stats, { added = 2, changed = 1, removed = 0 }) and external.summary(stats) == "+2 ~1", vim.inspect(stats))
hunks, stats = external.hunks({ "a", "b", "c" }, { "a", "c" })
assert(#hunks == 0 and external.summary(stats) == "-1", "a removed line has no place in the new text, it is only counted")
hunks, stats = external.hunks({ "a", "b", "c" }, { "a", "B1", "B2", "B3" })
assert(vim.deep_equal(hunks, { { first = 2, count = 3, kind = "change" } }) and external.summary(stats) == "+1 ~2",
    "two lines replaced by three: " .. vim.inspect(stats))
hunks, stats = external.hunks({ "a" }, { "a" })
assert(#hunks == 0 and external.summary(stats) == "", "the same text: nothing")

-- The notices, as they would be shown.
local notices = {}
local echo = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks, history, opts)
    if type(opts) == "table" and type(opts.id) == "string" and opts.id:find("^external_changes%.") then
        table.insert(notices, { text = chunks[1][1], group = chunks[1][2], id = opts.id, history = history })
        return 0
    end
    return echo(chunks, history, opts)
end
local function last_notice()
    vim.wait(200, function()
        return false
    end)
    return notices[#notices]
end

external.setup({ interval_ms = 0, flash_ms = 150 })
assert(vim.o.autoread == false, "the reload is decided by the module, not by 'autoread'")
local namespace = vim.api.nvim_get_namespaces().external_changes
assert(namespace, "the namespace of the highlight")

local path = vim.fn.tempname() .. ".txt"
local clock = 0
-- Write the file and move its time forward: two writes within one second
-- must still look like a change.
local function write(lines)
    vim.fn.writefile(lines, path)
    clock = clock + 5
    local stat = assert(vim.uv.fs_stat(path))
    assert(vim.uv.fs_utime(path, stat.atime.sec, stat.mtime.sec + clock))
end
local function marks(buf)
    local found = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
        table.insert(found, { mark[2] + 1, mark[4].line_hl_group })
    end
    return found
end

vim.fn.writefile({ "one", "two", "three", "four" }, path)
vim.cmd.edit(path)
local buf = vim.api.nvim_get_current_buf()
-- The name as the module shows it: the buffer resolves /var to /private/var.
local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")

-- A buffer without unsaved changes follows the file: reloaded, the changed
-- lines highlighted for a while, one notice with the counts.
write({ "one", "TWO", "three", "four", "five", "six" })
external.check()
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "one", "TWO", "three", "four", "five", "six" }), "reloaded")
assert(vim.bo[buf].modified == false and not vim.b[buf].disk_conflict, "still unmodified, no conflict")
assert(vim.deep_equal(marks(buf), { { 2, "ExternalChangeText" }, { 5, "ExternalChangeAdd" }, { 6, "ExternalChangeAdd" } }),
    vim.inspect(marks(buf)))
local notice = last_notice()
assert(#notices == 1 and notice.text == name .. " changed on disk: +2 ~1", vim.inspect(notices))
assert(notice.id == "external_changes." .. buf and notice.history == true, "one notice per buffer, kept in :messages")
assert(vim.wait(1000, function()
    return #marks(buf) == 0
end), "the highlight goes away by itself")
assert(vim.fn.hlexists("ExternalChangeAdd") == 1 and vim.fn.hlexists("ExternalChangeText") == 1, "highlight groups")

-- The same file again: the same notice id, so it replaces the previous one.
write({ "one", "TWO", "four", "five", "six" })
external.check()
notice = last_notice()
assert(#notices == 2 and notice.text == name .. " changed on disk: -1" and notice.id == notices[1].id, vim.inspect(notices))

-- Nothing changed: nothing is said.
external.check()
last_notice()
assert(#notices == 2, "no notice without a change")

-- Unsaved changes are never overwritten and never asked about: the buffer
-- stays, a warning and a mark for the status line.
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "ONE (mine)" })
write({ "theirs" })
external.check()
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, 2, false), { "ONE (mine)", "TWO" }), "the unsaved buffer is kept")
assert(vim.bo[buf].modified and vim.b[buf].disk_conflict == true, "marked as a conflict")
notice = last_notice()
assert(#notices == 3 and notice.group == "WarningMsg" and notice.text:find(name .. " changed on disk and has unsaved changes", 1, true),
    vim.inspect(notice))
assert(#marks(buf) == 0, "nothing is highlighted in a buffer that was not reloaded")
external.check()
external.check()
last_notice()
assert(#notices == 3, "the conflict is said once, not at every check: " .. #notices)

-- Reading the file again settles it.
vim.cmd("silent edit!")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "theirs" }) and vim.b[buf].disk_conflict == nil,
    ":e! takes the file and clears the mark")

-- So does writing the buffer over the file.
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "mine again" })
write({ "theirs again" })
external.check()
assert(vim.b[buf].disk_conflict == true, "a conflict again")
vim.cmd("silent write!")
assert(vim.b[buf].disk_conflict == nil and vim.fn.readfile(path)[1] == "mine again", ":w! keeps the buffer and clears the mark")

-- A deleted file: the buffer stays, one warning however often it is checked.
os.remove(path)
last_notice()
local before = #notices
external.check()
external.check()
external.check()
notice = last_notice()
assert(notice.group == "WarningMsg" and notice.text == name .. " was deleted on disk; the buffer is kept", vim.inspect(notice))
assert(#notices == before + 1, "said once: " .. vim.inspect(vim.list_slice(notices, before + 1)))
assert(vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "mine again", "the text is kept")
-- The file comes back with another text: read again; deleted once more:
-- said once more.
write({ "back again" })
external.check()
notice = last_notice()
assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "back again" and notice.text == name .. " changed on disk: ~1",
    "a file that reappears is read: " .. vim.inspect(notice))
os.remove(path)
before = #notices
external.check()
external.check()
last_notice()
assert(#notices == before + 1 and notices[#notices].text:find("was deleted on disk", 1, true), "deleted again, said again once")

-- A long file is reloaded without the comparison.
external.setup({ interval_ms = 0, max_lines = 3 })
vim.fn.writefile({ "1", "2", "3", "4", "5" }, path)
vim.cmd("silent edit!")
before = #notices
write({ "1", "2", "3", "4", "five" })
external.check()
last_notice()
assert(vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1] == "five" and #notices == before and #marks(buf) == 0,
    "over max_lines: reloaded, no notice, no highlight")

-- Many files at once (a git checkout): one line for all of them, each
-- buffer still reloaded and highlighted; a warning is never folded in.
external.setup({ interval_ms = 0, flash_ms = 150, max_lines = 20000 })
local paths, buffers = {}, {}
for index = 1, 5 do
    paths[index] = vim.fn.tempname() .. "-" .. index .. ".txt"
    vim.fn.writefile({ "old " .. index }, paths[index])
    vim.cmd.edit(paths[index])
    buffers[index] = vim.api.nvim_get_current_buf()
end
vim.api.nvim_buf_set_lines(buffers[5], 0, 1, false, { "unsaved" })
before = #notices
for index = 1, 5 do
    vim.fn.writefile({ "new " .. index }, paths[index])
    local stat = assert(vim.uv.fs_stat(paths[index]))
    assert(vim.uv.fs_utime(paths[index], stat.atime.sec, stat.mtime.sec + 100))
end
external.check()
for index = 1, 4 do
    -- Four of them are in no window: a plain :checktime would skip those.
    assert(vim.api.nvim_buf_get_lines(buffers[index], 0, 1, false)[1] == "new " .. index, "every buffer is reloaded")
    assert(#marks(buffers[index]) == 1, "and its change highlighted")
end
last_notice()
assert(vim.api.nvim_buf_get_lines(buffers[5], 0, 1, false)[1] == "unsaved" and vim.b[buffers[5]].disk_conflict, "the unsaved one is kept")
assert(#notices == before + 2, "one warning and one line for the rest: " .. vim.inspect(vim.list_slice(notices, before + 1)))
local folded, warned = false, false
for _, shown in ipairs(vim.list_slice(notices, before + 1)) do
    folded = folded or shown.text == "4 files changed on disk"
    warned = warned or (shown.group == "WarningMsg" and shown.text:find("has unsaved changes", 1, true) ~= nil)
end
assert(folded and warned, vim.inspect(vim.list_slice(notices, before + 1)))
-- Up to max_notices files keep a notice each.
before = #notices
for index = 1, 3 do
    vim.fn.writefile({ "newer " .. index }, paths[index])
    local stat = assert(vim.uv.fs_stat(paths[index]))
    assert(vim.uv.fs_utime(paths[index], stat.atime.sec, stat.mtime.sec + 200))
end
external.check()
last_notice()
assert(#notices == before + 3 and notices[#notices].text:find("changed on disk: ~1", 1, true), "three files, three notices")
vim.cmd("silent! bwipeout! " .. table.concat(buffers, " "))
for _, file in ipairs(paths) do
    os.remove(file)
end
vim.cmd.buffer(buf)

-- The periodic check: a timer runs it without anyone asking.
external.setup({ interval_ms = 50, flash_ms = 150, max_lines = 20000 })
write({ "by the timer" })
assert(vim.wait(2000, function()
    return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "by the timer"
end, 20), "the timer notices the change")
external.setup({ interval_ms = 0 })

os.remove(path)
print("EXTERNAL_CHANGES_OK")
