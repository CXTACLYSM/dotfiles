-- Every Lua file of the config parses, and every module loads in a bare
-- Neovim (plugins are required lazily inside functions).
local config = assert(os.getenv("NVIM_CONFIG_DIR"), "NVIM_CONFIG_DIR is required")
local lua_path = config .. "/lua"
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

local files = vim.fn.globpath(config, "**/*.lua", false, true)
assert(#files > 0, "no Lua files under " .. config)
for _, file in ipairs(files) do
    local chunk, err = loadfile(file)
    assert(chunk, err)
end
print(string.format("LUA_SYNTAX_OK files=%d", #files))

local modules = {
    "pairs",
    "go_lsp",
    "go_refs",
    "go_returns",
    "go_calls",
    "graph_view",
    "go_tasks",
    "completion_retrigger",
    "big_file",
    "go_debug",
    "go_rename",
    "go_alt",
    "peek",
    "breadcrumbs",
    "change_tree.go_index",
    "change_tree.semantic_graph",
    "change_tree",
}
for _, name in ipairs(modules) do
    assert(require(name), name)
end
print(string.format("LUA_MODULES_OK modules=%d", #modules))
