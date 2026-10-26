-- grp on the fixture verify.sh writes: a .proto, the code protoc would
-- generate from it, a handler, a mock of it and a client. The .proto
-- parser, then both ways through gopls: rpc → the handler (the generated
-- Unimplemented… and the mock set aside), an rpc without a handler,
-- service → its implementations, message / nested message / field / enum
-- → the generated code; handler method, getter, response type, enum value,
-- client call and the generated interface → their place in the .proto.
local go_proto = require("go_proto")
local root = vim.fn.getcwd()
local proto = root .. "/api/order/v1/order.proto"
local proto_lines = vim.fn.readfile(proto)

local function same(got, want, what)
    assert(vim.deep_equal(got, want), what .. ": " .. vim.inspect(got) .. " ~= " .. vim.inspect(want))
end

-- 0-based row of the line containing `text` in `lines`, and the column of
-- `word` on it.
local function at(lines, text, word)
    for index, line in ipairs(lines) do
        if line:find(text, 1, true) then
            return index - 1, line:find(word or text, 1, true) - 1
        end
    end
    error("no line with " .. text)
end

-- The .proto parser.
assert(go_proto.go_name("user_id") == "UserId" and go_proto.go_name("sku") == "Sku", "Go names")
local declared = {}
for _, declaration in ipairs(go_proto.proto_declarations(proto_lines)) do
    table.insert(declared, declaration.kind .. " " .. (declaration.service and (declaration.service .. ".") or "")
        .. declaration.path .. (declaration.kind == "field" and ("." .. declaration.name) or ""))
end
same(declared, {
    "service OrderService", "rpc OrderService.CreateOrder", "rpc OrderService.GetOrder",
    "message Order", "message Order.Item", "field Order.Item.sku", "field Order.Item.count",
    "field Order.id", "field Order.items", "field Order.status", "enum Status",
    "message CreateOrderRequest", "field CreateOrderRequest.user_id",
    "message CreateOrderResponse", "field CreateOrderResponse.order",
    "message GetOrderRequest", "field GetOrderRequest.id",
}, "declarations")
local target = go_proto.proto_target(proto_lines, (at(proto_lines, "STATUS_ACTIVE")))
assert(target.kind == "enum" and target.path == "Status", "a row inside a block is about the block")
same(go_proto.generated_files(root, "api/order/v1/order.proto"),
    { root .. "/pkg/api/order/v1/order.pb.go", root .. "/pkg/api/order/v1/order_grpc.pb.go" }, "generated files")
assert(go_proto.proto_for(root, "order/v1/order.proto") == proto, "the .proto of a source path")
print("GO_PROTO_PARSE_OK")

local attached = vim.wait(20000, function()
    return #vim.lsp.get_clients({ bufnr = 0, name = "gopls" }) == 1
end, 50)
assert(attached, "gopls did not attach")
vim.wait(1500)
local handler_buf = vim.api.nvim_get_current_buf()

local function relative(place)
    return string.format("%s:%d", vim.fs.relpath(root, place.path), place.row + 1)
end

-- .proto → Go.
vim.cmd.edit(proto)
local function to_go(text, word)
    vim.api.nvim_win_set_cursor(0, { at(proto_lines, text, word) + 1, 2 })
    local got
    go_proto.to_go(root, function(real, doubles, place)
        got = {
            real = vim.tbl_map(relative, real),
            doubles = vim.tbl_map(relative, doubles or {}),
            place = place and relative(place),
        }
    end)
    assert(vim.wait(20000, function()
        return got ~= nil
    end, 50), "no answer for " .. text)
    return got
end

local got = to_go("rpc CreateOrder")
same(got.real, { "internal/app/order/handler.go:14" }, "rpc → the handler")
same(got.doubles, { "internal/app/order/mocks/server_mock.go:13" }, "the mock set aside")
got = to_go("rpc GetOrder")
assert(#got.real == 0 and got.place == "pkg/api/order/v1/order_grpc.pb.go:27", "no handler yet: " .. vim.inspect(got))
got = to_go("service OrderService")
same(got.real, { "internal/app/order/handler.go:10" }, "service → its implementation")
same(to_go("message Item").real, { "pkg/api/order/v1/order.pb.go:28" }, "nested message")
same(to_go("int64 user_id = 1").real, { "pkg/api/order/v1/order.pb.go:34" }, "field")
same(to_go("enum Status").real, { "pkg/api/order/v1/order.pb.go:8" }, "enum")
print("GO_PROTO_TO_GO_OK")

-- Go → .proto.
local function to_proto(file, text, word)
    -- :edit of the same file reads it again and gopls attaches anew.
    if vim.api.nvim_buf_get_name(0) ~= root .. "/" .. file then
        vim.cmd.edit(root .. "/" .. file)
    end
    if not file:match("%.pb%.go$") then
        assert(vim.wait(20000, function()
            return #vim.lsp.get_clients({ bufnr = 0, name = "gopls" }) == 1
        end, 50), "gopls on " .. file)
    end
    local row, col = at(vim.api.nvim_buf_get_lines(0, 0, -1, false), text, word)
    vim.api.nvim_win_set_cursor(0, { row + 1, col })
    local got
    go_proto.to_proto(root, function(place)
        got = place
    end)
    assert(vim.wait(20000, function()
        return got ~= nil
    end, 50), "no answer for " .. word)
    return proto_lines[got.row + 1]:sub(got.col + 1)
end

local handler = "internal/app/order/handler.go"
assert(to_proto(handler, "func (i *Implementation) CreateOrder", "CreateOrder"):match("^CreateOrder%(CreateOrderRequest%)"),
    "handler → rpc")
assert(to_proto(handler, "req.GetUserId()", "GetUserId"):match("^user_id = 1"), "getter → field")
assert(to_proto(handler, "*orderv1.CreateOrderResponse, error", "CreateOrderResponse"):match("^CreateOrderResponse {"),
    "type → message")
assert(to_proto(handler, "orderv1.Status_STATUS_ACTIVE", "Status_STATUS_ACTIVE"):match("^Status {"), "enum value → enum")
assert(to_proto("internal/clients/order.go", "c.CreateOrder(", "CreateOrder"):match("^CreateOrder%("),
    "client call → rpc")
assert(to_proto("pkg/api/order/v1/order_grpc.pb.go", "type UnimplementedOrderServiceServer", "Unimplemented")
    :match("^OrderService {"), "generated server type → service")
print("GO_PROTO_TO_PROTO_OK")

-- grp itself jumps, Ctrl-o comes back.
assert(vim.fn.maparg("grp", "n") ~= "", "grp is mapped")
vim.cmd.edit(proto)
vim.api.nvim_win_set_cursor(0, { at(proto_lines, "rpc CreateOrder") + 1, 2 })
go_proto.jump(root)
assert(vim.wait(20000, function()
    return vim.api.nvim_buf_get_name(0):match("handler%.go$") ~= nil
end, 50), "grp opens the handler")
assert(vim.api.nvim_win_get_cursor(0)[1] == 14, "on the handler method")
assert(vim.api.nvim_get_current_buf() == handler_buf, "the same buffer")
print("GO_PROTO_SMOKE_OK")
