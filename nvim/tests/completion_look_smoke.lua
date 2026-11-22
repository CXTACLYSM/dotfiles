local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

-- The look of the completion menu (lua/completion_look.lua): the kind of
-- an item as an icon with the group of its kind, the detail without `func`
-- and cut to a column, nothing else decided for the native code; words
-- instead of icons without nvim-web-devicons.
local look = require("completion_look")
local kinds = vim.lsp.protocol.CompletionItemKind

-- As with the icons plugin loaded.
package.loaded["nvim-web-devicons"] = {}

local item = look.convert({
    label = "Println",
    kind = kinds.Function,
    detail = "func(a ...any) (n int, err error)",
})
assert(item.kind == "\u{f0295}" and item.kind_hlgroup == "CompletionKindFunction", vim.inspect(item))
assert(item.menu == "(a ...any) (n int, err error)", "the signature without func: " .. item.menu)
assert(item.abbr == nil and item.word == nil, "the native code keeps the word")
assert(item.info == "```go\nPrintln(a ...any) (n int, err error)\n```", "the popup: the signature as Go: " .. tostring(item.info))

-- The popup: the signature, then the doc comment; a value as `Name type`;
-- nothing for an item with neither.
item = look.convert({
    label = "Println",
    kind = kinds.Function,
    detail = "func(a ...any) (n int, err error)",
    documentation = { kind = "markdown", value = "Println formats using the default formats.\n" },
})
assert(item.info == "```go\nPrintln(a ...any) (n int, err error)\n```\n\nPrintln formats using the default formats.", item.info)
item = look.convert({ label = "Name", kind = kinds.Field, detail = "string", documentation = "contact address" })
assert(item.info == "```go\nName string\n```\n\ncontact address", item.info)
assert(look.convert({ label = "x", kind = kinds.Variable }).info == nil, "nothing to show")
print("COMPLETION_LOOK_INFO_OK")

item = look.convert({ label = "Save", kind = kinds.Method, detail = "func(o Order) error" })
assert(item.kind == "\u{f01a7}" and item.kind_hlgroup == "CompletionKindFunction" and item.menu == "(o Order) error", vim.inspect(item))

item = look.convert({ label = "Name", kind = kinds.Field, detail = "string" })
assert(item.kind == "\u{f0722}" and item.kind_hlgroup == "CompletionKindField" and item.menu == "string", vim.inspect(item))

item = look.convert({ label = "Order", kind = kinds.Struct, detail = "struct{...}" })
assert(item.kind_hlgroup == "CompletionKindType", vim.inspect(item))
item = look.convert({ label = "fmt", kind = kinds.Module, detail = '"fmt"' })
assert(item.kind_hlgroup == "CompletionKindModule" and item.menu == '"fmt"', vim.inspect(item))
item = look.convert({ label = "range", kind = kinds.Keyword })
assert(item.kind_hlgroup == "CompletionKindKeyword" and item.menu == "", vim.inspect(item))
print("COMPLETION_LOOK_KINDS_OK")

-- labelDetails.description wins over detail, as in the native code; a long
-- detail is cut to the column with "…"; spaces are collapsed.
item = look.convert({ label = "x", kind = kinds.Variable, detail = "int", labelDetails = { description = "*model.Order" } })
assert(item.menu == "*model.Order", item.menu)
local long = "func(ctx context.Context, req *CreateOrderRequest, opts ...grpc.CallOption) (*CreateOrderResponse, error)"
item = look.convert({ label = "CreateOrder", kind = kinds.Method, detail = long })
assert(vim.fn.strdisplaywidth(item.menu) == look.opts.menu_width and item.menu:sub(-3) == "…", item.menu)
assert(item.menu:sub(1, 5) == "(ctx ", item.menu)
item = look.convert({ label = "f", kind = kinds.Function, detail = "func(a int,\n\tb int)" })
assert(item.menu == "(a int, b int)", item.menu)
print("COMPLETION_LOOK_MENU_OK")

-- An unknown kind: only the menu; without the icons plugin the kind stays
-- the native word, the colour stays.
item = look.convert({ label = "?", kind = 999, detail = "x" })
assert(item.kind == nil and item.kind_hlgroup == nil and item.menu == "x", vim.inspect(item))
package.loaded["nvim-web-devicons"] = nil
item = look.convert({ label = "Println", kind = kinds.Function, detail = "func()" })
assert(item.kind == nil and item.kind_hlgroup == "CompletionKindFunction" and item.menu == "()", vim.inspect(item))
print("COMPLETION_LOOK_PLAIN_OK")

-- setup: the height of the menu, the groups, the autocommands.
look.setup({ pumheight = 9 })
assert(vim.o.pumheight == 9, "pumheight")
assert(vim.o.completeitemalign == "kind,abbr,menu", "the icon first in a row")
for _, group in ipairs({ "CompletionKindFunction", "CompletionKindField", "CompletionKindType", "CompletionKindModule" }) do
    assert(next(vim.api.nvim_get_hl(0, { name = group })) ~= nil, group .. " is defined")
end
assert(#vim.api.nvim_get_autocmds({ group = "completion_look", event = "CompleteChanged" }) == 1,
    "looks for the popup after a change of the selection")
assert(look.style_popup() == false, "no popup without a menu")
-- The options go to the popup window only: the global values stay.
vim.cmd("split")
local popup = vim.api.nvim_get_current_win()
vim.cmd("wincmd p")
local complete_info = vim.fn.complete_info
vim.fn.complete_info = function()
    return { preview_winid = popup }
end
assert(look.style_popup() == true, "the popup is styled")
vim.fn.complete_info = complete_info
assert(vim.wo[popup].linebreak and vim.wo[popup].breakindent, "the popup wraps at words")
assert(vim.go.linebreak == false and vim.wo.linebreak == false, "the other windows and the global value do not")
vim.cmd("only")
print("COMPLETION_LOOK_SETUP_OK")

print("COMPLETION_LOOK_SMOKE_OK")
