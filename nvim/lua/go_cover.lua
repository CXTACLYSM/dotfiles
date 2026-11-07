-- Space gc: test coverage of the package of the current file, drawn in the
-- sign column: a green bar on a line a test ran, a red one on a line no
-- test reached; the notification carries the percentage. Space gc again
-- clears the bars (Space gC clears them from every file). `go test
-- -coverprofile` runs in the background from the module root; the bars
-- follow the file when it is opened later, until the next run or clear.
local M = {}

M.namespace = vim.api.nvim_create_namespace("go_cover")

-- Import path of the module → { ["rel/path.go"] = { [line] = true/false } }
-- (true: covered).
M.state = { files = {}, root = nil, package = nil, percent = nil }

local function normalize(path)
    local absolute = vim.fs.normalize(vim.fs.abspath(path))
    return vim.uv.fs_realpath(absolute) or absolute
end

-- The module path from go.mod.
function M.module_path(root)
    for _, line in ipairs(vim.fn.readfile(root .. "/go.mod")) do
        local path = line:match("^module%s+(%S+)")
        if path then
            return path
        end
    end
    return nil
end

-- A cover profile → { ["module/path/file.go"] = { [line] = covered } }.
-- A line is covered when any block over it ran; the blocks are
-- "file:startLine.col,endLine.col statements count".
function M.parse(profile_lines)
    local files = {}
    for _, line in ipairs(profile_lines) do
        local file, first, last, count = line:match("^(.-):(%d+)%.%d+,(%d+)%.%d+ %d+ (%d+)$")
        if file then
            files[file] = files[file] or {}
            for number = tonumber(first), tonumber(last) do
                files[file][number] = files[file][number] or tonumber(count) > 0
            end
        end
    end
    return files
end

-- The coverage of a buffer, by its path relative to the module.
function M.lines_of(buffer)
    local name = vim.api.nvim_buf_get_name(buffer)
    if name == "" or not M.state.root then
        return nil
    end
    local rel = vim.fs.relpath(M.state.root, normalize(name))
    return rel and M.state.files[M.state.module .. "/" .. rel] or nil
end

local function define_highlights()
    vim.api.nvim_set_hl(0, "GoCoverHit", { link = "Added", default = true })
    vim.api.nvim_set_hl(0, "GoCoverMiss", { link = "Removed", default = true })
end

-- Draw the bars of a buffer from the state (nothing when it has none).
function M.draw(buffer)
    vim.api.nvim_buf_clear_namespace(buffer, M.namespace, 0, -1)
    local lines = M.lines_of(buffer)
    if not lines then
        return 0
    end
    define_highlights()
    local last = vim.api.nvim_buf_line_count(buffer)
    local drawn = 0
    for number, covered in pairs(lines) do
        if number <= last then
            vim.api.nvim_buf_set_extmark(buffer, M.namespace, number - 1, 0, {
                sign_text = "▎",
                sign_hl_group = covered and "GoCoverHit" or "GoCoverMiss",
                priority = 5,
            })
            drawn = drawn + 1
        end
    end
    return drawn
end

function M.draw_all()
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buffer) then
            M.draw(buffer)
        end
    end
end

function M.clear()
    M.state = { files = {}, root = nil, package = nil, percent = nil }
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buffer) then
            vim.api.nvim_buf_clear_namespace(buffer, M.namespace, 0, -1)
        end
    end
end

-- Covered and uncovered lines of a buffer.
function M.counts(buffer)
    local hit, miss = 0, 0
    for _, covered in pairs(M.lines_of(buffer) or {}) do
        if covered then
            hit = hit + 1
        else
            miss = miss + 1
        end
    end
    return hit, miss
end

-- Run the tests of the package of `file` with a profile; done(err) after
-- the bars are drawn.
function M.run(file, done)
    local go_tasks = require("go_tasks")
    local root = go_tasks.module_root(file)
    local module = M.module_path(root)
    if not module then
        vim.notify("No go.mod above " .. file, vim.log.levels.WARN)
        return
    end
    local package = go_tasks.package_pattern(vim.fs.dirname(normalize(file)), root) or "."
    local profile = vim.fn.tempname()
    local command = { "go", "test", "-count=1", "-covermode=count", "-coverprofile=" .. profile, package }
    vim.notify("Coverage: " .. package .. " …", vim.log.levels.INFO)
    vim.system(command, { cwd = root, text = true }, vim.schedule_wrap(function(result)
        local output = (result.stdout or "") .. (result.stderr or "")
        if result.code ~= 0 and not output:find("coverage:", 1, true) then
            vim.notify("go test failed:\n" .. vim.trim(output), vim.log.levels.ERROR)
            if done then
                done(output)
            end
            return
        end
        local profile_lines = vim.fn.filereadable(profile) == 1 and vim.fn.readfile(profile) or {}
        vim.fn.delete(profile)
        M.state = {
            files = M.parse(profile_lines),
            root = root,
            module = module,
            package = package,
            percent = output:match("coverage: ([%d%.]+)%%"),
        }
        M.draw_all()
        local hit, miss = M.counts(vim.fn.bufnr(file))
        vim.notify(string.format("Coverage %s: %s%% of statements; this file: %d lines covered, %d not",
            package, M.state.percent or "?", hit, miss), vim.log.levels.INFO)
        if done then
            done(nil)
        end
    end))
end

-- Space gc: run for the current file, or clear when its bars are shown.
function M.toggle()
    local buffer = vim.api.nvim_get_current_buf()
    local file = vim.api.nvim_buf_get_name(buffer)
    if file == "" or vim.bo[buffer].filetype ~= "go" then
        vim.notify("Coverage is for a saved Go file", vim.log.levels.INFO)
        return
    end
    if M.lines_of(buffer) then
        M.clear()
        return
    end
    if vim.bo[buffer].modified then
        vim.cmd.write()
    end
    M.run(file)
end

function M.setup()
    vim.api.nvim_create_autocmd("BufReadPost", {
        group = vim.api.nvim_create_augroup("go_cover", { clear = true }),
        pattern = "*.go",
        callback = function(event)
            if M.state.root then
                M.draw(event.buf)
            end
        end,
    })
end

return M
