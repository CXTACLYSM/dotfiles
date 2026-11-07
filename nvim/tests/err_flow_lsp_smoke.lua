-- Space ce on the error-flow fixture with gopls: from repo.Get the tree
-- climbs service.Place (wraps) to the handler (gRPC status) and stops.
local err_flow = require("err_flow")
local go_calls = require("go_calls")
local buffer = vim.api.nvim_get_current_buf()
assert(vim.wait(30000, function()
    return #vim.lsp.get_clients({ bufnr = buffer, name = "gopls" }) > 0
end, 100), "gopls attached")
local function find(text)
    for number, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
        if line:find(text, 1, true) then
            return number
        end
    end
    error("no line with " .. text)
end
local row = find("func (r *Repo) Get(")
local line, character, name = err_flow.function_position(buffer, row, 2)
assert(line == row - 1 and name == "Get", "the function around a cursor inside its body: " .. tostring(name))
local result, failure
go_calls.build(buffer, { textDocument = { uri = vim.uri_from_bufnr(buffer) }, position = { line = line, character = character } },
    "in", { max_depth = 6 }, function(root, err)
        result, failure = root, err
    end)
assert(vim.wait(30000, function()
    return result ~= nil or failure ~= nil
end, 100) and result, "callers: " .. tostring(failure))
err_flow.label(result)
local lines, _, summary = err_flow.render(result)
local plain = vim.tbl_map(function(l) return (l:gsub("%s+%S+:%d+$", "")) end, lines)
io.stdout:write(table.concat(plain, "\n") .. "\n")
assert(plain[1]:match('^repo%.%(%*Repo%)%.Get  raises: wraps "get %%s"$'), plain[1])
assert(plain[2]:match('service%.%(%*Service%)%.Place  wraps "place order"$'), plain[2])
assert(plain[3]:match("handler%.%(%*Handler%)%.PlaceOrder  → gRPC NotFound, Internal · checks$"), plain[3])
assert(#plain == 3, "the tree stops at the status: " .. #plain)
assert(summary:match("^2 callers, 1 end as a gRPC status"), summary)
print("ERR_FLOW_LSP_OK")
