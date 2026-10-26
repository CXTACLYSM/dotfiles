-- Pinned files of a task: a short numbered list per project (the root
-- where `nvim .` started, so a `dev -b` worktree has its own), kept across
-- restarts in stdpath("state")/pins.json.
--
--   Space p    pin the current file, or unpin it
--   Alt-1…9    open pinned file 1…9
--   Space P    the list with a preview: Enter opens, Ctrl-x unpins,
--              Alt-↑ / Alt-↓ move the file up or down (its number changes)
--
-- The pins also head the Space f tree, and the window bar shows the number
-- of a pinned file. M.recent gives the recently used files for that tree.

local M = {}

M.max = 9

local lists -- root → { relative paths }

local function file()
    return vim.fn.stdpath("state") .. "/pins.json"
end

local function load()
    if not lists then
        local ok, decoded = pcall(function()
            return vim.json.decode(table.concat(vim.fn.readfile(file()), "\n"))
        end)
        lists = ok and type(decoded) == "table" and decoded or {}
    end
    return lists
end

local function save()
    vim.fn.mkdir(vim.fn.fnamemodify(file(), ":h"), "p")
    vim.fn.writefile({ vim.json.encode(lists) }, file())
end

local function notify(message)
    vim.notify(message, vim.log.levels.INFO, { title = "pins" })
end

-- The pinned files of `root`, relative to it, in their order.
function M.list(root)
    return vim.deepcopy(load()[root] or {})
end

function M.set(root, paths)
    load()[root] = #paths > 0 and paths or nil
    save()
end

-- 1-based number of `path` (absolute) among the pins of `root`, or nil.
function M.number(root, path)
    local rel = path and vim.fs.relpath(root, path)
    for index, pinned in ipairs(rel and load()[root] or {}) do
        if pinned == rel then
            return index
        end
    end
    return nil
end

function M.toggle(root, path)
    path = path or vim.api.nvim_buf_get_name(0)
    local rel = path ~= "" and vim.fs.relpath(root, path)
    if not rel then
        notify("Only files of the project are pinned")
        return
    end
    local paths = M.list(root)
    local at = M.number(root, path)
    if at then
        table.remove(paths, at)
        notify(string.format("Unpinned %s", rel))
    elseif #paths >= M.max then
        notify(string.format("%d files are pinned already: Space P to unpin one", M.max))
        return
    else
        table.insert(paths, rel)
        notify(string.format("Pinned %d: %s", #paths, rel))
    end
    M.set(root, paths)
    vim.cmd.redrawstatus({ bang = true })
end

function M.jump(root, number)
    local rel = M.list(root)[number]
    if not rel then
        notify(string.format("No file pinned at %d", number))
        return
    end
    vim.cmd("normal! m'")
    vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. rel))
end

-- Move pin `number` by `step` (-1 up, 1 down); the new number or nil.
function M.move(root, number, step)
    local paths = M.list(root)
    local target = number + step
    if not paths[number] or not paths[target] then
        return nil
    end
    paths[number], paths[target] = paths[target], paths[number]
    M.set(root, paths)
    return target
end

function M.remove(root, number)
    local paths = M.list(root)
    table.remove(paths, number)
    M.set(root, paths)
end

-- Picker lines: "N  name  dir/<nbsp>path".
function M.lines(root)
    local utils = require("fzf-lua").utils
    local lines = {}
    for index, rel in ipairs(M.list(root)) do
        local dir, name = rel:match("^(.*/)([^/]*)$")
        table.insert(lines, string.format("%s  %s  %s%s%s",
            utils.ansi_codes.yellow(tostring(index)), name or rel, utils.ansi_codes.grey(dir or ""),
            utils.nbsp, rel))
    end
    return lines
end

-- The keys of the list: Ctrl-x, Alt-↑, Alt-↓ on pin `number` change the
-- pins and answer fzf with `reload()` (the list written anew) and the
-- cursor position.
function M.pick_keys(root, reload)
    local function moved(number, step)
        local target = number and M.move(root, number, step)
        return target and string.format("%s+pos(%d)", reload(), target) or ""
    end
    return {
        ["ctrl-x"] = function(number)
            if not number then
                return ""
            end
            M.remove(root, number)
            vim.schedule(function()
                vim.cmd.redrawstatus({ bang = true })
            end)
            return string.format("%s+pos(%d)", reload(), math.max(number - 1, 1))
        end,
        ["alt-up"] = function(number)
            return moved(number, -1)
        end,
        ["alt-down"] = function(number)
            return moved(number, 1)
        end,
    }
end

function M.pick(root)
    local fzf = require("fzf-lua")
    if #M.list(root) == 0 then
        notify("Nothing pinned: Space p pins the current file")
        return
    end
    local listing = vim.fn.tempname()
    local function reload()
        vim.fn.writefile(M.lines(root), listing)
        return string.format("reload-sync(cat %s)", vim.fn.shellescape(listing))
    end
    reload()

    local keymap = { fzf = {} }
    for key, fn in pairs(M.pick_keys(root, reload)) do
        keymap.fzf[key] = "transform:" .. fzf.shell.stringify_data(function(fields)
            return fn(tonumber((fzf.utils.strip_ansi_coloring(fields[1] or "")):match("^(%d+)")))
        end, {}, "{}")
    end
    local actions = {}
    for name, action in pairs(fzf.defaults.actions.files) do
        if not (type(action) == "table" and action.reuse) then
            actions[name] = action
        end
    end
    fzf.fzf_exec("cat " .. vim.fn.shellescape(listing), {
        cwd = root,
        prompt = "Pinned> ",
        previewer = "builtin",
        file_icons = false,
        git_icons = false,
        fzf_opts = { ["--delimiter"] = fzf.utils.nbsp, ["--with-nth"] = "{1}", ["--no-sort"] = true },
        winopts = { title = " pinned · Alt-1…9 " },
        header = ":: <ctrl-x> to unpin|<alt-up> <alt-down> to move",
        actions = actions,
        keymap = keymap,
    })
end

-- Files entered in this session, newest first (absolute paths).
local entered = {}

-- Recently used files of `root` (relative), newest first: files entered in
-- this session, then v:oldfiles of earlier ones. `skip` (absolute) is left
-- out.
function M.recent(root, limit, skip)
    local out, seen = {}, {}
    local function add(path)
        if #out >= limit or path == "" or path == skip then
            return
        end
        local rel = vim.fs.relpath(root, path)
        if rel and not seen[rel] and vim.uv.fs_stat(path) then
            seen[rel] = true
            table.insert(out, rel)
        end
    end
    for _, path in ipairs(entered) do
        add(path)
    end
    for _, path in ipairs(vim.v.oldfiles) do
        add(vim.fs.normalize(path))
    end
    return out
end

function M.setup()
    vim.api.nvim_create_autocmd("BufEnter", {
        group = vim.api.nvim_create_augroup("pins_recent", { clear = true }),
        callback = function(event)
            local name = vim.api.nvim_buf_get_name(event.buf)
            if name == "" or vim.bo[event.buf].buftype ~= "" then
                return
            end
            for index, path in ipairs(entered) do
                if path == name then
                    table.remove(entered, index)
                    break
                end
            end
            table.insert(entered, 1, name)
            entered[101] = nil
        end,
    })
end

-- For tests.
function M._reset()
    lists = nil
end

return M
