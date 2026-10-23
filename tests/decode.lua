-- A stored JSON value that is not valid JSON (templates_sql.lua, decode). rex.json.decode does not
-- raise on invalid JSON: it returns nil and an error text (JSON null returns nil alone, and is
-- valid). The readers under test here (operation replies, start forms, runs) fail with internal for
-- invalid JSON and name the row. Templates rows keep their own rule (templates.lua,
-- read_template). Tests in this file run in order on one hub and one database.

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

test('a run row that is not valid JSON: templates.runs fails with internal and names the run', function()
  local alice = agent('alice')
  local id = '900000'
  W.sql_write("INSERT INTO runs (id, ver, status, value) VALUES (?, 1, 'open', ?)", {id, BAD})
  local err = failure(function() return alice:call('templates.runs', {limit = 100}) end)
  expect(tostring(err.message):find('internal', 1, true) ~= nil or err.code == 'internal').to_be(true)
  expect(tostring(err.message):find('runs ' .. id, 1, true) ~= nil).to_be(true)
  W.sql_write('DELETE FROM runs WHERE id = ?', {id})
end)

-- The run scan skips a run row that is not valid JSON and does not change it: a person decides what
-- to do with it (coordinator ruling, 2026-10-22). The good run sorts after the bad row.
test('a run row that is not valid JSON: after a restart the scan resumes the run after it and keeps the row', function()
  local bad, good = '8000', '9002'
  local key = 'start/agent/' .. W.part('alice') .. W.part('dec-scan')
  W.put_runs({{id = good, status = 'authorizing', next_tab = 1, root = '/', tabs = {}, results = {},
    session_key = 'templates/' .. good .. '/session', request = {key = key, by = 'alice', root = '/', new_session_name = 'dec',
    template = {v = 1, name = 'dec', tabs = {}}}}})
  W.put_run_key(key, {run_id = good})
  W.sql_write("INSERT INTO runs (id, ver, status, value) VALUES (?, 1, 'open', ?)", {bad, BAD})
  hub:restart()
  agent('alice')
  wait('the scan saves run ' .. good, function() return sql('SELECT ver FROM runs WHERE id = ?', {good})[1].ver >= 2 end, 15)
  expect(sql('SELECT ver, status, value FROM runs WHERE id = ?', {bad})[1]).to_equal({ver = 1, status = 'open', value = BAD})
end)

-- run_summaries on a fake database: a row that is not valid JSON comes back as {id, invalid = true},
-- and the plugin reports it once per process (print), not at each page read.
test('run_summaries gives an invalid row as {id, invalid} and reports it once', function()
  local Sql = load_fixture(H.args.file:match('^(.*)/') .. '/../templates_sql.lua')
  local rows = {{id = '8000', status = 'open', valid = 0}, {id = '9002', status = 'open', valid = 1, by = '"alice"'}}
  local db = {migrate = function() end, each = function(...)
    local args = {...}
    for _, r in ipairs(rows) do args[select('#', ...)](r) end
  end}
  local S = Sql.new({db = db, int = function(v) return v end})
  local printed, real = {}, print
  print = function(s) printed[#printed + 1] = s end
  local ok, a = pcall(S.run_summaries, nil, 50)
  local ok2, b = pcall(S.run_summaries, nil, 50)
  print = real
  expect(ok and ok2).to_be(true)
  expect(a[1]).to_equal({id = '8000', invalid = true})
  expect(b[2].request.by).to_be('alice')
  expect(#printed).to_be(1)
  expect(printed[1]:find('8000', 1, true) ~= nil).to_be(true)
end)
