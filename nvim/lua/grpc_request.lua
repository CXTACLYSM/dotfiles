-- grq: a grpcurl request for the rpc under the cursor, typed into the
-- `rpc` window of the tmux session (created on demand, as `tests` receives
-- the tests) and left there to edit and run:
--
--   grpcurl -plaintext -d '{"user_id": 0}' localhost:8082 order.v1.OrderService/CreateOrder
--
-- In a .proto the cursor is on an rpc or inside its block; in Go on a
-- handler method, a client call or anything else grp maps to an rpc. The
-- JSON is a template of the request message from the .proto files of the
-- project: every field with a sample value (strings "", numbers 0, bool
-- false, an enum its first real value, repeated one element, map one
-- entry, oneof its first member, nested messages recursively, well-known
-- types such as Timestamp or Duration as samples). The address is the
-- port next to the word grpc in .env, config, compose or Makefile files,
-- localhost:8080 otherwise; without `reflection.Register` in the project
-- the schema goes to grpcurl with -import-path / -proto. Outside tmux the
-- line goes to the clipboard.
--
-- The parser reads a .proto as tokens (comments and strings aside), so
-- statements over several lines and options with braces are fine. Types
-- resolve like protoc does: from the message outwards to the package,
-- then by full name across the imported files of the project.
-- nvim/tools/grpc_request.lua gives the same templates to tmux/docs.

local M = {}

M.opts = {
    -- When no port is found next to "grpc" in the project.
    address = "localhost:8080",
    -- Nested messages deeper than this become {}.
    max_depth = 8,
    -- Files looked through for the gRPC port.
    address_files = { ".env*", "*.env", "*config*.y*ml", "*values*.y*ml", "Makefile", "*compose*.y*ml", "*.toml" },
}

local function notify(message, level)
    vim.notify(message, level or vim.log.levels.INFO, { title = "grq" })
end

local function file_lines(path)
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines or nil
end

-- ============================================================
-- .proto parsing
-- ============================================================

-- Tokens: { text, row (0-based), string = true for a literal }.
function M.tokenize(text)
    local tokens, row, i, n = {}, 0, 1, #text
    while i <= n do
        local c = text:sub(i, i)
        if c == "\n" then
            row, i = row + 1, i + 1
        elseif c:match("%s") then
            i = i + 1
        elseif text:sub(i, i + 1) == "//" then
            i = text:find("\n", i, true) or (n + 1)
        elseif text:sub(i, i + 1) == "/*" then
            local close = text:find("*/", i + 2, true)
            local chunk = text:sub(i, close and close + 1 or n)
            row = row + select(2, chunk:gsub("\n", ""))
            i = close and close + 2 or n + 1
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = text:sub(j, j)
                if d == "\\" then
                    j = j + 2
                elseif d == c then
                    break
                else
                    j = j + 1
                end
            end
            table.insert(tokens, { text = text:sub(i + 1, j - 1), row = row, string = true })
            i = j + 1
        else
            local word = text:match("^[%w_%.%-]+", i)
            if word then
                table.insert(tokens, { text = word, row = row })
                i = i + #word
            else
                table.insert(tokens, { text = c, row = row })
                i = i + 1
            end
        end
    end
    return tokens
end

-- A parsed file: { package, imports, messages[full] = { name, full, fields,
-- row, end_row }, enums[full] = { name, full, values }, services[name] =
-- { name, full, rpcs = { { name, request, response, row, client_stream,
-- server_stream } } }, order (messages as declared) }. A field: { name,
-- type, number, label (repeated / optional / required), map = { key,
-- value }, oneof, oneof_first }.
function M.parse(text)
    local tokens = M.tokenize(text)
    local file = { package = "", imports = {}, messages = {}, enums = {}, services = {}, order = {}, service_list = {} }
    local at = 1

    local function peek(ahead)
        local item = tokens[at + (ahead or 0)]
        return item and item.text
    end
    local function take()
        local item = tokens[at] or { text = "", row = 0 }
        at = at + 1
        return item
    end
    -- Past the next `stop` outside brackets; the brackets met on the way
    -- are skipped as a whole.
    local function skip_until(stop)
        local depth = 0
        while tokens[at] do
            local text = take().text
            if text == "{" or text == "(" or text == "[" or text == "<" then
                depth = depth + 1
            elseif text == "}" or text == ")" or text == "]" or text == ">" then
                depth = depth - 1
            end
            if text == stop and depth <= 0 then
                return
            end
        end
    end
    -- Past the block that starts at the next `{`.
    local function skip_block()
        while tokens[at] and take().text ~= "{" do
        end
        local depth = 1
        while tokens[at] do
            local text = take().text
            if text == "{" then
                depth = depth + 1
            elseif text == "}" then
                depth = depth - 1
                if depth == 0 then
                    return
                end
            end
        end
    end
    local function full(scope, name)
        return scope ~= "" and (scope .. "." .. name) or name
    end

    local parse_message, parse_enum

    -- Fields and nested declarations until the `}` of the body.
    local function parse_body(message, scope)
        while tokens[at] do
            local text = peek()
            if text == "}" then
                take()
                return
            elseif text == "message" then
                take()
                parse_message(scope)
            elseif text == "enum" then
                take()
                parse_enum(scope)
            elseif text == "oneof" then
                take()
                local name = take().text
                take() -- {
                local inner = { fields = {} }
                parse_body(inner, scope)
                for index, field in ipairs(inner.fields) do
                    field.oneof, field.oneof_first = name, index == 1
                    table.insert(message.fields, field)
                end
            elseif text == "extend" then
                take()
                skip_block()
            elseif text == "option" or text == "reserved" or text == "extensions" then
                take()
                skip_until(";")
            elseif text == ";" then
                take()
            elseif text == "group" or peek(1) == "group" then
                skip_block()
            else
                local field = {}
                if text == "repeated" or text == "optional" or text == "required" then
                    field.label = text
                    take()
                end
                if peek() == "map" and peek(1) == "<" then
                    take()
                    take()
                    local key = take().text
                    take() -- ,
                    local value = take().text
                    take() -- >
                    field.type, field.map = "map", { key = key, value = value }
                else
                    field.type = take().text
                end
                field.name = take().text
                if peek() == "=" then
                    take()
                    field.number = tonumber(take().text)
                end
                if peek() == "[" then
                    skip_until("]")
                end
                if peek() == ";" then
                    take()
                end
                if field.name ~= "" and field.type ~= "" and field.number then
                    table.insert(message.fields, field)
                end
            end
        end
    end

    parse_message = function(scope)
        local name = take()
        local message = { name = name.text, full = full(scope, name.text), fields = {}, row = name.row }
        take() -- {
        parse_body(message, message.full)
        message.end_row = (tokens[at - 1] or name).row
        file.messages[message.full] = message
        table.insert(file.order, message)
    end

    parse_enum = function(scope)
        local name = take()
        local enum = { name = name.text, full = full(scope, name.text), values = {}, row = name.row }
        take() -- {
        while tokens[at] do
            local text = peek()
            if text == "}" then
                take()
                break
            elseif text == "option" or text == "reserved" then
                take()
                skip_until(";")
            elseif text == ";" then
                take()
            else
                local value = take().text
                if peek() == "=" then
                    take()
                    table.insert(enum.values, { name = value, number = tonumber(take().text) })
                end
                if peek() == "[" then
                    skip_until("]")
                end
                if peek() == ";" then
                    take()
                end
            end
        end
        file.enums[enum.full] = enum
    end

    local function parse_service()
        local name = take()
        local service = { name = name.text, full = full(file.package, name.text), rpcs = {}, row = name.row }
        take() -- {
        while tokens[at] do
            local text = peek()
            if text == "}" then
                take()
                break
            elseif text == "rpc" then
                take()
                local rpc_name = take()
                local rpc = { name = rpc_name.text, row = rpc_name.row }
                take() -- (
                if peek() == "stream" then
                    rpc.client_stream = true
                    take()
                end
                rpc.request = take().text
                take() -- )
                if peek() == "returns" then
                    take()
                end
                take() -- (
                if peek() == "stream" then
                    rpc.server_stream = true
                    take()
                end
                rpc.response = take().text
                take() -- )
                if peek() == "{" then
                    skip_block()
                elseif peek() == ";" then
                    take()
                end
                table.insert(service.rpcs, rpc)
            elseif text == "option" then
                take()
                skip_until(";")
            else
                take()
            end
        end
        file.services[service.name] = service
        table.insert(file.service_list, service)
    end

    while tokens[at] do
        local text = take().text
        if text == "package" then
            file.package = take().text
            skip_until(";")
        elseif text == "import" then
            if peek() == "public" or peek() == "weak" then
                take()
            end
            local path = take()
            if path.string then
                table.insert(file.imports, path.text)
            end
            skip_until(";")
        elseif text == "message" then
            parse_message(file.package)
        elseif text == "enum" then
            parse_enum(file.package)
        elseif text == "service" then
            parse_service()
        elseif text == "extend" then
            skip_block()
        elseif text == "syntax" or text == "edition" or text == "option" then
            skip_until(";")
        end
    end
    return file
end

-- Every .proto of the project (relative paths), once per `loaded`.
local function project_protos(root, loaded)
    if not loaded.protos then
        local result = vim.system({ "rg", "--files", "--no-ignore", "--glob", "*.proto", "--glob", "!**/node_modules/**" },
            { cwd = root, text = true }):wait()
        loaded.protos = vim.split(result.stdout or "", "\n", { trimempty = true })
        table.sort(loaded.protos, function(a, b)
            local va, vb = a:find("vendor") ~= nil, b:find("vendor") ~= nil
            if va ~= vb then
                return vb
            end
            return #a < #b
        end)
    end
    return loaded.protos
end

-- The project file an `import "x/y.proto"` names: the one whose path ends
-- with it (vendored copies last), with the import root it was found under.
function M.import_file(root, import, loaded)
    for _, rel in ipairs(project_protos(root, loaded)) do
        if rel == import then
            return root .. "/" .. rel, root
        elseif rel:sub(-#import - 1) == "/" .. import then
            return root .. "/" .. rel, root .. "/" .. rel:sub(1, #rel - #import - 1)
        end
    end
    return nil
end

-- The .proto `path` and its imports, transitively, as far as they are in
-- the project: { files[path], messages[full], enums[full], roots[dir] }.
function M.load(root, path, loaded)
    loaded = loaded or { files = {}, messages = {}, enums = {}, roots = {} }
    if loaded.files[path] then
        return loaded
    end
    local lines = file_lines(path)
    if not lines then
        return loaded
    end
    local file = M.parse(table.concat(lines, "\n"))
    file.path = path
    loaded.files[path] = file
    for full, message in pairs(file.messages) do
        message.file = path
        loaded.messages[full] = loaded.messages[full] or message
    end
    for full, enum in pairs(file.enums) do
        loaded.enums[full] = loaded.enums[full] or enum
    end
    for _, import in ipairs(file.imports) do
        local found, import_root = M.import_file(root, import, loaded)
        if found then
            loaded.roots[import_root] = true
            M.load(root, found, loaded)
        end
    end
    return loaded
end

-- ============================================================
-- Templates
-- ============================================================

local scalars = {
    double = 0, float = 0, int32 = 0, int64 = 0, uint32 = 0, uint64 = 0, sint32 = 0, sint64 = 0,
    fixed32 = 0, fixed64 = 0, sfixed32 = 0, sfixed64 = 0, bool = false, string = "", bytes = "",
}

-- Values are strings, numbers, booleans, { array = { … } } or
-- { object = { { name, value }, … } } so the fields keep their order.
local function object(fields)
    return { object = fields or {} }
end

local well_known = {
    ["google.protobuf.Timestamp"] = "2025-01-01T00:00:00Z",
    ["google.protobuf.Duration"] = "1s",
    ["google.protobuf.Empty"] = object(),
    ["google.protobuf.Struct"] = object(),
    ["google.protobuf.Value"] = "",
    ["google.protobuf.ListValue"] = { array = {} },
    ["google.protobuf.Any"] = object(),
    ["google.protobuf.FieldMask"] = "",
    ["google.protobuf.StringValue"] = "",
    ["google.protobuf.BytesValue"] = "",
    ["google.protobuf.BoolValue"] = false,
    ["google.protobuf.Int32Value"] = 0,
    ["google.protobuf.Int64Value"] = 0,
    ["google.protobuf.UInt32Value"] = 0,
    ["google.protobuf.UInt64Value"] = 0,
    ["google.protobuf.FloatValue"] = 0,
    ["google.protobuf.DoubleValue"] = 0,
}

-- The declaration `name` refers to from inside `scope` (a full message
-- name or the package): "message" / "enum" and the full name, or nil and
-- the name as written.
function M.resolve(loaded, scope, name)
    if name:sub(1, 1) == "." then
        name = name:sub(2)
        return loaded.messages[name] and "message" or loaded.enums[name] and "enum" or nil, name
    end
    local parts = scope ~= "" and vim.split(scope, ".", { plain = true }) or {}
    for index = #parts, 0, -1 do
        local prefix = table.concat(vim.list_slice(parts, 1, index), ".")
        local candidate = prefix ~= "" and (prefix .. "." .. name) or name
        if loaded.messages[candidate] then
            return "message", candidate
        elseif loaded.enums[candidate] then
            return "enum", candidate
        end
    end
    return nil, name
end

-- The first real value of an enum: the second when the first is the zero
-- value (STATUS_UNSPECIFIED), the first otherwise.
function M.enum_sample(enum)
    local values = enum.values
    if #values >= 2 and values[1].number == 0 then
        return values[2].name
    end
    return values[1] and values[1].name or 0
end

local template

-- A sample for a field type seen from `scope`.
function M.sample(loaded, scope, type_name, seen, depth)
    if scalars[type_name] ~= nil then
        return scalars[type_name]
    end
    local kind, full = M.resolve(loaded, scope, type_name)
    if kind == "enum" then
        return M.enum_sample(loaded.enums[full])
    elseif kind == "message" then
        return template(loaded, full, seen, depth)
    end
    local known = well_known[full]
    if known ~= nil then
        return type(known) == "table" and vim.deepcopy(known) or known
    end
    return object()
end

-- The template of a message: every field in order with a sample value;
-- a type met again on the way down, or too deep, is {}.
template = function(loaded, full, seen, depth)
    seen = seen or {}
    depth = depth or 0
    local message = loaded.messages[full]
    if not message or seen[full] or depth > M.opts.max_depth then
        return object()
    end
    seen[full] = true
    local fields = {}
    for _, field in ipairs(message.fields) do
        if not field.oneof or field.oneof_first then
            local value
            if field.map then
                local key = field.map.key == "string" and "key" or field.map.key == "bool" and "false" or "0"
                value = object({ { key, M.sample(loaded, message.full, field.map.value, seen, depth + 1) } })
            else
                value = M.sample(loaded, message.full, field.type, seen, depth + 1)
                if field.label == "repeated" then
                    value = { array = { value } }
                end
            end
            table.insert(fields, { field.name, value })
        end
    end
    seen[full] = nil
    return object(fields)
end
M.template = template

-- One line of JSON, fields in their order: {"user_id": 0, "items": [{"sku": ""}]}.
function M.json(value)
    local kind = type(value)
    if kind == "string" then
        return '"' .. value:gsub('[%c"\\]', function(c)
            return string.format("\\u%04x", c:byte())
        end) .. '"'
    elseif kind == "number" or kind == "boolean" then
        return tostring(value)
    elseif value.array then
        local items = {}
        for _, item in ipairs(value.array) do
            table.insert(items, M.json(item))
        end
        return "[" .. table.concat(items, ", ") .. "]"
    end
    local fields = {}
    for _, field in ipairs(value.object) do
        table.insert(fields, M.json(field[1]) .. ": " .. M.json(field[2]))
    end
    return "{" .. table.concat(fields, ", ") .. "}"
end

-- ============================================================
-- The command
-- ============================================================

local function lines_of(cmd, cwd)
    local result = vim.system(cmd, { cwd = cwd, text = true }):wait()
    return vim.split(result.stdout or "", "\n", { trimempty = true })
end

-- host:port of the gRPC server: a port next to the word grpc (the line or
-- the three after it) in the address files, M.opts.address otherwise.
function M.address(root)
    local cmd = { "rg", "-i", "--no-heading", "--no-line-number", "--no-filename", "--sort", "path", "-A", "3", "--max-count", "5" }
    for _, glob in ipairs(M.opts.address_files) do
        vim.list_extend(cmd, { "--glob", glob })
    end
    vim.list_extend(cmd, { "--glob", "!**/node_modules/**", "--glob", "!**/vendor/**", "-e", "grpc", "." })
    for _, line in ipairs(lines_of(cmd, root)) do
        local port = line:match("[Pp][Oo][Rr][Tt]%s*[:=]%s*[\"']?(%d%d%d%d%d?)%f[^%d]")
            or line:match(":(%d%d%d%d%d?)%f[^%d]")
        if port then
            return "localhost:" .. port
        end
    end
    return M.opts.address
end

-- Whether a Go file of the project registers server reflection: then
-- grpcurl needs no .proto.
function M.uses_reflection(root)
    local result = vim.system({ "rg", "-l", "-q", "--glob", "*.go", "--glob", "!**/vendor/**", "--glob", "!**/node_modules/**",
        "-e", [[reflection\.Register]], "." }, { cwd = root, text = true }):wait()
    return result.code == 0
end

-- -import-path / -proto for `proto_path` (absolute): the roots its imports
-- were found under, the file itself relative to one of them (its own
-- folder otherwise). Paths relative to the project root.
function M.schema_flags(root, loaded, proto_path)
    local roots = vim.tbl_keys(loaded.roots)
    table.sort(roots)
    local proto
    for _, candidate in ipairs(roots) do
        local rel = vim.fs.relpath(candidate, proto_path)
        if rel then
            proto = rel
            break
        end
    end
    if not proto then
        local dir = vim.fs.dirname(proto_path)
        table.insert(roots, dir)
        proto = vim.fs.basename(proto_path)
    end
    local flags = {}
    for _, dir in ipairs(roots) do
        vim.list_extend(flags, { "-import-path", vim.fs.relpath(root, dir) or dir })
    end
    vim.list_extend(flags, { "-proto", proto })
    return flags
end

local function shell_quote(text)
    if text:match("^[%w%-%./=_,:]+$") then
        return text
    end
    return "'" .. text:gsub("'", "'\\''") .. "'"
end

-- The grpcurl line for `rpc` of `service` declared in `proto_path`.
-- opts: address, reflection (booleans / strings to skip the lookups).
function M.command(root, proto_path, service, rpc, loaded, opts)
    opts = opts or {}
    loaded = loaded or M.load(root, proto_path)
    local file = loaded.files[proto_path]
    local parts = { "grpcurl", "-plaintext" }
    local reflection = opts.reflection
    if reflection == nil then
        reflection = M.uses_reflection(root)
    end
    if not reflection then
        vim.list_extend(parts, M.schema_flags(root, loaded, proto_path))
    end
    local _, request = M.resolve(loaded, file and file.package or "", rpc.request)
    local body = M.json(M.sample(loaded, file and file.package or "", rpc.request))
    if request == "google.protobuf.Empty" then
        body = "{}"
    end
    vim.list_extend(parts, { "-d", shell_quote(body) })
    table.insert(parts, opts.address or M.address(root))
    table.insert(parts, service.full .. "/" .. rpc.name)
    return table.concat(parts, " ")
end

-- The rpc at `row` of a .proto (lines): service and rpc of the parsed
-- file, or nil and a reason.
function M.rpc_at(loaded, path, lines, row)
    local target = require("go_proto").proto_target(lines, row)
    if not target or target.kind ~= "rpc" then
        return nil, nil, "Put the cursor on an rpc (or inside it)"
    end
    local file = loaded.files[path]
    local service = file and file.services[target.service or ""]
    for _, rpc in ipairs(service and service.rpcs or {}) do
        if rpc.name == target.name then
            return service, rpc
        end
    end
    return nil, nil, string.format("rpc %s is not parsed from %s", target.name, vim.fs.basename(path))
end

-- The line for the rpc at `row` of the .proto `path`, or nil and a reason.
function M.build(root, path, row, opts)
    local lines = file_lines(path)
    if not lines then
        return nil, "cannot read " .. path
    end
    local loaded = M.load(root, path)
    local service, rpc, err = M.rpc_at(loaded, path, lines, row)
    if not service then
        return nil, err
    end
    return M.command(root, path, service, rpc, loaded, opts), nil, rpc
end

-- ============================================================
-- tmux
-- ============================================================

-- `editor` -> `rpc`, `backend/editor` -> `backend/rpc`.
function M.window_name(window_name)
    local prefix = window_name:match("^(.*)/[^/]+$")
    return prefix and (prefix .. "/rpc") or "rpc"
end

-- Runs tmux; tests replace it.
function M._tmux(args)
    local result = vim.system(vim.list_extend({ "tmux" }, args), { text = true }):wait()
    if result.code ~= 0 then
        return nil, vim.trim(result.stderr or "")
    end
    return vim.trim(result.stdout or "")
end

-- The line typed into the rpc window of the session (made in `root` when
-- missing), which is then shown; the clipboard outside tmux.
function M.send(root, line)
    if not vim.env.TMUX then
        vim.fn.setreg("+", line)
        notify("Not inside tmux: the request is in the clipboard")
        return "clipboard"
    end
    local tmux = M._tmux
    local session = tmux({ "display-message", "-p", "#S" })
    local window = tmux({ "display-message", "-p", "#W" })
    if not session or not window then
        vim.fn.setreg("+", line)
        notify("tmux is unavailable: the request is in the clipboard")
        return "clipboard"
    end
    local name = M.window_name(window)
    local target = string.format("=%s:%s", session, name)
    local windows = tmux({ "list-windows", "-t", "=" .. session, "-F", "#W" }) or ""
    local cwd
    if vim.tbl_contains(vim.split(windows, "\n", { trimempty = true }), name) then
        cwd = tmux({ "display-message", "-p", "-t", target, "#{pane_current_path}" })
    else
        tmux({ "new-window", "-d", "-t", "=" .. session .. ":", "-n", name, "-c", root })
        cwd = root
    end
    if cwd and vim.fs.normalize(cwd) ~= vim.fs.normalize(root) then
        line = string.format("cd -- %s && %s", shell_quote(root), line)
    end
    local sent, err = tmux({ "send-keys", "-t", target, "-l", "--", line })
    if not sent then
        vim.fn.setreg("+", line)
        notify("tmux send failed, the request is in the clipboard: " .. tostring(err), vim.log.levels.WARN)
        return "clipboard"
    end
    tmux({ "select-window", "-t", target })
    notify(line .. "  → tmux " .. target:gsub("^=", ""))
    return target
end

-- grq.
function M.request(root)
    local path = vim.api.nvim_buf_get_name(0)
    if vim.bo.filetype == "proto" then
        local line, err = M.build(root, path, vim.api.nvim_win_get_cursor(0)[1] - 1)
        if not line then
            return notify(err)
        end
        M.send(root, line)
    elseif vim.bo.filetype == "go" then
        require("go_proto").to_proto(root, function(place)
            local line, err = M.build(root, place.path, place.row)
            if not line then
                return notify(err)
            end
            M.send(root, line)
        end)
    else
        notify("grq works in .proto (on an rpc) and Go (on a handler or a client call)")
    end
end

return M
