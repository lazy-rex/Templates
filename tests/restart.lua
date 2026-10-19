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

-- A constructed recovery boundary, not an observed live migration: the run's record is rewritten
-- to the state of a crash between the grant and engine.authorize, with request.by set to an older
-- ID of the agent (an identity can take over a legacy ID after admission). The grant was made by
-- the agent's current ID. Resume finds the grant by its key and exact requests (find_grant), and
-- the tabs open as the grant's agent. Another agent cannot change the run.
test('constructed boundary: a run with a legacy owner and no recorded grant resumes with its grant', function()
  local alice, bob = agent('alice'), agent('bob')
  local _, root = saved_template(alice, 'legacy-owner')
  local id, held = hold(1)
  local r = alice:call('templates.start', {template = 'legacy-owner', root = root, key = 'legacy-start'})
  held()
  local run = store('run/' .. id).value
  local grant_id = run.grant_id
  expect(type(grant_id)).to_be('string')
  run.grant_id, run.status, run.request.by = nil, 'authorizing', 'claude:legacy-alice'
  write({{key = 'run/' .. id, value = run}})
  hub:restart({crash = true})
  local opened = W.wait_run(alice, r.run_id, 'open')
  expect(store('run/' .. id).value.grant_id).to_be(grant_id)
  local panes = workers_in(alice, opened.session_id)
  expect(#panes).to_be(3)
  for _, w in ipairs(panes) do expect(w.parent).to_be('alice') end
  expect_error(function() bob:call('templates.dismiss', {run_id = id, key = 'bob-dismiss'}) end, 'refused')
  expect_error(function() bob:call('templates.retry', {run_id = id, key = 'bob-retry'}) end, 'refused')
end)
