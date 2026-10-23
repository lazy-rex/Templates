-- Retention through the plugin (templates_run.lua, "Retention"; the engine cases test the rules with
-- a controlled clock). A run is retired when 200 newer eligible runs exist: retire() writes 200 newer
-- finished runs and a worker change wakes the engine. The 30 days of a marker are tested by writing
-- its expired_at back in time. Tests in this file share one hub: each one retires its own runs.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')
local TTL = 30 * 86400
local S = {n = 0} -- a table field (LazyRex docs/rex-protocol.md, "Rex Lua runtime")

-- template saves a template of a new workspace and returns its name and root.
local function template(a)
  S.n = S.n + 1
  local s, root = W.workspace()
  W.capture(a, s)
  local name = 'ret-' .. S.n
  a:call('templates.save', {name = name, root = root, session_id = s, key = 'ret-save-' .. S.n})
  return name, root
end
-- finished_run is an open user run.
local function finished_run(i, root)
  return {id = tostring(i), status = 'open', next_tab = 1, root = root, tabs = {},
    request = {key = 'newer' .. i, root = root, new_session_name = 'n', template = {v = 1, name = 'n', tabs = {}}},
    results = {}, session_key = 'templates/' .. i .. '/session'}
end
-- newer writes the 200 finished runs after run id and wakes the engine with a worker change. Each
-- run has its run key and its start form, as a real start has (the engine skips a run that no run
-- key names; retirement needs the form). The forms were submitted an hour ago: no switch waits for
-- them. counter: the run counter to write (default: the last of the 200).
local function newer(a, id, counter)
  local root = W.real(W.HOME)
  local first = tonumber(id) + 1
  local runs = {}
  for i = first, first + 199 do runs[#runs + 1] = finished_run(i, root) end
  W.put_runs(runs)
  for _, run in ipairs(runs) do W.put_run_key(run.request.key, {run_id = run.id}) end
  W.put_run_forms(first, first + 199, os.time() - 3600)
  W.set_counter(counter or tostring(first + 199))
  S.n = S.n + 1
  local w = a:hub('hub.spawn', {profile = 'watcher', key = 'ret-wake-' .. S.n})
  a:hub('hub.stop', {spawn_id = w.spawn_id})
end
-- retire makes run id the oldest of more than 200 eligible runs and waits until it is retired.
local function retire(a, id)
  newer(a, id)
  wait('run ' .. id .. ' retired', function() return W.run(id) == nil end, 60)
end
-- age sets the expired_at of a marker to seconds before now (keeping its id and form_rev).
local function age(op_key, seconds)
  local m = W.run_key(op_key)
  m.expired_at = os.time() - seconds
  W.put_run_key(op_key, m)
end

test('an agent replay of a retired start gives expired; changed arguments give operation_conflict', function()
  local alice = agent('alice')
  local name, root = template(alice)
  local r = alice:call('templates.start', {template = name, root = root, key = 'ret-a1'})
  W.wait_run(alice, r.run_id, 'open')
  wait('the grant revoked', function() return W.run(r.run_id).value.grant_revoked end, 20)
  retire(alice, r.run_id)
  local op_key = W.agent_start_key('alice', 'ret-a1')
  local marker = W.run_key(op_key)
  expect(marker.run_id).to_be(r.run_id)
  expect(marker.form_rev).to_be(W.form(W.agent_start_key('alice', 'ret-a1')).rev)
  local next_id = W.next_run_id()
  expect_error(function() alice:call('templates.start', {template = name, root = root, key = 'ret-a1'}) end, 'expired')
  expect_error(function() alice:call('templates.start', {template = name, root = root .. '/api', key = 'ret-a1'}) end, 'operation_conflict')
  expect(W.next_run_id()).to_be(next_id)
end)

-- Expiry on access: no restart and no cleanup. The marker of 'ret-a1' expires in 3 s.
test('a retired key is free again 30 days after its removal, also with changed arguments', function()
  local alice = agent('alice')
  local name, root = template(alice)
  local op_key = W.agent_start_key('alice', 'ret-a1')
  age(op_key, TTL - 3)
  expect_error(function() alice:call('templates.start', {template = name, root = root, key = 'ret-a1'}) end, 'operation_conflict')
  local old = W.run_key(op_key).run_id
  -- The same arguments as the first start (template ret-1 still exists).
  local first = W.form(W.agent_start_key('alice', 'ret-a1')).request
  expect_error(function() alice:call('templates.start', {template = first.template.name, root = first.root, key = 'ret-a1'}) end, 'expired')
  rex.sleep(4)
  -- Changed arguments after the expiry: a new start.
  local r = alice:call('templates.start', {template = name, root = root, key = 'ret-a1'})
  expect(r.run_id).not_to_be(old)
  W.wait_run(alice, r.run_id, 'open')
  expect(W.run_key(op_key).expired_at).to_be(nil)
end)

-- An agent that took over a legacy ID (alice reports a conversation: her identity changes, and
-- "alice" is her legacy ID). Her keys are looked up under both IDs.
test('the alias lookup: expired aliases start again; an expired alias does not hide an active start; a renamed agent gets expired', function()
  local alice = agent('alice')
  local name, root = template(alice)
  -- A start under the ID "alice", retired before the rename.
  local r = alice:call('templates.start', {template = name, root = root, key = 'ret-alias-old'})
  W.wait_run(alice, r.run_id, 'open')
  wait('the grant revoked', function() return W.run(r.run_id).value.grant_revoked end, 20)
  retire(alice, r.run_id)
  local current = alice:report({kind = 'claude', conversation_id = 'retention-alias'}).identity
  expect(current).not_to_be('alice')
  -- Replay through the renamed agent within 30 days: expired.
  expect_error(function() alice:call('templates.start', {template = name, root = root, key = 'ret-alias-old'}) end, 'expired')
  -- Two expired alias records of one key (one per ID): a new start, not a conflict.
  local fp
  for _, id in ipairs({'alice', current}) do
    local k = W.agent_start_key(id, 'ret-alias-two')
    local rev = W.put_form(k, {fingerprint = 'old-' .. id, request = {key = k}, at = 1})
    W.put_run_key(k, {run_id = '1', expired_at = os.time() - TTL - 1, form_rev = rev})
  end
  local two = alice:call('templates.start', {template = name, root = root, key = 'ret-alias-two'})
  W.wait_run(alice, two.run_id, 'open')
  -- An active start under the current ID, and an expired record of the same key under "alice":
  -- the replay gives the active run.
  local active = alice:call('templates.start', {template = name, root = root, key = 'ret-alias-active'})
  local k = W.agent_start_key('alice', 'ret-alias-active')
  local rev = W.put_form(k, {fingerprint = 'old', request = {key = k}, at = 1})
  W.put_run_key(k, {run_id = '1', expired_at = os.time() - TTL - 1, form_rev = rev})
  expect(alice:call('templates.start', {template = name, root = root, key = 'ret-alias-active'})).to_equal(active)
end)

-- The UI boundary: the hub saves a completed view operation and answers it without a call to
-- Templates. The plugin's recorded hub calls prove that it did not read the start form (no SQL
-- statement on start_forms; the complete record: no call dropped).
test('a completed Start form after its run was retired: the hub answers; Templates is not called', function()
  local alice = agent('alice')
  local name, root = template(alice)
  local s = W.workspace()
  local form = W.open('start_session', '/forms/start', s)
  local values = W.form_input(form:render(), 'start_session')
  values.template, values.root, values.session_id = name, root, '@new'
  local _, key = form:admit('action', {node_id = 'start_session', action = 'submit', input = {values = values}, operation_key = 'ret-ui'})
  local op = form:settle(key, 30)
  expect(op.status).to_be('succeeded')
  local id = op.result.run_id
  W.wait_run(alice, id, 'open')
  retire(alice, id)
  local _, base = calls('none')
  local again = operation(key)
  expect(again.status).to_be('succeeded')
  expect(again.result.run_id).to_be(id)
  local form2 = W.open('start_session', '/forms/start', s)
  expect_error(function()
    form2:admit('action', {node_id = 'start_session', action = 'submit', input = {values = values}, operation_key = key})
  end, 'operation_conflict')
  local list, out = calls('', {after = base.next})
  expect(out.dropped).to_be(false)
  local reads = 0
  for _, c in ipairs(list) do
    if rex.json.encode(c.args):find('start_forms', 1, true) then reads = reads + 1 end
  end
  expect(reads).to_be(0)
end)

-- A Start form into a new session stays open until its switch decision (switch_app). Retention
-- waits for that decision (switch_settled, templates_run.lua): else the form's next poll would find a
-- retired run and fail, although its session opened.
local function session_count() return #rex.call('session.list', {}).sessions end
-- start_form opens the Start form of a new template, for a new session.
local function start_form(a)
  local name, root = template(a)
  local s = W.workspace()
  local form = W.open('start_session', '/forms/start', s)
  local values = W.form_input(form:render(), 'start_session')
  values.template, values.root, values.session_id = name, root, '@new'
  return {s = s, form = form, values = values}
end
local function submit(c, key)
  local _, op = c.form:admit('action', {node_id = 'start_session', action = 'submit', input = {values = c.values}, operation_key = key})
  return op
end

-- sentinel writes a finished run (with its run key and its start form, submitted an hour ago: no
-- switch waits for it) as the next run, and returns its ID.
-- With 200 newer runs, its retirement shows that the engine counted them.
local function sentinel()
  local id = W.next_run_id()
  local run = finished_run(id, W.real(W.HOME))
  W.put_runs({run})
  W.put_run_key(run.request.key, {run_id = id})
  W.put_form(run.request.key, {fingerprint = 'fp', request = run.request, at = os.time() - 3600})
  W.set_counter(id)
  return id
end

-- The engine counted the 200 newer runs (the sentinel is retired) before the submit, so the run is
-- the oldest over 200 when it opens. If the step retired it at once, the next poll of
-- the form (every 500 ms) would fail with expired.
test('a run is not retired while its Start form waits for the switch: the form switches once, then the run is retired', function()
  local alice = agent('alice')
  local c = start_form(alice)
  local guard = sentinel()
  local id = tostring(tonumber(guard) + 1)
  newer(alice, id, guard) -- the run-counter stays at the sentinel: the form's start gets run id
  wait('the sentinel retired', function() return W.run(guard) == nil end, 150)
  local a = app('ret-app-wait', {sessions = {c.s}})
  local before = session_count()
  local key = submit(c, 'ret-wait')
  local op = c.form:settle(key, 30)
  W.set_counter(tostring(tonumber(id) + 200))
  expect(op.status).to_be('succeeded')
  expect(op.result.run_id).to_be(id)
  expect(#a:calls()).to_be(1)
  expect(session_count()).to_be(before + 1)
  -- The retirement comes after the switch decision (the step waits RETRY_DELAY, 60 s).
  wait('run ' .. id .. ' retired', function() return W.run(id) == nil end, 150)
  expect(W.run_key(W.start_key('ret-wait')).run_id).to_be(id)
  expect(operation(key).result.run_id).to_be(id)
  expect(#a:calls()).to_be(1)
  expect(session_count()).to_be(before + 1)
  a:close()
end)

-- The same with one shell tab: the first tab opens as the run finishes, so the run
-- is eligible when the switch can happen. The test holds the run's first update while it writes
-- the 200 newer runs, then releases it. If the step retired the run before the form's
-- next poll, that poll would fail with expired.
test('one tab: a run is not retired before its Start form\'s switch; the form succeeds with one session', function()
  local alice = agent('alice')
  local s, root = W.workspace()
  W.put_template(W.hex('ret-single'), {v = 1, name = 'ret-single',
    tabs = {{title = 'shell', layout = {launch = {shell = true}, dir = '.'}}}})
  local form = W.open('start_session', '/forms/start', s)
  local values = W.form_input(form:render(), 'start_session')
  values.template, values.root, values.session_id = 'ret-single', root, '@new'
  local a = app('ret-app-single', {sessions = {s}})
  local before = session_count()
  local id = W.next_run_id()
  local hold = inject({match = {sql_commit_writes = 'runs'}, skip = 1, fail = 'held by the test', times = 'always'})
  local _, key = form:admit('action', {node_id = 'start_session', action = 'submit', input = {values = values}, operation_key = 'ret-single'})
  wait('the held first update', function() return injection(hold).consumed >= 1 end, 10)
  newer(alice, id)
  cancel_injection(hold)
  local w = alice:hub('hub.spawn', {profile = 'watcher', key = 'ret-single-wake'})
  alice:hub('hub.stop', {spawn_id = w.spawn_id})
  local op = form:settle(key, 30)
  expect(op.status).to_be('succeeded')
  expect(op.result.run_id).to_be(id)
  expect(#a:calls() <= 1).to_be(true)
  expect(session_count()).to_be(before + 1)
  wait('run ' .. id .. ' retired', function() return W.run(id) == nil end, 150)
  expect(operation(key).result.run_id).to_be(id)
  expect(session_count()).to_be(before + 1)
  a:close()
end)

-- Constructed: the run was retired while its form operation still runs, and the hub restarts (it
-- runs the operation again). The test holds the run's first update, so no session ever opened:
-- this proves that the replay makes no run, no session and no switch, not that a session opened.
test('a form operation after a hub restart, with its run retired: the same run ID, no new run, session or switch', function()
  local alice = agent('alice')
  local c = start_form(alice)
  local id = W.next_run_id()
  local hold = inject({match = {sql_commit_writes = 'runs'}, skip = 1, fail = 'held by the test', times = 'always'})
  local key = submit(c, 'ret-replay')
  wait('the held first update', function() return injection(hold).consumed >= 1 end, 10)
  local op_key = W.start_key('ret-replay')
  W.delete_run(id)
  W.put_run_key(op_key, {run_id = id, expired_at = os.time(), form_rev = W.form(W.start_key('ret-replay')).rev})
  local counter, before = W.counter(), session_count()
  hub:restart() -- ends the hold (injections are hub state) and closes the apps
  local a = app('ret-app-replay', {sessions = {c.s}})
  local op = wait('the operation after the restart', function()
    local o = operation(key)
    return o.status ~= 'pending' and o or nil
  end, 30)
  expect(op.status).to_be('succeeded')
  expect(op.result.run_id).to_be(id)
  rex.sleep(1)
  expect(W.counter()).to_be(counter)
  expect(W.run(id)).to_be(nil)
  expect(session_count()).to_be(before)
  expect(#a:calls()).to_be(0)
  expect(W.switch(W.start_key('ret-replay'))).to_be(nil)
  a:close()
end)

-- An abandoned form: a finished user start into a new session, with no switch decision and no
-- form that polls. Its retirement waits until switch_wait + 60 s after the submit; the step's own
-- timer runs it. A normal start is not blocked meanwhile.
test('an abandoned form: its run is retired after the bound, without another wake; starts go on', function()
  local alice = agent('alice')
  local name, root = template(alice)
  local guard = sentinel()
  local id = tostring(tonumber(guard) + 1)
  local op_key = W.start_key('ret-abandon')
  local request = {key = op_key, root = W.real(root), new_session_name = 'abandoned', template = {v = 1, name = 'abandoned', tabs = {}}}
  W.put_runs({{id = id, status = 'open', next_tab = 1, root = W.real(root), tabs = {}, results = {},
      session_key = 'templates/' .. id .. '/session', request = request}})
  W.put_run_key(op_key, {run_id = id})
  W.put_form(op_key, {fingerprint = 'abandoned', request = request, at = os.time()})
  newer(alice, id)
  -- The sentinel is older: the step of the abandoned run comes next, at once.
  wait('the sentinel retired', function() return W.run(guard) == nil end, 150)
  rex.sleep(1)
  expect(W.run(id)).not_to_be(nil)
  local r = alice:call('templates.start', {template = name, root = root, key = 'ret-abandon-other'})
  W.wait_run(alice, r.run_id, 'open')
  expect(W.run(id)).not_to_be(nil)
  wait('run ' .. id .. ' retired', function() return W.run(id) == nil end, 200)
  expect(W.run_key(op_key).run_id).to_be(id)
end)
