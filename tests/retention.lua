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
-- retire makes run id the oldest of more than 200 eligible runs and waits until it is retired.
local function retire(a, id)
  local root = W.real(W.HOME)
  local first = tonumber(id) + 1
  local ops, n = {}, 0
  for i = first, first + 199 do
    local run = {id = tostring(i), status = 'open', next_tab = 1, root = root, tabs = {},
      request = {key = 'newer' .. i, root = root, new_session_name = 'n', template = {v = 1, name = 'n', tabs = {}}},
      results = {}, session_key = 'templates/' .. i .. '/session'}
    local cost = #rex.json.encode(run)
    if #ops > 0 and n + cost > 40000 then write(ops); ops, n = {}, 0 end
    ops[#ops + 1], n = {key = 'run/' .. i, value = run}, n + cost
  end
  ops[#ops + 1] = {key = 'run-counter', value = tostring(first + 199)}
  write(ops)
  S.n = S.n + 1
  local w = a:hub('hub.spawn', {profile = 'watcher', key = 'ret-wake-' .. S.n})
  a:hub('hub.stop', {spawn_id = w.spawn_id})
  wait('run ' .. id .. ' retired', function() return store('run/' .. id).value == nil end, 60)
end
local function agent_key(id, key) return 'start/agent/' .. W.part(id) .. W.part(key) end
-- age sets the expired_at of a marker to seconds before now (keeping its id and form_rev).
local function age(op_key, seconds)
  local m = store('run-key/' .. op_key).value
  m.expired_at = os.time() - seconds
  write({{key = 'run-key/' .. op_key, value = m}})
end

test('an agent replay of a retired start gives expired; changed arguments give operation_conflict', function()
  local alice = agent('alice')
  local name, root = template(alice)
  local r = alice:call('templates.start', {template = name, root = root, key = 'ret-a1'})
  W.wait_run(alice, r.run_id, 'open')
  wait('the grant revoked', function() return store('run/' .. r.run_id).value.grant_revoked end, 20)
  retire(alice, r.run_id)
  local op_key = agent_key('alice', 'ret-a1')
  local marker = store('run-key/' .. op_key).value
  expect(marker.id).to_be(r.run_id)
  expect(marker.form_rev).to_be(store(W.start_form_key_agent('alice', 'ret-a1')).rev)
  local next_id = W.next_run_id()
  expect_error(function() alice:call('templates.start', {template = name, root = root, key = 'ret-a1'}) end, 'expired')
  expect_error(function() alice:call('templates.start', {template = name, root = root .. '/api', key = 'ret-a1'}) end, 'operation_conflict')
  expect(W.next_run_id()).to_be(next_id)
end)

-- Expiry on access: no restart and no cleanup. The marker of 'ret-a1' expires in 3 s.
test('a retired key is free again 30 days after its removal, also with changed arguments', function()
  local alice = agent('alice')
  local name, root = template(alice)
  local op_key = agent_key('alice', 'ret-a1')
  age(op_key, TTL - 3)
  expect_error(function() alice:call('templates.start', {template = name, root = root, key = 'ret-a1'}) end, 'operation_conflict')
  local old = store('run-key/' .. op_key).value.id
  -- The same arguments as the first start (template ret-1 still exists).
  local first = store(W.start_form_key_agent('alice', 'ret-a1')).value.request
  expect_error(function() alice:call('templates.start', {template = first.template.name, root = first.root, key = 'ret-a1'}) end, 'expired')
  rex.sleep(4)
  -- Changed arguments after the expiry: a new start.
  local r = alice:call('templates.start', {template = name, root = root, key = 'ret-a1'})
  expect(r.run_id).not_to_be(old)
  W.wait_run(alice, r.run_id, 'open')
  expect(store('run-key/' .. op_key).value.expired_at).to_be(nil)
end)

-- A legacy run: no start-form record when it was retired (its marker has no form_rev). A replay
-- within 30 days writes a start-form record and gives expired; after 30 days that record is the
-- key's record (a legacy marker never frees a later record), and the same arguments start again.
test('a legacy run without a start-form record: expired, then a new start after 30 days', function()
  local bob = agent('bob')
  local name, root = template(bob)
  local op_key = agent_key('bob', 'ret-legacy')
  local id = tostring(tonumber(store('run-counter').value) + 1)
  write({{key = 'run/' .. id, value = {id = id, status = 'open', next_tab = 1, root = root, tabs = {}, results = {},
    grant_id = 'grant:legacy', grant_revoked = true, session_key = 'templates/' .. id .. '/session',
    request = {key = op_key, by = 'bob', root = root, new_session_name = name, template = {v = 1, name = name, tabs = {}}}}},
    {key = 'run-key/' .. op_key, value = {id = id}}, {key = 'run-counter', value = id}})
  retire(bob, id)
  expect(store('run-key/' .. op_key).value.form_rev).to_be(nil)
  expect_error(function() bob:call('templates.start', {template = name, root = root, key = 'ret-legacy'}) end, 'expired')
  expect(store(W.start_form_key_agent('bob', 'ret-legacy')).value).not_to_be(nil)
  age(op_key, TTL + 1)
  local r = bob:call('templates.start', {template = name, root = root, key = 'ret-legacy'})
  W.wait_run(bob, r.run_id, 'open')
end)

-- An agent that took over a legacy ID (alice reports a conversation: her identity changes, and
-- "alice" is her legacy ID). Her keys are looked up under both IDs.
test('the alias lookup: expired aliases start again; an expired alias does not hide an active start; a renamed agent gets expired', function()
  local alice = agent('alice')
  local name, root = template(alice)
  -- A start under the ID "alice", retired before the rename.
  local r = alice:call('templates.start', {template = name, root = root, key = 'ret-alias-old'})
  W.wait_run(alice, r.run_id, 'open')
  wait('the grant revoked', function() return store('run/' .. r.run_id).value.grant_revoked end, 20)
  retire(alice, r.run_id)
  local current = alice:report({kind = 'claude', conversation_id = 'retention-alias'}).identity
  expect(current).not_to_be('alice')
  -- Replay through the renamed agent within 30 days: expired.
  expect_error(function() alice:call('templates.start', {template = name, root = root, key = 'ret-alias-old'}) end, 'expired')
  -- Two expired alias records of one key (one per ID): a new start, not a conflict.
  local fp
  for _, id in ipairs({'alice', current}) do
    local k = agent_key(id, 'ret-alias-two')
    write({{key = W.start_form_key_agent(id, 'ret-alias-two'), value = {fingerprint = 'old-' .. id, request = {key = k}, at = 1}}})
    write({{key = 'run-key/' .. k, value = {id = '1', expired_at = os.time() - TTL - 1, form_rev = store(W.start_form_key_agent(id, 'ret-alias-two')).rev}}})
  end
  local two = alice:call('templates.start', {template = name, root = root, key = 'ret-alias-two'})
  W.wait_run(alice, two.run_id, 'open')
  -- An active start under the current ID, and an expired record of the same key under "alice":
  -- the replay gives the active run.
  local active = alice:call('templates.start', {template = name, root = root, key = 'ret-alias-active'})
  local k = agent_key('alice', 'ret-alias-active')
  write({{key = W.start_form_key_agent('alice', 'ret-alias-active'), value = {fingerprint = 'old', request = {key = k}, at = 1}}})
  write({{key = 'run-key/' .. k, value = {id = '1', expired_at = os.time() - TTL - 1, form_rev = store(W.start_form_key_agent('alice', 'ret-alias-active')).rev}}})
  expect(alice:call('templates.start', {template = name, root = root, key = 'ret-alias-active'})).to_equal(active)
end)

-- The UI boundary: the hub saves a completed view operation and answers it without a call to
-- Templates. A read hook on the start's start-form record proves that the plugin did not read it.
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
  local hook = inject({match = {reads = W.start_form_key('ret-ui')}, ops = {{key = 'probe/ret-ui', value = 1}}, times = 'always'})
  local again = operation(key)
  expect(again.status).to_be('succeeded')
  expect(again.result.run_id).to_be(id)
  local form2 = W.open('start_session', '/forms/start', s)
  expect_error(function()
    form2:admit('action', {node_id = 'start_session', action = 'submit', input = {values = values}, operation_key = key})
  end, 'operation_conflict')
  expect(injection(hook).consumed).to_be(0)
  cancel_injection(hook)
end)
