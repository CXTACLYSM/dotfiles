local M = {}

local config = {
    binary = vim.fn.stdpath("data") .. "/change-tree/go-change-index",
    timeout_ms = 20000,
}

local cache = {}

local function normalize(path)
    if not path or path == "" then
        return nil
    end

    local absolute = vim.fs.normalize(vim.fs.abspath(path))
    return vim.uv.fs_realpath(absolute) or absolute
end

local function relative(root, path)
    return vim.fs.relpath(root, path) or path
end

local function loaded_buffer(path)
    local bufnr = vim.fn.bufnr(path, false)

    if bufnr >= 0 and vim.api.nvim_buf_is_loaded(bufnr) then
        return bufnr
    end

    return nil
end

local function file_stamp(path)
    local bufnr = loaded_buffer(path)

    if bufnr then
        return "buf:" .. tostring(vim.api.nvim_buf_get_changedtick(bufnr))
    end

    local stat = vim.uv.fs_stat(path)
    if not stat then
        return nil
    end

    local mtime = stat.mtime or {}

    return table.concat({
        "fs",
        tostring(stat.size or 0),
        tostring(mtime.sec or 0),
        tostring(mtime.nsec or 0),
    }, ":")
end

local function buffer_content(path)
    local bufnr = loaded_buffer(path)

    if not bufnr then
        return nil
    end

    return table.concat(
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
        "\n"
    )
end

local function enrich_file(root, file)
    if not file then
        return nil
    end

    file.root = root
    file.absolute_path = normalize(root .. "/" .. file.path)
    file.symbol_by_id = {}
    file.top_level = {}
    file.members_by_owner = {}
    file.lines = vim.split(file.source or "", "\n", {
        plain = true,
        trimempty = false,
    })

    for _, symbol in ipairs(file.symbols or {}) do
        file.symbol_by_id[symbol.id] = symbol
        symbol.file = file
        symbol.absolute_path = file.absolute_path

        if symbol.top_level then
            table.insert(file.top_level, symbol)
        end

        if symbol.owner_id and symbol.owner_id ~= "" then
            file.members_by_owner[symbol.owner_id] =
                file.members_by_owner[symbol.owner_id] or {}
            table.insert(file.members_by_owner[symbol.owner_id], symbol)
        end
    end

    return file
end

local function cache_file(root, file, cache_key)
    file = enrich_file(root, file)
    if not file then
        return nil
    end

    local key = cache_key or file.absolute_path

    cache[key] = {
        stamp = file.baseline and ("baseline:" .. tostring(file.sha256))
            or file_stamp(file.absolute_path),
        file = file,
    }

    return file
end

local function decode_result(result, callback)
    vim.schedule(function()
        if result.code ~= 0 and (not result.stdout or result.stdout == "") then
            callback(nil, vim.trim(result.stderr or "go index helper failed"))
            return
        end

        local ok, payload = pcall(vim.json.decode, result.stdout or "")

        if not ok or type(payload) ~= "table" then
            callback(nil, "go index helper returned invalid JSON")
            return
        end

        if not payload.ok then
            callback(nil, payload.error or "go index helper failed")
            return
        end

        if tonumber(payload.version) ~= 3 then
            callback(nil, string.format(
                "go index protocol mismatch: expected 3, got %s",
                tostring(payload.version)
            ))
            return
        end

        callback(payload, nil)
    end)
end

local function request(body, callback)
    if vim.fn.executable(config.binary) ~= 1 then
        callback(nil, "missing helper: " .. config.binary)
        return
    end

    local encoded = vim.json.encode(body)

    vim.system({ config.binary }, {
        text = true,
        stdin = encoded,
        timeout = config.timeout_ms,
    }, function(result)
        decode_result(result, callback)
    end)
end

function M.setup(opts)
    config = vim.tbl_deep_extend("force", config, opts or {})
end

function M.binary()
    return config.binary
end

function M.clear_cache()
    cache = {}
end

function M.snapshot(opts, callback)
    request({
        mode = "snapshot",
        root = opts.root,
        current_file = opts.current_file,
        current_line = opts.current_line,
    }, function(payload, err)
        if err then
            callback(nil, err)
            return
        end

        local snapshot = payload.snapshot
        snapshot.root = normalize(snapshot.root)
        snapshot.files = type(snapshot.files) == "table"
                and snapshot.files
            or {}
        snapshot.roots = type(snapshot.roots) == "table"
                and snapshot.roots
            or {}

        for key, file in pairs(snapshot.files) do
            local cache_key

            if file.baseline then
                cache_key = snapshot.root .. "/" .. key
            else
                cache_key = normalize(snapshot.root .. "/" .. file.path)
            end

            snapshot.files[key] = cache_file(
                snapshot.root,
                file,
                cache_key
            )
        end

        for _, root_symbol in ipairs(snapshot.roots) do
            local file = snapshot.files[root_symbol.path]
                or snapshot.files[root_symbol.path .. "#HEAD"]

            if file then
                local canonical = file.symbol_by_id[root_symbol.id]
                if canonical then
                    for key, value in pairs(root_symbol) do
                        canonical[key] = value
                    end
                    root_symbol = canonical
                else
                    root_symbol.file = file
                    root_symbol.absolute_path = file.absolute_path
                end
            end
        end

        -- Replace root array with canonical cached symbol tables.
        local roots = {}
        for _, root_symbol in ipairs(snapshot.roots) do
            local file = snapshot.files[root_symbol.path]
                or snapshot.files[root_symbol.path .. "#HEAD"]
            local canonical = file
                and (file.symbol_by_id[root_symbol.id] or root_symbol)
                or root_symbol

            canonical.file = file
            canonical.absolute_path = file and file.absolute_path
                or normalize(snapshot.root .. "/" .. canonical.path)
            canonical.deleted = root_symbol.deleted == true
            canonical.baseline = root_symbol.baseline == true

            table.insert(roots, canonical)
        end
        snapshot.roots = roots

        callback(snapshot, nil)
    end)
end

function M.inspect_file(root, path, callback)
    root = normalize(root)
    path = normalize(path)

    local cached = cache[path]
    local stamp = file_stamp(path)

    if cached and cached.stamp == stamp then
        callback(cached.file, nil)
        return
    end

    request({
        mode = "inspect_file",
        root = root,
        path = path,
        content = buffer_content(path),
    }, function(payload, err)
        if err then
            callback(nil, err)
            return
        end

        callback(cache_file(root, payload.file, path), nil)
    end)
end

local function position_inside(symbol, line, col)
    if line < symbol.start_line or line > symbol.end_line then
        return false
    end

    if line == symbol.start_line and col < symbol.start_col then
        return false
    end

    if line == symbol.end_line and col > symbol.end_col then
        return false
    end

    return true
end

local function name_inside(symbol, line, col)
    if line < symbol.name_line or line > symbol.name_end_line then
        return false
    end

    if line == symbol.name_line and col < symbol.name_col then
        return false
    end

    if line == symbol.name_end_line and col > symbol.name_end_col then
        return false
    end

    return true
end

function M.symbol_at(file, line, byte_col)
    if not file then
        return nil
    end

    local best = nil
    local best_rank = -1
    local best_span = math.huge

    for _, symbol in ipairs(file.symbols or {}) do
        local rank = 0

        if name_inside(symbol, line, byte_col) then
            rank = symbol.owner_id and symbol.owner_id ~= "" and 4 or 3
        elseif position_inside(symbol, line, byte_col) then
            rank = symbol.owner_id and symbol.owner_id ~= "" and 2 or 1
        end

        if rank > 0 then
            local span = (symbol.end_offset or 0)
                - (symbol.start_offset or 0)

            if rank > best_rank
                or (rank == best_rank and span < best_span)
            then
                best = symbol
                best_rank = rank
                best_span = span
            end
        end
    end

    return best
end

function M.owner(file, symbol)
    if not file or not symbol or not symbol.owner_id then
        return nil
    end

    return file.symbol_by_id[symbol.owner_id]
end

function M.source(file, symbol)
    if not file or not symbol then
        return ""
    end

    local start_offset = tonumber(symbol.start_offset) or 0
    local end_offset = tonumber(symbol.end_offset) or start_offset

    local source = (file.source or ""):sub(start_offset + 1, end_offset)

    if (symbol.kind == "type"
        or symbol.kind == "struct"
        or symbol.kind == "interface")
        and not source:match("^%s*type%s")
    then
        source = "type " .. source
    elseif symbol.kind == "const"
        and not symbol.implicit
        and not source:match("^%s*const%s")
    then
        source = "const " .. source
    elseif symbol.kind == "var"
        and not source:match("^%s*var%s")
    then
        source = "var " .. source
    end

    return source
end

function M.container_source(file, symbol)
    if not file or not symbol then
        return ""
    end

    local start_offset = tonumber(symbol.container_start_offset) or 0
    local end_offset = tonumber(symbol.container_end_offset) or start_offset

    return (file.source or ""):sub(start_offset + 1, end_offset)
end

function M.projection(file, owner, selected_member_ids)
    if not file or not owner then
        return ""
    end

    local selected = {}
    for member_id in pairs(selected_member_ids or {}) do
        local member = file.symbol_by_id[member_id]
        if member then
            table.insert(selected, member)
        end
    end

    table.sort(selected, function(a, b)
        return a.start_offset < b.start_offset
    end)

    if #selected == 0 then
        return M.source(file, owner)
    end

    local lines = {
        owner.header_source ~= "" and owner.header_source
            or ("type " .. owner.name .. " " .. owner.kind .. " {")
    }
    local seen_source = {}

    for _, member in ipairs(selected) do
        local source = M.source(file, member)
        if source ~= "" and not seen_source[source] then
            seen_source[source] = true
            table.insert(lines, source)
        end
    end

    table.insert(lines, owner.footer_source ~= "" and owner.footer_source or "}")

    return table.concat(lines, "\n")
end

function M.line(file, one_based_line)
    return file and file.lines and file.lines[one_based_line] or ""
end

function M.line_for_offset(file, offset)
    if not file then
        return 1
    end

    offset = math.max(tonumber(offset) or 0, 0)
    local prefix = (file.source or ""):sub(1, offset)
    local _, newlines = prefix:gsub("\n", "\n")

    return newlines + 1
end

function M.lsp_character_to_byte(file, one_based_line, character, encoding)
    local line = M.line(file, one_based_line)
    encoding = encoding or "utf-16"

    local ok, byte_index = pcall(
        vim.str_byteindex,
        line,
        encoding,
        character,
        false
    )

    if ok then
        return byte_index + 1
    end

    return character + 1
end

function M.byte_to_lsp_character(file, one_based_line, one_based_col, encoding)
    local line = M.line(file, one_based_line)
    encoding = encoding or "utf-16"

    local ok, character = pcall(
        vim.str_utfindex,
        line,
        encoding,
        math.max(one_based_col - 1, 0),
        false
    )

    if ok then
        return character
    end

    return math.max(one_based_col - 1, 0)
end

function M.relative(root, path)
    return relative(root, path)
end

return M
