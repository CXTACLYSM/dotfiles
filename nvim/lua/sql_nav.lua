-- SQL queries of the project in one tree: grouped by table, by statement
-- kind or by file, the code of the selected query in the preview.
--
-- Where queries come from:
--   * Go string literals that start with a statement (`SELECT … FROM`,
--     `INSERT INTO`, `UPDATE x SET`, …; the same rules as the SQL
--     highlighting in after/queries/go/injections.scm), `+` concatenations
--     joined and string constants of the package substituted;
--   * squirrel-style builder chains: sq.Select(…).From("orders o")
--     .Join("users u ON …"), sq.Insert("orders"), psql.Update(ordersTable)…;
--   * statements of .sql files: migrations (goose Up / Down) and sqlc
--     queries (`-- name: GetOrder :one`).
-- Generated Go files (`// Code generated … DO NOT EDIT.`) and vendor/ are
-- skipped: sqlc output repeats its .sql files, mocks hold no queries.
--
-- In the tree: Enter on a query opens it, on a group opens or closes the
-- group (zM / zR for all); Tab regroups (table → kind → file); r rescans;
-- q closes. A table group previews its CREATE TABLE when a migration has
-- one.

local M = {}

local groupings = { "table", "kind", "file" }

local kind_rank = {
    CREATE = 1,
    ALTER = 2,
    DROP = 3,
    TRUNCATE = 4,
    SELECT = 5,
    INSERT = 6,
    UPDATE = 7,
    DELETE = 8,
    MERGE = 9,
}

local kind_highlight = {
    SELECT = "SqlNavRead",
    INSERT = "SqlNavWrite",
    UPDATE = "SqlNavWrite",
    DELETE = "SqlNavWrite",
    MERGE = "SqlNavWrite",
    CREATE = "SqlNavSchema",
    ALTER = "SqlNavSchema",
    DROP = "SqlNavSchema",
    TRUNCATE = "SqlNavSchema",
}

local function notify(message, level)
    vim.notify(message, level or vim.log.levels.INFO, { title = "sql" })
end

-- ============================================================
-- SQL text
-- ============================================================

-- Words, names, punctuation; comments dropped, string literals and
-- dollar-quoted bodies reduced to one token.
local function tokenize(sql)
    local tokens = {}
    local i, n = 1, #sql
    while i <= n do
        local c = sql:sub(i, i)
        local two = sql:sub(i, i + 1)
        if c:match("%s") then
            i = i + 1
        elseif two == "--" then
            local stop = sql:find("\n", i, true)
            i = stop and stop + 1 or n + 1
        elseif two == "/*" then
            local stop = sql:find("*/", i + 2, true)
            i = stop and stop + 2 or n + 1
        elseif c == "'" then
            local j = i + 1
            while j <= n do
                if sql:sub(j, j) == "'" then
                    if sql:sub(j + 1, j + 1) ~= "'" then
                        break
                    end
                    j = j + 2
                else
                    j = j + 1
                end
            end
            tokens[#tokens + 1] = { kind = "string" }
            i = j + 1
        elseif c == '"' or c == "`" then
            local stop = sql:find(c, i + 1, true) or n
            tokens[#tokens + 1] = { kind = "name", text = sql:sub(i + 1, stop - 1), quoted = true }
            i = stop + 1
        elseif c == "$" then
            local tag = sql:match("^%$[%a_]*%$", i)
            if tag then
                local stop = sql:find(tag, i + #tag, true)
                tokens[#tokens + 1] = { kind = "string" }
                i = stop and stop + #tag or n + 1
            else
                tokens[#tokens + 1] = { kind = "param" }
                i = i + #sql:match("^%$%d*", i)
            end
        elseif c:match("[%a_]") then
            local word = sql:match("^[%w_$]+", i)
            tokens[#tokens + 1] = { kind = "name", text = word, lower = word:lower() }
            i = i + #word
        elseif c:match("%d") then
            tokens[#tokens + 1] = { kind = "number" }
            i = i + #sql:match("^[%d.]+", i)
        else
            tokens[#tokens + 1] = { kind = "punct", text = c }
            i = i + 1
        end
    end
    return tokens
end

local function word(token)
    return token and token.kind == "name" and not token.quoted and token.lower or nil
end

local function punct(token, text)
    return token ~= nil and token.kind == "punct" and token.text == text
end

local function skip_words(tokens, i, words)
    while words[word(tokens[i]) or ""] do
        i = i + 1
    end
    return i
end

-- index of the token after the parenthesised group that starts at i
local function skip_parens(tokens, i)
    local depth = 0
    while tokens[i] do
        if punct(tokens[i], "(") then
            depth = depth + 1
        elseif punct(tokens[i], ")") then
            depth = depth - 1
            if depth == 0 then
                return i + 1
            end
        end
        i = i + 1
    end
    return i
end

-- A possibly qualified name at i: orders, public.orders, "Order".
-- Unquoted names are lowercased, as PostgreSQL folds them.
local function name_at(tokens, i)
    local token = tokens[i]
    if not token or token.kind ~= "name" then
        return nil, i
    end
    local parts = { token.quoted and token.text or token.lower }
    local j = i + 1
    while punct(tokens[j], ".") and tokens[j + 1] and tokens[j + 1].kind == "name" do
        parts[#parts + 1] = tokens[j + 1].quoted and tokens[j + 1].text or tokens[j + 1].lower
        j = j + 2
    end
    return table.concat(parts, "."), j
end

local ddl_objects = {
    table = true,
    index = true,
    view = true,
    type = true,
    schema = true,
    sequence = true,
    extension = true,
    ["function"] = true,
    trigger = true,
    materialized = true,
}

-- Statement kind when the tokens start like a query, as the highlighting
-- rules decide; nil otherwise.
local function statement_kind(tokens)
    local i = 1
    while punct(tokens[i], "(") do
        i = i + 1
    end
    local first = word(tokens[i])
    if not first then
        return nil
    end
    local second = tokens[i + 1]

    if first == "select" then
        for j = i + 1, #tokens do
            if word(tokens[j]) == "from" then
                return "SELECT"
            end
        end
        if second and (second.kind == "number" or second.kind == "param" or punct(second, "*")) then
            return "SELECT"
        end
        return nil
    elseif first == "insert" or first == "merge" then
        return word(second) == "into" and first:upper() or nil
    elseif first == "delete" then
        return word(second) == "from" and "DELETE" or nil
    elseif first == "update" then
        local _, after = name_at(tokens, skip_words(tokens, i + 1, { only = true }))
        return word(tokens[after]) == "set" and "UPDATE" or nil
    elseif first == "with" then
        local j = skip_words(tokens, i + 1, { recursive = true })
        if not tokens[j] or tokens[j].kind ~= "name" then
            return nil
        end
        j = j + 1
        if punct(tokens[j], "(") then
            j = skip_parens(tokens, j)
        end
        if word(tokens[j]) ~= "as" then
            return nil
        end
        -- The main statement: the first verb outside the CTE bodies.
        local depth = 0
        for k = j, #tokens do
            if punct(tokens[k], "(") then
                depth = depth + 1
            elseif punct(tokens[k], ")") then
                depth = depth - 1
            elseif depth == 0 then
                local verb = word(tokens[k])
                if verb == "select" or verb == "insert" or verb == "update" or verb == "delete" or verb == "merge" then
                    return verb:upper()
                end
            end
        end
        return nil
    elseif first == "create" then
        local j = skip_words(tokens, i + 1, {
            ["or"] = true,
            replace = true,
            unique = true,
            temp = true,
            temporary = true,
            unlogged = true,
        })
        return ddl_objects[word(tokens[j]) or ""] and "CREATE" or nil
    elseif first == "alter" or first == "drop" then
        return ddl_objects[word(second) or ""] and first:upper() or nil
    elseif first == "truncate" then
        local _, after = name_at(tokens, skip_words(tokens, i + 1, { table = true, only = true }))
        local next_token = tokens[after]
        local ok = after > i + 1 and (not next_token or punct(next_token, ";") or punct(next_token, ",")
            or word(next_token) == "restart" or word(next_token) == "cascade")
        return ok and "TRUNCATE" or nil
    end
    return nil
end

-- FROM inside these calls is not a table: extract(year from ts), trim(…).
local from_functions = {
    extract = true,
    substring = true,
    substr = true,
    trim = true,
    position = true,
    overlay = true,
}

-- Words that end a FROM list item (an alias is anything else).
local clause_words = {
    where = true,
    group = true,
    order = true,
    limit = true,
    offset = true,
    having = true,
    window = true,
    join = true,
    inner = true,
    left = true,
    right = true,
    full = true,
    cross = true,
    natural = true,
    on = true,
    using = true,
    union = true,
    except = true,
    intersect = true,
    returning = true,
    ["for"] = true,
    fetch = true,
    set = true,
    values = true,
    select = true,
}

local table_after = {
    create = true,
    alter = true,
    drop = true,
    truncate = true,
    lock = true,
    temp = true,
    temporary = true,
    unlogged = true,
    foreign = true,
}

-- Tables a statement reads or writes, in order of appearance; CTE names
-- and function calls are not tables.
local function statement_tables(tokens, kind)
    local found, seen, ctes = {}, {}, {}

    for i = 2, #tokens do
        local previous = tokens[i - 1]
        if tokens[i].kind == "name"
            and (word(previous) == "with" or word(previous) == "recursive" or punct(previous, ","))
        then
            local j = i + 1
            if punct(tokens[j], "(") then
                j = skip_parens(tokens, j)
            end
            local after_as = tokens[j + 1]
            if word(tokens[j]) == "as"
                and (punct(after_as, "(") or word(after_as) == "not" or word(after_as) == "materialized")
            then
                ctes[tokens[i].quoted and tokens[i].text or tokens[i].lower] = true
            end
        end
    end

    local function add(name)
        if name and name ~= "" and not ctes[name] and not seen[name] and not name:find("%", 1, true) then
            seen[name] = true
            found[#found + 1] = name
        end
    end

    -- FROM a [alias], b [alias] … ; stops at a subquery or a function.
    local function from_list(j)
        while true do
            local name, after = name_at(tokens, j)
            if not name or punct(tokens[after], "(") then
                return
            end
            add(name)
            local k = after
            if word(tokens[k]) == "as" then
                k = k + 1
            end
            if tokens[k] and tokens[k].kind == "name" and not clause_words[word(tokens[k]) or ""] then
                k = k + 1
            end
            if not punct(tokens[k], ",") then
                return
            end
            j = skip_words(tokens, k + 1, { only = true, lateral = true })
        end
    end

    local stack = {}
    local index_or_trigger = false
    for i, token in ipairs(tokens) do
        if punct(token, "(") then
            stack[#stack + 1] = word(tokens[i - 1]) or ""
        elseif punct(token, ")") then
            stack[#stack] = nil
        else
            local w = word(token)
            local previous = word(tokens[i - 1])
            if w == "from" then
                if previous ~= "distinct" and not from_functions[stack[#stack] or ""] then
                    from_list(skip_words(tokens, i + 1, { only = true, lateral = true }))
                end
            elseif w == "join" then
                local name, after = name_at(tokens, skip_words(tokens, i + 1, { lateral = true, only = true }))
                if name and not punct(tokens[after], "(") then
                    add(name)
                end
            elseif w == "into" then
                if previous == "insert" or previous == "merge" then
                    add((name_at(tokens, i + 1)))
                end
            elseif w == "update" then
                if previous ~= "do" and previous ~= "for" and previous ~= "key" and previous ~= "on" then
                    local name = name_at(tokens, skip_words(tokens, i + 1, { only = true }))
                    if name ~= "set" then
                        add(name)
                    end
                end
            elseif w == "table" then
                if table_after[previous or ""] then
                    local name, after = name_at(tokens, skip_words(tokens, i + 1, {
                        ["if"] = true,
                        ["not"] = true,
                        exists = true,
                        only = true,
                    }))
                    add(name)
                    while (kind == "DROP" or kind == "TRUNCATE") and punct(tokens[after], ",") do
                        name, after = name_at(tokens, after + 1)
                        add(name)
                    end
                end
            elseif w == "truncate" and i == 1 then
                local name, after = name_at(tokens, skip_words(tokens, i + 1, { table = true, only = true }))
                add(name)
                while punct(tokens[after], ",") do
                    name, after = name_at(tokens, after + 1)
                    add(name)
                end
            elseif (w == "index" or w == "trigger") and kind == "CREATE" then
                index_or_trigger = true
            elseif w == "on" and index_or_trigger and #stack == 0 then
                add((name_at(tokens, skip_words(tokens, i + 1, { only = true }))))
                index_or_trigger = false
            elseif w == "using" and (kind == "DELETE" or kind == "MERGE") and #stack == 0 then
                local name, after = name_at(tokens, i + 1)
                if name and not punct(tokens[after], "(") then
                    add(name)
                end
            end
        end
    end
    return found
end

local starters = {
    select = true,
    insert = true,
    update = true,
    delete = true,
    merge = true,
    with = true,
    create = true,
    alter = true,
    drop = true,
    truncate = true,
}

-- Cheap test before tokenizing: the first word of the text is a statement
-- keyword (leading comments and parentheses aside).
local function may_be_query(sql)
    local head = sql:match("^[%s(]*(%a+)")
    if head then
        return starters[head:lower()] == true
    end
    return sql:match("^%s*%-%-") ~= nil or sql:match("^%s*/%*") ~= nil
end

-- { kind = "SELECT", tables = { "orders", "users" } } or nil when the text
-- is not a query.
function M.analyze(sql)
    if not may_be_query(sql) then
        return nil
    end
    local tokens = tokenize(sql)
    local kind = statement_kind(tokens)
    if not kind then
        return nil
    end
    return { kind = kind, tables = statement_tables(tokens, kind) }
end

-- The first name in a builder argument: "orders o" → orders,
-- "users u ON u.id = o.user_id" → users.
local function leading_name(text)
    return (name_at(tokenize(text), 1))
end

-- ============================================================
-- .sql files
-- ============================================================

-- Statements of a .sql file with their first line, the sqlc query name and
-- the goose section they are in.
local function sql_statements(text)
    local out = {}
    local i, n, line = 1, #text, 1
    local start, start_line, name, section

    local function newlines(chunk)
        return select(2, chunk:gsub("\n", ""))
    end
    local function begin()
        if not start then
            start, start_line = i, line
        end
    end
    local function finish(stop)
        if start then
            out[#out + 1] = { text = text:sub(start, stop), line = start_line, name = name, section = section }
            start, name = nil, nil
        end
    end

    while i <= n do
        local c = text:sub(i, i)
        local two = text:sub(i, i + 1)
        if c == "\n" then
            line = line + 1
            i = i + 1
        elseif two == "--" then
            local stop = text:find("\n", i, true) or n + 1
            if not start then
                local comment = text:sub(i, stop - 1)
                name = comment:match("^%-%-%s*name:%s*([%w_]+)") or name
                local goose = comment:match("^%-%-%s*%+goose%s+(%a+)")
                if goose == "Up" or goose == "Down" then
                    section = goose:lower()
                end
            end
            i = stop
        elseif two == "/*" then
            local stop = text:find("*/", i + 2, true) or n
            line = line + newlines(text:sub(i, stop))
            i = stop + 2
        elseif c == "'" or c == '"' then
            begin()
            local j = i + 1
            while j <= n and not (text:sub(j, j) == c and text:sub(j + 1, j + 1) ~= c) do
                j = text:sub(j, j) == c and j + 2 or j + 1
            end
            line = line + newlines(text:sub(i, j))
            i = j + 1
        elseif c == "$" and text:match("^%$[%a_]*%$", i) then
            begin()
            local tag = text:match("^%$[%a_]*%$", i)
            local stop = text:find(tag, i + #tag, true)
            local last = stop and stop + #tag - 1 or n
            line = line + newlines(text:sub(i, last))
            i = last + 1
        elseif c == ";" then
            finish(i - 1)
            i = i + 1
        elseif c:match("%s") then
            i = i + 1
        else
            begin()
            i = i + 1
        end
    end
    finish(n)
    return out
end

-- Queries of one .sql file.
function M.extract_sql(text, path)
    local queries = {}
    local base = vim.fn.fnamemodify(path, ":t:r")
    for _, statement in ipairs(sql_statements(text)) do
        local info = M.analyze(statement.text)
        if info then
            local owner = statement.name or base
            if statement.section == "down" then
                owner = owner .. " ↓"
            end
            queries[#queries + 1] = {
                path = path,
                line = statement.line,
                col = 0,
                kind = info.kind,
                tables = info.tables,
                owner = owner,
            }
        end
    end
    return queries
end

-- ============================================================
-- Go files
-- ============================================================

local go_query, const_query
local function query()
    go_query = go_query or vim.treesitter.query.parse("go", [[
        (raw_string_literal) @string
        (interpreted_string_literal) @string
        ((call_expression
          function: (selector_expression
            field: (field_identifier) @verb))
          (#any-of? @verb "Select" "Insert" "Update" "Delete" "Replace"))
        (import_spec) @import
    ]])
    return go_query
end

local function node_text(node, source)
    return vim.treesitter.get_node_text(node, source)
end

local function string_value(node, source)
    local raw = node_text(node, source)
    if node:type() == "raw_string_literal" then
        return raw:sub(2, -2)
    end
    return (raw:sub(2, -2):gsub("\\(.)", { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\" }))
end

local function is_string(node)
    local type = node and node:type()
    return type == "raw_string_literal" or type == "interpreted_string_literal"
end

local function is_generated(text)
    for line in text:gmatch("[^\n]*") do
        if line:match("^// Code generated .* DO NOT EDIT%.$") then
            return true
        end
        if line:match("^package%s") then
            return false
        end
    end
    return false
end

local function parse_go(text)
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, "go")
    if not ok or not parser then
        return nil
    end
    local tree = parser:parse()[1]
    return tree and tree:root() or nil
end

-- String constants of a package directory: { name = value }.
local function package_constants(dir, cache)
    if cache[dir] then
        return cache[dir]
    end
    local constants = {}
    cache[dir] = constants
    for name, type in vim.fs.dir(dir) do
        if type == "file" and name:match("%.go$") and not name:match("_test%.go$") then
            local file = io.open(dir .. "/" .. name, "r")
            local text = file and file:read("*a")
            if file then
                file:close()
            end
            local root = text and text:find("const", 1, true) and parse_go(text)
            if root then
                const_query = const_query or vim.treesitter.query.parse("go", "(const_spec) @spec")
                for _, spec in const_query:iter_captures(root, text) do
                    local names = spec:field("name")
                    local value = spec:field("value")[1]
                    if #names == 1 and value and value:named_child_count() == 1 and is_string(value:named_child(0)) then
                        constants[node_text(names[1], text)] = string_value(value:named_child(0), text)
                    end
                end
            end
        end
    end
    return constants
end

local function receiver_type(node, source)
    local list = node:field("receiver")[1]
    if not list then
        return nil
    end
    for child in list:iter_children() do
        if child:type() == "parameter_declaration" then
            local type = child:field("type")[1]
            return type and node_text(type, source) or nil
        end
    end
    return nil
end

-- The function or method around a node, or the package-level constant /
-- variable it initialises: "(*Repo) Create", "getOrderQuery".
local function owner_of(node, source)
    local spec
    local current = node:parent()
    while current do
        local type = current:type()
        if (type == "const_spec" or type == "var_spec") and not spec then
            local name = current:field("name")[1]
            spec = name and node_text(name, source) or nil
        elseif type == "function_declaration" then
            local name = current:field("name")[1]
            return name and node_text(name, source) or spec or ""
        elseif type == "method_declaration" then
            local name = current:field("name")[1]
            name = name and node_text(name, source) or "?"
            local receiver = receiver_type(current, source)
            return receiver and ("(" .. receiver .. ") " .. name) or name
        end
        current = current:parent()
    end
    return spec or ""
end

local verbs = {
    Select = "SELECT",
    Insert = "INSERT",
    Update = "UPDATE",
    Delete = "DELETE",
    Replace = "INSERT",
}

local table_methods = {
    From = true,
    Into = true,
    Join = true,
    LeftJoin = true,
    RightJoin = true,
    InnerJoin = true,
    CrossJoin = true,
    FullJoin = true,
}

-- Methods that make a chain a query builder rather than, say, cache.Delete.
local builder_methods = {
    From = true,
    Into = true,
    Join = true,
    LeftJoin = true,
    RightJoin = true,
    InnerJoin = true,
    CrossJoin = true,
    FullJoin = true,
    Where = true,
    Set = true,
    SetMap = true,
    Values = true,
    Columns = true,
    Rows = true,
    Suffix = true,
    Prefix = true,
    Returning = true,
    OrderBy = true,
    GroupBy = true,
    Having = true,
    Limit = true,
    Offset = true,
    Options = true,
    PlaceholderFormat = true,
    RunWith = true,
    ToSql = true,
    MustSql = true,
}

local function method_name(call, source)
    local fn = call:field("function")[1]
    if not fn or fn:type() ~= "selector_expression" then
        return nil
    end
    local field = fn:field("field")[1]
    return field and node_text(field, source) or nil
end

local function first_argument(call)
    local args = call:field("arguments")[1]
    return args and args:named_child_count() > 0 and args:named_child(0) or nil
end

-- One builder chain starting at a verb call: kind, tables, or nil.
local function builder_query(call, verb, source, resolve, builder_aliases)
    -- A verb further down the chain owns it (InsertBuilder.Select(…)).
    local below = call:field("function")[1]:field("operand")[1]
    local operand_text = below and node_text(below, source) or ""
    while below and below:type() == "call_expression" do
        if verbs[method_name(below, source) or ""] then
            return nil
        end
        local fn = below:field("function")[1]
        below = fn and fn:type() == "selector_expression" and fn:field("operand")[1] or nil
    end

    local kind = verbs[verb]
    local table_args = {}
    if kind ~= "SELECT" then
        table_args[1] = first_argument(call)
    end

    local builder = builder_aliases[operand_text] or operand_text:find("StatementBuilder", 1, true)
        or operand_text:find("PlaceholderFormat", 1, true)
    local has_from = false
    local node = call
    while true do
        local selector = node:parent()
        local next_call = selector and selector:parent()
        if not selector or selector:type() ~= "selector_expression"
            or not next_call or next_call:type() ~= "call_expression"
        then
            break
        end
        local name = method_name(next_call, source)
        if not name or verbs[name] then
            break
        end
        if builder_methods[name] then
            builder = true
        end
        if table_methods[name] then
            has_from = true
            table_args[#table_args + 1] = first_argument(next_call)
        end
        node = next_call
    end
    if not builder or (kind == "SELECT" and not has_from) then
        return nil
    end

    -- Only now, for a real builder: string constants may need the package.
    local tables, seen = {}, {}
    for _, arg in ipairs(table_args) do
        local name = resolve(arg)
        name = name and leading_name(name)
        if name and not seen[name] and not name:find("%", 1, true) then
            seen[name] = true
            tables[#tables + 1] = name
        end
    end
    if #tables == 0 then
        return nil
    end
    return { kind = kind, tables = tables }
end

-- Queries of one Go file.
function M.extract_go(text, path, constants_cache)
    if is_generated(text) then
        return {}
    end
    local root = parse_go(text)
    if not root then
        return {}
    end
    constants_cache = constants_cache or {}
    local dir = vim.fn.fnamemodify(path, ":h")

    -- An identifier or a string literal as text: string constants of the
    -- package substituted, anything else left as a gap.
    local function resolve(node)
        if is_string(node) then
            return string_value(node, text)
        end
        local type = node:type()
        if type == "identifier" then
            local value = package_constants(dir, constants_cache)[node_text(node, text)]
            return value or node_text(node, text)
        end
        if type == "selector_expression" then
            return node_text(node, text)
        end
        return nil
    end

    local function concatenation(node)
        local type = node:type()
        if type == "binary_expression" then
            return concatenation(node:field("left")[1]) .. concatenation(node:field("right")[1])
        elseif type == "parenthesized_expression" and node:named_child(0) then
            return concatenation(node:named_child(0))
        end
        local value = resolve(node)
        if value and (is_string(node) or type == "identifier" and value ~= node_text(node, text)) then
            return value
        end
        return " … "
    end

    local queries = {}
    local builder_aliases = {}
    local q = query()
    for id, node in q:iter_captures(root, text) do
        local capture = q.captures[id]
        if capture == "import" then
            local import_path = node:field("path")[1]
            local alias = node:field("name")[1]
            if import_path and node_text(import_path, text):find("squirrel", 1, true) then
                builder_aliases[alias and node_text(alias, text) or "squirrel"] = true
            end
        elseif capture == "string" then
            local value = string_value(node, text)
            -- The first literal of a `+` concatenation stands for all of it.
            local top = node
            if may_be_query(value) then
                while top:parent() and top:parent():type() == "binary_expression"
                    and node_text(top:parent():field("operator")[1], text) == "+"
                do
                    top = top:parent()
                end
            end
            local leftmost = top
            while leftmost:type() == "binary_expression" do
                leftmost = leftmost:field("left")[1]
            end
            if may_be_query(value) and leftmost:id() == node:id() then
                local sql = top:id() == node:id() and value or concatenation(top)
                local info = M.analyze(sql)
                if info then
                    local row, col = node:start()
                    queries[#queries + 1] = {
                        path = path,
                        line = row + 1,
                        col = col,
                        kind = info.kind,
                        tables = info.tables,
                        owner = owner_of(node, text),
                    }
                end
            end
        elseif capture == "verb" then
            local verb = node_text(node, text)
            local call = node:parent() and node:parent():parent()
            if verbs[verb] and call and call:type() == "call_expression" then
                local info = builder_query(call, verb, text, resolve, builder_aliases)
                if info then
                    local row, col = call:start()
                    queries[#queries + 1] = {
                        path = path,
                        line = row + 1,
                        col = col,
                        kind = info.kind,
                        tables = info.tables,
                        owner = owner_of(call, text),
                    }
                end
            end
        end
    end
    return queries
end

-- ============================================================
-- Project scan
-- ============================================================

local go_patterns = {
    [=[[`"]\s*(?i:select|insert|update|delete|merge|with|create|alter|drop|truncate)\s]=],
    [=[\.(?:Select|Insert|Update|Delete|Replace)\(]=],
}

local function read(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local text = file:read("*a")
    file:close()
    return text
end

local function rg(args, cwd)
    local result = vim.system(vim.list_extend({ "rg" }, args), { cwd = cwd, text = true }):wait()
    if result.code > 1 then
        notify("rg failed: " .. vim.trim(result.stderr or ""), vim.log.levels.WARN)
    end
    return vim.split(vim.trim(result.stdout or ""), "\n", { trimempty = true })
end

-- Every query under root, sorted by path and line.
function M.collect(root)
    root = vim.fs.normalize(root)
    local queries = {}
    local constants_cache = {}

    for _, file in ipairs(rg({ "--files", "--glob", "*.sql", "--glob", "!vendor/**" }, root)) do
        local path = root .. "/" .. file
        local text = read(path)
        if text then
            vim.list_extend(queries, M.extract_sql(text, path))
        end
    end

    local args = { "--files-with-matches", "--multiline", "--glob", "*.go", "--glob", "!vendor/**",
        "--glob", "!*.pb.go" }
    for _, pattern in ipairs(go_patterns) do
        vim.list_extend(args, { "-e", pattern })
    end
    for _, file in ipairs(rg(args, root)) do
        local path = root .. "/" .. file
        local text = read(path)
        if text then
            vim.list_extend(queries, M.extract_go(text, path, constants_cache))
        end
    end

    table.sort(queries, function(a, b)
        if a.path ~= b.path then
            return a.path < b.path
        end
        return a.line < b.line
    end)
    return queries
end

-- ============================================================
-- Tree
-- ============================================================

local function by_rank(a, b)
    local ra, rb = kind_rank[a.kind] or 99, kind_rank[b.kind] or 99
    if ra ~= rb then
        return ra < rb
    end
    if a.path ~= b.path then
        return a.path < b.path
    end
    return a.line < b.line
end

-- Ordered groups { name, queries, preview? } for a grouping.
function M.groups(queries, by, root)
    local groups, index = {}, {}
    local function add(name, item)
        if not index[name] then
            index[name] = { name = name, queries = {} }
            groups[#groups + 1] = index[name]
        end
        table.insert(index[name].queries, item)
    end

    for _, item in ipairs(queries) do
        if by == "table" then
            if #item.tables == 0 then
                add("", item)
            end
            for _, name in ipairs(item.tables) do
                add(name, item)
            end
        elseif by == "kind" then
            add(item.kind, item)
        else
            add(vim.fs.relpath(root, item.path) or item.path, item)
        end
    end

    table.sort(groups, function(a, b)
        if (a.name == "") ~= (b.name == "") then
            return b.name == ""
        end
        if by == "kind" then
            return (kind_rank[a.name] or 99) < (kind_rank[b.name] or 99)
        end
        return a.name < b.name
    end)

    for _, group in ipairs(groups) do
        if by == "table" then
            table.sort(group.queries, by_rank)
            -- The table's definition when there is one.
            for _, item in ipairs(group.queries) do
                if item.kind == "CREATE" and item.tables[1] == group.name then
                    group.preview = item
                    break
                end
            end
        end
        group.preview = group.preview or group.queries[1]
    end
    return groups
end

local function clip(text, width)
    if vim.fn.strdisplaywidth(text) <= width then
        return text
    end
    return vim.fn.strcharpart(text, 0, width - 1) .. "…"
end

local function pad(text, width)
    return text .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(text)))
end

local function target(item)
    return { path = item.path, line = item.line, col = item.col }
end

-- graph_view spec for queries grouped `by`.
function M.view(queries, by, root)
    local groups = M.groups(queries, by, root)
    local lines, entries, folds = {}, {}, {}

    local owner_width, tables_width, kind_width = 0, 0, 0
    for _, item in ipairs(queries) do
        owner_width = math.max(owner_width, vim.fn.strdisplaywidth(clip(item.owner ~= "" and item.owner or "—", 40)))
        tables_width = math.max(tables_width, vim.fn.strdisplaywidth(clip(table.concat(item.tables, ", "), 36)))
        kind_width = math.max(kind_width, #item.kind)
    end

    for _, group in ipairs(groups) do
        local header_row = #lines + 1
        local title = group.name ~= "" and group.name or "(no table)"
        local count = tostring(#group.queries)
        lines[#lines + 1] = title .. "  " .. count
        entries[#entries + 1] = {
            highlights = {
                { group.name ~= "" and (by == "kind" and kind_highlight[group.name] or "SqlNavGroup") or "SqlNavDim",
                    0, #title },
                { "SqlNavDim", #title + 2, #title + 2 + #count },
            },
            preview = group.preview and target(group.preview) or nil,
        }

        for _, item in ipairs(group.queries) do
            local parts = {}
            local function part(text, hl)
                parts[#parts + 1] = { text, hl }
            end
            local owner = pad(clip(item.owner ~= "" and item.owner or "—", 40), owner_width)
            local tables = pad(clip(table.concat(item.tables, ", "), 36), tables_width)
            local location = (vim.fs.relpath(root, item.path) or item.path) .. ":" .. item.line
            if by ~= "kind" then
                part(pad(item.kind, kind_width), kind_highlight[item.kind])
            end
            part(owner)
            if by ~= "table" then
                part(tables, "SqlNavTables")
            end
            if by ~= "file" then
                part(location, "SqlNavDim")
            else
                part(":" .. item.line, "SqlNavDim")
            end

            local line, highlights = "  ", {}
            for index, piece in ipairs(parts) do
                local start = #line
                line = line .. piece[1]
                if piece[2] then
                    highlights[#highlights + 1] = { piece[2], start, #line }
                end
                if index < #parts then
                    line = line .. "  "
                end
            end
            lines[#lines + 1] = (line:gsub("%s+$", ""))
            entries[#entries + 1] = {
                highlights = highlights,
                preview = target(item),
                jumps = { ["<CR>"] = target(item) },
            }
        end
        folds[#folds + 1] = { header_row, #lines }
    end

    local next_by = groupings[(vim.fn.index(groupings, by) + 1) % #groupings + 1]
    return {
        title = string.format("SQL · %d queries · by %s", #queries, by),
        footer = "Tab: by " .. next_by .. " · Enter: open / fold · r: rescan",
        filetype = "sqlnav",
        lines = lines,
        entries = entries,
        folds = folds,
        folded = #lines > vim.o.lines - 6,
    }, next_by
end

local function highlights()
    for group, link in pairs({
        SqlNavGroup = "Title",
        SqlNavDim = "Comment",
        SqlNavTables = "Identifier",
        SqlNavRead = "Function",
        SqlNavWrite = "DiagnosticWarn",
        SqlNavSchema = "Keyword",
    }) do
        vim.api.nvim_set_hl(0, group, { link = link, default = true })
    end
end

function M.show(queries, by, root, source_win)
    highlights()
    local spec, next_by = M.view(queries, by, root)
    spec.source_win = source_win
    spec.keys = {
        ["<Tab>"] = function(ctx)
            ctx.close()
            M.show(queries, next_by, root, source_win)
        end,
        r = function(ctx)
            ctx.close()
            M.open(root, by, source_win)
        end,
    }
    return require("graph_view").open(spec)
end

function M.open(root, by, source_win)
    root = root or vim.fn.getcwd()
    local queries = M.collect(root)
    if #queries == 0 then
        notify("No SQL queries under " .. vim.fn.fnamemodify(root, ":~"))
        return
    end
    return M.show(queries, by or "table", root, source_win or vim.api.nvim_get_current_win())
end

M._tokenize = tokenize
M._sql_statements = sql_statements

return M
