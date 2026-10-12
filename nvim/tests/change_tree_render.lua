-- Drawing a built graph as a tree, without gopls: dependents before
-- dependencies, one row per (tag, node), cycles marked instead of followed,
-- locations relative to the root, Enter on the use site, d on the declaration.
local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

local change_tree = require("change_tree")

local root_dir = "/repo"

local function node(id, kind, name, path, line)
    return {
        id = id,
        symbol = { kind = kind, qualified = name, path = path, start_line = line, end_line = line + 3 },
    }
end

local save = node("save", "method", "Service.Save", "store/service.go", 10)
local handler = node("handler", "func", "Handler.Put", "http/handler.go", 20)
local test = node("test", "func", "TestSave", "store/service_test.go", 5)
local validate = node("validate", "func", "validate", "store/validate.go", 3)
local task = node("task", "type", "Task", "store/task.go", 1)

local graph = {
    root = root_dir,
    roots = { save },
    nodes = { save, handler, test, validate, task },
    node_by_id = { save = save, handler = handler, test = test, validate = validate, task = task },
    edges = {
        { from = "validate", to = "task", relation = "uses_type" },
        { from = "save", to = "validate", relation = "calls", occurrence = { path = "store/service.go", line = 12, col = 9 } },
        { from = "test", to = "save", relation = "test_oracle" },
        { from = "handler", to = "save", relation = "caller" },
        -- A second call from the same caller collapses into one row.
        { from = "handler", to = "save", relation = "caller" },
        -- A cycle back to the root is marked, not followed.
        { from = "validate", to = "save", relation = "calls" },
        { from = "save", to = "task", relation = "uses_type" },
    },
    externals = { { id = "fmt.Errorf" } },
    complete = true,
}

local lines, entries, summary = change_tree.render(graph, { max_tree_depth = 3 })
local text = table.concat(lines, "\n")

local function row(pattern)
    for index, line in ipairs(lines) do
        if line:find(pattern, 1, true) then
            return index, line
        end
    end
    error("row not found: " .. pattern .. "\n" .. text)
end

local root_row = row("Δ method Service.Save")
local caller_row = row("caller Handler.Put")
local test_row = row("test   TestSave")
local calls_row, calls_line = row("calls  validate")
local type_row = row("type   Task")

assert(root_row == 1, "root first")
assert(caller_row < test_row and test_row < calls_row and calls_row < type_row,
    "dependents before dependencies:\n" .. text)

local callers = 0
for _, line in ipairs(lines) do
    if line:find("caller Handler.Put", 1, true) then
        callers = callers + 1
    end
end
assert(callers == 1, "duplicate caller edges collapse:\n" .. text)

assert(calls_line:find("store/service.go:12", 1, true), "call row shows the call site:\n" .. text)
assert(text:find("calls  Service.Save ↑", 1, true), "cycle to the root is marked:\n" .. text)
assert(text:find("type   Task", 1, true) and text:find("│  └─ type   Task", 1, true), "nested dependency drawn under validate:\n" .. text)

local calls_entry = entries[calls_row]
assert(calls_entry.jumps["<CR>"].path == "/repo/store/service.go" and calls_entry.jumps["<CR>"].line == 12,
    "Enter goes to the call site")
assert(calls_entry.jumps.d.path == "/repo/store/validate.go" and calls_entry.jumps.d.line == 3,
    "d goes to the declaration")
assert(entries[root_row].preview.path == "/repo/store/service.go", "root previews its declaration")

assert(summary == "1 changed · 2 affected · 2 uses · 1 external", "summary: " .. summary)

-- Deleted roots have nothing to open.
local deleted = node("gone", "func", "legacy", "old.go", 1)
deleted.symbol.deleted = true
local deleted_lines, deleted_entries = change_tree.render({
    root = root_dir,
    roots = { deleted },
    nodes = { deleted },
    node_by_id = { gone = deleted },
    edges = {},
    complete = false,
}, { max_tree_depth = 3 })
assert(deleted_lines[1]:find("✗ func legacy  (deleted)", 1, true), deleted_lines[1])
assert(deleted_entries[1].preview == nil, "deleted root has no preview")

print("CHANGE_TREE_RENDER_OK")
