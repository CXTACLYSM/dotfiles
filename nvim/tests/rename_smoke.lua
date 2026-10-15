-- Rename end to end in a three-package module (verify.sh writes it): a method
-- renamed from its declaration changes every package on disk, not just
-- hidden buffers; a package renamed on its `package` clause moves its
-- directory and rewrites the imports. The module still builds afterwards.
local root = assert(os.getenv("NVIM_RENAME_ROOT"), "NVIM_RENAME_ROOT is required")
-- Optional non-Go file in the package directory (NVIM_RENAME_EXTRA).
local extra_file = os.getenv("NVIM_RENAME_EXTRA")
if extra_file == "" then
    extra_file = nil
end

local attached = vim.wait(20000, function()
    return #vim.lsp.get_clients({ bufnr = 0, name = "gopls" }) == 1
end, 50)
assert(attached, "gopls did not attach")

local go_rename = require("go_rename")

local function disk(path)
    local ok, lines = pcall(vim.fn.readfile, root .. "/" .. path)
    return ok and table.concat(lines, "\n") or nil
end

local function wait_disk(path, needle)
    return vim.wait(20000, function()
        local text = disk(path)
        return text ~= nil and text:find(needle, 1, true) ~= nil
    end, 50)
end

local function loaded(path)
    local bufnr = vim.fn.bufnr(root .. "/" .. path)
    return bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr)
end

-- 1. Method: declaration in store/, callers in service/ and main.
vim.wait(1000)
vim.api.nvim_win_set_cursor(0, { 5, 17 })
assert(vim.fn.expand("<cword>") == "Save", "cursor on the method name")
go_rename.rename("Persist")
assert(wait_disk("main.go", ".Persist("), "main.go on disk was not renamed")

for _, path in ipairs({ "store/store.go", "service/service.go", "main.go" }) do
    local text = disk(path)
    assert(text:find("Persist", 1, true) and not text:find("Save", 1, true), path .. " on disk:\n" .. text)
end
assert(not vim.bo.modified, "current buffer is written")
assert(not loaded("service/service.go") and not loaded("main.go"), "buffers opened only for the rename are closed")

local qf = vim.fn.getqflist({ title = 1, items = 1 })
assert(qf.title == "rename Save → Persist", "quickfix title: " .. qf.title)
assert(#qf.items == 3, "quickfix lists every changed place: " .. #qf.items)
print("RENAME_METHOD_OK places=" .. #qf.items)

-- 2. Package: rename on the package clause moves the directory.
vim.wait(1500)
vim.api.nvim_win_set_cursor(0, { 1, 9 })
assert(vim.fn.expand("<cword>") == "store", "cursor on the package name")
go_rename.rename("storage")
assert(wait_disk("storage/store.go", "package storage"), "package directory was not moved")
if extra_file then
    -- gopls moves the whole package directory: a non-Go file moves with it.
    assert(vim.fn.filereadable(root .. "/storage/" .. extra_file) == 1, extra_file .. " moved with the package")
end
assert(vim.fn.isdirectory(root .. "/store") == 0, "old package directory is gone")
for _, path in ipairs({ "service/service.go", "main.go" }) do
    local text = disk(path)
    assert(text:find('"example.com/app/storage"', 1, true) and text:find("storage.Store", 1, true),
        path .. " imports the renamed package:\n" .. text)
end
assert(vim.api.nvim_buf_get_name(0) == root .. "/storage/store.go", "current buffer follows the move")
print("RENAME_PACKAGE_OK")

local build = vim.system({ "go", "build", "./..." }, { cwd = root, text = true }):wait()
assert(build.code == 0, "module does not build after renames:\n" .. (build.stderr or ""))
print("RENAME_SMOKE_OK")
