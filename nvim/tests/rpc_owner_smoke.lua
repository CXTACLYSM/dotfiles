local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

-- grP without gopls: the rg command, the kind of a match, the matches
-- sorted handlers first and named by repository, on two fake repositories
-- with a real rg.
local rpc_owner = require("rpc_owner")

local function same(got, want, what)
    assert(vim.deep_equal(got, want), what .. ": " .. vim.inspect(got) .. " ~= " .. vim.inspect(want))
end

local home = vim.fn.tempname()
local order, billing = home .. "/workspace/order", home .. "/workspace/billing"
vim.fn.mkdir(order .. "/api/order/v1", "p")
vim.fn.mkdir(order .. "/internal/server", "p")
vim.fn.mkdir(order .. "/pkg/api/order/v1", "p")
vim.fn.mkdir(billing .. "/internal/clients", "p")
vim.fn.mkdir(billing .. "/vendor/x", "p")
vim.fn.writefile({ "service OrderService {", "  rpc PlaceOrder(PlaceOrderRequest) returns (PlaceOrderResponse);", "}" },
    order .. "/api/order/v1/order.proto")
vim.fn.writefile({ "package server", "", "func (s *Server) PlaceOrder(ctx context.Context, req *orderv1.PlaceOrderRequest) (*orderv1.PlaceOrderResponse, error) {",
    "\treturn nil, nil", "}" }, order .. "/internal/server/order.go")
vim.fn.writefile({ "package server", "", "func TestPlaceOrder(t *testing.T) {", "\t_, _ = s.PlaceOrder(ctx, req)", "}" },
    order .. "/internal/server/order_test.go")
vim.fn.writefile({ "package orderv1", "func (c *orderServiceClient) PlaceOrder(ctx context.Context, in *PlaceOrderRequest) (*PlaceOrderResponse, error) {}" },
    order .. "/pkg/api/order/v1/order_grpc.pb.go")
vim.fn.writefile({ "package clients", "", "func (c *Orders) Place(ctx context.Context) error {", "\t_, err := c.client.PlaceOrder(ctx, &orderv1.PlaceOrderRequest{})", "\treturn err", "}" },
    billing .. "/internal/clients/orders.go")
vim.fn.writefile({ "package x", "func (v *V) PlaceOrder(ctx context.Context) {}" }, billing .. "/vendor/x/x.go")

local projects = { billing, order }
local cmd = rpc_owner.command("PlaceOrder", projects, home)
assert(cmd[1] == "rg" and cmd[#cmd] == "workspace/order" and cmd[#cmd - 1] == "workspace/billing", "rg over the repositories from home")
assert(rpc_owner.kind("a/b.proto", "  rpc PlaceOrder(", "PlaceOrder") == "contract", "a contract")
assert(rpc_owner.kind("a/b_test.go", "s.PlaceOrder(ctx)", "PlaceOrder") == "test", "a test")
assert(rpc_owner.kind("a/b.go", "func (s *Server) PlaceOrder(ctx context.Context) {", "PlaceOrder") == "handler", "a handler")
assert(rpc_owner.kind("a/b.go", "_, err := c.PlaceOrder(ctx, req)", "PlaceOrder") == "call", "a call")

local result = vim.system(cmd, { cwd = home, text = true }):wait()
local matches = rpc_owner.matches(result.stdout, "PlaceOrder", projects, home)
same(vim.tbl_map(function(m) return m.kind .. " " .. m.repo .. " " .. m.path .. ":" .. m.line end, matches), {
    "handler order workspace/order/internal/server/order.go:3",
    "contract order workspace/order/api/order/v1/order.proto:2",
    "call billing workspace/billing/internal/clients/orders.go:4",
    "test order workspace/order/internal/server/order_test.go:4",
}, "handlers first, generated code and vendor out")
vim.fn.delete(home, "rf")
print("RPC_OWNER_OK")
