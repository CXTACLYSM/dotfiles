-- Space ce: where the errors of the function under the cursor go. The
-- callers tree of gopls (as gre), each function labelled by what it does
-- with the error it receives: turns it into a gRPC status (`status.Error`,
-- `status.Errorf`, `status.New` with its codes — the branch ends there),
-- wraps it (`fmt.Errorf("…: %w", err)`, the message shown), checks it
-- (`errors.Is` / `errors.As`), passes it up (`return …, err`), logs it
-- (`log.Error`, `.Errorw`, `.Warn` without returning), panics, or handles
-- it some other way. The root shows what its own errors are made of. Read
-- from the source text, not the types: a label is a hint for the eye, the
-- preview on the right shows the code.
local M = {}

M.opts = { max_depth = 6 }

local function file_lines(path)
    local existing = vim.fn.bufnr(path)
    if existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) then
        return vim.api.nvim_buf_get_lines(existing, 0, -1, false)
    end
    return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
end

local function unique(list)
    local seen, out = {}, {}
    for _, item in ipairs(list) do
        if not seen[item] then
            seen[item] = true
            table.insert(out, item)
        end
    end
    return out
end

-- The label of a function body: { kind, detail, checks }.
-- kind: "grpc", "wraps", "passes", "logs", "panics", "handles".
function M.classify(text)
    local codes = {}
    for code in text:gmatch("codes%.(%u[%w]*)") do
        table.insert(codes, code)
    end
    for code in text:gmatch("connect%.Code(%u[%w]*)") do
        table.insert(codes, code)
    end
    local status = text:find("status%.%u%a*%(") or text:find("connect%.NewError%(")
    local checks = text:find("errors%.Is%(") ~= nil or text:find("errors%.As%(") ~= nil
    if status then
        codes = unique(codes)
        return { kind = "grpc", detail = #codes > 0 and table.concat(codes, ", ") or "status", checks = checks }
    end
    local messages = {}
    for message in text:gmatch('fmt%.Errorf%(%s*"([^"]-)%s*:?%s*%%w') do
        table.insert(messages, message)
    end
    if text:find("errors%.Join%(") then
        table.insert(messages, "errors.Join")
    end
    if #messages > 0 then
        messages = unique(messages)
        local shown = { messages[1] }
        if messages[2] then
            table.insert(shown, messages[2])
        end
        local detail = '"' .. table.concat(shown, '", "') .. '"'
        if #messages > 2 then
            detail = detail .. string.format(" +%d", #messages - 2)
        end
        return { kind = "wraps", detail = detail, checks = checks }
    end
    if text:find("return[^\n]*%f[%w_]err%f[^%w_]") then
        return { kind = "passes", detail = "", checks = checks }
    end
    if text:find("panic%(%s*err") then
        return { kind = "panics", detail = "", checks = checks }
    end
    if text:find("%.Error[fw]?%(") or text:find("%.Warn[fw]?%(") or text:find("log%.Print") or text:find("slog%.") then
        return { kind = "logs", detail = "", checks = checks }
    end
    return { kind = "handles", detail = "", checks = checks }
end

-- The source text of the function of a call hierarchy item: gopls's range
-- covers the name only, so the declaration around it is found in the
-- file's syntax tree; the lines of the range when there is none.
function M.item_text(item)
    local lines = file_lines(vim.uri_to_fname(item.uri))
    local text = table.concat(lines, "\n")
    local row = item.range.start.line
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, "go")
    if ok and parser then
        local tree = parser:parse()[1]
        local node = tree and tree:root():named_descendant_for_range(row, item.range.start.character, row, item.range.start.character)
        while node do
            local kind = node:type()
            if kind == "function_declaration" or kind == "method_declaration" or kind == "func_literal" then
                return vim.treesitter.get_node_text(node, text)
            end
            node = node:parent()
        end
    end
    return table.concat(vim.list_slice(lines, row + 1, item.range["end"].line + 1), "\n")
end

-- The package of the file of an item (gopls's `detail` of a caller names
-- the callee's package).
function M.item_package(item)
    for _, line in ipairs(file_lines(vim.uri_to_fname(item.uri))) do
        local name = line:match("^package%s+([%w_]+)")
        if name then
            return name
        end
    end
    return ""
end

-- Label every node of a callers tree; a node that turns the error into a
-- status keeps no callers (the error stops there as a status).
function M.label(root)
    local function walk(node)
        node.flow = M.classify(M.item_text(node.item))
        node.package = M.item_package(node.item)
        if node.flow.kind == "grpc" and node.relation ~= "root" then
            node.children = {}
            node.truncated = false
        else
            for _, child in ipairs(node.children) do
                walk(child)
            end
        end
    end
    walk(root)
    return root
end

local label_text = {
    grpc = "→ gRPC ",
    wraps = "wraps ",
    passes = "passes up",
    logs = "logs, stops",
    panics = "panics",
    handles = "handles",
}

local label_hl = {
    grpc = "DiagnosticOk",
    wraps = "String",
    passes = "Comment",
    logs = "DiagnosticWarn",
    panics = "DiagnosticError",
    handles = "DiagnosticInfo",
}

local glyphs = { branch = "├─ ", last = "└─ ", pipe = "│  ", blank = "   " }

-- Lines, entries (highlights, site, decl) and a summary for the view.
function M.render(root)
    local rows = {}
    local function add(prefix, connector, node)
        local name = node.package ~= "" and (node.package .. "." .. node.name) or node.name
        local text = prefix .. connector .. name
        local highlights = {}
        if #prefix + #connector > 0 then
            table.insert(highlights, { "Comment", 0, #prefix + #connector })
        end
        table.insert(highlights, { node.relation == "root" and "Title" or "Function", #prefix + #connector, #text })
        local flow = node.flow or { kind = "handles", detail = "" }
        local label = (node.relation == "root" and "raises: " or "") .. label_text[flow.kind] .. flow.detail
        if flow.checks then
            label = label .. " · checks"
        end
        if node.relation == "impl" then
            label = "impl · " .. label
        end
        local start = #text + 2
        text = text .. "  " .. label
        table.insert(highlights, { label_hl[flow.kind], start, #text })
        local notes = {}
        if node.recursive then
            table.insert(notes, "recursive")
        end
        if node.truncated then
            table.insert(notes, "…")
        end
        if #notes > 0 then
            local note = "  (" .. table.concat(notes, ", ") .. ")"
            table.insert(highlights, { "Comment", #text, #text + #note })
            text = text .. note
        end
        table.insert(rows, { text = text, node = node, highlights = highlights })
    end
    add("", "", root)
    local function children(node, prefix)
        for index, child in ipairs(node.children) do
            local last = index == #node.children
            add(prefix, last and glyphs.last or glyphs.branch, child)
            children(child, prefix .. (last and glyphs.blank or glyphs.pipe))
        end
    end
    children(root, "")

    local width = 0
    for _, row in ipairs(rows) do
        width = math.max(width, vim.fn.strdisplaywidth(row.text))
    end
    local lines, entries = {}, {}
    local counts = { grpc = 0, total = 0 }
    for index, row in ipairs(rows) do
        local node = row.node
        local location = index == 1 and node.decl or (node.site or node.decl)
        local text = row.text
        if location then
            text = text .. string.rep(" ", width - vim.fn.strdisplaywidth(text) + 2)
            local suffix = string.format("%s:%d", vim.fn.fnamemodify(vim.uri_to_fname(location.uri), ":~:."), location.line)
            table.insert(row.highlights, { "LineNr", #text, #text + #suffix })
            text = text .. suffix
        end
        table.insert(lines, text)
        table.insert(entries, { highlights = row.highlights, site = node.site, decl = node.decl })
        if index > 1 then
            counts.total = counts.total + 1
            if node.flow and node.flow.kind == "grpc" then
                counts.grpc = counts.grpc + 1
            end
        end
    end
    local summary = string.format("%d caller%s, %d end%s as a gRPC status  [d] decl",
        counts.total, counts.total == 1 and "" or "s", counts.grpc, counts.grpc == 1 and "" or "s")
    return lines, entries, summary
end

-- The position of the name of the function around the cursor, for the
-- call hierarchy (gopls wants an identifier).
function M.function_position(bufnr, row, col)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "go")
    if not ok or not parser then
        return nil
    end
    local tree = parser:parse()[1]
    local node = tree and tree:root():named_descendant_for_range(row, col, row, col)
    while node do
        local kind = node:type()
        if kind == "function_declaration" or kind == "method_declaration" then
            local name = node:field("name")[1]
            local line, character = name:range()
            return line, character, vim.treesitter.get_node_text(name, bufnr)
        end
        node = node:parent()
    end
    return nil
end

function M.show(user_opts)
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line, character, name = M.function_position(bufnr, cursor[1] - 1, cursor[2])
    if not line then
        return vim.notify("Put the cursor inside a function", vim.log.levels.INFO)
    end
    local client = vim.lsp.get_clients({ bufnr = bufnr, name = "gopls" })[1]
    if not client then
        return vim.notify("Error flow needs gopls", vim.log.levels.INFO)
    end
    local go_calls = require("go_calls")
    local source_win = vim.api.nvim_get_current_win()
    local params = {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        position = { line = line, character = character },
    }
    local opts = vim.tbl_extend("force", M.opts, user_opts or {})
    go_calls.build(bufnr, params, "in", { max_depth = opts.max_depth }, function(root, err)
        if not root then
            return vim.notify("Error flow: " .. tostring(err), vim.log.levels.WARN)
        end
        M.label(root)
        local lines, entries, summary = M.render(root)
        local graph_view = require("graph_view")
        for _, entry in ipairs(entries) do
            local function target(location)
                return location and { path = vim.uri_to_fname(location.uri), line = location.line, col = location.col or 0 } or nil
            end
            local site, decl = target(entry.site), target(entry.decl)
            entry.preview = site or decl
            entry.jumps = { ["<CR>"] = site or decl, d = decl }
        end
        graph_view.open({
            title = "errors of " .. name,
            footer = summary,
            filetype = "gocalls",
            lines = lines,
            entries = entries,
            source_win = source_win,
        })
    end)
end

return M
