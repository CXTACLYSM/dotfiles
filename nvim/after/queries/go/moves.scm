; Jumps between the Go keywords (]m [m ]e [e … in init.lua, run by
; nvim-treesitter-textobjects' move with this query group). Each capture
; is the whole statement or declaration, so the jump lands on its first
; character; a variable (]v) is its name.

; ]m: a method
(method_declaration) @method.outer

; ]e: an error check — an `if` whose condition mentions err
(if_statement
  condition: (_) @_condition
  (#lua-match? @_condition "%f[%w_]err%f[^%w_]")) @err.outer

; ]R: a return
(return_statement) @return.outer

; ]g: a goroutine, ]G: a defer
(go_statement) @go.outer
(defer_statement) @defer.outer

; ]l: a loop
(for_statement) @loop.outer

; ]w: a switch or a select, ]k: a case in one
[
  (expression_switch_statement)
  (type_switch_statement)
  (select_statement)
] @switch.outer

[
  (expression_case)
  (default_case)
  (type_case)
  (communication_case)
] @case.outer

; ]i: an interface
(type_declaration
  (type_spec
    type: (interface_type))) @interface.outer

; ]v: a variable, on its name where it is declared: var (of the file or of
; a function), :=, the variables of a range, of a type switch and of a
; select case; each name of `a, err :=` is a stop of its own, `_` is not
(var_spec
  name: (identifier) @var.outer
  (#not-eq? @var.outer "_"))

(short_var_declaration
  left: (expression_list
    (identifier) @var.outer)
  (#not-eq? @var.outer "_"))

(range_clause
  left: (expression_list
    (identifier) @var.outer)
  ":="
  (#not-eq? @var.outer "_"))

(type_switch_statement
  alias: (expression_list
    (identifier) @var.outer)
  (#not-eq? @var.outer "_"))

(receive_statement
  left: (expression_list
    (identifier) @var.outer)
  ":="
  (#not-eq? @var.outer "_"))

; ]T: a test
(function_declaration
  name: (identifier) @_name
  (#lua-match? @_name "^Test")) @test.outer
