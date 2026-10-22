-- The canonical text of agent arguments (templates.lua, canon) is part of each saved operation's
-- fingerprint, so its bytes must not change. Rex Lua's table.concat fails over 2559 items
-- ("registry overflow", LazyRex docs/rex-protocol.md, observed on Rex 0.0.1792158932-g88fd41), and
-- an argument object can have more entries than that within the request bound.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')

local function part(s) return #s .. ':' .. s end
-- join concatenates in blocks of 1000 (the test itself is under the same limit).
local function join(list)
  local blocks = {}
  for i = 1, #list, 1000 do blocks[#blocks + 1] = table.concat(list, '', i, math.min(i + 999, #list)) end
  return table.concat(blocks)
end

-- The reviewer's probe (concat audit): 2600 pane choices. Before the fix, the save failed with
-- registry overflow before its replay. The fingerprint is computed here by the canon rules, so the
-- replay of the saved operation proves the exact bytes.
test('a save with 2600 pane choices replays an operation saved with the same canonical text', function()
  local alice = agent('alice')
  local panes, ids = {}, {}
  for i = 1, 2600 do
    local id = string.format('b%04d', i)
    panes[id], ids[#ids + 1] = 'skip', id
  end
  table.sort(ids)
  local entries = {'{'}
  for _, id in ipairs(ids) do entries[#entries + 1] = part(id) .. 's' .. part('skip') end
  entries[#entries + 1] = '}'
  local fingerprint = 'save-agent-v1/{' .. part('name') .. 's' .. part('cc') .. part('panes') .. join(entries)
    .. part('root') .. 's' .. part('/cc-root') .. part('session_id') .. 's' .. part('cc-s') .. '}'
  W.put_op({key = 'save/agent/' .. part('alice') .. part('cc-1'), fingerprint = fingerprint, result = {name = 'cc'}})
  local args = {name = 'cc', root = '/cc-root', session_id = 'cc-s', panes = panes, key = 'cc-1'}
  expect(#rex.json.encode(args) < 60 * 1024).to_be(true)
  expect(alice:call('templates.save', args)).to_equal({name = 'cc'})
  -- Other content with the key is a conflict, not an overflow.
  panes.b0001 = 'shell'
  expect_error(function() alice:call('templates.save', args) end, 'operation_conflict')
end)
