local parsers = { "go", "gomod", "gosum", "gowork" }
local check_only = vim.env.NVIM_BOOTSTRAP_CHECK_ONLY == "1"

local function fail(message)
    error("editor asset bootstrap: " .. message)
end

local config_dir = vim.fn.stdpath("config")
local lock_path = config_dir .. "/nvim-pack-lock.json"
local lock_file = io.open(lock_path, "rb")
if not lock_file then
    fail("missing plugin lock: " .. lock_path)
end

local lock = vim.json.decode(lock_file:read("*a"))
lock_file:close()

local plugins = lock and lock.plugins or nil
if type(plugins) ~= "table" then
    fail("invalid plugin lock: " .. lock_path)
end

local pack_root = vim.fn.stdpath("data") .. "/site/pack/core/opt"
local plugin_count = 0

for name, spec in pairs(plugins) do
    plugin_count = plugin_count + 1
    local path = pack_root .. "/" .. name
    local result = vim.system(
        { "git", "-C", path, "rev-parse", "HEAD" },
        { text = true }
    ):wait()

    if result.code ~= 0 then
        fail(string.format(
            "plugin %s is missing or unreadable: %s",
            name,
            vim.trim(result.stderr or "")
        ))
    end

    local revision = vim.trim(result.stdout or "")
    if revision ~= spec.rev then
        fail(string.format(
            "plugin %s revision mismatch: expected %s, got %s",
            name,
            tostring(spec.rev),
            revision
        ))
    end
end

if not check_only then
    local treesitter = require("nvim-treesitter")
    assert(
        treesitter.install(parsers, { summary = true }):wait(300000),
        "Tree-sitter parser installation failed"
    )
    assert(
        treesitter.update(parsers, { summary = true }):wait(300000),
        "Tree-sitter parser update failed"
    )
end

for _, language in ipairs(parsers) do
    local ok, err = pcall(vim.treesitter.language.add, language)
    if not ok then
        fail(string.format("parser %s is unavailable: %s", language, err))
    end
end

print(string.format(
    "EDITOR_ASSETS_OK plugins=%d parsers=%d mode=%s",
    plugin_count,
    #parsers,
    check_only and "check" or "provision"
))
