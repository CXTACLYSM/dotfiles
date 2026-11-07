local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

-- Space cp: field details, rpc signatures, the changes between two
-- versions of a contract by severity, and the whole thing on a git
-- repository: a branch off main with edits, a new file and an untracked
-- one.
local proto_diff = require("proto_diff")

local function same(got, want, what)
    assert(vim.deep_equal(got, want), what .. ": " .. vim.inspect(got) .. " ~= " .. vim.inspect(want))
end

same({ proto_diff.field_detail("  repeated string names = 3; // list") }, { 3, "repeated string", "names" }, "a repeated field")
same({ proto_diff.field_detail("  map<string, int64> totals = 4 [json_name = \"t\"];") }, { 4, "map<string, int64>", "totals" }, "a map")
same({ proto_diff.field_detail("  optional int32 count = 7;") }, { 7, "int32", "count" }, "optional dropped")
assert(proto_diff.field_detail("message Order {") == nil, "not a field")
assert(proto_diff.rpc_signature("  rpc PlaceOrder ( PlaceOrderRequest ) returns (PlaceOrderResponse) {}") == "PlaceOrderRequest → PlaceOrderResponse",
    "rpc signature")

local old = {
    'syntax = "proto3";',
    "package order.v1;",
    "",
    "service OrderService {",
    "  rpc PlaceOrder(PlaceOrderRequest) returns (PlaceOrderResponse);",
    "  rpc CancelOrder(CancelOrderRequest) returns (CancelOrderResponse);",
    "  rpc GetOrder(GetOrderRequest) returns (GetOrderResponse);",
    "}",
    "",
    "message PlaceOrderRequest {",
    "  string customer_id = 1;",
    "  int32 count = 2;",
    "  string note = 3;",
    "  string coupon = 4;",
    "}",
    "",
    "message CancelOrderRequest { string id = 1; }",
    "message CancelOrderResponse {}",
    "message PlaceOrderResponse { string id = 1; }",
    "message GetOrderRequest { string id = 1; }",
    "message GetOrderResponse { string id = 1; }",
    "",
    "enum Status {",
    "  STATUS_UNSPECIFIED = 0;",
    "  STATUS_NEW = 1;",
    "  STATUS_PAID = 2;",
    "}",
}
local new = {
    'syntax = "proto3";',
    "package order.v1;",
    "",
    "service OrderService {",
    "  rpc PlaceOrder(PlaceOrderRequest) returns (PlaceOrderResponse);",
    "  // GetOrder reads one order.",
    "  rpc GetOrder(GetOrderRequest) returns (OrderResponse);",
    "  rpc ListOrders(ListOrdersRequest) returns (ListOrdersResponse);",
    "}",
    "",
    "message PlaceOrderRequest {",
    "  string customer_id = 1;",
    "  int64 count = 2;",
    "  string comment = 3;",
    "  string coupon = 5;",
    "  string currency = 6;",
    "}",
    "",
    "message PlaceOrderResponse { string id = 1; }",
    "message GetOrderRequest { string id = 1; }",
    "message OrderResponse { string id = 1; }",
    "message ListOrdersRequest {}",
    "message ListOrdersResponse {}",
    "",
    "enum Status {",
    "  STATUS_UNSPECIFIED = 0;",
    "  STATUS_NEW = 1;",
    "  STATUS_PAID = 3;",
    "  STATUS_SHIPPED = 4;",
    "}",
}
local changes = proto_diff.compare(old, new)
local function listed(severity)
    local out = {}
    for _, change in ipairs(changes) do
        if change.severity == severity then
            table.insert(out, change.what .. " · " .. change.detail .. " @" .. (change.row + 1))
        end
    end
    return out
end
same(listed("breaking"), {
    "message CancelOrderRequest · removed @1",
    "message CancelOrderResponse · removed @1",
    "message GetOrderResponse · removed @1",
    "rpc OrderService.CancelOrder · removed @4",
    "rpc OrderService.GetOrder · GetOrderRequest → GetOrderResponse → GetOrderRequest → OrderResponse @7",
    "field PlaceOrderRequest.count · type int32 → int64 @13",
    "field PlaceOrderRequest.coupon · number 4 → 5 @15",
    "enum value Status.STATUS_PAID · number 2 → 3 @28",
}, "breaking changes first, in file order (removed top-level messages point at the top)")
same(listed("warning"), { "field PlaceOrderRequest.note · renamed to comment (number 3 kept: wire ok, JSON and Go break) @14" },
    "a renamed field")
same(listed("added"), {
    "rpc OrderService.ListOrders · ListOrdersRequest → ListOrdersResponse @8",
    "field PlaceOrderRequest.currency · string = 6 @16",
    "message OrderResponse ·  @21",
    "message ListOrdersRequest ·  @22",
    "message ListOrdersResponse ·  @23",
    "enum value Status.STATUS_SHIPPED ·  @29",
}, "additions")
same(listed("changed"), {}, "nothing else")
same(proto_diff.compare(new, new), {}, "the same file: no changes")

-- On a repository: main holds the old contract, the branch the new one
-- plus a new file; an untracked file counts as added.
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/api/order/v1", "p")
local function git(...)
    local result = vim.system({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", ... }, { cwd = root, text = true }):wait()
    assert(result.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. (result.stderr or ""))
    return result.stdout
end
git("init", "-q", "-b", "main")
vim.fn.writefile(old, root .. "/api/order/v1/order.proto")
vim.fn.writefile({ "package main" }, root .. "/main.go")
git("add", ".")
git("commit", "-q", "-m", "main")
git("checkout", "-q", "-b", "task")
vim.fn.writefile(new, root .. "/api/order/v1/order.proto")
vim.fn.mkdir(root .. "/api/billing/v1", "p")
vim.fn.writefile({ 'syntax = "proto3";', "package billing.v1;", "service Billing {", "  rpc Charge(ChargeRequest) returns (ChargeResponse);", "}",
    "message ChargeRequest {}", "message ChargeResponse {}" }, root .. "/api/billing/v1/billing.proto")
git("add", "api/billing")
git("commit", "-q", "-m", "billing")
vim.fn.writefile({ 'syntax = "proto3";', "package audit.v1;", "message Event {", "  string id = 1;", "}" }, root .. "/api/audit.proto")

local base, branch = proto_diff.base(root)
assert(branch == "main" and base == vim.trim(git("rev-parse", "main")), "the merge base with main")
local files = proto_diff.changed_files(root, base)
table.sort(files, function(a, b) return a.path < b.path end)
same(vim.tbl_map(function(f) return f.status .. " " .. f.path end, files),
    { "A api/audit.proto", "A api/billing/v1/billing.proto", "M api/order/v1/order.proto" }, "changed, committed and untracked files")
local all, against = proto_diff.collect(root)
assert(against == "main", "against main")
local by_path = {}
for _, change in ipairs(all) do
    by_path[change.path] = (by_path[change.path] or 0) + 1
end
same(by_path, { ["api/order/v1/order.proto"] = #changes, ["api/billing/v1/billing.proto"] = 4, ["api/audit.proto"] = 2 }, "changes per file")
assert(all[1].severity == "breaking" and all[1].path == "api/order/v1/order.proto", "breaking first")
vim.fn.delete(root, "rf")
print("PROTO_DIFF_OK")
