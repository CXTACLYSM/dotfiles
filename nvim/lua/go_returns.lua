-- Return graph for the enclosing Go callable.
--
-- Builds a control-flow tree from the Tree-sitter AST of the function under
-- the cursor and keeps only the branches that lead to an exit: `return`,
-- `panic`, terminal calls such as `os.Exit`, and `goto`. Deferred calls are
-- kept because they run on every exit and may rewrite named results.
--
-- The tree is rendered as a text diagram in a floating window with a live
-- source preview on the right (see graph_view.lua). Enter jumps to the
-- selected exit; q or Esc closes the window.

local M = {}

M.defaults = {
    -- Use plain ASCII connectors instead of box-drawing glyphs.
    pure_ascii = false,
    -- Maximum width of one node label before it is truncated.
    max_label = 72,
    -- Show `defer` statements on kept paths.
    show_defer = true,
    -- Calls that terminate the process or unwind like `panic`.
    exit_calls = {
        ["panic"] = "panic",
        ["os.Exit"] = "exit",
        ["log.Fatal"] = "exit",
        ["log.Fatalf"] = "exit",
        ["log.Fatalln"] = "exit",
        ["log.Panic"] = "panic",
        ["log.Panicf"] = "panic",
        ["log.Panicln"] = "panic",
    },
}

M.opts = vim.deepcopy(M.defaults)

local callable_types = {
    function_declaration = true,
    method_declaration = true,
    func_literal = true,
}

local exit_kinds = {
    ["return"] = true,
    panic = true,
    exit = true,
    ["goto"] = true,
    ["end"] = true,
}

-- ============================================================
-- Tree-sitter helpers
-- ============================================================

local function field(node, name)
    local values = node:field(name)
    return values and values[1] or nil
end

local function named_children(node)
    local result = {}
    for index = 0, node:named_child_count() - 1 do
        table.insert(result, node:named_child(index))
    end
    return result
end

local function collapse(text, limit, pure_ascii)
    text = text:gsub("%s+", " ")
    text = vim.trim(text)
    if limit and #text > limit then
        local ellipsis = pure_ascii and "..." or "…"
        text = text:sub(1, limit - #ellipsis) .. ellipsis
    end
    return text
end

local function node_text(node, bufnr, opts)
    if not node then
        return ""
    end
    return collapse(
        vim.treesitter.get_node_text(node, bufnr),
        opts.max_label,
        opts.pure_ascii
    )
end

-- Statement list of a `block`, a case, or a bare statement_list.
local function statements_of(node)
    if not node then
        return {}
    end

    if node:type() == "statement_list" then
        return named_children(node)
    end

    local result = {}
    for _, child in ipairs(named_children(node)) do
        if child:type() == "statement_list" then
            vim.list_extend(result, named_children(child))
        end
    end
    return result
end

function M.enclosing_callable(bufnr, row, col)
    local ok, node = pcall(vim.treesitter.get_node, {
        bufnr = bufnr,
        pos = { row, col },
    })
    if not ok then
        return nil
    end

    while node do
        if callable_types[node:type()] then
            return node
        end
        node = node:parent()
    end

    return nil
end

-- ============================================================
-- Signature analysis
-- ============================================================

local function result_info(fn, bufnr)
    local result = field(fn, "result")
    if not result then
        return { count = 0, last_type = nil }
    end

    if result:type() ~= "parameter_list" then
        return {
            count = 1,
            last_type = vim.trim(vim.treesitter.get_node_text(result, bufnr)),
        }
    end

    local count = 0
    local last_type = nil
    for _, declaration in ipairs(named_children(result)) do
        if declaration:type() == "parameter_declaration" then
            local names = declaration:field("name") or {}
            count = count + math.max(#names, 1)
            local type_node = field(declaration, "type")
            if type_node then
                last_type = vim.trim(
                    vim.treesitter.get_node_text(type_node, bufnr)
                )
            end
        end
    end

    return { count = count, last_type = last_type }
end

local function signature(fn, bufnr, opts)
    local kind = fn:type()
    local parameters = node_text(field(fn, "parameters"), bufnr, opts)
    local result = field(fn, "result")
    local result_text = result and (" " .. node_text(result, bufnr, opts)) or ""

    if kind == "func_literal" then
        return "func" .. parameters .. result_text .. "  (literal)"
    end

    local name = node_text(field(fn, "name"), bufnr, opts)
    local type_parameters = field(fn, "type_parameters")
    local generic = type_parameters and node_text(type_parameters, bufnr, opts) or ""

    if kind == "method_declaration" then
        local receiver = node_text(field(fn, "receiver"), bufnr, opts)
        return "func " .. receiver .. " " .. name .. generic .. parameters .. result_text
    end

    return "func " .. name .. generic .. parameters .. result_text
end

-- ============================================================
-- Control-flow tree
-- ============================================================

local function new_node(kind, label, node, children)
    local row, col = nil, nil
    if node then
        row, col = node:start()
    end
    return {
        kind = kind,
        label = label,
        line = row and (row + 1) or nil,
        col = col,
        children = children or {},
    }
end

local function has_exit(node)
    if exit_kinds[node.kind] then
        return true
    end
    for _, child in ipairs(node.children) do
        if has_exit(child) then
            return true
        end
    end
    return false
end

local function classify_return(return_node, info)
    local list = field(return_node, "expression_list")
        or named_children(return_node)[1]
    local expressions = list and named_children(list) or {}

    if #expressions == 0 then
        if info.count > 0 then
            return "named"
        end
        return nil
    end

    if info.last_type ~= "error" then
        return nil
    end

    if #expressions == info.count then
        local last = expressions[#expressions]
        if last:type() == "nil" then
            return "ok"
        end
        return "err"
    end

    if #expressions == 1 and expressions[1]:type() == "call_expression" then
        return "pass"
    end

    return nil
end

local visit

local function walk(statements, bufnr, info, opts)
    local out = {}
    for _, statement in ipairs(statements) do
        visit(statement, out, bufnr, info, opts)
    end
    return out
end

local function push_if_exit(out, node)
    if has_exit(node) then
        table.insert(out, node)
        return true
    end
    return false
end

local function if_header(if_node, bufnr, opts)
    local parts = {}
    local initializer = field(if_node, "initializer")
    if initializer then
        table.insert(parts, node_text(initializer, bufnr, opts) .. ";")
    end
    table.insert(parts, node_text(field(if_node, "condition"), bufnr, opts))
    return table.concat(parts, " ")
end

local function visit_if(if_node, out, bufnr, info, opts, keyword)
    local consequence = field(if_node, "consequence")
    local node = new_node(
        "if",
        keyword .. " " .. if_header(if_node, bufnr, opts),
        if_node,
        walk(statements_of(consequence), bufnr, info, opts)
    )
    push_if_exit(out, node)

    local alternative = field(if_node, "alternative")
    if not alternative then
        return
    end

    if alternative:type() == "if_statement" then
        visit_if(alternative, out, bufnr, info, opts, "else if")
    else
        push_if_exit(out, new_node(
            "else",
            "else",
            alternative,
            walk(statements_of(alternative), bufnr, info, opts)
        ))
    end
end

local function case_label(case_node, bufnr, opts)
    local kind = case_node:type()
    if kind == "default_case" then
        return "default"
    end

    local parts = {}
    for _, child in ipairs(named_children(case_node)) do
        if child:type() ~= "statement_list" then
            table.insert(parts, node_text(child, bufnr, opts))
        end
    end
    return "case " .. table.concat(parts, ", ")
end

local function visit_switch(switch_node, out, bufnr, info, opts, header)
    local cases = {}
    for _, child in ipairs(named_children(switch_node)) do
        local kind = child:type()
        if kind == "expression_case"
            or kind == "type_case"
            or kind == "communication_case"
            or kind == "default_case"
        then
            push_if_exit(cases, new_node(
                "case",
                case_label(child, bufnr, opts),
                child,
                walk(statements_of(child), bufnr, info, opts)
            ))
        end
    end

    push_if_exit(out, new_node("switch", header, switch_node, cases))
end

local function switch_header(switch_node, bufnr, opts)
    local kind = switch_node:type()
    if kind == "select_statement" then
        return "select"
    end

    local parts = {}
    local initializer = field(switch_node, "initializer")
    if initializer then
        table.insert(parts, node_text(initializer, bufnr, opts) .. ";")
    end

    if kind == "type_switch_statement" then
        local alias = field(switch_node, "alias")
        local value = node_text(field(switch_node, "value"), bufnr, opts)
        if alias then
            value = node_text(alias, bufnr, opts) .. " := " .. value
        end
        table.insert(parts, value .. ".(type)")
    else
        local value = field(switch_node, "value")
        if value then
            table.insert(parts, node_text(value, bufnr, opts))
        end
    end

    if #parts == 0 then
        return "switch"
    end
    return "switch " .. table.concat(parts, " ")
end

local function for_header(for_node, bufnr, opts)
    for _, child in ipairs(named_children(for_node)) do
        if child:type() ~= "block" then
            return "for " .. node_text(child, bufnr, opts)
        end
    end
    return "for"
end

local function call_target(call_node, bufnr)
    local target = field(call_node, "function")
    if not target then
        return nil
    end
    return vim.trim(vim.treesitter.get_node_text(target, bufnr))
end

visit = function(statement, out, bufnr, info, opts)
    local kind = statement:type()

    if kind == "return_statement" then
        local node = new_node("return", node_text(statement, bufnr, opts), statement)
        node.tag = classify_return(statement, info)
        table.insert(out, node)
    elseif kind == "if_statement" then
        visit_if(statement, out, bufnr, info, opts, "if")
    elseif kind == "for_statement" then
        push_if_exit(out, new_node(
            "for",
            for_header(statement, bufnr, opts),
            statement,
            walk(statements_of(field(statement, "body")), bufnr, info, opts)
        ))
    elseif kind == "expression_switch_statement"
        or kind == "type_switch_statement"
        or kind == "select_statement"
    then
        visit_switch(statement, out, bufnr, info, opts, switch_header(statement, bufnr, opts))
    elseif kind == "labeled_statement" then
        local children = named_children(statement)
        local label = field(statement, "label") or children[1]
        local inner = children[#children]
        if inner and inner ~= label then
            local before = #out
            visit(inner, out, bufnr, info, opts)
            if #out > before then
                local first = out[before + 1]
                first.label = node_text(label, bufnr, opts) .. ": " .. first.label
            end
        end
    elseif kind == "block" then
        vim.list_extend(out, walk(statements_of(statement), bufnr, info, opts))
    elseif kind == "expression_statement" then
        local call = named_children(statement)[1]
        if call and call:type() == "call_expression" then
            local exit_kind = opts.exit_calls[call_target(call, bufnr) or ""]
            if exit_kind then
                table.insert(out, new_node(exit_kind, node_text(statement, bufnr, opts), statement))
            end
        end
    elseif kind == "goto_statement" then
        table.insert(out, new_node("goto", node_text(statement, bufnr, opts), statement))
    elseif kind == "defer_statement" then
        if opts.show_defer then
            local call = named_children(statement)[1]
            local label = "defer"
            if call then
                local target = field(call, "function")
                if target and target:type() == "func_literal" then
                    label = "defer func" .. node_text(field(target, "parameters"), bufnr, opts)
                        .. " { " .. (opts.pure_ascii and "..." or "…") .. " }()"
                else
                    label = node_text(statement, bufnr, opts)
                end
            end
            table.insert(out, new_node("defer", label .. "  (on every exit)", statement))
        end
    end
    -- go statements, assignments, declarations and nested func literals
    -- never contribute exits of the enclosing callable.
end

function M.build(bufnr, fn, user_opts)
    local opts = vim.tbl_deep_extend("force", M.opts, user_opts or {})
    local info = result_info(fn, bufnr)
    local body = field(fn, "body")
    local children = walk(statements_of(body), bufnr, info, opts)

    -- A callable without results may fall off its final closing brace.
    if info.count == 0 then
        local last = children[#children]
        local last_statement = statements_of(body)
        local final = last_statement[#last_statement]
        local terminal = final and (
            final:type() == "return_statement"
            or (last and last.line == final:start() + 1 and exit_kinds[last.kind])
        )
        if not terminal then
            local end_row = fn:end_()
            local node = new_node("end", "end of func (implicit return)", nil)
            node.line = end_row + 1
            node.col = 0
            table.insert(children, node)
        end
    end

    local root = new_node("func", signature(fn, bufnr, opts), fn, children)
    root.info = info
    return root
end

-- Keep only the paths that can leave the function abnormally or with a
-- non-nil error: `[ok]` returns and the implicit end are dropped, branches
-- without a remaining exit are pruned, defers stay.
function M.filter_errors(root)
    local function copy(node)
        local result = vim.deepcopy(node)
        result.children = {}
        for _, child in ipairs(node.children) do
            if exit_kinds[child.kind] then
                if child.kind ~= "end" and child.tag ~= "ok" then
                    table.insert(result.children, copy(child))
                end
            elseif child.kind == "defer" then
                table.insert(result.children, copy(child))
            else
                local kept = copy(child)
                if has_exit(kept) then
                    table.insert(result.children, kept)
                end
            end
        end
        return result
    end

    local filtered = copy(root)
    filtered.errors_only = true
    return filtered
end

-- ============================================================
-- Rendering
-- ============================================================

local glyphs = {
    unicode = { branch = "├─ ", last = "└─ ", pipe = "│  ", blank = "   " },
    ascii = { branch = "|- ", last = "`- ", pipe = "|  ", blank = "   " },
}

local tag_text = {
    ok = "[ok]",
    err = "[err]",
    pass = "[pass]",
    named = "[named]",
}

local kind_highlight = {
    ["return"] = "Keyword",
    panic = "DiagnosticWarn",
    exit = "DiagnosticWarn",
    ["goto"] = "DiagnosticWarn",
    ["end"] = "Comment",
    defer = "Special",
    ["if"] = "Conditional",
    ["else"] = "Conditional",
    switch = "Conditional",
    case = "Conditional",
    ["for"] = "Repeat",
}

local tag_highlight = {
    ok = "DiagnosticOk",
    err = "DiagnosticError",
    pass = "DiagnosticInfo",
    named = "DiagnosticHint",
}

local function count_exits(node, counts)
    counts = counts or { total = 0, ["return"] = 0, panic = 0, exit = 0, ["goto"] = 0, ["end"] = 0 }
    if exit_kinds[node.kind] then
        counts.total = counts.total + 1
        counts[node.kind] = counts[node.kind] + 1
    end
    for _, child in ipairs(node.children) do
        count_exits(child, counts)
    end
    return counts
end

local function keyword_length(node)
    local first = node.label:match("^[%a_]+")
    if node.kind == "if" then
        first = node.label:match("^else if") or first
    end
    return first and #first or 0
end

function M.render(root, user_opts)
    local opts = vim.tbl_deep_extend("force", M.opts, user_opts or {})
    local set = opts.pure_ascii and glyphs.ascii or glyphs.unicode

    local rows = {}

    local function add_row(prefix, connector, node)
        local text = prefix .. connector .. node.label
        local highlights = {}

        local glyph_width = #prefix + #connector
        if glyph_width > 0 then
            table.insert(highlights, { "Comment", 0, glyph_width })
        end

        local keyword = keyword_length(node)
        local hl = kind_highlight[node.kind]
        if hl and keyword > 0 then
            local start = glyph_width
            local label_prefix = node.label:match("^[%w_]+: ")
            if label_prefix then
                start = start + #label_prefix
                keyword = node.label:sub(#label_prefix + 1):match("^[%a_]+")
                keyword = keyword and #keyword or 0
            end
            table.insert(highlights, { hl, start, start + keyword })
        end

        table.insert(rows, {
            text = text,
            node = node,
            highlights = highlights,
        })
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

    -- Right-align tags and line numbers after the widest label.
    local width = 0
    for _, row in ipairs(rows) do
        width = math.max(width, vim.fn.strdisplaywidth(row.text))
    end

    local tag_width = 0
    for index, row in ipairs(rows) do
        if index > 1 then
            local tag = row.node.tag and tag_text[row.node.tag]
            if tag then
                tag_width = math.max(tag_width, #tag)
            end
        end
    end

    local lines = {}
    local meta = {}
    for index, row in ipairs(rows) do
        local text = row.text
        local node = row.node

        if index > 1 and node.line then
            local padding = width - vim.fn.strdisplaywidth(text) + 2
            text = text .. string.rep(" ", padding)

            local tag = node.tag and tag_text[node.tag]
            if tag_width > 0 then
                if tag then
                    table.insert(row.highlights, {
                        tag_highlight[node.tag] or "Comment",
                        #text,
                        #text + #tag,
                    })
                end
                text = text .. (tag or "") .. string.rep(" ", tag_width - #(tag or "") + 1)
            end

            local number = string.format(":%d", node.line)
            table.insert(row.highlights, { "LineNr", #text, #text + #number })
            text = text .. number
        end

        table.insert(lines, text)
        table.insert(meta, {
            line = node.line,
            col = node.col,
            kind = node.kind,
            highlights = row.highlights,
        })
    end

    local counts = count_exits(root)
    local summary_parts = {}
    for _, kind in ipairs({ "return", "panic", "exit", "goto", "end" }) do
        if counts[kind] > 0 then
            table.insert(summary_parts, string.format("%d %s", counts[kind], kind))
        end
    end
    local summary = string.format(
        "%d exit%s",
        counts.total,
        counts.total == 1 and "" or "s"
    )
    if #summary_parts > 0 then
        summary = summary .. ": " .. table.concat(summary_parts, ", ")
    end

    return lines, meta, summary
end

-- ============================================================
-- UI
-- ============================================================

local graph_view = require("graph_view")

local function open_view(lines, meta, summary, source_win, source_buf, extra)
    extra = extra or {}
    local entries = {}
    for index, entry in ipairs(meta) do
        local target = entry.line and {
            bufnr = source_buf,
            line = entry.line,
            col = entry.col or 0,
        } or nil
        entries[index] = {
            highlights = entry.highlights,
            preview = target,
            jumps = { ["<CR>"] = target },
        }
    end

    return graph_view.open({
        title = extra.title or "return graph",
        footer = summary,
        filetype = "goreturns",
        lines = lines,
        entries = entries,
        source_win = source_win,
        keys = extra.keys,
        cursor_row = extra.cursor_row,
    })
end

function M.show(user_opts)
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].filetype ~= "go" then
        vim.notify("Return graph is available in Go buffers", vim.log.levels.INFO)
        return nil
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local fn = M.enclosing_callable(bufnr, cursor[1] - 1, cursor[2])
    if not fn then
        vim.notify("No enclosing Go function or method", vim.log.levels.INFO)
        return nil
    end

    local opts = user_opts or {}
    local root = M.build(bufnr, fn, opts)
    if opts.errors_only then
        root = M.filter_errors(root)
    end
    local lines, meta, summary = M.render(root, opts)

    local source_win = vim.api.nvim_get_current_win()
    local title = opts.errors_only and "return graph: error paths" or "return graph"
    summary = summary .. (opts.errors_only and "  [e] all exits" or "  [e] error paths")

    return open_view(lines, meta, summary, source_win, bufnr, {
        title = title,
        cursor_row = opts.cursor_row,
        keys = {
            e = function(ctx)
                ctx.close()
                if vim.api.nvim_win_is_valid(source_win) then
                    vim.api.nvim_set_current_win(source_win)
                end
                M.show(vim.tbl_extend("force", opts, {
                    errors_only = not opts.errors_only,
                    cursor_row = ctx.row,
                }))
            end,
        },
    })
end

function M.setup(user_opts)
    M.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts or {})

    vim.api.nvim_create_user_command("GoReturns", function(command)
        M.show({ pure_ascii = command.bang or M.opts.pure_ascii })
    end, {
        bang = true,
        desc = "Return graph of the enclosing Go function (! for pure ASCII)",
    })
end

return M
