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
