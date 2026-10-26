local scenario = assert(os.getenv("NVIM_LSP_SCENARIO"), "NVIM_LSP_SCENARIO is required")
local expected_root = assert(os.getenv("NVIM_EXPECTED_ROOT"), "NVIM_EXPECTED_ROOT is required")

local function real(path)
    return vim.uv.fs_realpath(path) or vim.fs.normalize(vim.fs.abspath(path))
end

local attached = vim.wait(20000, function()
    return #vim.lsp.get_clients({ bufnr = 0, name = "gopls" }) == 1
end, 50)
assert(attached, "gopls did not attach")

local client = assert(vim.lsp.get_clients({ bufnr = 0, name = "gopls" })[1])
assert(real(client.config.root_dir) == real(expected_root), string.format(
    "unexpected root: expected %s, got %s",
    real(expected_root),
    real(client.config.root_dir)
))
assert(client.config.cmd_env.GOTOOLCHAIN == nil, "gopls cmd_env must not pin GOTOOLCHAIN")
assert(client.config.cmd_env.GOPROXY == nil, "gopls config overrides GOPROXY")

for _, mapping in ipairs({
    { "n", "K" },
    { "n", "grr" },
    { "n", "grn" },
    { "n", "<leader>rn" },
    { "n", "gri" },
    { "n", "[r" },
    { "n", "]r" },
    { "n", "<leader>cf" },
    { "n", "gre" },
    { "n", "grc" },
    { "n", "gro" },
    { "n", "<leader>d" },
    { "n", "<leader>gf" },
    { "n", "<leader>gi" },
    { "n", "<leader>gb" },
    { "n", "<leader>gt" },
    { "n", "<leader>gT" },
    { "n", "<leader>sS" },
    { "i", "<C-Space>" },
    { "i", "jk" },
    { "i", "(" },
    { "i", "<BS>" },
    { "i", "<CR>" },
}) do
    local value = vim.fn.maparg(mapping[2], mapping[1], false, true)
    assert(next(value) ~= nil, string.format(
        "missing %s-mode mapping %s",
        mapping[1],
        mapping[2]
    ))
end

local workspace_symbols = vim.fn.maparg("<leader>sS", "n", false, true)
assert(
    type(workspace_symbols.callback) == "function"
        and workspace_symbols.desc:find("Live workspace symbols", 1, true),
    "workspace symbol mapping is not live"
)
assert(
    type(require("fzf-lua").fzf_live) == "function",
    "fzf-lua live picker is unavailable"
)
assert(vim.bo.tagfunc == "v:lua.vim.lsp.tagfunc", "Ctrl-] LSP tagfunc is not active")
assert(vim.fn.maparg("<C-o>", "n") == "", "Ctrl-o must retain native jumplist behavior")

local bufnr = vim.api.nvim_get_current_buf()
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

-- Completion re-trigger is attached alongside native autotrigger.
local retrigger_autocmds = vim.api.nvim_get_autocmds({ group = "completion_retrigger_" .. bufnr })
local retrigger_events = {}
for _, autocmd in ipairs(retrigger_autocmds) do
    retrigger_events[autocmd.event] = true
end
for _, event in ipairs({ "TextChangedI", "CompleteDone", "InsertLeave" }) do
    assert(retrigger_events[event], "completion re-trigger autocmd missing: " .. event)
end
assert(require("completion_retrigger").should_retrigger("\tfmt.Pri") == true, "member re-trigger predicate")
assert(require("completion_retrigger").should_retrigger("\tfmt.") == false, "bare dot must stay quiet")
-- The dot is no longer a native trigger: the module owns it.
assert(vim.deep_equal(client.server_capabilities.completionProvider.triggerCharacters, {}),
    "server trigger characters must be taken over: " .. vim.inspect(client.server_capabilities.completionProvider.triggerCharacters))

local function position(line_number, needle, after)
    local start = assert(lines[line_number]:find(needle, 1, true), "needle not found: " .. needle)
    return {
        line = line_number - 1,
        character = start - 1 + (after and #needle or 0),
    }
end

local function params_at(line_number, needle, after)
    return {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        position = position(line_number, needle, after),
    }
end

local function line_containing(needle)
    for line_number, line in ipairs(lines) do
        if line:find(needle, 1, true) then
            return line_number
        end
    end

    error("line not found: " .. needle)
end

local function request(method, params, timeout)
    local response = client:request_sync(method, params, timeout or 15000, bufnr)
    assert(response, method .. " returned no response")
    assert(not response.err, method .. " failed: " .. vim.inspect(response.err))
    return response.result
end

local definition_line
local definition_needle
local definition_suffix
local reference_line
local reference_needle
local completion_line
local call_line
local call_needle

if scenario == "module" then
    definition_line = 10
    definition_needle = "Greeting"
    definition_suffix = "/localdep/greeting.go"
    reference_line = 14
    reference_needle = "greeting"
    completion_line = 14
    call_line = 14
    call_needle = "greeting"
elseif scenario == "standalone" then
    definition_line = 6
    definition_needle = "message"
    definition_suffix = "/helper.go"
    reference_line = 6
    reference_needle = "message"
    completion_line = 6
    call_line = 6
    call_needle = "message"
else
    error("unknown scenario: " .. scenario)
end

local definitions = request(
    "textDocument/definition",
    params_at(definition_line, definition_needle, false)
)
if definitions.uri then
    definitions = { definitions }
end
assert(vim.islist(definitions) and #definitions > 0, "definition result is empty")
local definition_path = vim.uri_to_fname(definitions[1].uri or definitions[1].targetUri)
assert(real(definition_path):sub(-#definition_suffix) == definition_suffix, string.format(
    "definition target %s does not end with %s",
    real(definition_path),
    definition_suffix
))

local hover = request(
    "textDocument/hover",
    params_at(definition_line, definition_needle, false)
)
assert(hover and hover.contents, "hover result is empty")

local reference_params = params_at(reference_line, reference_needle, false)
reference_params.context = { includeDeclaration = true }
local references = request("textDocument/references", reference_params)
assert(vim.islist(references) and #references >= 2, "references are incomplete")

local highlights = request(
    "textDocument/documentHighlight",
    params_at(reference_line, reference_needle, false)
)
assert(vim.islist(highlights) and #highlights >= 1, "document highlights are empty")

local completion = request(
    "textDocument/completion",
    params_at(completion_line, "fmt.", true)
)
local completion_items = completion and (completion.items or completion) or {}
assert(vim.islist(completion_items) and #completion_items > 0, "completion is empty")

assert(
    client:supports_method("textDocument/semanticTokens/full", { bufnr = bufnr }),
    "semantic tokens are not advertised"
)
local tokens = request("textDocument/semanticTokens/full", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
})
assert(tokens and vim.islist(tokens.data) and #tokens.data > 0, "semantic tokens are empty")

local hierarchy = request(
    "textDocument/prepareCallHierarchy",
    params_at(call_line, call_needle, false)
)
assert(vim.islist(hierarchy) and #hierarchy > 0, "call hierarchy is empty")

local workspace_symbols_result = request("workspace/symbol", {
    query = "renameFixture",
})
assert(
    vim.islist(workspace_symbols_result) and #workspace_symbols_result > 0,
    "live workspace symbol query is empty"
)
local found_rename_fixture = false
for _, symbol in ipairs(workspace_symbols_result) do
    if symbol.name == "renameFixture" then
        found_rename_fixture = true
        break
    end
end
assert(found_rename_fixture, "workspace symbol query missed renameFixture")

assert(
    client:supports_method("textDocument/rename", { bufnr = bufnr }),
    "gopls rename is unavailable"
)
local rename_line = line_containing("value := 1")
local shadow_line = line_containing("value := 2")
local rename_position = params_at(rename_line, "value", false)
local rename_range = request("textDocument/prepareRename", rename_position)
assert(rename_range, "prepareRename result is empty")

rename_position.newName = "renamedValue"
local workspace_edit = request("textDocument/rename", rename_position)
assert(workspace_edit, "rename workspace edit is empty")

local uri = vim.uri_from_bufnr(bufnr)
local rename_edits = {}
for _, edit in ipairs((workspace_edit.changes or {})[uri] or {}) do
    table.insert(rename_edits, edit)
end
for _, document_change in ipairs(workspace_edit.documentChanges or {}) do
    if document_change.textDocument
        and document_change.textDocument.uri == uri
    then
        vim.list_extend(rename_edits, document_change.edits or {})
    end
end

assert(#rename_edits == 2, string.format(
    "local rename must edit declaration and use only, got %d edits",
    #rename_edits
))
for _, edit in ipairs(rename_edits) do
    assert(edit.newText == "renamedValue", "rename returned an unexpected replacement")
    assert(
        edit.range.start.line >= rename_line - 1
            and edit.range.start.line < shadow_line - 1,
        "rename escaped the target function scope"
    )
end

local implementations = 0
if scenario == "module" then
    local go_refs = require("go_refs")
    local interface_line = line_containing("Save(name string) error")
    local memory_line = line_containing("func (memoryStore) Save")
    local file_line = line_containing("func (fileStore) Save")
    local call_line = line_containing("s.store.Save(")

    local function context_at(line_number, needle)
        local at = position(line_number, needle, false)
        return go_refs.context(bufnr, at.line, at.character)
    end

    assert(context_at(interface_line, "Save") == "interface", "interface method context")
    assert(context_at(memory_line, "Save") == "concrete_method", "concrete method context")
    assert(context_at(call_line, "Save") == "other", "call-site context")
    assert(context_at(line_containing("type Store interface"), "Store") == "interface", "interface type context")

    local finder = go_refs.finder_opts("interface")
    assert(finder.providers[1][1] == "implementations", "implementations must be listed first")
    assert(finder.providers[2][1] == "references", "references must follow implementations")
    assert(finder.includeDeclaration == true, "declarations must be included")
    assert(go_refs.finder_opts("concrete_method").providers[1].prefix == "iface", "concrete prefix")

    local interface_params = params_at(interface_line, "Save", false)
    local interface_refs_params = params_at(interface_line, "Save", false)
    interface_refs_params.context = { includeDeclaration = true }
    local interface_refs = request("textDocument/references", interface_refs_params)
    local impls = request("textDocument/implementation", interface_params)
    assert(vim.islist(impls) and #impls == 2, string.format(
        "interface method must have two implementations, got %d",
        #impls
    ))

    local impl_lines = {}
    for _, location in ipairs(impls) do
        impl_lines[location.range.start.line + 1] = true
    end
    assert(impl_lines[memory_line] and impl_lines[file_line], "implementation lines mismatch")

    for _, location in ipairs(interface_refs) do
        assert(not impl_lines[location.range.start.line + 1],
            "gopls references already contain implementations; merge is redundant")
    end
    implementations = #impls

    -- Call graph: callers of the interface method are the dispatch sites,
    -- expanded transitively, plus the implementations as `impl` leaves.
    local go_calls = require("go_calls")
    local graph, graph_err
    go_calls.build(bufnr, interface_params, "in", { max_depth = 3 }, function(root, err)
        graph, graph_err = root, err
    end)
    assert(vim.wait(15000, function() return graph ~= nil or graph_err ~= nil end, 50), "call graph timed out")
    assert(graph, "call graph failed: " .. tostring(graph_err))
    assert(graph.name == "Store.Save", "call graph root name: " .. tostring(graph.name))

    local graph_lines, graph_meta, graph_summary = go_calls.render(graph, { max_depth = 3 })
    local rendered = table.concat(graph_lines, "\n")
    assert(graph_lines[1]:match("^editorfixture%.Store%.Save%s+main%.go:" .. interface_line .. "$"), graph_lines[1])
    assert(rendered:find("(service).run", 1, true), "run must be a caller of Store.Save:\n" .. rendered)
    assert(rendered:find("(service).retry  (x2)", 1, true), "retry calls run twice:\n" .. rendered)
    assert(rendered:find("runAll", 1, true), "runAll must appear at depth 3:\n" .. rendered)
    assert(rendered:find("impl editorfixture.(memoryStore).Save", 1, true), "memoryStore impl leaf:\n" .. rendered)
    assert(rendered:find("impl editorfixture.(fileStore).Save", 1, true), "fileStore impl leaf:\n" .. rendered)
    assert(graph_summary:find("2 impl", 1, true) and graph_summary:find("depth 3", 1, true), graph_summary)
    assert(graph_meta[2].site and graph_meta[2].site.line == line_containing("return s.store.Save(name)"),
        "Enter target must be the call site")

    -- Recursion is marked and not expanded.
    local retry_graph
    go_calls.build(bufnr, params_at(line_containing("func (s service) retry"), "retry", false), "out", { max_depth = 4 }, function(root)
        retry_graph = root
    end)
    assert(vim.wait(15000, function() return retry_graph ~= nil end, 50), "callee graph timed out")
    local callee_lines, _, callee_summary = go_calls.render(retry_graph, { max_depth = 4 })
    local callee_text = table.concat(callee_lines, "\n")
    assert(callee_text:find("(service).run  (x2)", 1, true), "retry -> run x2:\n" .. callee_text)
    assert(callee_text:find("Save", 1, true), "run -> Save:\n" .. callee_text)
    assert(callee_summary:find("callee", 1, true), callee_summary)

    -- Direct recursion is marked and not expanded further.
    local recursive_graph
    go_calls.build(bufnr, params_at(line_containing("func countdown"), "countdown", false), "out", { max_depth = 4 }, function(root)
        recursive_graph = root
    end)
    assert(vim.wait(15000, function() return recursive_graph ~= nil end, 50), "recursive graph timed out")
    local recursive_lines, _, recursive_summary = go_calls.render(recursive_graph, { max_depth = 4 })
    assert(#recursive_lines == 2 and recursive_lines[2]:find("(recursive)", 1, true), table.concat(recursive_lines, "\n"))
    assert(recursive_summary:find("1 recursive", 1, true), recursive_summary)
    assert(go_calls.clamp_depth(0) == 1 and go_calls.clamp_depth(99) == 8 and go_calls.clamp_depth(4) == 4, "depth clamp")

    local satisfied = request("textDocument/implementation", params_at(memory_line, "Save", false))
    assert(vim.islist(satisfied) and #satisfied == 1
        and satisfied[1].range.start.line + 1 == interface_line,
        "concrete method must resolve to its interface method")
end

print(string.format(
    "LSP_INTEGRATION_OK scenario=%s root=%s refs=%d symbols=%d tokens=%d completion=%d rename=%d implementations=%d",
    scenario,
    real(client.config.root_dir),
    #references,
    #workspace_symbols_result,
    #tokens.data,
    #completion_items,
    #rename_edits,
    implementations
))
