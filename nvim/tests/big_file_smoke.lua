local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/site")

local big_file = require("big_file")
local opts = { max_bytes = 1000, max_lines = 50 }

assert(big_file.is_big("x.go", opts, { size = 999 }, 10) == false, "small stays small")
assert(big_file.is_big("x.go", opts, { size = 1001 }, 10) == true, "size threshold")
assert(big_file.is_big("x.go", opts, { size = 10 }, 51) == true, "line threshold")
assert(big_file.is_big("", opts) == false, "no file")

-- End to end: a generated file over the line threshold is marked on read,
-- Tree-sitter stays off for it, a normal file keeps highlighting.
big_file.setup({ max_bytes = 1024 * 1024, max_lines = 50 })
vim.api.nvim_create_autocmd("FileType", {
    pattern = "go",
    callback = function(event)
        if not big_file.is_marked(event.buf) then
            vim.treesitter.start(event.buf)
        end
    end,
})
vim.cmd("filetype on")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local generated = {}
table.insert(generated, "package gen")
for index = 1, 60 do
    table.insert(generated, string.format("var V%d = %d", index, index))
end
vim.fn.writefile(generated, dir .. "/generated.go")
vim.fn.writefile({ "package small", "", "func f() {}" }, dir .. "/small.go")

vim.cmd("edit " .. dir .. "/generated.go")
local generated_buf = vim.api.nvim_get_current_buf()
assert(big_file.is_marked(generated_buf), "generated file must be marked")
assert(vim.bo[generated_buf].syntax == "", "syntax must be off for a big file")
assert(not vim.treesitter.highlighter.active[generated_buf], "Tree-sitter must not highlight a big file")

vim.cmd("edit " .. dir .. "/small.go")
local small_buf = vim.api.nvim_get_current_buf()
assert(not big_file.is_marked(small_buf), "small file must not be marked")
assert(vim.treesitter.highlighter.active[small_buf], "Tree-sitter must highlight a small file")

vim.fn.delete(dir, "rf")
print("BIG_FILE_SMOKE_OK")
