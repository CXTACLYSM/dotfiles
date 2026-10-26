-- K on app/main.go of the fixture verify.sh writes: a variable, parameter
-- or field of a struct type shows that struct and every project type its
-- fields name (another package, pointers, slices, maps, an embedded field,
-- a grouped `type ( … )`), each once, a cycle stops, time.Time stays a
-- name, an interface is shown but not followed; a generated message loses
-- its machinery fields and tags; on a type name only the types of its
-- fields are added; functions and plain values keep the gopls hover; the
-- limit cuts the list; K opens the float and focuses it.
local go_hover = require("go_hover")

local attached = vim.wait(20000, function()
    return #vim.lsp.get_clients({ bufnr = 0, name = "gopls" }) == 1
end, 50)
assert(attached, "gopls did not attach")
vim.wait(1500)

local win = vim.api.nvim_get_current_win()
local buf = vim.api.nvim_get_current_buf()
local client = vim.lsp.get_clients({ bufnr = buf, name = "gopls" })[1]
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

local function at(on, needle)
    for index, line in ipairs(lines) do
        if line:find(on, 1, true) then
            local col = assert(line:find(needle, 1, true), needle .. " not on line " .. index)
            vim.api.nvim_win_set_cursor(win, { index, col - 1 })
            return
        end
    end
    error("no line containing " .. on)
end

local function hover_at(on, needle)
    at(on, needle)
    local got, done = nil, false
    go_hover.contents(client, win, function(result)
        got, done = result, true
    end)
    assert(vim.wait(10000, function()
        return done
    end, 20), "no hover at " .. needle)
    return got and table.concat(got, "\n") or ""
end

-- The declared types in the order they appear.
local function types_in(text)
    local names = {}
    for name in text:gmatch("\ntype ([%w_]+)") do
        table.insert(names, name)
    end
    return table.concat(names, " ")
end

assert(go_hover.kind({ "```go", "var o *model.Order", "```" }) == "var", "var")
assert(select(2, go_hover.kind({ "```go", "field Delivery model.Address `json:\"d\"`", "```" })) == "model.Address `json:\"d\"`",
    "field type")
assert(go_hover.kind({ "```go", "type Order struct {", "}", "```" }) == "type", "type")
assert(go_hover.kind({ "```go", "func main()", "```" }) == nil, "function")
print("GO_HOVER_KIND_OK")

local text = hover_at("func handle(o *model.Order", "o *")
assert(text:find("var o *model.Order", 1, true), "the gopls hover stays first: " .. text)
assert(types_in(text) == "Order Customer Item Address Notifier Status Money", "types breadth first: " .. text)
assert(text:find("// Order is a purchase.\ntype Order struct {", 1, true), "doc comment of the root")
assert(text:find("Email string // contact address", 1, true), "field comments kept")
assert(text:find("Delivery Address `json:\"delivery\"`", 1, true), "tags kept")
assert(text:find("type Money struct {\n\tAmount   int64\n\tCurrency string\n}", 1, true),
    "a spec of `type ( … )` loses the group indentation: " .. text)
assert(not text:find("type Time", 1, true), "time.Time stays a name")
assert(select(2, text:gsub("type Order struct", "")) == 1, "a recursive type once")
assert(not text:find("// … more types", 1, true), "everything fits")
print("GO_HOVER_STRUCT_OK")

text = hover_at("c := o.Customer", "c :=")
assert(types_in(text) == "Customer", "local variable: " .. text)
text = hover_at("o.Delivery.City", "Delivery")
assert(types_in(text) == "Address" and text:find("field Delivery", 1, true), "field: " .. text)
text = hover_at("func handle(o *model.Order, items", "items")
assert(types_in(text) == "Item Money", "slice: " .. text)
print("GO_HOVER_VALUES_OK")

text = hover_at("func create(req", "req")
assert(types_in(text) == "CreateOrderRequest CreateOrderRequest_Line", "generated message: " .. text)
assert(text:find("type CreateOrderRequest struct {\n\t// Who pays.\n\tCustomerId    int64\n"
    .. "\tLines         []*CreateOrderRequest_Line\n}", 1, true), "no machinery fields and tags: " .. text)
assert(text:find("type CreateOrderRequest_Line struct {\n\tSku           string\n}", 1, true), "nested message: " .. text)
print("GO_HOVER_GENERATED_OK")

text = hover_at("var o model.Order", "Order")
assert(text:find("^```go\ntype Order struct {"), "gopls shows the type itself: " .. text)
assert(types_in("\n" .. text:match("%-%-%-\n```go\n(.*)$")) == "Customer Item Address Notifier Status Money",
    "only the types of its fields are added: " .. text)
for _, probe in ipairs({ { "count := len(items)", "count" }, { "f := handle", "f :=" }, { "handle(&o, nil)", "handle" } }) do
    text = hover_at(probe[1], probe[2])
    assert(text ~= "" and not text:find("\ntype ", 1, true), "plain gopls hover for " .. probe[2] .. ": " .. text)
end
print("GO_HOVER_TYPES_OK")

go_hover.opts.max_types = 2
text = hover_at("func handle(o *model.Order", "o *")
go_hover.opts.max_types = 15
assert(types_in(text) == "Order Customer" and text:find("// … more types", 1, true), "limit: " .. text)
print("GO_HOVER_LIMIT_OK")

-- K itself: the float, then K again goes into it.
local k = vim.fn.maparg("K", "n", false, true)
assert(k.buffer == 1 and k.desc == "Hover with the fields of struct types", "K in gopls buffers: " .. vim.inspect(k))
at("c := o.Customer", "c :=")
k.callback()
local float
assert(vim.wait(10000, function()
    for _, other in ipairs(vim.api.nvim_list_wins()) do
        if vim.w[other]["textDocument/hover"] == buf then
            float = other
            return true
        end
    end
    return false
end, 20), "K opened no float")
local shown = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), "\n")
assert(shown:find("type Customer struct", 1, true), "float shows the struct: " .. shown)
k.callback()
assert(vim.api.nvim_get_current_win() == float, "K again focuses the float")
vim.cmd("wincmd p")
vim.api.nvim_win_close(float, true)
print("GO_HOVER_FLOAT_OK")

print("GO_HOVER_SMOKE_OK")
