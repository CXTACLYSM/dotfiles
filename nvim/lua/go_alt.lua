-- Go file ↔ its test: service.go ↔ service_test.go.
--
-- A missing test file opens as a new unsaved buffer with the package
-- clause of its source and the testing import; a missing source file is
-- reported, not created.

local M = {}

local function notify(message, level)
    vim.notify(message, level or vim.log.levels.INFO, { title = "alternate" })
end

-- The paired path, or nil for a non-Go file.
function M.target(path)
    if path:match("_test%.go$") then
        return (path:gsub("_test%.go$", ".go"))
    end
    if path:match("%.go$") then
        return (path:gsub("%.go$", "_test.go"))
    end
    return nil
end

-- `package` name declared in the first lines of a Go buffer.
local function package_name(bufnr)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, 50, false)) do
        local name = line:match("^package%s+([%w_]+)")
        if name then
            return name
        end
    end
    return nil
end

function M.toggle()
    local source = vim.api.nvim_get_current_buf()
    local path = vim.api.nvim_buf_get_name(source)
    local target = M.target(path)
    if not target then
        notify("Not a Go file")
        return
    end

    local exists = vim.uv.fs_stat(target) ~= nil or vim.fn.bufexists(target) == 1
    if not exists and not target:match("_test%.go$") then
        notify("No " .. vim.fn.fnamemodify(target, ":t"))
        return
    end

    local pkg = package_name(source)
    vim.cmd.edit(vim.fn.fnameescape(target))

    local bufnr = vim.api.nvim_get_current_buf()
    local empty = vim.api.nvim_buf_line_count(bufnr) == 1
        and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ""
    if not exists and empty and pkg then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
            "package " .. pkg,
            "",
            'import "testing"',
            "",
        })
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        notify("New " .. vim.fn.fnamemodify(target, ":t") .. " (not saved yet)")
    end
end

return M
