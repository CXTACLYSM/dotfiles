; extends

; SQL inside Go strings is highlighted as SQL. A string counts as a query when
; it starts with a statement, not just with a word: `SELECT … FROM`,
; `INSERT INTO`, `UPDATE x SET`, `DELETE FROM`, `WITH x AS (`, `CREATE TABLE`,
; …, so messages like "update order: %w" stay plain text. lua/sql_nav.lua
; recognises queries by the same rules. The text is matched as one string in
; which a newline is an ordinary character: [[:space:]] and . cover it, \_s
; and \n do not.
([
  (raw_string_literal
    (raw_string_literal_content) @injection.content)
  (interpreted_string_literal
    (interpreted_string_literal_content) @injection.content)
]
  (#match? @injection.content "\\v\\c^[[:space:]]*%(select>.{-}<from>|select[[:space:]]+%(\\d|\\*|\\$)|insert[[:space:]]+into>|update[[:space:]]+%(only[[:space:]]+)?[a-z0-9_.\"]+[[:space:]]+set>|delete[[:space:]]+from>|merge[[:space:]]+into>|with[[:space:]]+%(recursive[[:space:]]+)?[a-z0-9_\"]+[[:space:]]*%(\\([^)]*\\))?[[:space:]]*as>|create[[:space:]]+%(or[[:space:]]+replace[[:space:]]+)?%(unique[[:space:]]+)?%(temp%(orary)?[[:space:]]+|unlogged[[:space:]]+)?%(table|index|view|type|schema|sequence|extension|function|trigger|materialized)>|alter[[:space:]]+%(table|index|type|sequence|view)>|drop[[:space:]]+%(table|index|type|view|sequence|function|trigger|schema|extension)>|truncate[[:space:]]+%(table[[:space:]]+)?[a-z0-9_.\"]+[[:space:]]*%($|;|,|restart>|cascade>))")
  (#set! injection.language "sql"))
