-- grpcurl requests from the shell, with the same templates as grq in the
-- editor (lua/grpc_request.lua); tmux/docs (prefix i) previews and types
-- them. Runs without the editor config:
--
--   nvim --clean -l grpc_request.lua command ROOT PROTO SERVICE METHOD
--       the grpcurl line
--   nvim --clean -l grpc_request.lua preview ROOT PROTO SERVICE METHOD
--       the rpc with its comment, the request message as declared, then
--       the grpcurl line after an empty line
--
-- PROTO is relative to ROOT, the project root (where `nvim .` would run).
local here = debug.getinfo(1, "S").source:sub(2)
local lua_dir = vim.fs.normalize(vim.fs.dirname(here) .. "/../lua")
package.path = lua_dir .. "/?.lua;" .. package.path

local mode, root, proto, service_name, method = unpack(arg)
if not (mode and root and proto and service_name and method) then
    io.stderr:write("usage: nvim --clean -l grpc_request.lua command|preview ROOT PROTO SERVICE METHOD\n")
    os.exit(2)
end

local grpc_request = require("grpc_request")
root = vim.fs.normalize(root)
local path = root .. "/" .. proto
local loaded = grpc_request.load(root, path)
local file = loaded.files[path]
local service = file and file.services[service_name]
local rpc
for _, candidate in ipairs(service and service.rpcs or {}) do
    if candidate.name == method then
        rpc = candidate
    end
end
if not rpc then
    io.stderr:write(string.format("no rpc %s in service %s of %s\n", method, service_name, proto))
    os.exit(1)
end

local command = grpc_request.command(root, path, service, rpc, loaded)
if mode == "command" then
    io.stdout:write(command, "\n")
    os.exit(0)
end

-- The rpc with the comment above it and the request message as declared.
local lines = vim.fn.readfile(path)
local out = {}
local start = rpc.row + 1
while start > 1 and lines[start - 1]:match("^%s*//") do
    start = start - 1
end
local depth, stop = 0, rpc.row + 1
for index = rpc.row + 1, #lines do
    local line = lines[index]
    depth = depth + select(2, line:gsub("{", "")) - select(2, line:gsub("}", ""))
    stop = index
    if depth <= 0 and (line:find(";", 1, true) or line:find("}", 1, true)) then
        break
    end
end
for index = start, stop do
    table.insert(out, (lines[index]:gsub("^%s%s", "")))
end
local _, request = grpc_request.resolve(loaded, file.package, rpc.request)
local message = loaded.messages[request]
if message then
    local declared = message.file == path and lines or vim.fn.readfile(message.file)
    table.insert(out, "")
    for index = message.row + 1, math.min(message.end_row + 1, #declared) do
        table.insert(out, declared[index])
    end
end
table.insert(out, "")
table.insert(out, command)
io.stdout:write(table.concat(out, "\n"), "\n")
