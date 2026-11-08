local lua_path = assert(os.getenv("NVIM_CONFIG_LUA"), "NVIM_CONFIG_LUA is required")
package.path = lua_path .. "/?.lua;" .. lua_path .. "/?/init.lua;" .. package.path

-- The normal mode of the pickers (lua/picker_mode.lua): the prompt holds
-- the mode, the binds are shell one-liners.
local picker_mode = require("picker_mode")

assert(picker_mode.prompt("Symbols") == "Symbols ·N> " and picker_mode.prompt("") == "·N> ", "prompts")

for _, shell in ipairs({ "sh", vim.o.shell }) do
    local function run(key, prompt)
        return picker_mode.run(shell, key, prompt)
    end
    -- Esc: typing → normal, normal → close.
    assert(run("esc", "Symbols> ") == "change-prompt(Symbols ·N> )", shell .. ": Esc to normal")
    assert(run("esc", "> ") == "change-prompt(·N> )", shell .. ": Esc to normal, bare prompt")
    assert(run("esc", "Symbols ·N> ") == "abort" and run("esc", "·N> ") == "abort", shell .. ": Esc closes")
    -- i: normal → typing, the prompt as it was.
    assert(run("i", "Symbols ·N> ") == "change-prompt(Symbols> )" and run("i", "·N> ") == "change-prompt(> )",
        shell .. ": i types again")
    assert(run("i", "Symbols> ") == "put(i)", shell .. ": i is typed")
    -- The moves.
    assert(run("j", "Files ·N> ") == "down" and run("k", "Files ·N> ") == "up" and run("g", "·N> ") == "first",
        shell .. ": j k g")
    assert(run("q", "·N> ") == "abort" and run("l", "·N> ") == "print(enter)+accept" and run("h", "·N> ") == "",
        shell .. ": q l h")
    assert(run("j", "Files> ") == "put(j)" and run("q", "> ") == "put(q)" and run("l", "Rg> ") == "put(l)",
        shell .. ": letters while typing")
end

print("PICKER_MODE_OK")
