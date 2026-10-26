-- K for Go: the gopls hover, and when the name under the cursor is a
-- variable, parameter or field of a struct type (or a pointer, slice, array
-- or channel of one), that struct below it together with every project type
-- its fields name, transitively: Order → Customer, Item → Money, Address.
-- Each type is shown once, in the order the fields name it, so a recursive
-- type does not loop; on the name of a struct type gopls already shows it,
-- and only the types of its fields are added. Types from outside the
-- project (time.Time, the module cache, vendor/) stay names, interfaces are
-- shown but not followed. A generated struct (protobuf messages) is shown
-- without its unexported machinery fields and struct tags.
--
-- gopls does the resolving: typeDefinition finds the struct of the value,
-- definition finds each type named in its fields; Tree-sitter cuts the
-- declarations out of their files, field comments and tags included.
-- K again focuses the float, as the native K.

local M = {}

M.opts = {
    -- Most type declarations under one hover.
    max_types = 15,
    -- Wait for gopls at most this long, then show what has arrived.
    timeout_ms = 1500,
}

local focus_id = "textDocument/hover"
local hover_ns = vim.api.nvim_create_namespace("go_hover")

local predeclared = {}
for _, name in ipairs({
    "any", "bool", "byte", "comparable", "complex64", "complex128", "error",
    "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune",
    "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
}) do
    predeclared[name] = true
end

local function file_lines(path)
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines or nil
end

-- The `// Code generated … DO NOT EDIT.` line before the package clause.
local function is_generated(lines)
    for _, line in ipairs(lines) do
        if line:match("^// Code generated .* DO NOT EDIT%.$") then
            return true
        end
        if line:match("^package ") then
            return false
        end
    end
    return false
end

-- { lines, text, root, generated } of a Go file, parsed once per hover.
local function parsed(cache, path)
    if cache[path] == nil then
        cache[path] = false
        local lines = file_lines(path)
        if lines then
            local text = table.concat(lines, "\n")
            local ok, parser = pcall(vim.treesitter.get_string_parser, text, "go")
            local tree = ok and parser:parse()[1]
            if tree then
                cache[path] = { lines = lines, text = text, root = tree:root(), generated = is_generated(lines) }
            end
        end
    end
    return cache[path] or nil
end

local function contains(node, row, col)
    local start_row, start_col, end_row, end_col = node:range()
    return (row > start_row or row == start_row and col >= start_col)
        and (row < end_row or row == end_row and col < end_col)
end

-- The type spec whose name is at `row`, `col` (a type parameter is not one).
local function type_spec_at(file, row, col)
    local node = file.root:named_descendant_for_range(row, col, row, col)
    while node and node:type() ~= "type_spec" and node:type() ~= "type_alias" do
        node = node:parent()
    end
    local name = node and node:field("name")[1]
    return name and contains(name, row, col) and node or nil
end

-- Rows to leave out and struct tags to cut ({ start_col, end_col } by row)
-- of a generated struct (protobuf and the like): unexported fields there
-- are machinery (state, sizeCache, unknownFields), tags are wire details.
local function generated_noise(file, spec)
    local drop, tags = {}, {}
    local struct = spec:field("type")[1]
    local list = struct and struct:type() == "struct_type" and struct:named_child(0)
    for field in (list and list:iter_children() or function() end) do
        if field:type() == "field_declaration" then
            local name = field:field("name")[1]
            local tag = field:field("tag")[1]
            if name and vim.treesitter.get_node_text(name, file.text):match("^[%l_]") then
                local first, _, last = field:range()
                for row = first, last do
                    drop[row] = true
                end
            elseif tag then
                local row, start_col, _, end_col = tag:range()
                tags[row] = { start_col, end_col }
            end
        end
    end
    return drop, tags
end

-- "type <spec>" as in the file; a spec inside `type ( … )` loses the
-- indentation of the group. The doc comment above goes first when asked.
local function declaration(file, spec, with_doc)
    local start_row, start_col, end_row, end_col = spec:range()
    local indent = file.lines[start_row + 1]:match("^%s*")
    local drop, tags = {}, {}
    if file.generated then
        drop, tags = generated_noise(file, spec)
    end
    local lines = {}
    if with_doc then
        local first = start_row
        while first > 0 and vim.trim(file.lines[first]):sub(1, 2) == "//" do
            first = first - 1
        end
        for row = first + 1, start_row do
            table.insert(lines, vim.trim(file.lines[row]))
        end
    end
    for row = start_row, end_row do
        local line = file.lines[row + 1]
        local tag = tags[row]
        if tag and row > start_row and row < end_row then
            line = (line:sub(1, tag[1]) .. line:sub(tag[2] + 1)):gsub("%s+$", "")
        end
        line = line:sub(row == start_row and start_col + 1 or 1, row == end_row and end_col or #line)
        if row > start_row and line:sub(1, #indent) == indent then
            line = line:sub(#indent + 1)
        end
        if not drop[row] then
            table.insert(lines, row == start_row and ("type " .. line) or line)
        end
    end
    return lines
end

-- Type names used by a type expression: struct fields, element and key
-- types, type arguments; not inside interfaces and function types.
local function type_names(node, out)
    out = out or {}
    local kind = node:type()
    if kind == "type_identifier" then
        table.insert(out, node)
    elseif kind ~= "interface_type" and kind ~= "function_type" and kind ~= "field_identifier" then
        for child in node:iter_children() do
            if child:named() then
                type_names(child, out)
            end
        end
    end
    return out
end

local function first_location(result)
    if not result then
        return nil
    end
    local item = vim.islist(result) and result[1] or result
    local uri = item and (item.uri or item.targetUri)
    local range = item and (item.targetSelectionRange or item.range)
    return uri and range and { uri = uri, range = range } or nil
end

-- Declarations (lists of lines) of the structs at `roots` and of every
-- project type their fields name, breadth first: `done(declarations,
-- more)`, more = the limit or the timeout cut the list. With `skip_roots`
-- the roots are followed but not listed (gopls shows them already).
function M.collect(client, roots, skip_roots, done)
    local root_dir = client.root_dir or vim.fn.getcwd()
    local encoding = client.offset_encoding
    local cache, seen, requested, declarations = {}, {}, {}, {}
    local finished = false

    local function finish(more)
        if not finished then
            finished = true
            done(declarations, more)
        end
    end

    local function inside(path)
        return vim.fs.relpath(root_dir, path) ~= nil and not path:find("/vendor/", 1, true)
    end

    local level
    level = function(locations, first)
        local names = {}
        for _, location in ipairs(locations) do
            local path = vim.uri_to_fname(location.uri)
            local file = inside(path) and parsed(cache, path)
            local start = location.range.start
            local line = file and file.lines[start.line + 1]
            local spec = line and type_spec_at(file, start.line,
                vim.str_byteindex(line, encoding, start.character, false))
            local key = spec and (path .. ":" .. spec:start())
            local type_node = spec and spec:field("type")[1]
            local kind = type_node and type_node:type()
            if key and not seen[key] and (kind == "struct_type" or not first) then
                seen[key] = true
                if not (first and skip_roots) then
                    if #declarations >= M.opts.max_types then
                        return finish(true)
                    end
                    table.insert(declarations, declaration(file, spec, first))
                end
                if kind ~= "interface_type" then
                    for _, name in ipairs(type_names(type_node)) do
                        local parent = name:parent()
                        local spelled = vim.treesitter.get_node_text(
                            parent and parent:type() == "qualified_type" and parent or name, file.text)
                        local name_key = path .. "|" .. spelled
                        if not predeclared[spelled] and not requested[name_key] then
                            requested[name_key] = true
                            table.insert(names, { path = path, file = file, node = name })
                        end
                    end
                end
            end
        end
        if #names == 0 then
            return finish(false)
        end

        -- Resolve the names of this level together, keep the field order.
        local found, pending = {}, #names
        local function settle()
            pending = pending - 1
            if pending > 0 or finished then
                return
            end
            local next_level = {}
            for index = 1, #names do
                if found[index] then
                    table.insert(next_level, found[index])
                end
            end
            level(next_level, false)
        end
        for index, item in ipairs(names) do
            local row, col = item.node:start()
            local ok = client:request("textDocument/definition", {
                textDocument = { uri = vim.uri_from_fname(item.path) },
                position = {
                    line = row,
                    character = vim.str_utfindex(item.file.lines[row + 1], encoding, col, false),
                },
            }, function(err, result)
                found[index] = not err and first_location(result) or nil
                settle()
            end)
            if not ok then
                settle()
            end
        end
    end

    vim.defer_fn(function()
        finish(true)
    end, M.opts.timeout_ms)
    level(roots, true)
end

-- What the hover is about, from its first line of code: "var" (variables
-- and parameters), "field" or "type", and the spelled type of a var or
-- field. nil for functions, constants, packages.
function M.kind(lines)
    for _, line in ipairs(lines) do
        if not line:match("^```") and line ~= "" then
            local kind, spelled = line:match("^(%a+) [%w_]+ (.+)$")
            if kind == "var" or kind == "field" then
                return kind, spelled
            end
            if line:match("^type ") then
                return "type", nil
            end
            return nil
        end
    end
    return nil
end

-- The hover with the declarations below it.
function M.with_types(lines, declarations, more)
    if #declarations == 0 then
        return lines
    end
    local out = vim.list_extend({}, lines)
    vim.list_extend(out, { "---", "```go" })
    for index, decl in ipairs(declarations) do
        if index > 1 then
            table.insert(out, "")
        end
        vim.list_extend(out, decl)
    end
    if more then
        vim.list_extend(out, { "", "// … more types" })
    end
    table.insert(out, "```")
    return out
end

-- Markdown lines of the hover at the cursor of `win`: `done(lines, hover)`,
-- lines = nil when gopls has nothing to say.
function M.contents(client, win, done)
    local bufnr = vim.api.nvim_win_get_buf(win)
    local params = vim.lsp.util.make_position_params(win, client.offset_encoding)
    local hover, roots, pending = nil, nil, 2

    local function ready()
        pending = pending - 1
        if pending > 0 then
            return
        end
        if not hover or not hover.contents then
            return done(nil)
        end
        local lines = vim.lsp.util.convert_input_to_markdown_lines(hover.contents)
        if #lines == 0 then
            return done(nil)
        end
        local kind, spelled = M.kind(lines)
        -- typeDefinition of a function value is its result type: not this.
        if not kind or not roots or (spelled and spelled:match("^func")) then
            return done(lines, hover)
        end
        M.collect(client, roots, kind == "type", function(declarations, more)
            done(M.with_types(lines, declarations, more), hover)
        end)
    end

    client:request("textDocument/hover", params, function(err, result)
        hover = not err and result or nil
        ready()
    end, bufnr)
    client:request("textDocument/typeDefinition", params, function(err, result)
        if not err and result then
            roots = {}
            for _, item in ipairs(vim.islist(result) and result or { result }) do
                local location = first_location(item)
                if location then
                    table.insert(roots, location)
                end
            end
        end
        ready()
    end, bufnr)
end

local function show(bufnr, client, lines, hover)
    local _, winid = vim.lsp.util.open_floating_preview(lines, "markdown", {
        focus_id = focus_id,
        max_height = math.max(10, math.floor(vim.o.lines * 0.7)),
    })
    -- The hovered name stays marked while the float is open, as with the
    -- native K.
    local range = hover.range
    if range then
        local function byte(position)
            local line = vim.api.nvim_buf_get_lines(bufnr, position.line, position.line + 1, false)[1] or ""
            return vim.str_byteindex(line, client.offset_encoding, position.character, false)
        end
        vim.hl.range(bufnr, hover_ns, "LspReferenceTarget",
            { range.start.line, byte(range.start) },
            { range["end"].line, byte(range["end"]) },
            { priority = vim.hl.priorities.user })
        vim.api.nvim_create_autocmd("WinClosed", {
            pattern = tostring(winid),
            once = true,
            callback = function()
                vim.api.nvim_buf_clear_namespace(bufnr, hover_ns, 0, -1)
            end,
        })
    end
end

function M.hover()
    local win = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_get_current_buf()

    -- K in the float goes back, K with the float open goes into it.
    if vim.w[win][focus_id] then
        vim.cmd("wincmd p")
        return
    end
    for _, other in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.w[other][focus_id] == bufnr then
            vim.api.nvim_set_current_win(other)
            return
        end
    end

    local client = vim.lsp.get_clients({ bufnr = bufnr, name = "gopls", method = "textDocument/hover" })[1]
    if not client then
        vim.lsp.buf.hover()
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(win)
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    M.contents(client, win, function(lines, hover)
        -- Too late: the cursor or the text moved while gopls answered.
        if not vim.api.nvim_win_is_valid(win)
            or vim.api.nvim_get_current_win() ~= win
            or vim.api.nvim_win_get_buf(win) ~= bufnr
            or not vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor)
            or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick
        then
            return
        end
        if not lines then
            vim.notify("No information available", vim.log.levels.INFO)
            return
        end
        show(bufnr, client, lines, hover)
    end)
end

M._declaration = declaration
M._type_spec_at = type_spec_at

return M
