-- Call graph of the Go symbol under the cursor.
--
-- Uses gopls call hierarchy (`textDocument/prepareCallHierarchy`, then
-- `callHierarchy/incomingCalls` or `callHierarchy/outgoingCalls`) to build a
-- bounded tree: who calls this function or method, transitively, or what it
-- calls. When the root is an interface method the concrete implementations
-- are attached as `impl` leaves, because gopls lists the dispatch sites as
-- callers of the interface method, not the implementations.
--
-- The tree is drawn in a floating window with a live source preview of the
-- selected call site on the right (see graph_view.lua). Enter jumps to the
-- call site, d to the declaration, q closes.

local M = {}

M.defaults = {
    max_depth = 3,
    max_children = 12,
    max_nodes = 160,
    timeout_ms = 10000,
    pure_ascii = false,
}

M.opts = vim.deepcopy(M.defaults)

-- ============================================================
-- Item helpers
-- ============================================================

local function item_key(item)
    local range = item.selectionRange or item.range
    return string.format("%s:%d:%d", item.uri, range.start.line, range.start.character)
end

local line_cache = {}

local function source_line(uri, row)
    local bufnr = vim.fn.bufnr(vim.uri_to_fname(uri))
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        return (vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]) or ""
    end

    local path = vim.uri_to_fname(uri)
    local lines = line_cache[path]
    if not lines then
        local ok, content = pcall(vim.fn.readfile, path)
        lines = ok and content or {}
        line_cache[path] = lines
    end
    return lines[row + 1] or ""
end

-- gopls names a method only by its identifier; recover the receiver from
-- the declaration line so `(*Memory).Save` and `(Postgres).Save` differ.
function M.qualified_name(item)
    local name = item.name or "?"
    local range = item.selectionRange or item.range
    local line = source_line(item.uri, range.start.line)

    local suffix = "%s*%)%s*" .. vim.pesc(name) .. "[%s%(%[]"
    local receiver = line:match("^%s*func%s*%(%s*[%w_]+%s+(%*?[%w_%.%[%]]+)" .. suffix)
        or line:match("^%s*func%s*%(%s*(%*?[%w_%.%[%]]+)" .. suffix)
    if receiver then
        return "(" .. receiver .. ")." .. name
    end

    -- An interface method has no receiver; take the interface name from the
    -- enclosing type declaration when the file is loaded.
    local bufnr = vim.fn.bufnr(vim.uri_to_fname(item.uri))
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        local ok, node = pcall(vim.treesitter.get_node, {
            bufnr = bufnr,
            pos = { range.start.line, range.start.character },
        })
        local inside_interface = false
        while ok and node do
            local kind = node:type()
            if kind == "interface_type" then
                inside_interface = true
            elseif kind == "type_spec" and inside_interface then
                local type_name = node:field("name")[1]
                if type_name then
                    return vim.treesitter.get_node_text(type_name, bufnr) .. "." .. name
                end
                break
            elseif kind == "function_declaration" or kind == "method_declaration" then
                break
            end
            node = node:parent()
        end
    end

    return name
end

function M.package_of(item)
    local detail = item.detail or ""
    local package_path = detail:match("^(.-)%s+•") or detail
    return vim.fs.basename(package_path)
end

local function location_text(uri, row)
    return string.format("%s:%d", vim.fs.basename(vim.uri_to_fname(uri)), row + 1)
end

-- ============================================================
-- Asynchronous graph build
-- ============================================================

local function new_node(item, relation)
    local range = item.selectionRange or item.range
    return {
        item = item,
        key = item_key(item),
        name = M.qualified_name(item),
        package = M.package_of(item),
        relation = relation,
        decl = { uri = item.uri, line = range.start.line + 1, col = range.start.character },
        site = nil,
        children = {},
        truncated = false,
        recursive = false,
    }
end

local function attach_implementations(client, bufnr, root, params, finish)
    if not client:supports_method("textDocument/implementation") then
        finish()
        return
    end

    client:request("textDocument/implementation", params, function(err, result)
        if not err and vim.islist(result) then
            for _, location in ipairs(result) do
                local uri = location.uri or location.targetUri
                local range = location.range or location.targetSelectionRange
                if uri and range then
                    local item = {
                        name = root.item.name,
                        detail = root.item.detail,
                        uri = uri,
                        range = range,
                        selectionRange = range,
                    }
                    local node = new_node(item, "impl")
                    node.site = { uri = uri, line = range.start.line + 1, col = range.start.character }
                    table.insert(root.children, node)
                end
            end
        end
        finish()
    end, bufnr)
end

-- Build the graph for the symbol at `params` in `bufnr`.
-- direction: "in" (callers) or "out" (callees). Calls `callback(root, err)`.
function M.build(bufnr, params, direction, user_opts, callback)
    local opts = vim.tbl_deep_extend("force", M.opts, user_opts or {})
    local client = nil
    for _, candidate in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        if candidate:supports_method("textDocument/prepareCallHierarchy") then
            client = candidate
            break
        end
    end
    if not client then
        callback(nil, "no LSP client with call hierarchy support")
        return
    end

    local method = direction == "out"
        and "callHierarchy/outgoingCalls"
        or "callHierarchy/incomingCalls"

    local total = 1
    local pending = 0
    local finished = false
    local root

    local function finish(err)
        if finished then
            return
        end
        finished = true
        line_cache = {}
        if root then
            -- Implementations arrive asynchronously; keep them after callers.
            local calls, impls = {}, {}
            for _, child in ipairs(root.children) do
                table.insert(child.relation == "impl" and impls or calls, child)
            end
            root.children = vim.list_extend(calls, impls)
        end
        callback(root, err)
    end

    local function done_one()
        pending = pending - 1
        if pending == 0 then
            finish()
        end
    end

    local expand

    local function add_children(node, depth, path, calls)
        table.sort(calls, function(a, b)
            local ia = direction == "out" and a.to or a.from
            local ib = direction == "out" and b.to or b.from
            if ia.uri == ib.uri then
                return (ia.selectionRange or ia.range).start.line
                    < (ib.selectionRange or ib.range).start.line
            end
            return ia.uri < ib.uri
        end)

        for index, call in ipairs(calls) do
            if index > opts.max_children or total >= opts.max_nodes then
                node.truncated = true
                break
            end

            local item = direction == "out" and call.to or call.from
            local child = new_node(item, direction)
            child.sites = #call.fromRanges
            local site_uri = direction == "out" and node.item.uri or item.uri
            local first = call.fromRanges[1]
            if first then
                child.site = {
                    uri = site_uri,
                    line = first.start.line + 1,
                    col = first.start.character,
                }
            end

            total = total + 1
            table.insert(node.children, child)

            if path[child.key] then
                child.recursive = true
            elseif depth + 1 < opts.max_depth then
                local next_path = vim.tbl_extend("force", path, { [child.key] = true })
                expand(child, depth + 1, next_path)
            end
        end
    end

    expand = function(node, depth, path)
        pending = pending + 1
        local ok = client:request(method, { item = node.item }, function(err, result)
            if not err and vim.islist(result) then
                add_children(node, depth, path, result)
            end
            done_one()
        end, bufnr)
        if not ok then
            done_one()
        end
    end

    client:request("textDocument/prepareCallHierarchy", params, function(err, result)
        if err or not vim.islist(result) or #result == 0 then
            finish(err and (err.message or tostring(err)) or "no callable symbol under the cursor")
            return
        end

        root = new_node(result[1], "root")
        root.direction = direction

        pending = pending + 1
        expand(root, 0, { [root.key] = true })

        if direction ~= "out" then
            pending = pending + 1
            attach_implementations(client, bufnr, root, params, done_one)
        end
        done_one()
    end, bufnr)

    vim.defer_fn(function()
        finish(root and nil or "call hierarchy request timed out")
    end, opts.timeout_ms)
end

-- ============================================================
-- Rendering
-- ============================================================

local glyphs = {
    unicode = { branch = "├─ ", last = "└─ ", pipe = "│  ", blank = "   " },
    ascii = { branch = "|- ", last = "`- ", pipe = "|  ", blank = "   " },
}

local relation_marker = {
    ["in"] = "",
    out = "",
    impl = "impl ",
}

local function count_nodes(node, counts)
    counts = counts or { calls = 0, impl = 0, recursive = 0, truncated = 0 }
    for _, child in ipairs(node.children) do
        if child.relation == "impl" then
            counts.impl = counts.impl + 1
        else
            counts.calls = counts.calls + 1
        end
        if child.recursive then
            counts.recursive = counts.recursive + 1
        end
        count_nodes(child, counts)
    end
    if node.truncated then
        counts.truncated = counts.truncated + 1
    end
    return counts
end

function M.render(root, user_opts)
    local opts = vim.tbl_deep_extend("force", M.opts, user_opts or {})
    local set = opts.pure_ascii and glyphs.ascii or glyphs.unicode
    local ellipsis = opts.pure_ascii and "..." or "…"

    local rows = {}

    local function label_of(node)
        local text = node.name
        if node.package ~= "" then
            text = node.package .. "." .. text
        end
        return text
    end

    local function add_row(prefix, connector, node)
        local marker = relation_marker[node.relation] or ""
        local label = label_of(node)
        local text = prefix .. connector .. marker .. label
        local highlights = {}
        local glyph_width = #prefix + #connector
        if glyph_width > 0 then
            table.insert(highlights, { "Comment", 0, glyph_width })
        end
        if #marker > 0 then
            table.insert(highlights, { "DiagnosticOk", glyph_width, glyph_width + #marker })
        end
        local name_start = glyph_width + #marker
        if node.package ~= "" then
            table.insert(highlights, { "Comment", name_start, name_start + #node.package + 1 })
            name_start = name_start + #node.package + 1
        end
        table.insert(highlights, { node.relation == "root" and "Title" or "Function", name_start, #text })

        local notes = {}
        if node.sites and node.sites > 1 then
            table.insert(notes, string.format("x%d", node.sites))
        end
        if node.recursive then
            table.insert(notes, "recursive")
        end
        if node.truncated then
            table.insert(notes, ellipsis)
        end
        if #notes > 0 then
            local note = "  (" .. table.concat(notes, ", ") .. ")"
            table.insert(highlights, { "Comment", #text, #text + #note })
            text = text .. note
        end

        table.insert(rows, { text = text, node = node, highlights = highlights })
    end

    add_row("", "", root)
    local function render_children(node, prefix)
        for index, child in ipairs(node.children) do
            local last = index == #node.children
            add_row(prefix, last and set.last or set.branch, child)
            render_children(child, prefix .. (last and set.blank or set.pipe))
        end
    end
    render_children(root, "")

    local width = 0
    for _, row in ipairs(rows) do
        width = math.max(width, vim.fn.strdisplaywidth(row.text))
    end

    local lines, meta = {}, {}
    for index, row in ipairs(rows) do
        local node = row.node
        local text = row.text
        local location = index == 1 and node.decl or (node.site or node.decl)
        if location then
            local padding = width - vim.fn.strdisplaywidth(text) + 2
            text = text .. string.rep(" ", padding)
            local suffix = location_text(location.uri, location.line - 1)
            table.insert(row.highlights, { "LineNr", #text, #text + #suffix })
            text = text .. suffix
        end
        table.insert(lines, text)
        table.insert(meta, {
            site = node.site,
            decl = node.decl,
            relation = node.relation,
            highlights = row.highlights,
        })
    end

    local counts = count_nodes(root)
    local summary
    if root.direction == "out" then
        summary = string.format("%d callee%s", counts.calls, counts.calls == 1 and "" or "s")
    else
        summary = string.format("%d caller%s", counts.calls, counts.calls == 1 and "" or "s")
    end
    if counts.impl > 0 then
        summary = summary .. string.format(", %d impl", counts.impl)
    end
    if counts.recursive > 0 then
        summary = summary .. string.format(", %d recursive", counts.recursive)
    end
    if counts.truncated > 0 then
        summary = summary .. ", truncated"
    end
    summary = summary .. string.format(", depth %d", opts.max_depth)

    return lines, meta, summary
end

-- ============================================================
-- UI
-- ============================================================

local graph_view = require("graph_view")

local function as_target(location)
    if not location then
        return nil
    end
    return {
        path = vim.uri_to_fname(location.uri),
        line = location.line,
        col = location.col or 0,
    }
end

function M.clamp_depth(depth)
    return math.max(1, math.min(depth or M.opts.max_depth, 8))
end

local function open_view(lines, meta, summary, title, extra)
    extra = extra or {}
    local entries = {}
    for index, entry in ipairs(meta) do
        local site = as_target(entry.site)
        local decl = as_target(entry.decl)
        entries[index] = {
            highlights = entry.highlights,
            preview = site or decl,
            jumps = { ["<CR>"] = site or decl, d = decl },
        }
    end

    return graph_view.open({
        title = title,
        footer = summary,
        filetype = "gocalls",
        lines = lines,
        entries = entries,
        keys = extra.keys,
        cursor_row = extra.cursor_row,
    })
end

function M.show(direction, user_opts)
    local bufnr = vim.api.nvim_get_current_buf()
    local client = nil
    for _, candidate in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        if candidate:supports_method("textDocument/prepareCallHierarchy") then
            client = candidate
            break
        end
    end
    if not client then
        vim.notify("Call graph needs an attached gopls client", vim.log.levels.INFO)
        return
    end

    local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
    local source_win = vim.api.nvim_get_current_win()

    -- The view can be rebuilt in place: +/- change the depth, o flips the
    -- direction. The root position is captured once, so the cursor may move.
    local function open(current_direction, opts, cursor_row)
        opts = vim.tbl_extend("force", M.opts, opts or {})
        opts.max_depth = M.clamp_depth(opts.max_depth)

        M.build(bufnr, params, current_direction, opts, function(root, err)
            if not root then
                vim.notify("Call graph: " .. tostring(err), vim.log.levels.WARN)
                return
            end
            local lines, meta, summary = M.render(root, opts)
            local title = (current_direction == "out" and "callees of " or "callers of ") .. root.name
            summary = summary .. "  [+/-] depth [o] flip [d] decl"

            local function reopen(next_direction, next_depth, row)
                return function(ctx)
                    ctx.close()
                    if vim.api.nvim_win_is_valid(source_win) then
                        vim.api.nvim_set_current_win(source_win)
                    end
                    open(next_direction, vim.tbl_extend("force", opts, { max_depth = next_depth }), row or ctx.row)
                end
            end

            open_view(lines, meta, summary, title, {
                cursor_row = cursor_row,
                keys = {
                    ["+"] = reopen(current_direction, opts.max_depth + 1),
                    ["-"] = reopen(current_direction, opts.max_depth - 1),
                    o = reopen(current_direction == "out" and "in" or "out", opts.max_depth, 1),
                },
            })
        end)
    end

    open(direction, user_opts)
end

function M.setup(user_opts)
    M.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts or {})

    vim.api.nvim_create_user_command("GoCallers", function(command)
        M.show("in", { pure_ascii = command.bang or M.opts.pure_ascii })
    end, { bang = true, desc = "Call graph: who calls the symbol under the cursor" })

    vim.api.nvim_create_user_command("GoCallees", function(command)
        M.show("out", { pure_ascii = command.bang or M.opts.pure_ascii })
    end, { bang = true, desc = "Call graph: what the symbol under the cursor calls" })
end

return M
