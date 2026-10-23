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

test('a start form request that is not valid JSON: a retry of the start fails with internal and names the row', function()
  local alice = agent('alice')
  local args = {template = 'dec-op', root = T.save.root, key = 'dec-form'}
  local r = alice:call('templates.start', args)
  W.wait_run(alice, r.run_id, 'open')
  local key = W.agent_start_key('alice', 'dec-form')
  expect(#sql('SELECT key FROM start_forms WHERE key = ?', {key})).to_be(1)
  W.sql_write('UPDATE start_forms SET request = ? WHERE key = ?', {BAD, key})
  local err = failure(function() return alice:call('templates.start', args) end)
  expect(tostring(err.message):find('internal', 1, true) ~= nil or err.code == 'internal').to_be(true)
  expect(tostring(err.message):find('start_forms', 1, true) ~= nil).to_be(true)
end)

test('a test reader raises on a stored row that is not valid JSON (W.decode)', function()
  local hx = W.hex('dec-bad')
  W.sql_write('INSERT INTO templates (hex, rev, value) VALUES (?, 1, ?)', {hx, BAD})
  local ok, err = pcall(W.template, hx)
  expect(ok).to_be(false)
  expect(tostring(err):find('not valid JSON', 1, true) ~= nil).to_be(true)
  W.sql_write('DELETE FROM templates WHERE hex = ?', {hx})
end)
