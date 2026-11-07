-- Space j: the JSON of the log line under the cursor, drawn in a float
-- next to it with the keys sorted and nested objects indented, so a zap /
-- slog line from the `server` window reads like a document. Enter on a
-- line with `path.go:123` (the caller of the log entry) opens that place;
-- q or Esc closes. Lines without JSON are reported, not opened.
local M = {}

-- The JSON object in `line`: from the first `{` to the last `}` that
-- decodes; a prefix like a timestamp or a log level is skipped.
function M.extract(line)
    local start = line:find("{", 1, true)
    while start do
        local stop = line:find("}[^}]*$")
        while stop and stop > start do
            local ok, value = pcall(vim.json.decode, line:sub(start, stop))
            if ok and type(value) == "table" then
                return value
            end
            stop = line:sub(1, stop - 1):find("}[^}]*$")
        end
        start = line:find("{", start + 1, true)
    end
    return nil
end

local function sorted_keys(object)
    local keys = {}
    for key in pairs(object) do
        table.insert(keys, key)
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return keys
end

local function encode_scalar(value)
    if value == vim.NIL or value == nil then
        return "null"
    end
    if type(value) == "string" then
        return vim.json.encode(value)
    end
    return tostring(value)
end

-- The value as JSON lines, two spaces per level, keys sorted.
function M.pretty(value, indent, lines, suffix)
    indent = indent or ""
    lines = lines or {}
    suffix = suffix or ""
    if type(value) ~= "table" then
        table.insert(lines, indent .. encode_scalar(value) .. suffix)
        return lines
    end
    local is_list = vim.islist(value) and #value > 0 or (vim.tbl_isempty(value) and getmetatable(value) == nil and false)
    if vim.tbl_isempty(value) then
        table.insert(lines, indent .. (vim.islist(value) and "[]" or "{}") .. suffix)
        return lines
    end
    if is_list then
        table.insert(lines, indent .. "[")
        for index, item in ipairs(value) do
            M.pretty(item, indent .. "  ", lines, index < #value and "," or "")
        end
        table.insert(lines, indent .. "]" .. suffix)
        return lines
    end
    table.insert(lines, indent .. "{")
    local keys = sorted_keys(value)
    for index, key in ipairs(keys) do
        local item = value[key]
        local comma = index < #keys and "," or ""
        if type(item) == "table" and not vim.tbl_isempty(item) then
            local nested = M.pretty(item, indent .. "  ", {}, comma)
            nested[1] = indent .. "  " .. vim.json.encode(tostring(key)) .. ": " .. vim.trim(nested[1])
            vim.list_extend(lines, nested)
        else
            local shown = type(item) == "table" and (vim.islist(item) and "[]" or "{}") or encode_scalar(item)
            table.insert(lines, indent .. "  " .. vim.json.encode(tostring(key)) .. ": " .. shown .. comma)
        end
    end
    table.insert(lines, indent .. "}" .. suffix)
    return lines
end

-- "internal/order/service.go:42" in a line → path, line number.
function M.caller(line)
    local path, number = line:match("([%w_%.%-/]+%.go):(%d+)")
    if path then
        return path, tonumber(number)
    end
    return nil
end

-- The file of a caller: as given when it exists, else under `root`, else
-- the first file of the project whose path ends with it (zap logs the path
-- from the module, not from the repository).
function M.resolve(path, root)
    if vim.fn.filereadable(path) == 1 then
        return vim.fn.fnamemodify(path, ":p")
    end
    if vim.fn.filereadable(root .. "/" .. path) == 1 then
        return root .. "/" .. path
    end
    local found = vim.fn.globpath(root, "**/" .. path, true, true)
    return found[1]
end

local function close(win)
    if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
    end
end

function M.show(root)
    root = root or vim.fn.getcwd()
    local line = vim.api.nvim_get_current_line()
    local value = M.extract(line)
    if not value then
        vim.notify("No JSON object in this line", vim.log.levels.INFO)
        return
    end
    local lines = M.pretty(value)
    local width = 0
    for _, text in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(text))
    end
    width = math.min(width + 2, math.floor(vim.o.columns * 0.8))
    local height = math.min(#lines, math.floor(vim.o.lines * 0.8))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "json"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false
    local origin = vim.api.nvim_get_current_win()
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "cursor",
        row = 1,
        col = 0,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = " json · Enter on path.go:N opens it ",
        title_pos = "center",
    })
    vim.wo[win].wrap = false
    vim.wo[win].conceallevel = 0
    local function map(lhs, fn)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
    end
    map("q", function()
        close(win)
    end)
    map("<Esc>", function()
        close(win)
    end)
    map("<CR>", function()
        local path, number = M.caller(vim.api.nvim_get_current_line())
        local file = path and M.resolve(path, root)
        if not file then
            vim.notify(path and ("Not in the project: " .. path) or "No path.go:N on this line", vim.log.levels.INFO)
            return
        end
        close(win)
        if vim.api.nvim_win_is_valid(origin) then
            vim.api.nvim_set_current_win(origin)
        end
        vim.cmd.edit(vim.fn.fnameescape(file))
        vim.api.nvim_win_set_cursor(0, { number, 0 })
        vim.cmd("normal! zz")
    end)
    return win
end

return M
