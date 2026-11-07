-- grq on the fixture verify.sh writes: the .proto parser (tokens, nested
-- messages, enums, oneof, map, options with braces, an rpc over two lines,
-- imports resolved in the project), the JSON template checked against
-- grpcurl's own, the command with its address from .env, the reflection
-- check and the schema flags without it, the rpc under the cursor in a
-- .proto and from a Go handler and a client call through gopls, and the
-- line typed into the rpc window of tmux (tmux stubbed).
local grpc_request = require("grpc_request")
local root = vim.fn.getcwd()

local function same(got, want, what)
    assert(vim.deep_equal(got, want), what .. ": " .. vim.inspect(got) .. " ~= " .. vim.inspect(want))
end

local function sorted(list)
    table.sort(list)
    return list
end

-- The parser on the richer contract.
local billing = root .. "/api/billing/v1/billing.proto"
local lines = vim.fn.readfile(billing)
local function row_of(text)
    for index, line in ipairs(lines) do
        if line:find(text, 1, true) then
            return index - 1
        end
    end
    error("no line with " .. text)
end
local loaded = grpc_request.load(root, billing)
local file = loaded.files[billing]
assert(file.package == "billing.v1", "package: " .. file.package)
same(file.imports, { "google/api/annotations.proto", "google/protobuf/timestamp.proto", "google/protobuf/empty.proto",
    "common/v1/common.proto" }, "imports")
same(vim.tbl_map(function(rpc)
    return rpc.name .. "(" .. rpc.request .. ") " .. rpc.response .. (rpc.server_stream and " stream" or "")
end, file.service_list[1].rpcs), {
    "CreateInvoice(CreateInvoiceRequest) CreateInvoiceResponse",
    "ListInvoices(ListInvoicesRequest) Invoice stream",
    "Ping(google.protobuf.Empty) google.protobuf.Empty",
}, "rpcs")
assert(file.service_list[1].full == "billing.v1.BillingService", "service full name")
same(sorted(vim.tbl_keys(loaded.messages)), {
    "billing.v1.Card", "billing.v1.CreateInvoiceRequest", "billing.v1.CreateInvoiceResponse", "billing.v1.Invoice",
    "billing.v1.Item", "billing.v1.Item.Money", "billing.v1.ListInvoicesRequest", "common.v1.Address", "google.api.HttpRule",
}, "messages of the file and its imports")
same(vim.tbl_map(function(value)
    return value.name
end, loaded.enums["billing.v1.Status"].values), { "STATUS_UNSPECIFIED", "STATUS_ACTIVE", "STATUS_LIVE" }, "enum values")
local request = loaded.messages["billing.v1.CreateInvoiceRequest"]
same(vim.tbl_map(function(field)
    return field.name
end, request.fields), { "user_id", "items", "status", "counts", "card", "voucher", "deliver_at", "address", "parent", "blob", "rush" },
    "fields in order")
assert(request.fields[2].label == "repeated" and request.fields[4].map.key == "string" and request.fields[4].map.value == "int32",
    "repeated and map")
assert(request.fields[5].oneof == "payment" and request.fields[5].oneof_first and request.fields[6].oneof == "payment"
    and not request.fields[6].oneof_first, "oneof")
assert(request.row == row_of("message CreateInvoiceRequest") and request.end_row == row_of('reserved "old_name";') + 1,
    "rows of the message: " .. request.row .. "-" .. request.end_row)
local kind, full = grpc_request.resolve(loaded, "billing.v1.Item", "Money")
assert(kind == "message" and full == "billing.v1.Item.Money", "a nested type from its message")
kind, full = grpc_request.resolve(loaded, "billing.v1.CreateInvoiceRequest", "Status")
assert(kind == "enum" and full == "billing.v1.Status", "a package type from a message")
kind, full = grpc_request.resolve(loaded, "billing.v1", ".common.v1.Address")
assert(kind == "message" and full == "common.v1.Address", "an absolute name")
kind, full = grpc_request.resolve(loaded, "billing.v1", "google.protobuf.Timestamp")
assert(kind == nil and full == "google.protobuf.Timestamp", "a well-known type is not loaded")
same(vim.tbl_keys(loaded.roots), { root .. "/api" }, "import root")
print("GRPC_REQUEST_PARSE_OK")

-- The template, and grpcurl's own template names the same fields.
local want = '{"user_id": 0, "items": [{"sku": "", "count": 0, "price": {"units": 0, "currency": ""}}], "status": "STATUS_ACTIVE",'
    .. ' "counts": {"key": 0}, "card": {"number": ""}, "deliver_at": "2025-01-01T00:00:00Z", "address": {"city": "", "street": ""},'
    .. ' "parent": {"id": 0, "parent": {}}, "blob": "", "rush": false}'
same(grpc_request.json(grpc_request.template(loaded, "billing.v1.CreateInvoiceRequest")), want, "template")
assert(grpc_request.json(grpc_request.sample(loaded, "billing.v1", "google.protobuf.Empty")) == "{}", "Empty")
assert(grpc_request.json(grpc_request.sample(loaded, "billing.v1", "Unknown")) == "{}", "an unknown type")
assert(grpc_request.json('a"b\n') == '"a\\u0022b\\u000a"', "json escapes")
local described = vim.system({ "grpcurl", "-msg-template", "-import-path", "api", "-proto", "billing/v1/billing.proto",
    "describe", "billing.v1.CreateInvoiceRequest" }, { cwd = root, text = true }):wait()
assert(described.code == 0, "grpcurl describe: " .. (described.stderr or ""))
-- grpcurl writes the JSON names (userId) and, like the template, one
-- member per oneof; it accepts the .proto names the template uses too.
local json_text = assert(described.stdout:match("Message template:%s*(%b{})"), described.stdout)
local theirs = vim.json.decode(json_text)
local ours = vim.json.decode(want)
local function camel(keys)
    return sorted(vim.tbl_map(function(key)
        return (key:gsub("_(%l)", string.upper))
    end, keys))
end
same(camel(vim.tbl_keys(ours)), sorted(vim.tbl_keys(theirs)), "the fields grpcurl names")
if type(theirs.items) == "table" and theirs.items[1] then
    same(camel(vim.tbl_keys(ours.items[1])), sorted(vim.tbl_keys(theirs.items[1])), "nested fields")
end
print("GRPC_REQUEST_TEMPLATE_OK")

-- The command: the address from .env, reflection in the project, the
-- schema flags without it, the rpc at a row.
assert(grpc_request.address(root) == "localhost:8082", "port from .env: " .. grpc_request.address(root))
assert(grpc_request.address(root .. "/api") == "localhost:8080", "default address")
assert(grpc_request.uses_reflection(root) and not grpc_request.uses_reflection(root .. "/api"), "reflection")
same(grpc_request.schema_flags(root, loaded, billing), { "-import-path", "api", "-proto", "billing/v1/billing.proto" }, "schema flags")
local lonely = grpc_request.load(root, root .. "/api/common/v1/common.proto")
same(grpc_request.schema_flags(root, lonely, root .. "/api/common/v1/common.proto"),
    { "-import-path", "api/common/v1", "-proto", "common.proto" }, "a file without imports: its folder")
local line = assert(grpc_request.build(root, billing, row_of("rpc CreateInvoice")))
same(line, "grpcurl -plaintext -d '" .. want .. "' localhost:8082 billing.v1.BillingService/CreateInvoice", "the line")
assert(grpc_request.build(root, billing, row_of('body: "*"')) == line, "inside the rpc block")
same(grpc_request.build(root, billing, row_of("rpc Ping")),
    "grpcurl -plaintext -d '{}' localhost:8082 billing.v1.BillingService/Ping", "Empty request")
same(grpc_request.build(root, billing, row_of("returns (stream Invoice)")),
    "grpcurl -plaintext -d '{\"page_size\": 0}' localhost:8082 billing.v1.BillingService/ListInvoices",
    "an rpc over two lines, from its second")
local none, err = grpc_request.build(root, billing, row_of("message Card"))
assert(none == nil and err:find("rpc", 1, true), "not an rpc: " .. tostring(err))
same(grpc_request.build(root, billing, row_of("rpc CreateInvoice"), { reflection = false, address = "localhost:1" }),
    "grpcurl -plaintext -import-path api -proto billing/v1/billing.proto -d '" .. want
    .. "' localhost:1 billing.v1.BillingService/CreateInvoice", "without reflection")
print("GRPC_REQUEST_COMMAND_OK")

-- tmux stubbed: the rpc window is made in the root, the line typed, the
-- window shown; an existing window in another directory gets a cd first;
-- outside tmux the clipboard.
local calls, windows, cwd = {}, "editor\nserver\ntests", root
grpc_request._tmux = function(args)
    table.insert(calls, table.concat(args, " "))
    if args[1] == "display-message" then
        if args[3] == "#S" then
            return "shop"
        elseif args[3] == "#W" then
            return "editor"
        end
        return cwd
    elseif args[1] == "list-windows" then
        return windows
    end
    return ""
end
vim.env.TMUX = "fixture"
same(grpc_request.send(root, "grpcurl x"), "=shop:rpc", "target")
same(calls, {
    "display-message -p #S", "display-message -p #W", "list-windows -t =shop -F #W",
    "new-window -d -t =shop: -n rpc -c " .. root, "send-keys -t =shop:rpc -l -- grpcurl x", "select-window -t =shop:rpc",
}, "a new rpc window")
calls, windows = {}, "editor\nrpc"
grpc_request.send(root, "grpcurl y")
same(calls, {
    "display-message -p #S", "display-message -p #W", "list-windows -t =shop -F #W",
    "display-message -p -t =shop:rpc #{pane_current_path}", "send-keys -t =shop:rpc -l -- grpcurl y", "select-window -t =shop:rpc",
}, "an existing window")
calls, cwd = {}, "/elsewhere"
grpc_request.send(root, "grpcurl z")
assert(calls[5] == "send-keys -t =shop:rpc -l -- cd -- " .. root .. " && grpcurl z", "another directory: cd first: " .. calls[5])
assert(grpc_request.window_name("backend/editor") == "backend/rpc" and grpc_request.window_name("editor") == "rpc", "window names")
vim.env.TMUX = nil
local register
local real_setreg = vim.fn.setreg
vim.fn.setreg = function(name, value)
    register = { name, value }
end
same(grpc_request.send(root, "grpcurl q"), "clipboard", "outside tmux")
same(register, { "+", "grpcurl q" }, "the clipboard register")
vim.fn.setreg = real_setreg
print("GRPC_REQUEST_TMUX_OK")

-- From Go through gopls (the handler and the client call) and from the
-- .proto; grq itself is mapped.
assert(vim.wait(20000, function()
    return #vim.lsp.get_clients({ bufnr = 0, name = "gopls" }) == 1
end, 50), "gopls did not attach")
vim.wait(1500)
vim.env.TMUX = "fixture"
local function typed()
    for _, call in ipairs(calls) do
        local sent = call:match("^send%-keys %-t =shop:rpc %-l %-%- (.*)$")
        if sent then
            return sent
        end
    end
    return nil
end
local function request_from(path, text, word)
    if vim.api.nvim_buf_get_name(0) ~= root .. "/" .. path then
        vim.cmd.edit(root .. "/" .. path)
        if path:match("%.go$") then
            assert(vim.wait(20000, function()
                return #vim.lsp.get_clients({ bufnr = 0, name = "gopls" }) == 1
            end, 50), "gopls on " .. path)
        end
    end
    for index, buffer_line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        if buffer_line:find(text, 1, true) then
            vim.api.nvim_win_set_cursor(0, { index, buffer_line:find(word or text, 1, true) - 1 })
            break
        end
    end
    calls, windows, cwd = {}, "editor\nrpc", root
    grpc_request.request(root)
    assert(vim.wait(20000, function()
        return typed() ~= nil
    end, 50), "no request typed from " .. path .. ": " .. vim.inspect(calls))
    return typed()
end
local order_line = "grpcurl -plaintext -d '{\"user_id\": 0}' localhost:8082 order.v1.OrderService/CreateOrder"
same(request_from("internal/app/order/handler.go", "func (i *Implementation) CreateOrder", "CreateOrder"), order_line, "from the handler")
same(request_from("internal/clients/order.go", "c.CreateOrder(", "CreateOrder"), order_line, "from the client call")
same(request_from("api/order/v1/order.proto", "rpc GetOrder"),
    "grpcurl -plaintext -d '{\"id\": 0}' localhost:8082 order.v1.OrderService/GetOrder", "from the .proto")
assert(vim.fn.maparg("grq", "n") ~= "", "grq is mapped")
vim.env.TMUX = nil
print("GRPC_REQUEST_GO_OK")

print("GRPC_REQUEST_SMOKE_OK")
