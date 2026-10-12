-- Large-file hygiene.
--
-- Generated Go (protobuf, mocks, embedded fixtures) can run to hundreds of
-- thousands of lines. Tree-sitter highlighting, semantic tokens and
-- CursorHold document highlights are each proportional to file size and make
-- such buffers sluggish. A buffer over the thresholds is marked before it is
-- read, and init.lua skips those features for it; gopls still attaches, so
-- definitions, references and completion keep working.

local M = {}

M.defaults = {
    max_bytes = 1024 * 1024,
    max_lines = 10000,
}

M.opts = vim.deepcopy(M.defaults)

-- Decide from size and line count. `stat` and `lines` are injectable for
-- tests; by default the file on disk is inspected.
function M.is_big(path, opts, stat, line_count)
    opts = opts or M.opts
    stat = stat or (path ~= "" and vim.uv.fs_stat(path)) or nil
    if not stat then
        return false
    end
    if stat.size > opts.max_bytes then
        return true
    end
    if line_count and line_count > opts.max_lines then
        return true
    end
    return false
end

function M.mark(bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)
    if M.is_big(path, M.opts) then
        vim.b[bufnr].big_file = true
        return true
    end
    return false
end

function M.is_marked(bufnr)
    return vim.b[bufnr].big_file == true
end

-- Line-count check for buffers that arrive without a file (or after a big
-- paste); run once the buffer is loaded.
function M.mark_by_lines(bufnr)
    if vim.api.nvim_buf_line_count(bufnr) > M.opts.max_lines then
        vim.b[bufnr].big_file = true
        return true
    end
    return false
end

function M.setup(user_opts)
    M.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts or {})

    local group = vim.api.nvim_create_augroup("big_file", { clear = true })

    vim.api.nvim_create_autocmd("BufReadPre", {
        group = group,
        callback = function(event)
            M.mark(event.buf)
        end,
    })

    vim.api.nvim_create_autocmd("BufReadPost", {
        group = group,
        callback = function(event)
            if not M.is_marked(event.buf) and M.mark_by_lines(event.buf) then
                -- Marked late: undo what FileType may already have started.
                pcall(vim.treesitter.stop, event.buf)
            end
            if M.is_marked(event.buf) then
                vim.bo[event.buf].syntax = ""
                vim.bo[event.buf].swapfile = false
                vim.notify(
                    string.format(
                        "Large file: Tree-sitter, semantic tokens and reference highlights are off (%s)",
                        vim.fs.basename(vim.api.nvim_buf_get_name(event.buf))
                    ),
                    vim.log.levels.INFO
                )
            end
        end,
    })
end

return M
