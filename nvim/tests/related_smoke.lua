-- Space , on the categories fixture: the domain of a file (the deepest
-- folder that is not a generic name, else the file name), the lines of the
-- other folders of the domain and of files with the same name, and the
-- picker (fzf stubbed).
local related = require("related")
local fzf = require("fzf-lua")
-- The lines carry the plain marks of the file tree (file_tree_smoke.lua
-- checks the devicons glyphs).
require("file_tree").plain = true
local root = vim.fn.getcwd()

local function same(got, want, what)
    assert(vim.deep_equal(got, want), what .. ": " .. vim.inspect(got) .. " ~= " .. vim.inspect(want))
end

local function plain(line)
    return fzf.utils.strip_ansi_coloring(line):gsub(fzf.utils.nbsp .. ".*$", "")
end

for rel, want in pairs({
    ["internal/app/order/handler.go"] = { "order", "folder" },
    ["api/order/v1/order.proto"] = { "order", "folder" },
    ["pkg/api/order/v1/order.pb.go"] = { "order", "folder" },
    ["internal/handler/order.go"] = { "order", "file" },
    ["internal/service/order_test.go"] = { "order", "file" },
    ["cmd/app/main.go"] = { "main", "file" },
    ["go.mod"] = { "go", "file" },
    [".env"] = { ".env", "file" },
}) do
    same({ related.domain(rel) }, want, "domain of " .. rel)
end
assert(related.stem("order_grpc.pb.go") == "order_grpc" and related.stem("service_test.go") == "service"
    and related.stem("README.md") == "README", "stems")
print("RELATED_DOMAIN_OK")

local listed = vim.system({ "rg", "--files", "--hidden", "--glob", "!.git" }, { cwd = root, text = true }):wait()
local paths = vim.split(listed.stdout, "\n", { trimempty = true })
local lines, domain, in_folders, same_name = related.lines(root, "internal/order/service.go", paths)
assert(domain == "order" and in_folders == 7 and same_name == 0, string.format("%s %d %d", domain, in_folders, same_name))
same(vim.tbl_map(plain, lines), {
    "◇ order.proto  api/order/v1/",
    "▫ store_mock.go  internal/order/mocks/",
    "▪ pg.go  internal/order/repo/",
    "∷ golden.json  internal/order/testdata/",
    "▫ order.pb.go  pkg/api/order/v1/",
    "▫ order.pb.validate.go  pkg/api/order/v1/",
    "▫ order_grpc.pb.go  pkg/api/order/v1/",
}, "other folders of the domain, with the marks of the tree")
assert(fzf.utils.strip_ansi_coloring(lines[1]):match(fzf.utils.nbsp .. "api/order/v1/order%.proto$"), "the path after the separator")
lines, domain, in_folders, same_name = related.lines(root, "internal/order/repo/pg.go", paths)
assert(domain == "order" and in_folders == 8 and same_name == 0, "from a folder of the domain: the others, the current one left out")
lines = related.lines(root, "internal/orders/batch.go", paths)
same(lines, {}, "a domain on its own")
lines, domain, in_folders, same_name = related.lines(root, "pkg/api/order/v1/order.pb.go", { "pkg/api/order/v1/order.pb.go", "api/order/v1/order.proto", "docs/order.md", "cmd/order/main.go" })
same(vim.tbl_map(plain, lines), { "◇ order.proto  api/order/v1/", "▪ main.go  cmd/order/", "≡ order.md  docs/ · same name" },
    "the same name elsewhere comes last, marked")
print("RELATED_LINES_OK")

local real_exec, picked = fzf.fzf_exec, nil
fzf.fzf_exec = function(contents, opts)
    picked = { contents = contents, opts = opts }
end
vim.cmd.edit(root .. "/internal/order/service.go")
related.pick(root)
fzf.fzf_exec = real_exec
assert(picked and #picked.contents == 7, "the picker lists the related files")
assert(picked.opts.winopts.title == " related · order · 7 in other folders · 0 same name ", "title: " .. picked.opts.winopts.title)
assert(picked.opts.fzf_opts["--with-nth"] == "{1}" and picked.opts.previewer == "builtin" and picked.opts.fzf_opts["--no-sort"],
    "paths hidden, preview, order kept")
assert(vim.fn.maparg("<leader>,", "n") ~= "", "Space , is mapped")
print("RELATED_SMOKE_OK")
