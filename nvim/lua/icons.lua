-- One set of glyphs for the kinds of declarations, so a method is the same
-- cube in the window bar (lua/breadcrumbs.lua), in the completion menu
-- (lua/completion_look.lua) and in the symbol pickers of fzf-lua (Space
-- ss / sS, Alt-k by kind, lua/categories.lua). Nerd Font, nf-md and
-- nf-cod of the JetBrainsMono NF of the iTerm2 profile; the places fall
-- back to words without nvim-web-devicons, which stands for a Nerd Font.

local M = {}

-- By the kind of a Go declaration.
M.kind = {
    ["function"] = "\u{f0295}", -- 󰊕 function
    method = "\u{f01a7}", -- 󰆧 cube: a method, a constructor
    field = "\u{f0722}", -- 󰜢 tag: a field, a property
    variable = "\u{f002b}", -- 󰀫 alpha-v
    constant = "\u{f03ff}", -- 󰏿 pi: a constant, an enum member, a value
    struct = "\u{f0645}", -- 󰙅 struct, class, type parameter
    interface = "\u{f0730}", -- 󰜰 interface
    module = "\u{f487}", --  package: a module, a package, a namespace
    keyword = "\u{f030b}", -- 󰌋 key
    text = "\u{eab1}", --  string: text, a snippet
    file = "\u{f0219}", -- 󰈙 file
    folder = "\u{f024b}", -- 󰉋 folder
    operator = "\u{f0195}", -- 󰆕 operator
    enum = "\u{f15d}", --  enum
    event = "\u{f0e7}", --  event
    number = "\u{f03a0}", -- 󰎠 number
    boolean = "\u{f0a19}", -- 󰨙 boolean
}

-- The icon of every LSP SymbolKind (fzf-lua `symbol_icons`), from the set
-- above: a class and a struct are one icon, a property and a field, a
-- package and a module.
M.lsp_symbols = {
    File = M.kind.file,
    Module = M.kind.module,
    Namespace = M.kind.module,
    Package = M.kind.module,
    Class = M.kind.struct,
    Method = M.kind.method,
    Property = M.kind.field,
    Field = M.kind.field,
    Constructor = M.kind.method,
    Enum = M.kind.enum,
    Interface = M.kind.interface,
    Function = M.kind["function"],
    Variable = M.kind.variable,
    Constant = M.kind.constant,
    String = M.kind.text,
    Number = M.kind.number,
    Boolean = M.kind.boolean,
    Array = M.kind.variable,
    Object = M.kind.struct,
    Key = M.kind.keyword,
    Null = M.kind.constant,
    EnumMember = M.kind.constant,
    Struct = M.kind.struct,
    Event = M.kind.event,
    Operator = M.kind.operator,
    TypeParameter = M.kind.struct,
}

return M
