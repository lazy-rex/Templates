-- The start records in SQL (templates_sql.lua; tests/templates-run.md, "Contract"). Admission
-- writes the start form, the run key, the counter and the run in one transaction; dismiss writes
-- the run and its operation in one transaction. A lost commit reply (the commit happened) replays;
-- a refused commit leaves nothing.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')
local function part(s) return #s .. ':' .. s end
local function rows(sql_text, params) return #sql(sql_text, params) end
-- settled waits until an agent run is open and its grant is revoked: the revoke save is the last
-- write of the run. A test ends here, so a later injection (sql_commit_writes = 'runs') cannot meet
-- that save, and a read of the run does not overlap it. The wait is one statement: one snapshot
-- (W.run reads the value in parts, each part on its own snapshot).
local function settled(a, id)
  W.wait_run(a, id, 'open')
  wait('the revoke of the grant', function()
    return rows("SELECT id FROM runs WHERE id = ? AND value ->> '$.grant_revoked' = 1", {id}) == 1
  end, 20)
end
local function saved(a, name)
  local s, root = W.workspace()
  W.capture(a, s)
  a:call('templates.save', {name = name, root = root, session_id = s, key = 'save-' .. name})
  return root
end

test('admission: a lost commit reply replays the same run; the counter moves once', function()
  local alice = agent('alice')
  local root = saved(alice, 'sr-lost')
  local before = W.counter()
  local key = 'start/agent/' .. part('alice') .. part('sr-lost')
  local inj = inject({match = {sql_commit_writes = 'runs'}, fail = 'reply lost by the test', fail_code = 'unavailable', after = true})
  local args = {template = 'sr-lost', root = root, key = 'sr-lost'}
  expect_error(function() alice:call('templates.start', args) end, 'unavailable')
  expect(injection(inj).consumed).to_be(1)
  local id = W.run_key(key).run_id
  expect(id).to_be(tostring((tonumber(before) or 0) + 1))
  local r = alice:call('templates.start', args)
  expect(r.run_id).to_be(id)
  expect(W.counter()).to_be(id)
  expect(rows("SELECT id FROM runs WHERE value ->> '$.request.key' = ?", {key})).to_be(1)
  expect(rows('SELECT key FROM start_forms WHERE key = ?', {key})).to_be(1)
  settled(alice, id)
end)

-- A commit that the hub refuses (here tx_expired, as after the 10 s transaction limit; the test
-- refuses the commit, it does not wait for the limit): the start form, the run key, the counter
-- and the run all stay absent, and a retry with the same key admits once.
test('admission: a refused commit leaves no form, key, counter or run; a retry admits once', function()
  local alice = agent('alice')
  local root = saved(alice, 'sr-refused')
  local before = W.counter()
  local key = 'start/agent/' .. part('alice') .. part('sr-refused')
  local inj = inject({match = {sql_commit_writes = 'runs'}, fail = 'transaction ended by the test', fail_code = 'tx_expired'})
  local args = {template = 'sr-refused', root = root, key = 'sr-refused'}
  expect_error(function() alice:call('templates.start', args) end, 'tx_expired')
  expect(injection(inj).consumed).to_be(1)
  expect(W.counter()).to_be(before)
  expect(W.run_key(key)).to_be(nil)
  expect(rows('SELECT key FROM start_forms WHERE key = ?', {key})).to_be(0)
  expect(rows("SELECT id FROM runs WHERE value ->> '$.request.key' = ?", {key})).to_be(0)
  local r = alice:call('templates.start', args)
  expect(r.run_id).to_be(tostring((tonumber(before) or 0) + 1))
  settled(alice, r.run_id)
end)

-- An agent run that waits for its grant (authorizing): the engine only looks for the grant, so
-- the test opens no session.
test('dismiss: a lost commit reply replays its saved reply; one operation, one dismissed run', function()
  local alice = agent('alice')
  local id = '9001'
  local key = 'start/agent/' .. part('alice') .. part('sr-dismiss')
  W.put_runs({{id = id, status = 'authorizing', next_tab = 1, root = '/', tabs = {}, results = {},
    session_key = 'templates/' .. id .. '/session', request = {key = key, by = 'alice', root = '/', new_session_name = 'sr',
    template = {v = 1, name = 'sr', tabs = {}}}}})
  W.put_run_key(key, {run_id = id})
  local inj = inject({match = {sql_commit_writes = 'ops'}, fail = 'reply lost by the test', fail_code = 'unavailable', after = true})
  local args = {run_id = id, key = 'sr-dismiss'}
  expect_error(function() alice:call('templates.dismiss', args) end, 'unavailable')
  expect(injection(inj).consumed).to_be(1)
  expect(W.run(id).value.status).to_be('dismissed')
  expect(alice:call('templates.dismiss', args)).to_equal({run_id = id, status = 'dismissed'})
  expect(rows('SELECT key FROM ops WHERE key = ?', {'dismiss/agent/' .. part('alice') .. part('sr-dismiss')})).to_be(1)
  expect(W.run(id).value.dismissed_from).to_be('authorizing')
end)

-- A run over FRAME_MAX as a parameter: the root holds 3 directories of 240 "<", and the run holds
-- the root 12 times (the run, its request, and the cwd of each of 5 panes in the tab and in the
-- tab request). "<" is 6 bytes in the value and 7 as a parameter, so the value fits MAX_RUN and the
-- parameter is over the frame limit. Each save of advance writes the run in chunks over the ver
-- of its read. (A long tab title cannot be used: Rex allows 60 characters.)
test('a run over the frame limit as a parameter opens; each save is a chunked update with the ver check', function()
  local alice = agent('alice')
  local root = W.real(W.HOME) .. '/' .. string.rep('<', 240) .. '/' .. string.rep('<', 240) .. '/' .. string.rep('<', 240)
  W.mkdir(root)
  root = W.real(root)
  local function leaf() return {launch = {shell = true}, dir = '.'} end
  local layout = leaf()
  for _ = 1, 4 do layout = {direction = 'horizontal', ratio = 0.5, before = leaf(), after = layout} end
  W.put_template(W.hex('sr-chunk'), {v = 1, name = 'sr-chunk', saved_by = 'alice',
    tabs = {{title = 'chunk', layout = layout}}})
  local r = alice:call('templates.start', {template = 'sr-chunk', root = root, key = 'sr-chunk'})
  settled(alice, r.run_id)
  local run = W.run(r.run_id)
  expect(#rex.json.encode(rex.json.encode(run.value)) > 60 * 1024).to_be(true)
  expect(#rex.json.encode(run.value) <= 61 * 1024).to_be(true)
  expect(run.ver > 2).to_be(true)
  expect(run.value.tabs[1].request.layout ~= nil).to_be(true)
end)

-- A failed append in a chunked run update (templates_sql.lua, update_run: the UPDATE with the ver
-- check, then "value = value || ?"). The pad makes the run over the frame limit as a parameter
-- ("<" is 7 bytes there), so a dismiss writes it in 2 chunks. A fault fails a call by its number
-- only, so a probe dismiss of an equal run gives the number of the first append; the test then
-- checks that the fault failed that statement.
local function big_authorizing(id, name)
  local key = 'start/agent/' .. part('alice') .. part(name)
  W.put_runs({{id = id, status = 'authorizing', next_tab = 1, root = '/', tabs = {}, results = {},
    pad = string.rep('<', 9000), session_key = 'templates/' .. id .. '/session', request = {key = key, by = 'alice', root = '/',
    new_session_name = 'sr', template = {v = 1, name = 'sr', tabs = {}}}}})
  W.put_run_key(key, {run_id = id})
end
local function run_row(id) return sql('SELECT ver, status, value FROM runs WHERE id = ?', {id})[1] end
local function is_append(c) return c.args.sql:match('^UPDATE runs SET value = value || %?') ~= nil end

test('a failed append in a chunked run update commits nothing; the run keeps its value, ver and status', function()
  local alice = agent('alice')
  big_authorizing('9101', 'sr-probe')
  big_authorizing('9102', 'sr-append')
  local _, base = calls('none')
  alice:call('templates.dismiss', {run_id = '9101', key = 'sr-probe'})
  local nth
  for i, c in ipairs(calls('hub.sql.exec', {after = base.next})) do
    if is_append(c) then nth = i break end
  end
  expect(nth ~= nil).to_be(true)
  local before = run_row('9102')
  local _, base2 = calls('none')
  local f = fault({point = 'action', action = 'hub.sql.exec', when = 'before', mode = 'fail', nth = nth})
  local ok = pcall(alice.call, alice, 'templates.dismiss', {run_id = '9102', key = 'sr-append'})
  expect(ok).to_be(false)
  expect(fault_fired(f)).to_be(true)
  local execs = calls('hub.sql.exec', {after = base2.next})
  expect(is_append(execs[nth])).to_be(true)
  expect(execs[nth - 1].args.sql).to_match('^UPDATE runs SET ver = ver %+ 1')
  expect(run_row('9102')).to_equal(before)
  expect(rows('SELECT key FROM ops WHERE key = ?', {'dismiss/agent/' .. part('alice') .. part('sr-append')})).to_be(0)
  expect(alice:call('templates.dismiss', {run_id = '9102', key = 'sr-append'})).to_equal({run_id = '9102', status = 'dismissed'})
  local after = run_row('9102')
  expect(after.ver).to_be(before.ver + 1)
  expect(rex.json.decode(after.value).pad).to_be(string.rep('<', 9000))
end)

-- status is a copy of value.status: every writer sets both (admission, each save, dismiss, the
-- test writer). This file's runs went through each engine write.
test('every run row has status = value.status', function()
  expect(sql("SELECT count(*) AS n FROM runs WHERE status IS NOT value ->> '$.status'")[1].n).to_be(0)
  expect(rows('SELECT id FROM runs')).not_to_be(0)
end)
