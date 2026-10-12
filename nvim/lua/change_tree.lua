-- Change tree: what changed against HEAD and what depends on it.
--
-- The roots are Go declarations touched by `git diff HEAD` and untracked
-- .go files, found exactly by the AST helper in tools/goindex (without a
-- git repository: the declaration under the cursor). gopls then expands
-- every root into the code that depends on it (callers, references, tests,
-- implementations, interface contracts) and the code it uses (calls, types,
-- values, fields). The result is drawn in graph_view: the tree on the left,
-- the code of the selected node on the right, Enter jumps into it.
--
-- Space ct builds and opens the tree. Building after every :w is off by
-- default; Space cT (:ChangeTreeAuto) toggles it, and the finished tree is
-- reopened with :ChangeTree! without rebuilding.

local go_index = require("change_tree.go_index")
local semantic_graph = require("change_tree.semantic_graph")
local go_lsp = require("go_lsp")

local M = {}

M.defaults = {
    -- Build the tree after every :w of a Go buffer.
    auto = false,
    debounce_ms = 1500,
    -- AST helper binary; install.sh builds it from tools/goindex.
    helper = nil,
    helper_timeout_ms = 30000,
    -- Expansion limits passed to the graph builder.
    graph = {
        outbound_depth = 3,
        max_nodes = 72,
        max_root_occurrences = 256,
        max_dependency_occurrences = 28,
        max_same_package_tests = 4,
        max_non_test_callers = 5,
        max_other_tests = 2,
        max_parallel_implementations = 3,
        lsp_timeout_ms = 6000,
        allow_incomplete = true,
    },
    -- How deep the drawn tree follows edges below each root.
    max_tree_depth = 3,
}

M.opts = vim.deepcopy(M.defaults)

local state = {
    last = nil,
    building = false,
    pending = nil,
    generation = 0,
    debounce = 0,
    cancel_token = nil,
}

local function notify(message, level)
    vim.notify(message, level or vim.log.levels.INFO, { title = "change tree" })
end

-- ============================================================
-- Tree rendering
-- ============================================================

-- Edges into a node: code that depends on it. Edges out of a node: code it
-- uses. Labels are the short tags drawn in front of each child.
local inbound = {
    caller = "caller",
    reference = "ref",
    test_oracle = "test",
    implementation = "impl",
    parallel_implementation = "impl",
    member_of = "member",
}

local outbound = {
    contract = "iface",
    calls = "calls",
    references_callable = "func",
    uses_contract_method = "method",
    uses_type = "type",
    uses_value = "value",
    uses_field = "field",
}

local order = {
    caller = 1, ref = 2, test = 3, impl = 4, member = 5,
    iface = 6, calls = 7, func = 8, method = 9, type = 10, value = 11, field = 12,
}

local function absolute(root, path)
    if not path or path == "" then
        return nil
    end
    if path:sub(1, 1) == "/" then
        return path
    end
    return root .. "/" .. path
end

local function node_target(graph, node)
    local symbol = node.symbol
    if symbol.deleted then
        return nil
    end
    local path = symbol.absolute_path
        or (node.file and node.file.absolute_path)
        or absolute(graph.root, symbol.path)
    return path and { path = path, line = symbol.start_line or 1, col = 0 } or nil
end

local function site_target(graph, occurrence)
    if not occurrence or not occurrence.path or not occurrence.line then
        return nil
    end
    return {
        path = absolute(graph.root, occurrence.path),
        line = occurrence.line,
        col = math.max((occurrence.col or 1) - 1, 0),
    }
end

-- Children of a node, dependents first, each { tag, node, edge }.
local function children(graph, node)
    local result = {}
    for _, edge in ipairs(graph.edges) do
        local tag, other
        if edge.to == node.id and inbound[edge.relation] then
            tag, other = inbound[edge.relation], edge.from
        elseif edge.from == node.id and outbound[edge.relation] then
            tag, other = outbound[edge.relation], edge.to
        end
        local child = tag and graph.node_by_id[other]
        if child then
            table.insert(result, { tag = tag, node = child, edge = edge })
        end
    end

    table.sort(result, function(a, b)
        if order[a.tag] ~= order[b.tag] then
            return order[a.tag] < order[b.tag]
        end
        local sa, sb = a.node.symbol, b.node.symbol
        if (sa.path or "") ~= (sb.path or "") then
            return (sa.path or "") < (sb.path or "")
        end
        return (sa.start_line or 0) < (sb.start_line or 0)
    end)

    -- One child per node and tag: a function calling the root twice is
    -- one caller.
    local seen, unique = {}, {}
    for _, child in ipairs(result) do
        local key = child.tag .. "|" .. child.node.id
        if not seen[key] then
            seen[key] = true
            table.insert(unique, child)
        end
    end
    return unique
end

local function symbol_name(symbol)
    return symbol.qualified or symbol.name or "?"
end

-- Lines, graph_view entries and a footer summary for a built graph.
function M.render(graph, opts)
    opts = opts or M.opts
    local rows = {}
    -- Distinct nodes outside the changed roots, by direction.
    local root_ids, affected, uses = {}, {}, {}
    for _, root in ipairs(graph.roots) do
        root_ids[root.id] = true
    end

    local function add_row(text, highlights, target, site)
        table.insert(rows, {
            text = text,
            highlights = highlights,
            target = target,
            site = site,
        })
    end

    local function walk(node, prefix, depth, path)
        local kids = children(graph, node)
        for index, child in ipairs(kids) do
            local last = index == #kids
            local connector = last and "└─ " or "├─ "
            local tag = string.format("%-6s ", child.tag)
            local text = prefix .. connector .. tag .. symbol_name(child.node.symbol)
            local highlights = {
                { "Comment", 0, #prefix + #connector },
                { inbound[child.edge.relation] and "DiagnosticInfo" or "Comment", #prefix + #connector, #prefix + #connector + #tag },
            }

            if not root_ids[child.node.id] then
                if inbound[child.edge.relation] then
                    affected[child.node.id] = true
                else
                    uses[child.node.id] = true
                end
            end

            local repeated = path[child.node.id]
            if repeated then
                text = text .. " ↑"
            end
            add_row(text, highlights, node_target(graph, child.node), site_target(graph, child.edge.occurrence))

            if not repeated and depth < opts.max_tree_depth then
                path[child.node.id] = true
                walk(child.node, prefix .. (last and "   " or "│  "), depth + 1, path)
                path[child.node.id] = nil
            end
        end
    end

    for _, root in ipairs(graph.roots) do
        local symbol = root.symbol
        local marker = symbol.deleted and "✗ " or "Δ "
        local text = marker .. (symbol.kind or "") .. " " .. symbol_name(symbol)
        if symbol.deleted then
            text = text .. "  (deleted)"
        end
        add_row(text, {
            { symbol.deleted and "DiagnosticError" or "DiagnosticWarn", 0, #marker },
            { "Bold", #marker, #text },
        }, node_target(graph, root), nil)
        walk(root, "", 1, { [root.id] = true })
    end

    -- Locations right-aligned after the widest label, like the call graph.
    local width = 0
    for _, row in ipairs(rows) do
        width = math.max(width, vim.fn.strdisplaywidth(row.text))
    end

    local lines, entries = {}, {}
    for _, row in ipairs(rows) do
        local text = row.text
        local location = row.site or row.target
        if location then
            local relative = vim.fs.relpath(graph.root, location.path) or location.path
            local suffix = string.format("%s:%d", relative, location.line)
            text = text .. string.rep(" ", width - vim.fn.strdisplaywidth(text) + 2)
            table.insert(row.highlights, { "LineNr", #text, #text + #suffix })
            text = text .. suffix
        end
        table.insert(lines, text)
        table.insert(entries, {
            highlights = row.highlights,
            preview = row.site or row.target,
            jumps = { ["<CR>"] = row.site or row.target, d = row.target },
        })
    end

    local summary = string.format(
        "%d changed · %d affected · %d uses",
        #graph.roots,
        vim.tbl_count(affected),
        vim.tbl_count(uses)
    )
    if #(graph.externals or {}) > 0 then
        summary = summary .. string.format(" · %d external", #graph.externals)
    end
    if graph.truncated then
        summary = summary .. " · truncated"
    elseif graph.complete == false then
        summary = summary .. " · incomplete"
    end

    return lines, entries, summary
end

-- ============================================================
-- Building
-- ============================================================

local function normalize(path)
    if not path or path == "" then
        return nil
    end
    local absolute_path = vim.fs.normalize(vim.fs.abspath(path))
    return vim.uv.fs_realpath(absolute_path) or absolute_path
end

local function gopls_client(bufnr)
    return vim.lsp.get_clients({ bufnr = bufnr, name = "gopls" })[1]
end

local function project_root(bufnr, client)
    local root = client and client.config and client.config.root_dir
    return normalize(root) or go_lsp.root_for_buffer(bufnr)
end

-- Go buffers under root with unsaved edits: the helper reads files from
-- disk, so a tree built past them would describe a different program.
local function modified_go_buffers(root)
    local result = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr)
            and vim.bo[bufnr].filetype == "go"
            and vim.bo[bufnr].modified
        then
            local path = normalize(vim.api.nvim_buf_get_name(bufnr))
            if path and (path == root or path:sub(1, #root + 1) == root .. "/") then
                table.insert(result, vim.fs.relpath(root, path) or path)
            end
        end
    end
    table.sort(result)
    return result
end

local function finish()
    state.building = false
    state.cancel_token = nil
    if state.pending then
        local pending = state.pending
        state.pending = nil
        vim.schedule(function()
            M.build(pending.bufnr, pending.show)
        end)
    end
end

-- Build the tree for a Go buffer. show = true opens it when done (manual
-- build); otherwise a one-line summary is reported (build after :w).
function M.build(bufnr, show)
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "go" then
        if show then
            notify("The change tree is built from a Go buffer")
        end
        return
    end

    if state.building then
        state.pending = { bufnr = bufnr, show = show }
        return
    end

    local client = gopls_client(bufnr)
    if not client then
        if show then
            notify("The change tree needs an attached gopls client", vim.log.levels.WARN)
        end
        return
    end

    local root = project_root(bufnr, client)
    local unsaved = modified_go_buffers(root)
    if #unsaved > 0 then
        if show then
            notify("Save the Go buffers first: " .. table.concat(unsaved, ", "), vim.log.levels.WARN)
        end
        return
    end

    state.building = true
    state.generation = state.generation + 1
    local generation = state.generation
    state.cancel_token = { cancelled = false }

    local graph_opts = vim.tbl_extend("force", M.opts.graph, {
        bufnr = bufnr,
        client = client,
        root = root,
        cancel_token = state.cancel_token,
    })

    semantic_graph.build(graph_opts, function(graph, err)
        vim.schedule(function()
            if generation ~= state.generation then
                finish()
                return
            end

            if err or not graph then
                finish()
                if err == "cancelled" then
                    return
                end
                if tostring(err):find("no changed or enclosing", 1, true) then
                    if show then
                        notify("No Go changes against HEAD")
                    end
                    return
                end
                notify("Change tree failed: " .. tostring(err), show and vim.log.levels.ERROR or vim.log.levels.WARN)
                return
            end

            state.last = graph
            finish()

            if show then
                M.show()
            else
                local _, _, summary = M.render(graph)
                notify(summary .. "  (Space ct or :ChangeTree! to open)")
            end
        end)
    end)
end

-- ============================================================
-- Views
-- ============================================================

function M.show()
    local graph = state.last
    if not graph then
        notify("No change tree yet: Space ct builds it")
        return
    end
    local lines, entries, summary = M.render(graph)
    return require("graph_view").open({
        title = "change tree",
        footer = summary,
        filetype = "changetree",
        lines = lines,
        entries = entries,
    })
end

function M.open()
    M.build(vim.api.nvim_get_current_buf(), true)
end

-- The last built graph, nil before the first build.
function M.last()
    return state.last
end

function M.is_building()
    return state.building
end

local function open_scratch(name, text)
    vim.cmd("botright new")
    local bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    pcall(vim.api.nvim_buf_set_name, bufnr, name)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text, "\n", { plain = true }))
    vim.bo[bufnr].modifiable = false
end

local function with_last(name, format)
    return function()
        if not state.last then
            notify("No change tree yet: Space ct builds it")
            return
        end
        open_scratch(name, format(state.last))
    end
end

local function format_index(graph)
    local snapshot = graph.snapshot
    local lines = {
        "CHANGED DECLARATIONS",
        "====================",
        "root=" .. tostring(snapshot.root),
        "git_head=" .. tostring(snapshot.git_head),
        "",
    }
    for _, root in ipairs(snapshot.roots) do
        table.insert(lines, string.format(
            "- %s %s %s:%d-%d%s",
            root.kind,
            root.qualified,
            root.path,
            root.start_line,
            root.end_line,
            root.deleted and " (deleted)" or ""
        ))
    end
    return table.concat(lines, "\n")
end

M.show_text = with_last("changetree://graph", semantic_graph.format_graph)
M.show_ledger = with_last("changetree://ledger", semantic_graph.format_materiality)
M.show_trace = with_last("changetree://lsp-trace", semantic_graph.format_requests)
M.show_index = with_last("changetree://index", format_index)

-- ============================================================
-- Build after save
-- ============================================================

function M.schedule(bufnr)
    if not M.opts.auto then
        return
    end
    state.debounce = state.debounce + 1
    local ticket = state.debounce
    vim.defer_fn(function()
        if ticket == state.debounce and M.opts.auto then
            M.build(bufnr, false)
        end
    end, M.opts.debounce_ms)
end

function M.toggle_auto()
    M.opts.auto = not M.opts.auto
    notify("Build after save: " .. (M.opts.auto and "on" or "off"))
end

function M.cancel()
    state.generation = state.generation + 1
    state.pending = nil
    if state.cancel_token then
        state.cancel_token.cancelled = true
    end
    state.building = false
    state.cancel_token = nil
end

function M.setup(user_opts)
    M.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts or {})

    -- NVIM_CHANGE_TREE_HELPER points tests at a freshly built helper.
    local helper = M.opts.helper
    if not helper and vim.env.NVIM_CHANGE_TREE_HELPER and vim.env.NVIM_CHANGE_TREE_HELPER ~= "" then
        helper = vim.env.NVIM_CHANGE_TREE_HELPER
    end

    go_index.setup({
        binary = helper or go_index.binary(),
        timeout_ms = M.opts.helper_timeout_ms,
    })

    local group = vim.api.nvim_create_augroup("change_tree", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        pattern = "*.go",
        callback = function(event)
            M.schedule(event.buf)
        end,
    })

    vim.api.nvim_create_user_command("ChangeTree", function(command)
        if command.bang then
            M.show()
        else
            M.open()
        end
    end, { bang = true, desc = "Build the change tree (! reopens the last one)" })
    vim.api.nvim_create_user_command("ChangeTreeAuto", M.toggle_auto, { desc = "Toggle building the change tree after save" })
    vim.api.nvim_create_user_command("ChangeTreeCancel", M.cancel, { desc = "Cancel the running change tree build" })
    vim.api.nvim_create_user_command("ChangeTreeText", M.show_text, { desc = "Change tree as text: nodes, edges, externals" })
    vim.api.nvim_create_user_command("ChangeTreeLedger", M.show_ledger, { desc = "Every identifier of the changed roots and where it resolves" })
    vim.api.nvim_create_user_command("ChangeTreeTrace", M.show_trace, { desc = "gopls requests behind the last change tree" })
    vim.api.nvim_create_user_command("ChangeTreeIndex", M.show_index, { desc = "Changed declarations found by the AST helper" })
end

return M
