-- A stored JSON value that is not valid JSON (templates_sql.lua, decode). rex.json.decode does not
-- raise on invalid JSON: it returns nil and an error text. JSON null returns nil alone. A reader of
-- a Templates row fails with internal and names the row; it never answers nil for it. Tests in
-- this file run in order on one hub and one database.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')
local BAD = '{"a":' -- not valid JSON
local T = {} -- a table field (LazyRex docs/rex-protocol.md, "Rex Lua runtime")
local function failure(f)
  local ok, err = pcall(f)
  expect(ok).to_be(false)
  return type(err) == 'table' and err or {message = tostring(err)}
end

test('a saved operation reply that is not valid JSON: a retry fails with internal and names the row', function()
  local alice = agent('alice')
  local s, root = W.workspace()
  W.capture(alice, s)
  T.save = {name = 'dec-op', root = root, session_id = s, key = 'dec-op'}
  expect(alice:call('templates.save', T.save)).to_equal({name = 'dec-op'})
  local ops = sql('SELECT key FROM ops')
  expect(#ops).to_be(1)
  T.op = ops[1].key
  W.sql_write('UPDATE ops SET result = ? WHERE key = ?', {BAD, T.op})
  local err = failure(function() return alice:call('templates.save', T.save) end)
  expect(tostring(err.message):find('internal', 1, true) ~= nil or err.code == 'internal').to_be(true)
  expect(tostring(err.message):find('ops', 1, true) ~= nil).to_be(true)
end)

test('a saved operation reply that is valid JSON stays valid', function()
  local alice = agent('alice')
  W.sql_write('UPDATE ops SET result = ? WHERE key = ?', {rex.json.encode({name = 'dec-op'}), T.op})
  expect(alice:call('templates.save', T.save)).to_equal({name = 'dec-op'})
end)
