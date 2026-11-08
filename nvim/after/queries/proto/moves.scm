; Jumps over a .proto contract (]p [p ]M [M ]s [s in init.lua, run by
; nvim-treesitter-textobjects' move with this query group), as the Go
; keywords in go/moves.scm.

; ]p: an rpc
(rpc) @rpc.outer

; ]M: a message
(message) @message.outer

; ]s: a message or an enum, as struct / interface in Go
[
  (message)
  (enum)
] @type.outer
