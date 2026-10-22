-- The one-time import into SQL (templates_sql.lua, docs/sdk-port.md "Stage 2"). A test seeds the
-- store as an older version left it, clears the SQL state, and restarts the hub: the plugin
-- imports at its start. The import copies each template record (its exact JSON text and its rev)
-- and each save and delete operation; a large value goes in chunks in one transaction.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')
local function part(s) return #s .. ':' .. s end
local function tpl(name, title) return {v = 1, name = name, saved_by = 'user', tabs = {{title = title, layout = {launch = {shell = true}, dir = '.'}}}} end
-- reset clears the SQL state, so the next plugin start imports again. rev = true also clears the
-- revision counter (the import sets its floor again).
local function reset(rev)
  sql_write('DELETE FROM templates')
  sql_write('DELETE FROM ops')
  sql_write(rev and "DELETE FROM meta" or "DELETE FROM meta WHERE k <> 'rev'")
end
-- restart replaces the plugin instance (hub.admin.replace), so the new instance imports. The hub's
-- faults and injections stay armed (a hub restart would end them).
local function restart()
  local st = H.hub('hub.test.status', {}).plugins.templates
  H.hub('hub.admin.replace', {plugin = 'templates', expect_instance = st.instance_id})
end
local function imported()
  wait('the import', function()
    local ok, rows = pcall(sql, "SELECT v FROM meta WHERE k = 'import'")
    return ok and rows[1] and rows[1].v == 'done' or nil
  end, 60)
end
local function row(key) return sql('SELECT CAST(rev AS TEXT) AS rev, value FROM templates WHERE hex = ?', {key:sub(#'template/' + 1)})[1] end
-- same checks that the row of key has the exact JSON text and the rev of the store record.
local function same(key)
  local r, s = row(key), store(key)
  expect(r ~= nil).to_be(true)
  expect(r.value == rex.json.encode(s.value)).to_be(true)
  expect(r.rev).to_be(s.rev)
end

-- The hard texts: "&" is 6 bytes in a record and 7 as a parameter; '"' and "\" are 2 and 4; the
-- multibyte characters can fall at a chunk boundary.
local AMP = 'template/' .. W.hex('imp-amp')
local MIX = 'template/' .. W.hex('imp-mix')
local MIX_TITLE = string.rep('"', 6000) .. string.rep('\\', 4000) .. string.rep('é漢😀', 2000)

test('the import copies every template record exactly, the save and delete operations, and sets the revision floor', function()
  local alice = agent('alice')
  write({{key = AMP, value = tpl('imp-amp', string.rep('&', 10000))}})
  write({{key = MIX, value = tpl('imp-mix', MIX_TITLE)}})
  write({{key = 'template/' .. W.hex('imp-foreign'), value = 7}, {key = 'template/zz', value = tpl('zz', 'not hex')},
    {key = 'template/', value = tpl('', 'empty')}})
  put_operation({key = 'save/' .. part('imp-s'), fingerprint = 'fp-save', result = {close_form = true}})
  put_operation({key = 'delete/agent/' .. part('alice') .. part('imp-d'), fingerprint = 'fp-delete', result = {}})
  put_operation({key = 'dismiss/' .. part('imp-x'), fingerprint = 'fp-dismiss', result = {}})
  -- The JSON of the "&" record is too large for one request as a parameter: it goes in chunks.
  expect(#rex.json.encode(rex.json.encode(store(AMP).value)) > 64 * 1024).to_be(true)
  reset(true)
  restart()
  imported()
  for _, key in ipairs({AMP, MIX, 'template/' .. W.hex('imp-foreign'), 'template/zz', 'template/'}) do same(key) end
  expect(alice:call('templates.get', {template = 'imp-mix'}).template.tabs[1].title == MIX_TITLE).to_be(true)
  local ops = {}
  for _, o in ipairs(sql('SELECT key, fingerprint, result FROM ops ORDER BY key')) do ops[#ops + 1] = {o.key, o.fingerprint, o.result} end
  expect(ops).to_equal({{'delete/agent/' .. part('alice') .. part('imp-d'), 'fp-delete', '{}'},
    {'save/' .. part('imp-s'), 'fp-save', '{"close_form":true}'}})
  -- The floor is above every store revision, and a new save gets a revision above it.
  local floor = tonumber(sql("SELECT v FROM meta WHERE k = 'rev'")[1].v)
  expect(floor > tonumber(store(AMP).rev) and floor > tonumber(store(MIX).rev)).to_be(true)
  local s, root = W.workspace()
  W.capture(alice, s)
  alice:call('templates.save', {name = 'imp-new', root = root, session_id = s, key = 'imp-new'})
  expect(tonumber(W.trow('template/' .. W.hex('imp-new')).rev) > floor).to_be(true)
end)

-- The reviewer's probe (773cd80 review): a value that is a string is a JSON string in its row, also
-- a string that looks like JSON. Before the fix, the import wrote such a string as the row's text.
test('a string value and a string operation result import as JSON strings', function()
  local plain, looks = 'template/' .. W.hex('imp-str'), 'template/' .. W.hex('imp-str-json')
  write({{key = plain, value = 'ordinary text'}, {key = looks, value = '{"v":1,"tabs":[]}'}})
  put_operation({key = 'save/' .. part('imp-str-op'), fingerprint = 'fp-str', result = 'done'})
  put_operation({key = 'delete/' .. part('imp-str-op'), fingerprint = 'fp-str', result = '{"close_form":true}'})
  reset(false)
  restart()
  imported()
  same(plain)
  same(looks)
  expect(row(looks).value).to_be(rex.json.encode('{"v":1,"tabs":[]}'))
  expect(sql('SELECT result FROM ops WHERE key = ?', {'save/' .. part('imp-str-op')})[1].result).to_be('"done"')
  expect(sql('SELECT result FROM ops WHERE key = ?', {'delete/' .. part('imp-str-op')})[1].result).to_be(rex.json.encode('{"close_form":true}'))
  -- The list and the panel pass over a value that is not a template.
  local names = {}
  for _, t in ipairs(agent('alice'):call('templates.list', {}).templates) do names[t.name] = true end
  expect(names['imp-str'] or names['imp-str-json'] or false).to_be(false)
  write({{key = plain, delete = true}, {key = looks, delete = true}})
  W.twrite({{key = plain, delete = true}, {key = looks, delete = true}})
end)

test('a failed append between two chunks commits nothing; the next start imports the record whole', function()
  write({{key = 'template/' .. W.hex('!imp-first'), value = tpl('!imp-first', string.rep('&', 10000))}})
  -- The empty name sorts first (hex ''): it is put back after this test.
  write({{key = 'template/', delete = true}})
  reset(false)
  -- The first record in key order is the large one: exec 1 is its first chunk, exec 2 its first
  -- append. The failed import ends the plugin process; the hub starts it again, and it imports.
  local _, base = calls('none')
  local f = fault({point = 'action', action = 'hub.sql.exec', when = 'before', mode = 'fail', nth = 2})
  restart()
  wait('the failed append', function() return fault_fired(f) or nil end, 30)
  local execs = calls('hub.sql.exec', {after = base.next})
  expect(execs[1].args.sql).to_match('^INSERT INTO templates')
  expect(execs[2].args.sql).to_match('^UPDATE templates SET value = value || %?')
  local r = row('template/' .. W.hex('!imp-first'))
  expect(r == nil or r.value == rex.json.encode(store('template/' .. W.hex('!imp-first')).value)).to_be(true)
  imported()
  same('template/' .. W.hex('!imp-first'))
  same(AMP)
  write({{key = 'template/', value = tpl('', 'empty')}})
end)

test('a failed import commit and a lost import commit reply: a restart continues, and every row is exact', function()
  reset(false)
  local inj = inject({match = {sql_commit_writes = 'templates'}, fail = 'commit failed by the test', skip = 1})
  restart()
  wait('the failed commit', function() return injection(inj).consumed >= 1 or nil end, 30)
  imported()
  for _, key in ipairs({AMP, MIX, 'template/zz', 'template/'}) do same(key) end
  reset(false)
  inj = inject({match = {sql_commit_writes = 'templates'}, fail = 'reply lost by the test', fail_code = 'unavailable', after = true, skip = 2})
  restart()
  wait('the lost reply', function() return injection(inj).consumed >= 1 or nil end, 30)
  imported()
  for _, key in ipairs({AMP, MIX, 'template/zz', 'template/'}) do same(key) end
end)

-- The largest row: a store record is at most one 64 KiB control message as JSON, and a '"' doubles
-- as a parameter (2 bytes in the record, 4 in the request), the largest growth. So such a record
-- needs the most chunks: 3 of 60 KiB. They commit in one transaction, within the hub's 10 s.
test('the largest record imports in three chunks in one transaction', function()
  local key = 'template/' .. W.hex('imp-max')
  write({{key = key, value = tpl('imp-max', string.rep('"', 31000))}})
  expect(#rex.json.encode(store(key).value) > 62000).to_be(true)
  reset(false)
  local _, base = calls('none')
  restart()
  imported()
  same(key)
  local appends = 0
  for _, c in ipairs(calls('hub.sql.exec', {after = base.next})) do
    local p = c.args.params
    if c.args.sql:match('^UPDATE templates SET value = value || %?') and p[2] == W.hex('imp-max') then appends = appends + 1 end
  end
  expect(appends).to_be(2)
  write({{key = key, delete = true}})
end)

-- A row whose key alone is over the request budget is refused (too_large). The import stops at it,
-- with no cursor past it and no 'import' mark, so the plugin does not serve; the hub starts it
-- again, and the import tries again from its cursor. Without the record, the import completes.
test('a key over the request budget stops the import without moving its cursor past it', function()
  local bad = 'template/' .. string.rep('f', 63000)
  write({{key = bad, value = tpl('bad', 't')}})
  reset(false)
  local _, base = calls('none')
  restart()
  -- Two import attempts: the scan of template/ runs once in each.
  wait('a second import attempt', function()
    local n = 0
    for _, c in ipairs(calls('hub.store.scan', {after = base.next})) do if c.args.prefix == 'template/' then n = n + 1 end end
    return n >= 2 or nil
  end, 60)
  expect(sql("SELECT v FROM meta WHERE k = 'import'")[1]).to_be(nil)
  local cursor = sql("SELECT v FROM meta WHERE k = 'import/template'")[1]
  expect(cursor == nil or cursor.v < bad).to_be(true)
  expect(row(bad)).to_be(nil)
  write({{key = bad, delete = true}})
  imported()
  same(AMP)
end)

-- restart_running replaces the plugin and waits until the new instance is registered (the import
-- runs after the registration). It returns true when the import has not committed its end yet: a
-- call sent now arrives during the import.
local function restart_running()
  local old = H.hub('hub.test.status', {}).plugins.templates.instance_id
  restart()
  wait('the new instance', function()
    local p = H.hub('hub.test.status', {}).plugins.templates
    return p.registered and p.instance_id ~= old or nil
  end, 30)
  return sql("SELECT v FROM meta WHERE k = 'import'")[1] == nil
end

-- A call while the import runs: the import runs in the SDK's registration callback, and Rex Lua runs
-- one handler at a time, so the call waits until the import ends. 200 records keep the import's
-- calls under the 1000 that the hub keeps (testing.md, calls), so the record is complete.
test('a call sent during the import is served after its end (a complete call record)', function()
  local alice = agent('alice')
  local s, root = W.workspace()
  W.capture(alice, s)
  local ops = {}
  for i = 1, 200 do ops[#ops + 1] = {key = 'template/' .. W.hex(string.format('o-%03d', i)), value = tpl('o', 't')} end
  write(ops)
  -- The import can end before the test reads it; then the test runs it again (at most 3 times).
  local S = {}
  for _ = 1, 3 do
    reset(false)
    local _, base = calls('none')
    S.base = base
    S.during = restart_running()
    if S.during then break end
  end
  expect(S.during).to_be(true)
  expect(alice:call('templates.save', {name = 'o-save', root = root, session_id = s, key = 'o-save'})).to_equal({name = 'o-save'})
  local list, out = calls('', {after = S.base.next})
  expect(out.dropped).to_be(false)
  local done_seq, identify_seq
  for _, c in ipairs(list) do
    local p = c.args and c.args.params
    if c.action == 'hub.sql.exec' and type(p) == 'table' and p[1] == 'import' and p[2] == 'done' then done_seq = c.seq end
    if c.action == 'hub.identify' and not identify_seq then identify_seq = c.seq end
  end
  expect(done_seq ~= nil and identify_seq ~= nil).to_be(true)
  expect(identify_seq > done_seq).to_be(true)
  for i = 1, 200 do write({{key = 'template/' .. W.hex(string.format('o-%03d', i)), delete = true}}) end
end)

-- A call that times out during a long import: 6000 records take longer than the hub's 10 s for a
-- forwarded call (hub agentface.go, timeout_ms). This test does not check the order of the calls
-- (the import makes more calls than the hub keeps); the test above does.
test('a call that times out during a long import answers as one save on its retry', function()
  local alice = agent('alice')
  local s, root = W.workspace()
  W.capture(alice, s)
  local ops = {}
  for i = 1, 6000 do
    ops[#ops + 1] = {key = 'template/' .. W.hex(string.format('q-%05d', i)), value = tpl('q', 't')}
    if #ops == 300 then write(ops); ops = {} end
  end
  reset(false)
  expect(restart_running()).to_be(true)
  local args = {name = 'q-save', root = root, session_id = s, key = 'q-save'}
  local ok, err = pcall(alice.call, alice, 'templates.save', args)
  expect(ok).to_be(false)
  expect(tostring(err and (err.message or err))).to_match('timed out')
  imported()
  -- Rex can still deliver the timed-out call after the import (observed in one lab run on Rex
  -- 0.0.1792158932-g88fd41, LazyRex hub/sql-lab f413b36; another run did not show it by the time of
  -- this read). Either way the retry answers as one save: it replays a save that ran, or saves.
  local rev = W.trow('template/' .. W.hex('q-save')).rev
  expect(alice:call('templates.save', args)).to_equal({name = 'q-save'})
  local after = W.trow('template/' .. W.hex('q-save')).rev
  expect(after ~= nil).to_be(true)
  if rev then expect(after).to_be(rev) end
  expect(#sql('SELECT key FROM ops WHERE key LIKE ?', {'save/agent/%q-save'})).to_be(1)
end)
