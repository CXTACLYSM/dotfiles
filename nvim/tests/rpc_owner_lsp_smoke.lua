-- grP on the proto fixture with gopls: the rpc from a handler method
-- (through the generated interface it implements), from the generated
-- code, and from the .proto.
local rpc_owner = require("rpc_owner")
local root = vim.fn.getcwd()
local buffer = vim.api.nvim_get_current_buf()
assert(vim.wait(30000, function()
    return #vim.lsp.get_clients({ bufnr = buffer, name = "gopls" }) > 0
end, 100), "gopls attached")
local function at(text, col)
    for number, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        if line:find(text, 1, true) then
            vim.api.nvim_win_set_cursor(0, { number, col or (line:find(text, 1, true) - 1) })
            return
        end
    end
    error("no line with " .. text)
end
local function rpc_here()
    local got, reason
    rpc_owner.rpc_at_cursor(root, function(rpc, why)
        got, reason = rpc or false, why
    end)
    assert(vim.wait(30000, function()
        return got ~= nil
    end, 100), "answered")
    return got, reason
end
at("CreateOrder(ctx context.Context", 26)
local rpc = rpc_here()
assert(rpc and rpc.service == "OrderService" and rpc.name == "CreateOrder", "from the handler: " .. vim.inspect(rpc))
vim.cmd.edit(root .. "/api/order/v1/order.proto")
at("rpc CreateOrder")
rpc = rpc_here()
assert(rpc and rpc.service == "OrderService" and rpc.name == "CreateOrder", "from the contract: " .. vim.inspect(rpc))
at("message CreateOrderRequest")
local none, reason = rpc_here()
assert(none == false and reason:match("rpc"), "not on an rpc: " .. tostring(reason))
-- The search itself over the fixture as the only repository.
local matches = rpc_owner.matches(vim.system(rpc_owner.command("CreateOrder", { root }, vim.fs.dirname(root)),
    { cwd = vim.fs.dirname(root), text = true }):wait().stdout, "CreateOrder", { root }, vim.fs.dirname(root))
local kinds = {}
for _, match in ipairs(matches) do
    kinds[match.kind] = (kinds[match.kind] or 0) + 1
end
assert(kinds.handler and kinds.contract, "handler and contract found: " .. vim.inspect(kinds))
print("RPC_OWNER_LSP_OK")
