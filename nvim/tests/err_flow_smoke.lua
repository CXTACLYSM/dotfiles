local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

-- Space ce without gopls: the label of a function body by what it does
-- with an error, the labelled tree pruned at a gRPC status, the lines.
local err_flow = require("err_flow")

local function same(got, want, what)
    assert(vim.deep_equal(got, want), what .. ": " .. vim.inspect(got) .. " ~= " .. vim.inspect(want))
end

same(err_flow.classify([[
	o, err := s.repo.Get(ctx, id)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return nil, status.Error(codes.NotFound, "order")
		}
		return nil, status.Errorf(codes.Internal, "get: %v", err)
	}
]]), { kind = "grpc", detail = "NotFound, Internal", checks = true }, "a handler: statuses with codes, after a check")
same(err_flow.classify([[
	if err := s.repo.Save(ctx, o); err != nil {
		return fmt.Errorf("place order %s: %w", o.ID, err)
	}
	if err := s.bus.Publish(ctx, o); err != nil {
		return fmt.Errorf("publish: %w", err)
	}
]]), { kind = "wraps", detail = '"place order %s", "publish"', checks = false }, "wrapping with messages")
same(err_flow.classify("\tif err != nil {\n\t\treturn nil, err\n\t}\n"), { kind = "passes", detail = "", checks = false }, "passed up")
same(err_flow.classify("\tif err != nil {\n\t\tlog.Error(\"save\", zap.Error(err))\n\t}\n\treturn nil\n"),
    { kind = "logs", detail = "", checks = false }, "logged and dropped")
same(err_flow.classify("\terr := run()\n\tif err != nil {\n\t\tpanic(err)\n\t}\n"), { kind = "panics", detail = "", checks = false }, "panics")
same(err_flow.classify("\t_ = run()\n\treturn 0\n"), { kind = "handles", detail = "", checks = false }, "nothing recognised")
same(err_flow.classify('\treturn nil, connect.NewError(connect.CodeInvalidArgument, err)\n'),
    { kind = "grpc", detail = "InvalidArgument", checks = false }, "connect codes")

-- A tree from files on disk: the root wraps, one caller passes, its
-- caller answers with a status and keeps no callers of its own.
local root_dir = vim.fn.tempname()
vim.fn.mkdir(root_dir, "p")
local function write(name, lines)
    vim.fn.writefile(lines, root_dir .. "/" .. name)
    return vim.uri_from_fname(root_dir .. "/" .. name)
end
local repo = write("repo.go", { "package repo", "", "func (r *Repo) Get(id string) error {", '\treturn fmt.Errorf("get %s: %w", id, sql.ErrNoRows)', "}" })
local service = write("service.go", { "package service", "", "func (s *Service) Place(id string) error {", "\tif err := s.repo.Get(id); err != nil {", "\t\treturn err", "\t}", "\treturn nil", "}" })
local handler = write("handler.go", { "package handler", "", "func (h *Handler) Place(ctx context.Context) error {", "\tif err := h.service.Place(id); err != nil {", "\t\treturn status.Error(codes.NotFound, err.Error())", "\t}", "\treturn nil", "}" })
local main = write("main.go", { "package main", "", "func main() {", "\t_ = h.Place(ctx)", "}" })
local function item(uri, first, last, name)
    return { uri = uri, name = name, range = { start = { line = first, character = 0 }, ["end"] = { line = last, character = 1 } },
        selectionRange = { start = { line = first, character = 5 }, ["end"] = { line = first, character = 6 } } }
end
local function node(uri, first, last, name, package, relation, children)
    return { item = item(uri, first, last, name), name = name, package = package, relation = relation, children = children or {},
        decl = { uri = uri, line = first + 1, col = 0 }, site = relation ~= "root" and { uri = uri, line = first + 2, col = 0 } or nil }
end
local tree = node(repo, 2, 4, "(*Repo).Get", "repo", "root", {
    node(service, 2, 7, "(*Service).Place", "service", "in", {
        node(handler, 2, 7, "(*Handler).Place", "handler", "in", {
            node(main, 2, 4, "main", "main", "in"),
        }),
    }),
})
err_flow.label(tree)
assert(tree.flow.kind == "wraps" and tree.flow.detail == '"get %s"', "the root's own errors: " .. vim.inspect(tree.flow))
assert(tree.children[1].flow.kind == "passes", "the service passes up")
assert(tree.children[1].children[1].flow.kind == "grpc" and tree.children[1].children[1].flow.detail == "NotFound", "the handler answers a status")
assert(#tree.children[1].children[1].children == 0, "no callers past a status")
local lines, entries, summary = err_flow.render(tree)
local plain = vim.tbl_map(function(line) return (line:gsub("%s+%S+:%d+$", "")) end, lines)
same(plain, {
    'repo.(*Repo).Get  raises: wraps "get %s"',
    "└─ service.(*Service).Place  passes up",
    "   └─ handler.(*Handler).Place  → gRPC NotFound",
}, "the tree with labels")
assert(lines[3]:match("handler%.go:4$"), "the call site after the label: " .. lines[3])
assert(summary:match("^2 callers, 1 end as a gRPC status"), summary)
assert(#entries == 3 and entries[2].site.line == 4 and entries[1].decl.line == 3, "entries carry the sites")
vim.fn.delete(root_dir, "rf")
print("ERR_FLOW_OK")
