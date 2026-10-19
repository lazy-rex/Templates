-- Starts across a hub restart (hub:restart). The plugin starts again with the hub and resumes
-- every unfinished run from its records (engine.resume). A hold (an injection that fails the run's
-- first update) keeps the run before its first tab until the restart; the restart ends the hold.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')

local function view(s) return rex.call('session.view', {session_id = s}) end
-- skip: changes of the record that pass first (an agent's start authorizes its run: 1).
local function hold(skip)
  local id = W.next_run_id()
  local inj = inject({match = {updates = 'run/' .. id}, skip = skip, fail = 'held by the test', times = 'always'})
  return id, function() wait('the held update of run ' .. id, function() return injection(inj).consumed >= 1 end, 10) end
end
local function saved_template(alice, name)
  local s, root = W.workspace()
  W.capture(alice, s)
  alice:call('templates.save', {name = name, root = root, session_id = s, key = 'save-' .. name})
  return s, root
end
-- windows_of lists the windows of a session whose workers have this parent.
local function workers_in(a, session_id)
  local list = {}
  for _, w in ipairs(a:hub('hub.workers', {}).workers) do if w.session_id == session_id then list[#list + 1] = w end end
  return list
end

test('lab 4 the hub crashes right after a user start is admitted: the run finishes once', function()
  local alice = agent('alice')
  local s, root = saved_template(alice, 'crash-ui')
  local form = W.open('start_session', '/forms/start', s)
  local values = W.form_input(form:render(), 'start_session')
  values.template, values.root, values.session_id = 'crash-ui', root, '@new'
  local id, held = hold()
  form:admit('action', {node_id = 'start_session', action = 'submit', input = {values = values}, operation_key = 'lab4-start'})
  held()
  hub:restart({crash = true})
  local run = W.wait_run(alice, id, 'open')
  local v = view(run.session_id)
  expect(#v.windows).to_be(2)
  expect(v.windows[1].label).to_be('code')
  expect(v.windows[2].label).to_be('logs')
  expect(#workers_in(alice, run.session_id)).to_be(3)
end)

-- spawn_blocks lists the blocks of a session that carry a lazyrex-spawn label, sorted.
local function spawn_blocks(s)
  local ids = {}
  for _, b in ipairs(rex.call('session.list_blocks', {session_id = s}).blocks) do
    if (b.label or ''):match('^lazyrex%-spawn:') then ids[#ids + 1] = b.block_id end
  end
  table.sort(ids)
  return ids
end
local function window_ids(s)
  local ids = {}
  for _, w in ipairs(view(s).windows) do ids[#ids + 1] = w.window_id end
  table.sort(ids)
  return ids
end
local function session_ids()
  local set = {}
  for _, x in ipairs(rex.call('session.list', {}).sessions) do set[x.session_id] = true end
  return set
end

-- lab 4 (formerly templates-lab.mjs, TEMPLATES_RESTART=1): the hub crashes after Rex created the
-- first tab and before the hub recorded it. A window hold (docs/testing.md) stops the create
-- there. Until the restart the test asks only Rex: the hub gets no request while it holds a call.
-- The hub never adopts accessory panes by their label (decided 2026-10-17), so the run stays
-- pending with its candidate panes, and Dismiss ends it without closing a pane. The hub replays
-- the original Start operation after its restart; it must give the same run.
test('lab 4 a crash inside a tab create: the run waits pending with its candidate panes; Dismiss keeps them', function()
  local alice = agent('alice')
  local s, root = saved_template(alice, 'crash-create')
  local form = W.open('start_session', '/forms/start', s)
  local values = W.form_input(form:render(), 'start_session')
  values.template, values.root, values.session_id = 'crash-create', root, '@new'
  local id = W.next_run_id()
  local before = session_ids()
  inject({match = {window = 'templates/' .. id .. '/tab/1', caller = 'user'}, hold = true})
  local _, key = form:admit('action', {node_id = 'start_session', action = 'submit', input = {values = values}, operation_key = 'lab4-create'})
  local N = wait('the new session', function()
    for sid in pairs(session_ids()) do if not before[sid] and #spawn_blocks(sid) > 0 then return sid end end
  end, 20)
  -- The first tab ("code") has two panes; Rex made both before the hold.
  local panes = wait('the first tab\'s panes', function() local p = spawn_blocks(N); return #p == 2 and p or nil end, 20)
  local windows = window_ids(N)
  expect(#windows).to_be(1)
  hub:restart({crash = true})
  -- The run resumes, gets the recorded pending leaves for the same key, and stops at tab 1.
  local run = W.wait_run(alice, id, 'pending')
  expect(run.session_id).to_be(N)
  local op = wait('the replayed Start operation', function()
    local o = operation(key)
    return o.status ~= 'pending' and o or nil
  end, 30)
  expect(op.status).to_be('succeeded')
  expect(op.result.run_id).to_be(id)
  -- The resolver reports one candidate pane per leaf; it adopts none.
  wait('the candidate panes', function()
    local n = 0
    for _, w in ipairs(alice:hub('hub.workers', {}).workers) do
      if w.session_id == N then
        if w.state ~= 'starting' then return nil end
        if w.error == 'outcome unknown: 1 candidate pane(s)' then n = n + 1 end
      end
    end
    return n == 2
  end, 30)
  expect(spawn_blocks(N)).to_equal(panes)
  expect(window_ids(N)).to_equal(windows)
  expect(W.next_run_id()).to_be(tostring(tonumber(id) + 1))
  -- Dismiss from the panel (a pending run has no Retry row). The panel opens in another session:
  -- after the crash, the form's side panel did not give up its place (reported separately).
  local p = W.panel(W.workspace())
  local stuck = node(p:render(), 'stuck').items
  expect(W.find(stuck, 'id', 'retry:' .. id)).to_be(nil)
  expect(W.find(stuck, 'id', 'dismiss:' .. id)).not_to_be(nil)
  expect(p:action('stuck', 'dismiss', {item_id = 'dismiss:' .. id}, 'lab4-dismiss').status).to_be('succeeded')
  expect(W.run_of(alice, id).status).to_be('dismissed')
  expect(W.template('crash-create')).not_to_be(nil)
  expect(spawn_blocks(N)).to_equal(panes)
  expect(window_ids(N)).to_equal(windows)
  -- The Start operation's record after Dismiss (a read, not a resubmit). A resubmit through the
  -- same form waits for the harness fix testview-reattach: now the form's renderer still sends to
  -- the old hub client ("lazyrex-hub is waiting to reconnect").
  local again = operation(key)
  expect(again.status).to_be('succeeded')
  expect(again.result.run_id).to_be(id)
  expect(W.next_run_id()).to_be(tostring(tonumber(id) + 1))
  expect(spawn_blocks(N)).to_equal(panes)
  expect(window_ids(N)).to_equal(windows)
end)

test('an agent start returns before its tabs; after a hub restart they open as the agent\'s', function()
  local alice, bob = agent('alice'), agent('bob')
  local _, root = saved_template(alice, 'crash-agent')
  local id, held = hold(1)
  local r = alice:call('templates.start', {template = 'crash-agent', root = root, key = 'restart-agent'})
  expect(r.run_id).to_be(id)
  held()
  expect(store('run/' .. id).value.status).to_be('queued')
  expect(type(store('run/' .. id).value.grant_id)).to_be('string')
  hub:restart()
  local run = W.wait_run(alice, id, 'open')
  local panes = workers_in(alice, run.session_id)
  expect(#panes).to_be(3)
  for _, w in ipairs(panes) do expect(w.parent).to_be('alice') end
  -- Only the owner stops a pane.
  expect_error(function() bob:hub('hub.stop', {spawn_id = panes[1].spawn_id}) end, 'did not start')
  expect(alice:hub('hub.stop', {spawn_id = panes[1].spawn_id}).status).to_be('closed')
  wait('the revoke of the grant', function() return store('run/' .. id).value.grant_revoked == true end, 20)
end)

-- A constructed recovery boundary, not an observed live migration. alice reports a conversation,
-- so her identity takes over the legacy ID "alice" (a real alias). Her start and its grant belong
-- to the current identity. Then the run's record is rewritten to the state of a crash between the
-- grant and engine.authorize, with request.by set to the legacy ID. Resume finds the grant by its
-- key and exact requests (find_grant), and the tabs open as the grant's agent. The current
-- identity still owns the run (through its legacy ID); another agent cannot change it.
test('constructed boundary: a run with a legacy owner and no recorded grant resumes with its grant', function()
  local alice, bob = agent('alice'), agent('bob')
  local _, root = saved_template(alice, 'legacy-owner')
  local current = alice:report({kind = 'claude', conversation_id = 'legacy-boundary'}).identity
  expect(current).not_to_be('alice')
  local id, held = hold(1)
  local r = alice:call('templates.start', {template = 'legacy-owner', root = root, key = 'legacy-start'})
  held()
  local run = store('run/' .. id).value
  expect(run.request.by).to_be(current)
  local grant_id = run.grant_id
  expect(type(grant_id)).to_be('string')
  run.grant_id, run.status, run.request.by = nil, 'authorizing', 'alice'
  write({{key = 'run/' .. id, value = run}})
  hub:restart({crash = true})
  local opened = W.wait_run(alice, r.run_id, 'open')
  expect(store('run/' .. id).value.grant_id).to_be(grant_id)
  expect(store('run/' .. id).value.request.by).to_be('alice')
  local panes = workers_in(alice, opened.session_id)
  expect(#panes).to_be(3)
  for _, w in ipairs(panes) do expect(w.parent).to_be(current) end
  expect(alice:call('templates.retry', {run_id = id, key = 'owner-retry'})).to_equal({run_id = id, woken = false})
  expect_error(function() bob:call('templates.dismiss', {run_id = id, key = 'bob-dismiss'}) end, 'refused')
  expect_error(function() bob:call('templates.retry', {run_id = id, key = 'bob-retry'}) end, 'refused')
end)
