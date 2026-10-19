-- The engine (templates_run.lua) with a controlled hub: lost replies, restarts, dismiss, and the
-- grant of an agent's run. The cases are in support/engine_cases.lua.

local dir = H.args.file:match('^(.*)/')
local Run = load_fixture(dir .. '/../templates_run.lua')
local cases = load_fixture(dir .. '/support/engine_cases.lua')(Run)
local names = {}
for name in pairs(cases) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do test('engine: ' .. name:gsub('_', ' '), cases[name]) end
