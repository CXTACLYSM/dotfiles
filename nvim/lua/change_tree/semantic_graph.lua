local M = {}

local go_index = require("change_tree.go_index")

local defaults = {
    outbound_depth = 3,
    max_nodes = 72,
    max_root_occurrences = 256,
    max_dependency_occurrences = 28,
    max_same_package_tests = 4,
    max_non_test_callers = 5,
    max_other_tests = 2,
    max_parallel_implementations = 3,
    lsp_timeout_ms = 6000,
    allow_incomplete = false,
}

local predeclared = {
    any = true,
    bool = true,
    byte = true,
    comparable = true,
    complex64 = true,
    complex128 = true,
    error = true,
    float32 = true,
    float64 = true,
    int = true,
    int8 = true,
    int16 = true,
    int32 = true,
    int64 = true,
    rune = true,
    string = true,
    uint = true,
    uint8 = true,
    uint16 = true,
    uint32 = true,
    uint64 = true,
    uintptr = true,
    ["true"] = true,
    ["false"] = true,
    iota = true,
    ["nil"] = true,
    append = true,
    cap = true,
    clear = true,
    close = true,
    complex = true,
    copy = true,
    delete = true,
    imag = true,
    len = true,
    make = true,
    max = true,
    min = true,
    new = true,
    panic = true,
    print = true,
    println = true,
    real = true,
    recover = true,
}

local function normalize(path)
    if not path or path == "" then
        return nil
    end

    local absolute = vim.fs.normalize(vim.fs.abspath(path))
    return vim.uv.fs_realpath(absolute) or absolute
end

local function is_inside(root, path)
    root = normalize(root)
    path = normalize(path)

    if not root or not path then
        return false
    end

    if root == path then
        return true
    end

    return path:sub(1, #root + 1) == root .. "/"
end

local function set_add(set, value)
    if value ~= nil then
        set[value] = true
    end
end

local function sorted_keys(set)
    local keys = {}

    for key in pairs(set or {}) do
        table.insert(keys, key)
    end

    table.sort(keys)
    return keys
end

local function copy_array(values)
    local result = {}

    for _, value in ipairs(values or {}) do
        table.insert(result, value)
    end

    return result
end

local function location_parts(location)
    if type(location) ~= "table" then
        return nil
    end

    if location.uri and location.range then
        return location.uri, location.range
    end

    if location.targetUri and location.targetRange then
        return location.targetUri,
            location.targetSelectionRange or location.targetRange
    end

    return nil
end

local function call_item_location(item)
    if type(item) ~= "table" or not item.uri then
        return nil
    end

    return {
        uri = item.uri,
        range = item.selectionRange or item.range,
    }
end

local function normalize_locations(result)
    if not result then
        return {}
    end

    if result.uri or result.targetUri then
        return { result }
    end

    if vim.islist(result) then
        return result
    end

    return {}
end

local function relation_for(symbol, occurrence)
    if occurrence.kind == "call" then
        return "calls"
    end

    if symbol.kind == "field" then
        return "uses_field"
    end

    if symbol.kind == "interface_method" then
        return "uses_contract_method"
    end

    if symbol.kind == "method" or symbol.kind == "function" then
        return "references_callable"
    end

    if symbol.kind == "struct"
        or symbol.kind == "interface"
        or symbol.kind == "type"
        or symbol.kind == "embedded_interface"
        or occurrence.kind == "type"
    then
        return "uses_type"
    end

    if symbol.kind == "const" or symbol.kind == "var" then
        return "uses_value"
    end

    return "definition"
end

local function relation_score(relation, depth)
    local base = {
        root = 100,
        contract = 98,
        calls = 95,
        uses_field = 94,
        uses_contract_method = 94,
        uses_value = 93,
        uses_type = 92,
        definition = 90,
        references_callable = 88,
        implementation = 88,
        parallel_implementation = 88,
        test_oracle = 87,
        caller = 76,
        reference = 70,
        member_of = 65,
    }

    return math.max((base[relation] or 60) - math.max(depth - 1, 0) * 18, 20)
end

local function mandatory_relation(relation, depth)
    if depth ~= 1 then
        return false
    end

    return relation == "contract"
        or relation == "calls"
        or relation == "uses_field"
        or relation == "uses_contract_method"
        or relation == "uses_value"
        or relation == "uses_type"
        or relation == "definition"
end

local function node_expandable(node, opts)
    if node.context_only
        or node.symbol.deleted
        or node.symbol.baseline
    then
        return false
    end

    if node.depth >= opts.outbound_depth then
        return false
    end

    local kind = node.symbol.kind

    return kind == "function"
        or kind == "method"
        or kind == "const"
        or kind == "var"
        or kind == "type"
        or kind == "field"
        or kind == "interface_method"
        or kind == "embedded_interface"
end

local function node_id(symbol)
    return symbol.id
end

local function add_request_trace(slice, item)
    item.id = #slice.requests + 1
    table.insert(slice.requests, item)
    return item
end

local function request_error_text(err)
    if type(err) == "table" then
        return err.message or vim.inspect(err)
    end

    return tostring(err or "unknown LSP error")
end

local function await_lsp(slice, client, method, params, bufnr, purpose, required)
    return coroutine.yield({
        kind = "lsp",
        slice = slice,
        client = client,
        method = method,
        params = params,
        bufnr = bufnr,
        purpose = purpose,
        required = required == true,
        timeout_ms = slice.opts.lsp_timeout_ms,
    })
end

local function await_file(slice, path)
    return coroutine.yield({
        kind = "index",
        slice = slice,
        root = slice.root,
        path = path,
    })
end

local function run_async(token, fn, on_done, on_error)
    local co = coroutine.create(fn)

    local function step(value)
        if token.cancelled then
            on_error("cancelled")
            return
        end

        local ok, yielded = coroutine.resume(co, value)

        if not ok then
            on_error(yielded)
            return
        end

        if coroutine.status(co) == "dead" then
            on_done(yielded)
            return
        end

        if type(yielded) ~= "table" then
            on_error("semantic graph yielded an invalid operation")
            return
        end

        if yielded.kind == "index" then
            go_index.inspect_file(yielded.root, yielded.path, function(file, err)
                step({ result = file, err = err })
            end)
            return
        end

        if yielded.kind ~= "lsp" then
            on_error("unsupported semantic graph operation: " .. tostring(yielded.kind))
            return
        end

        local trace = add_request_trace(yielded.slice, {
            method = yielded.method,
            purpose = yielded.purpose,
            required = yielded.required,
            started_ns = vim.uv.hrtime(),
            status = "pending",
        })
        local completed = false
        local request_id

        local accepted
        accepted, request_id = yielded.client:request(
            yielded.method,
            yielded.params,
            function(err, result)
                if completed then
                    return
                end

                completed = true
                trace.duration_ms = (vim.uv.hrtime() - trace.started_ns) / 1e6
                trace.status = err and "error" or "ok"
                trace.error = err and request_error_text(err) or nil

                vim.schedule(function()
                    step({ result = result, err = err, trace = trace })
                end)
            end,
            yielded.bufnr
        )

        if accepted == false then
            completed = true
            trace.duration_ms = (vim.uv.hrtime() - trace.started_ns) / 1e6
            trace.status = "rejected"
            trace.error = "request rejected"

            vim.schedule(function()
                step({
                    result = nil,
                    err = { message = "request rejected" },
                    trace = trace,
                })
            end)
            return
        end

        vim.defer_fn(function()
            if completed then
                return
            end

            completed = true
            trace.duration_ms = (vim.uv.hrtime() - trace.started_ns) / 1e6
            trace.status = "timeout"
            trace.error = "request timed out"

            if request_id then
                pcall(
                    yielded.client.cancel_request,
                    yielded.client,
                    request_id
                )
            end

            step({
                result = nil,
                err = { message = "request timed out" },
                trace = trace,
            })
        end, yielded.timeout_ms)
    end

    step(nil)
end

local function new_slice(opts, snapshot)
    return {
        root = normalize(opts.root),
        opts = opts,
        snapshot = snapshot,
        signature = snapshot.signature,
        git_diff = snapshot.diff or "",
        roots = {},
        nodes = {},
        node_by_id = {},
        edges = {},
        edge_seen = {},
        externals = {},
        external_by_id = {},
        materiality = {},
        requests = {},
        gaps = {},
        warnings = copy_array(snapshot.warnings),
        truncated = false,
        complete = true,
        buffer_ticks = {},
    }
end

local function add_gap(slice, root_id, occurrence, reason, required)
    local gap = {
        root_id = root_id,
        occurrence_id = occurrence and occurrence.id,
        name = occurrence and occurrence.name,
        kind = occurrence and occurrence.kind,
        path = occurrence and occurrence.path,
        line = occurrence and occurrence.line,
        col = occurrence and occurrence.col,
        reason = reason,
        required = required == true,
    }

    table.insert(slice.gaps, gap)

    if gap.required then
        slice.complete = false
    end

    return gap
end

local function root_ids_from(node)
    return sorted_keys(node.root_ids)
end

local function add_node(slice, symbol, file, relation, depth, roots, reason, mandatory)
    if not symbol then
        return nil, false
    end

    local id = node_id(symbol)
    local existing = slice.node_by_id[id]

    if existing then
        for _, root_id in ipairs(roots or {}) do
            set_add(existing.root_ids, root_id)
        end
        set_add(existing.relations, relation)
        set_add(existing.reasons, reason)
        existing.score = math.max(
            existing.score,
            relation_score(relation, depth)
        )
        existing.depth = math.min(existing.depth, depth)
        existing.mandatory = existing.mandatory or mandatory == true
        if relation ~= "test_oracle"
            and relation ~= "caller"
            and relation ~= "reference"
            and relation ~= "implementation"
            and relation ~= "parallel_implementation"
            and relation ~= "contract"
            and relation ~= "member_of"
        then
            existing.context_only = false
        end
        return existing, false
    end

    if #slice.nodes >= slice.opts.max_nodes then
        slice.truncated = true
        slice.complete = false
        add_gap(slice, roots and roots[1], nil, "node limit reached", true)
        return nil, false
    end

    local node = {
        id = id,
        symbol = symbol,
        file = file or symbol.file,
        depth = depth,
        score = relation_score(relation, depth),
        relations = { [relation] = true },
        reasons = reason and { [reason] = true } or {},
        root_ids = {},
        mandatory = mandatory == true,
        selected_members = {},
        context_only = relation == "test_oracle"
            or relation == "caller"
            or relation == "reference"
            or relation == "implementation"
            or relation == "parallel_implementation"
            or relation == "contract"
            or relation == "member_of",
        expanded = false,
    }

    for _, root_id in ipairs(roots or {}) do
        set_add(node.root_ids, root_id)
    end

    slice.node_by_id[id] = node
    table.insert(slice.nodes, node)

    return node, true
end

local function add_edge(slice, from, to, relation, roots, occurrence)
    if not from or not to or from.id == to.id then
        return
    end

    local key = table.concat({ from.id, relation, to.id }, "|")
    local existing = slice.edge_seen[key]

    if existing then
        for _, root_id in ipairs(roots or {}) do
            set_add(existing.root_ids, root_id)
        end
        return
    end

    local edge = {
        id = vim.fn.sha256(key):sub(1, 20),
        from = from.id,
        to = to.id,
        relation = relation,
        root_ids = {},
        occurrence = occurrence and {
            id = occurrence.id,
            path = occurrence.path,
            line = occurrence.line,
            col = occurrence.col,
            name = occurrence.name,
            kind = occurrence.kind,
        } or nil,
    }

    for _, root_id in ipairs(roots or {}) do
        set_add(edge.root_ids, root_id)
    end

    slice.edge_seen[key] = edge
    table.insert(slice.edges, edge)
end

local function ensure_owner(slice, member_node, relation, depth, roots)
    local symbol = member_node.symbol

    if not symbol.owner_id or symbol.owner_id == "" then
        return nil
    end

    local owner_symbol = member_node.file.symbol_by_id[symbol.owner_id]
    if not owner_symbol then
        return nil
    end

    local owner, _ = add_node(
        slice,
        owner_symbol,
        member_node.file,
        relation,
        depth,
        roots,
        "owner projection for " .. symbol.qualified,
        member_node.mandatory
    )

    if owner then
        owner.selected_members[symbol.id] = true
        add_edge(slice, member_node, owner, "member_of", roots)
    end

    return owner
end

local function builtin_location(path, name)
    if predeclared[name] then
        return true
    end

    if not path then
        return false
    end

    return path:find("/src/builtin/builtin.go", 1, true) ~= nil
end

local function external_id(path, line, col, name)
    return vim.fn.sha256(table.concat({
        tostring(path),
        tostring(line),
        tostring(col),
        tostring(name),
    }, "|")):sub(1, 24)
end

local function add_external(slice, item, relation, roots)
    local id = external_id(item.path, item.line, item.col, item.name)
    local external = slice.external_by_id[id]

    if not external then
        external = {
            id = id,
            name = item.name,
            path = item.path,
            uri = item.uri,
            line = item.line,
            col = item.col,
            class = item.class,
            signature = item.signature,
            relations = {},
            root_ids = {},
        }
        slice.external_by_id[id] = external
        table.insert(slice.externals, external)
    end

    set_add(external.relations, relation)
    for _, root_id in ipairs(roots or {}) do
        set_add(external.root_ids, root_id)
    end

    return external
end

local function external_class(path)
    if not path then
        return "virtual"
    end

    if path:find("/pkg/mod/", 1, true)
        or path:find("/go/pkg/mod/", 1, true)
    then
        return "module"
    end

    if path:find("/src/", 1, true) then
        return "stdlib"
    end

    return "external"
end

local function markdown_text(value)
    if type(value) == "string" then
        return value
    end

    if type(value) ~= "table" then
        return ""
    end

    if type(value.value) == "string" then
        return value.value
    end

    if vim.islist(value) then
        local parts = {}
        for _, item in ipairs(value) do
            local text = markdown_text(item)
            if text ~= "" then
                table.insert(parts, text)
            end
        end
        return table.concat(parts, "\n")
    end

    return ""
end

local function compact_hover(result)
    if type(result) ~= "table" then
        return ""
    end

    local text = markdown_text(result.contents)
    text = text:gsub("```%w*", ""):gsub("```", "")
    text = vim.trim(text:gsub("\n+", " "):gsub("%s+", " "))

    if #text > 500 then
        text = text:sub(1, 500) .. "…"
    end

    return text
end

local function file_for_path(slice, path)
    path = normalize(path)

    for _, file in pairs(slice.snapshot.files or {}) do
        if normalize(file.absolute_path) == path and not file.baseline then
            return file
        end
    end

    return nil
end

local function get_file(slice, path)
    local existing = file_for_path(slice, path)
    if existing then
        return existing, nil
    end

    local response = await_file(slice, path)
    if response.err then
        return nil, response.err
    end

    return response.result, nil
end

local function lsp_params(client, file, occurrence)
    return {
        textDocument = {
            uri = vim.uri_from_fname(file.absolute_path),
        },
        position = {
            line = occurrence.line - 1,
            character = go_index.byte_to_lsp_character(
                file,
                occurrence.line,
                occurrence.col,
                client.offset_encoding
            ),
        },
    }
end

local function location_to_symbol(slice, client, location, label)
    local uri, range = location_parts(location)

    if not uri or not range or not range.start then
        return nil, nil, "location has no URI/range"
    end

    local path
    if uri:sub(1, 7) == "file://" then
        path = normalize(vim.uri_to_fname(uri))
    end

    if not path or not is_inside(slice.root, path) then
        return nil, {
            name = label,
            uri = uri,
            path = path,
            line = range.start.line + 1,
            col = range.start.character + 1,
            class = external_class(path),
        }, nil
    end

    local file, file_err = get_file(slice, path)
    if not file then
        return nil, nil, "index file failed: " .. tostring(file_err)
    end

    local line = range.start.line + 1
    local byte_col = go_index.lsp_character_to_byte(
        file,
        line,
        range.start.character,
        client.offset_encoding
    )
    local symbol = go_index.symbol_at(file, line, byte_col)

    if not symbol then
        return nil, nil, string.format(
            "no exact Go symbol at %s:%d:%d",
            go_index.relative(slice.root, path),
            line,
            byte_col
        )
    end

    return symbol, nil, nil
end

local function ledger_for(slice, root)
    local ledger = slice.materiality[root.id]
    if ledger then
        return ledger
    end

    ledger = {
        root_id = root.id,
        total = 0,
        resolved_internal = 0,
        resolved_external = 0,
        local_count = 0,
        builtin_count = 0,
        baseline_count = 0,
        unresolved = 0,
        entries = {},
    }
    slice.materiality[root.id] = ledger
    return ledger
end

local function add_ledger_entry(ledger, occurrence)
    local entry = {
        id = occurrence.id,
        name = occurrence.name,
        kind = occurrence.kind,
        path = occurrence.path,
        line = occurrence.line,
        col = occurrence.col,
        disposition = "pending",
        target_ids = {},
    }
    table.insert(ledger.entries, entry)
    ledger.total = ledger.total + 1
    return entry
end

local function mark_ledger(ledger, entry, disposition, target_id, detail)
    if target_id then
        local seen = false
        for _, existing in ipairs(entry.target_ids) do
            if existing == target_id then
                seen = true
                break
            end
        end
        if not seen then
            table.insert(entry.target_ids, target_id)
        end
    end

    if entry.disposition ~= "pending" then
        -- A single semantic occurrence may legitimately resolve to multiple
        -- implementation locations. Keep all targets but count the
        -- occurrence exactly once in coverage.
        if entry.disposition == disposition then
            if detail then
                entry.detail = detail
            end
            return
        end

        -- Prefer a resolved internal declaration over an external fallback.
        if entry.disposition == "external" and disposition == "internal" then
            ledger.resolved_external = math.max(ledger.resolved_external - 1, 0)
            ledger.resolved_internal = ledger.resolved_internal + 1
            entry.disposition = disposition
        end
        return
    end

    entry.disposition = disposition
    entry.detail = detail

    if disposition == "internal" then
        ledger.resolved_internal = ledger.resolved_internal + 1
    elseif disposition == "external" then
        ledger.resolved_external = ledger.resolved_external + 1
    elseif disposition == "local" then
        ledger.local_count = ledger.local_count + 1
    elseif disposition == "builtin" then
        ledger.builtin_count = ledger.builtin_count + 1
    elseif disposition == "baseline" then
        ledger.baseline_count = ledger.baseline_count + 1
    elseif disposition == "unresolved" then
        ledger.unresolved = ledger.unresolved + 1
    end
end

local function resolve_hover(slice, client, bufnr, file, occurrence, external)
    if external.signature and external.signature ~= "" then
        return
    end

    local response = await_lsp(
        slice,
        client,
        "textDocument/hover",
        lsp_params(client, file, occurrence),
        bufnr,
        "external signature: " .. occurrence.name,
        false
    )

    if not response.err then
        external.signature = compact_hover(response.result)
    end
end

local function resolve_occurrence(
    slice,
    client,
    bufnr,
    source_node,
    occurrence,
    root_id,
    ledger_entry,
    direct
)
    local roots = root_ids_from(source_node)
    if root_id then
        roots = { root_id }
    end

    if occurrence.binding or occurrence["local"] then
        if ledger_entry then
            mark_ledger(ledger_for(slice, slice.node_by_id[root_id]), ledger_entry, "local")
        end
        return nil
    end

    if occurrence.builtin_candidate or predeclared[occurrence.name] then
        if ledger_entry then
            mark_ledger(ledger_for(slice, slice.node_by_id[root_id]), ledger_entry, "builtin")
        end
        return nil
    end

    occurrence.path = source_node.symbol.path
    local params = lsp_params(client, source_node.file, occurrence)
    local response = await_lsp(
        slice,
        client,
        "textDocument/definition",
        params,
        bufnr,
        "definition: " .. occurrence.name,
        direct
    )

    local resolved_any = false
    local locations = not response.err and normalize_locations(response.result) or {}

    for _, location in ipairs(locations) do
        local symbol, external_info, resolve_err = location_to_symbol(
            slice,
            client,
            location,
            occurrence.name
        )

        if symbol then
            local relation = relation_for(symbol, occurrence)
            local target, _ = add_node(
                slice,
                symbol,
                symbol.file,
                relation,
                source_node.depth + 1,
                roots,
                string.format(
                    "%s at %s:%d",
                    occurrence.name,
                    occurrence.path,
                    occurrence.line
                ),
                direct and mandatory_relation(relation, source_node.depth + 1)
            )

            if target then
                add_edge(slice, source_node, target, relation, roots, occurrence)
                if symbol.owner_id and symbol.owner_id ~= "" then
                    ensure_owner(slice, target, relation, target.depth, roots)
                end
                resolved_any = true
                if ledger_entry then
                    mark_ledger(
                        ledger_for(slice, slice.node_by_id[root_id]),
                        ledger_entry,
                        "internal",
                        target.id
                    )
                end
            end
        elseif external_info then
            if builtin_location(external_info.path, occurrence.name) then
                resolved_any = true
                if ledger_entry then
                    mark_ledger(
                        ledger_for(slice, slice.node_by_id[root_id]),
                        ledger_entry,
                        "builtin"
                    )
                end
            else
                local external = add_external(
                    slice,
                    external_info,
                    occurrence.kind == "call" and "calls" or "definition",
                    roots
                )
                resolve_hover(
                    slice,
                    client,
                    bufnr,
                    source_node.file,
                    occurrence,
                    external
                )
                resolved_any = true
                if ledger_entry then
                    mark_ledger(
                        ledger_for(slice, slice.node_by_id[root_id]),
                        ledger_entry,
                        "external",
                        external.id
                    )
                end
            end
        elseif resolve_err and direct then
            add_gap(slice, root_id, occurrence, resolve_err, true)
        end
    end

    -- typeDefinition is intentionally narrow. It is never used for package
    -- vars/consts (the source of the old ErrInvalidState -> builtin.go bug).
    if not resolved_any and occurrence.kind == "type" then
        local type_response = await_lsp(
            slice,
            client,
            "textDocument/typeDefinition",
            params,
            bufnr,
            "type definition: " .. occurrence.name,
            direct
        )

        for _, location in ipairs(
            not type_response.err
                and normalize_locations(type_response.result)
                or {}
        ) do
            local symbol, external_info = location_to_symbol(
                slice,
                client,
                location,
                occurrence.name
            )

            if symbol then
                local target = add_node(
                    slice,
                    symbol,
                    symbol.file,
                    "uses_type",
                    source_node.depth + 1,
                    roots,
                    "type of " .. occurrence.name,
                    direct
                )
                if target then
                    add_edge(slice, source_node, target, "uses_type", roots, occurrence)
                    if symbol.owner_id and symbol.owner_id ~= "" then
                        ensure_owner(slice, target, "uses_type", target.depth, roots)
                    end
                    resolved_any = true
                    if ledger_entry then
                        mark_ledger(
                            ledger_for(slice, slice.node_by_id[root_id]),
                            ledger_entry,
                            "internal",
                            target.id
                        )
                    end
                end
            elseif external_info and not builtin_location(external_info.path, occurrence.name) then
                local external = add_external(slice, external_info, "uses_type", roots)
                resolve_hover(slice, client, bufnr, source_node.file, occurrence, external)
                resolved_any = true
                if ledger_entry then
                    mark_ledger(
                        ledger_for(slice, slice.node_by_id[root_id]),
                        ledger_entry,
                        "external",
                        external.id
                    )
                end
            elseif external_info then
                resolved_any = true
                if ledger_entry then
                    mark_ledger(
                        ledger_for(slice, slice.node_by_id[root_id]),
                        ledger_entry,
                        "builtin"
                    )
                end
            end
        end
    end

    if not resolved_any and ledger_entry then
        mark_ledger(
            ledger_for(slice, slice.node_by_id[root_id]),
            ledger_entry,
            "unresolved",
            nil,
            response.err and request_error_text(response.err) or "no LSP result"
        )
        add_gap(
            slice,
            root_id,
            occurrence,
            "unresolved material root occurrence",
            true
        )
    end
end

local function record_baseline_occurrences(slice, root)
    local ledger = ledger_for(slice, root)

    for _, occurrence in ipairs(root.symbol.occurrences or {}) do
        occurrence.path = root.symbol.path
        local entry = add_ledger_entry(ledger, occurrence)
        mark_ledger(
            ledger,
            entry,
            "baseline",
            nil,
            "deletion-only/baseline declaration; no current LSP position"
        )
    end
end

local function process_occurrences(slice, client, bufnr, node, direct)
    local occurrences = node.symbol.occurrences or {}
    local max_count = direct
        and slice.opts.max_root_occurrences
        or slice.opts.max_dependency_occurrences

    if #occurrences > max_count then
        if direct then
            add_gap(
                slice,
                node.id,
                nil,
                string.format(
                    "root has %d semantic occurrences; limit is %d",
                    #occurrences,
                    max_count
                ),
                true
            )
        end
        occurrences = vim.list_slice(occurrences, 1, max_count)
    end

    local ledger = direct and ledger_for(slice, node) or nil

    for _, occurrence in ipairs(occurrences) do
        local entry = ledger and add_ledger_entry(ledger, occurrence) or nil

        resolve_occurrence(
            slice,
            client,
            bufnr,
            node,
            occurrence,
            direct and node.id or nil,
            entry,
            direct
        )
    end
end

local function hierarchy_params(client, node)
    return {
        textDocument = {
            uri = vim.uri_from_fname(node.file.absolute_path),
        },
        position = {
            line = node.symbol.name_line - 1,
            character = go_index.byte_to_lsp_character(
                node.file,
                node.symbol.name_line,
                node.symbol.name_col,
                client.offset_encoding
            ),
        },
    }
end

local function expand_outgoing_calls(slice, client, bufnr, node)
    local kind = node.symbol.kind
    if kind ~= "function" and kind ~= "method" then
        return
    end

    local prepared = await_lsp(
        slice,
        client,
        "textDocument/prepareCallHierarchy",
        hierarchy_params(client, node),
        bufnr,
        "prepare outgoing calls: " .. node.symbol.qualified,
        false
    )

    if prepared.err
        or not vim.islist(prepared.result)
        or not prepared.result[1]
    then
        return
    end

    local calls = await_lsp(
        slice,
        client,
        "callHierarchy/outgoingCalls",
        { item = prepared.result[1] },
        bufnr,
        "outgoing calls: " .. node.symbol.qualified,
        false
    )

    if calls.err or not vim.islist(calls.result) then
        return
    end

    for _, call in ipairs(calls.result) do
        local location = call_item_location(call.to)
        if location then
            local symbol, external = location_to_symbol(
                slice,
                client,
                location,
                call.to and call.to.name or "call"
            )
            local roots = root_ids_from(node)

            if symbol then
                local target = add_node(
                    slice,
                    symbol,
                    symbol.file,
                    "calls",
                    node.depth + 1,
                    roots,
                    "gopls outgoing call",
                    node.depth == 0
                )
                if target then
                    add_edge(slice, node, target, "calls", roots)
                end
            elseif external and not builtin_location(external.path, external.name) then
                add_external(slice, external, "calls", roots)
            end
        end
    end
end

local function implementation_nodes(slice, client, bufnr, node, purpose, required)
    local response = await_lsp(
        slice,
        client,
        "textDocument/implementation",
        hierarchy_params(client, node),
        bufnr,
        purpose,
        required
    )

    local result = {}

    for _, location in ipairs(
        not response.err and normalize_locations(response.result) or {}
    ) do
        local symbol = location_to_symbol(
            slice,
            client,
            location,
            node.symbol.name
        )

        if symbol and symbol.id ~= node.id then
            table.insert(result, symbol)
        end
    end

    return result
end

local function add_contracts(slice, client, bufnr, root)
    local kind = root.symbol.kind
    if kind ~= "method"
        and kind ~= "interface_method"
        and kind ~= "struct"
        and kind ~= "interface"
        and kind ~= "type"
    then
        return
    end

    local implementations = implementation_nodes(
        slice,
        client,
        bufnr,
        root,
        "contracts/implementations: " .. root.symbol.qualified,
        false
    )
    local contracts = {}

    for _, symbol in ipairs(implementations) do
        local relation = (symbol.kind == "interface"
            or symbol.kind == "interface_method")
            and "contract"
            or "implementation"
        local target = add_node(
            slice,
            symbol,
            symbol.file,
            relation,
            1,
            { root.id },
            relation .. " of changed root",
            relation == "contract"
        )

        if target then
            add_edge(slice, root, target, relation, { root.id })
            if relation == "contract" then
                table.insert(contracts, target)
            end
        end
    end

    local parallel_count = 0

    for _, contract in ipairs(contracts) do
        if parallel_count >= slice.opts.max_parallel_implementations then
            break
        end

        for _, symbol in ipairs(implementation_nodes(
            slice,
            client,
            bufnr,
            contract,
            "parallel implementations: " .. contract.symbol.qualified,
            false
        )) do
            if parallel_count >= slice.opts.max_parallel_implementations then
                break
            end

            if symbol.id ~= root.id then
                local target, added = add_node(
                    slice,
                    symbol,
                    symbol.file,
                    "parallel_implementation",
                    1,
                    { root.id },
                    "parallel implementation of selected contract",
                    false
                )

                if target then
                    add_edge(
                        slice,
                        contract,
                        target,
                        "parallel_implementation",
                        { root.id }
                    )
                    if added then
                        parallel_count = parallel_count + 1
                    end
                end
            end
        end
    end
end

local function path_dir(path)
    return vim.fs.dirname(path) or ""
end

local function inbound_rank(root, symbol)
    local same_dir = path_dir(root.symbol.path) == path_dir(symbol.path)
    local same_package = root.symbol.package == symbol.package
    local name_match = symbol.name:lower():find(
        root.symbol.name:lower(),
        1,
        true
    ) ~= nil
    local score
    local class

    if symbol.is_test and same_dir then
        score = 96 + (name_match and 3 or 0)
        class = "same_package_test"
    elseif symbol.is_test and same_package then
        score = 90 + (name_match and 3 or 0)
        class = "same_package_test"
    elseif not symbol.is_test and same_dir then
        score = 86
        class = "non_test"
    elseif not symbol.is_test and same_package then
        score = 82
        class = "non_test"
    elseif not symbol.is_test then
        score = 72
        class = "non_test"
    else
        score = 55 + (name_match and 3 or 0)
        class = "other_test"
    end

    if symbol.generated then
        score = score - 25
    end

    return score, class
end

local function collect_inbound_candidate(candidates, root, symbol, relation)
    if not symbol or symbol.id == root.id then
        return
    end

    local score, class = inbound_rank(root, symbol)

    -- gopls references often exposes the matching interface method even when
    -- textDocument/implementation does not return the reverse relation for a
    -- concrete method. Promote that to an explicit contract.
    if symbol.kind == "interface_method"
        or symbol.kind == "interface"
    then
        relation = "contract"
        score = 98
        class = "contract"
    end

    local existing = candidates[symbol.id]

    if not existing or score > existing.score then
        candidates[symbol.id] = {
            symbol = symbol,
            relation = relation,
            score = score,
            class = class,
        }
    end
end

local function add_inbound_context(slice, client, bufnr, root)
    local kind = root.symbol.kind
    if kind ~= "function" and kind ~= "method" then
        return
    end

    local candidates = {}
    local prepared = await_lsp(
        slice,
        client,
        "textDocument/prepareCallHierarchy",
        hierarchy_params(client, root),
        bufnr,
        "prepare incoming calls: " .. root.symbol.qualified,
        false
    )

    if not prepared.err
        and vim.islist(prepared.result)
        and prepared.result[1]
    then
        local incoming = await_lsp(
            slice,
            client,
            "callHierarchy/incomingCalls",
            { item = prepared.result[1] },
            bufnr,
            "incoming calls: " .. root.symbol.qualified,
            false
        )

        for _, call in ipairs(
            not incoming.err and incoming.result or {}
        ) do
            local location = call_item_location(call.from)
            if location then
                local symbol = location_to_symbol(
                    slice,
                    client,
                    location,
                    call.from and call.from.name or "caller"
                )
                collect_inbound_candidate(candidates, root, symbol, "caller")
            end
        end
    end

    local params = hierarchy_params(client, root)
    params.context = { includeDeclaration = false }
    local references = await_lsp(
        slice,
        client,
        "textDocument/references",
        params,
        bufnr,
        "references: " .. root.symbol.qualified,
        false
    )

    for _, location in ipairs(
        not references.err and references.result or {}
    ) do
        local symbol = location_to_symbol(
            slice,
            client,
            location,
            root.symbol.name
        )
        collect_inbound_candidate(candidates, root, symbol, "reference")
    end

    local ordered = {}
    for _, candidate in pairs(candidates) do
        table.insert(ordered, candidate)
    end
    table.sort(ordered, function(a, b)
        if a.score == b.score then
            if a.symbol.path == b.symbol.path then
                return a.symbol.start_line < b.symbol.start_line
            end
            return a.symbol.path < b.symbol.path
        end
        return a.score > b.score
    end)

    local quotas = {
        contract = 4,
        same_package_test = slice.opts.max_same_package_tests,
        non_test = slice.opts.max_non_test_callers,
        other_test = slice.opts.max_other_tests,
    }

    for _, candidate in ipairs(ordered) do
        if quotas[candidate.class] and quotas[candidate.class] > 0 then
            local relation = candidate.class == "same_package_test"
                    and "test_oracle"
                or candidate.class == "contract"
                    and "contract"
                or candidate.relation
            local target, added = add_node(
                slice,
                candidate.symbol,
                candidate.symbol.file,
                relation,
                1,
                { root.id },
                string.format(
                    "ranked inbound context (%s, score=%d)",
                    candidate.class,
                    candidate.score
                ),
                relation == "contract"
            )

            if target then
                target.score = math.max(target.score, candidate.score)
                if relation == "contract" then
                    add_edge(slice, root, target, relation, { root.id })
                else
                    add_edge(slice, target, root, relation, { root.id })
                end
                if added then
                    quotas[candidate.class] = quotas[candidate.class] - 1
                end

                if relation == "contract" then
                    local parallel_added = 0
                    for _, implementation in ipairs(implementation_nodes(
                        slice,
                        client,
                        bufnr,
                        target,
                        "parallel implementations: " .. target.symbol.qualified,
                        false
                    )) do
                        if implementation.id ~= root.id
                            and parallel_added
                                < slice.opts.max_parallel_implementations
                        then
                            local parallel, was_added = add_node(
                                slice,
                                implementation,
                                implementation.file,
                                "parallel_implementation",
                                1,
                                { root.id },
                                "parallel implementation of inbound contract",
                                false
                            )
                            if parallel then
                                add_edge(
                                    slice,
                                    target,
                                    parallel,
                                    "parallel_implementation",
                                    { root.id }
                                )
                            end
                            if was_added then
                                parallel_added = parallel_added + 1
                            end
                        end
                    end
                end
            end
        end
    end
end

local function expand_graph(slice, client, bufnr)
    local queue = {}
    local queued = {}

    local function enqueue(node)
        if node and not queued[node.id] and node_expandable(node, slice.opts) then
            queued[node.id] = true
            table.insert(queue, node)
        end
    end

    -- Changed roots are complete: every AST occurrence gets a
    -- deterministic disposition before optional graph expansion begins.
    for _, root in ipairs(slice.roots) do
        if root.symbol.deleted or root.symbol.baseline then
            record_baseline_occurrences(slice, root)
        else
            process_occurrences(slice, client, bufnr, root, true)
            add_contracts(slice, client, bufnr, root)
            add_inbound_context(slice, client, bufnr, root)
            expand_outgoing_calls(slice, client, bufnr, root)
            enqueue(root)
        end
    end

    local index = 1

    while index <= #queue do
        local node = queue[index]
        index = index + 1

        if not node.expanded and node_expandable(node, slice.opts) then
            node.expanded = true

            -- Root occurrences were already processed in full.
            if node.depth > 0 then
                process_occurrences(slice, client, bufnr, node, false)
            end

            expand_outgoing_calls(slice, client, bufnr, node)

            for _, candidate in ipairs(slice.nodes) do
                if candidate.depth > node.depth
                    and candidate.depth <= slice.opts.outbound_depth
                then
                    enqueue(candidate)
                end
            end
        end
    end

    return slice
end

local function workspace_buffer_ticks(root)
    local ticks = {}

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr)
            and vim.bo[bufnr].filetype == "go"
        then
            local path = normalize(vim.api.nvim_buf_get_name(bufnr))
            if path and is_inside(root, path) then
                ticks[path] = vim.api.nvim_buf_get_changedtick(bufnr)
            end
        end
    end

    return ticks
end

function M.buffers_unchanged(slice)
    for path, tick in pairs(slice.buffer_ticks or {}) do
        local bufnr = vim.fn.bufnr(path, false)
        if bufnr >= 0 and vim.api.nvim_buf_is_loaded(bufnr) then
            if vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
                return false
            end
        end
    end

    return true
end

function M.snapshot_signature(opts, callback)
    go_index.snapshot(opts, function(snapshot, err)
        callback(snapshot and snapshot.signature or nil, err)
    end)
end

function M.build(opts, callback)
    opts = vim.tbl_deep_extend("force", defaults, opts or {})

    local token = opts.cancel_token or { cancelled = false }
    local current_path = vim.api.nvim_buf_get_name(opts.bufnr)
    local current_line = vim.api.nvim_win_get_cursor(0)[1]

    go_index.snapshot({
        root = opts.root,
        current_file = current_path,
        current_line = current_line,
    }, function(snapshot, snapshot_err)
        if snapshot_err then
            callback(nil, snapshot_err)
            return
        end

        if token.cancelled then
            callback(nil, "cancelled")
            return
        end

        local slice = new_slice(opts, snapshot)
        slice.buffer_ticks = workspace_buffer_ticks(slice.root)

        for _, root_symbol in ipairs(snapshot.roots or {}) do
            local root, _ = add_node(
                slice,
                root_symbol,
                root_symbol.file,
                "root",
                0,
                { root_symbol.id },
                "changed declaration",
                true
            )

            if root then
                root.score = 100
                table.insert(slice.roots, root)
                ledger_for(slice, root)
            end
        end

        if #slice.roots == 0 then
            callback(nil, "no changed or enclosing Go declaration found")
            return
        end

        run_async(token, function()
            return expand_graph(slice, opts.client, opts.bufnr)
        end, function(result)
            if #result.gaps > 0 and not opts.allow_incomplete then
                for _, gap in ipairs(result.gaps) do
                    if gap.required then
                        result.complete = false
                        break
                    end
                end
            end

            callback(result, nil)
        end, function(err)
            callback(nil, tostring(err))
        end)
    end)
end

local function node_label(node)
    return string.format(
        "%s %s %s:%d-%d",
        node.symbol.kind,
        node.symbol.qualified,
        node.symbol.path,
        node.symbol.start_line,
        node.symbol.end_line
    )
end

function M.format_graph(slice)
    if not slice then
        return "No semantic graph built yet."
    end

    local lines = {
        "CHANGE GRAPH",
        "============",
        "",
        "root: " .. slice.root,
        "snapshot: " .. tostring(slice.signature),
        "roots: " .. tostring(#slice.roots),
        "nodes: " .. tostring(#slice.nodes),
        "edges: " .. tostring(#slice.edges),
        "externals: " .. tostring(#slice.externals),
        "gaps: " .. tostring(#slice.gaps),
        "complete: " .. tostring(slice.complete),
        "truncated: " .. tostring(slice.truncated),
        "",
        "CHANGED ROOTS",
        "-------------",
    }

    for _, root in ipairs(slice.roots) do
        table.insert(lines, "- [" .. root.id .. "] " .. node_label(root))
    end

    table.insert(lines, "")
    table.insert(lines, "NODES")
    table.insert(lines, "-----")

    local nodes = copy_array(slice.nodes)
    table.sort(nodes, function(a, b)
        if a.score == b.score then
            if a.symbol.path == b.symbol.path then
                return a.symbol.start_line < b.symbol.start_line
            end
            return a.symbol.path < b.symbol.path
        end
        return a.score > b.score
    end)

    for _, node in ipairs(nodes) do
        table.insert(lines, string.format(
            "[%s] score=%d depth=%d mandatory=%s roots=%s relations=%s :: %s",
            node.id,
            node.score,
            node.depth,
            tostring(node.mandatory),
            table.concat(sorted_keys(node.root_ids), ","),
            table.concat(sorted_keys(node.relations), ","),
            node_label(node)
        ))
    end

    table.insert(lines, "")
    table.insert(lines, "EDGES")
    table.insert(lines, "-----")

    for _, edge in ipairs(slice.edges) do
        table.insert(lines, string.format(
            "%s --%s--> %s  roots=%s",
            edge.from,
            edge.relation,
            edge.to,
            table.concat(sorted_keys(edge.root_ids), ",")
        ))
    end

    if #slice.externals > 0 then
        table.insert(lines, "")
        table.insert(lines, "EXTERNAL API SURFACE")
        table.insert(lines, "--------------------")

        for _, external in ipairs(slice.externals) do
            table.insert(lines, string.format(
                "[%s] class=%s roots=%s relations=%s name=%s source=%s signature=%s",
                external.id,
                external.class,
                table.concat(sorted_keys(external.root_ids), ","),
                table.concat(sorted_keys(external.relations), ","),
                external.name,
                external.path or external.uri or "?",
                external.signature or ""
            ))
        end
    end

    return table.concat(lines, "\n")
end

function M.format_materiality(slice)
    if not slice then
        return "No semantic graph built yet."
    end

    local lines = {
        "IDENTIFIERS OF CHANGED ROOTS",
        "============================",
    }

    for _, root in ipairs(slice.roots) do
        local ledger = slice.materiality[root.id]
        table.insert(lines, "")
        table.insert(lines, string.format(
            "ROOT [%s] %s",
            root.id,
            node_label(root)
        ))
        table.insert(lines, string.format(
            "coverage: total=%d internal=%d external=%d local=%d builtin=%d baseline=%d unresolved=%d",
            ledger.total,
            ledger.resolved_internal,
            ledger.resolved_external,
            ledger.local_count,
            ledger.builtin_count,
            ledger.baseline_count,
            ledger.unresolved
        ))

        for _, entry in ipairs(ledger.entries) do
            table.insert(lines, string.format(
                "- %s:%d:%d %-10s %-24s -> %-10s %s %s",
                entry.path,
                entry.line,
                entry.col,
                entry.kind,
                entry.name,
                entry.disposition,
                table.concat(entry.target_ids or {}, ","),
                entry.detail or ""
            ))
        end
    end

    if #slice.gaps > 0 then
        table.insert(lines, "")
        table.insert(lines, "REQUIRED GAPS")
        table.insert(lines, "-------------")
        for _, gap in ipairs(slice.gaps) do
            table.insert(lines, string.format(
                "- root=%s required=%s %s:%s:%s %s (%s)",
                tostring(gap.root_id),
                tostring(gap.required),
                tostring(gap.path or "?"),
                tostring(gap.line or "?"),
                tostring(gap.col or "?"),
                tostring(gap.name or "?"),
                tostring(gap.reason)
            ))
        end
    end

    return table.concat(lines, "\n")
end

function M.format_requests(slice)
    if not slice then
        return "No semantic graph built yet."
    end

    local lines = {
        "LSP REQUEST TRACE",
        "=================",
    }

    for _, request in ipairs(slice.requests) do
        table.insert(lines, string.format(
            "[%03d] %-8s %7.1fms required=%s %-36s %s%s",
            request.id,
            request.status,
            request.duration_ms or 0,
            tostring(request.required),
            request.method,
            request.purpose or "",
            request.error and (" :: " .. request.error) or ""
        ))
    end

    return table.concat(lines, "\n")
end

return M
