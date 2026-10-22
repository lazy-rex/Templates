-- The Start form's waiting state (templates.lua, start_session; tests/templates-run.md, "Start form
-- wait"). While a start into a new session waits for its first tab, the form shows "Starting…" and
-- its operation answers running. A poll that ends with a definite error ends the operation (hub
-- viewsvc.go, definiteFailure), so the form must not keep "Starting…". A transient error keeps
-- it: the hub runs the operation again. A hold on the run's updates keeps the start waiting; the
-- switch wait is 3 s in the lab (switch_wait).
--
-- The tests read the form as the renderer gets it (v:get()), never with a forced render: each
-- change of the waiting state must reach the form by a render that the hub starts. start_session
-- calls app.refresh() for each change (tests/templates-run.md, "Render inputs"); the hub counts
-- those renders with the cause invalidate.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')

-- shown: the tree that the renderer has now. invalidated: the renders of view v for app.refresh().
local function shown(v) local g = v:get(); return g and g.tree or {nodes = {}} end
local function invalidated(v)
  for _, c in ipairs(renders('templates')) do if c.view_id == v.id then return (c.causes or {}).invalidate or 0 end end
  return 0
end

-- waiting opens a Start form for a one-tab template, holds the run's updates, and submits. It
-- returns the form, the operation key, the hold and the start key (of its switches row) once the form shows
-- "Starting…".
local function waiting(name, op_key)
  local s, root = W.workspace()
  W.put_template(W.hex(name), {v = 1, name = name, tabs = {{title = 'shell', layout = {launch = {shell = true}, dir = '.'}}}})
  local form = W.open('start_session', '/forms/start', s)
  local values = W.form_input(form:render(), 'start_session')
  values.template, values.root, values.session_id = name, root, '@new'
  local id = W.next_run_id()
  local hold = inject({match = {sql_commit_writes = 'runs'}, skip = 1, fail = 'held by the test', times = 'always'})
  local before = invalidated(form)
  local _, key = form:admit('action', {node_id = 'start_session', action = 'submit', input = {values = values}, operation_key = op_key})
  wait('the waiting form', function() return node(shown(form), 'starting') end, 10)
  expect(invalidated(form) > before).to_be(true)
  return form, key, hold, W.run(id).value.request.key
end

-- A definite error ends the operation, and the form does not show "Starting…" any more.
test('a poll that fails with a definite error clears Starting', function()
  local a = app('starting-definite', {sessions = {}})
  local form, key, hold, switch = waiting('st-definite', 'st-definite')
  local inv = invalidated(form)
  inject({match = {sql_commit_writes = 'switches'}, fail = 'switch record write refused', fail_code = 'invalid_input'})
  local op = form:settle(key, 10)
  cancel_injection(hold)
  a:close()
  expect(op.status).to_be('failed')
  expect(op.error.code).to_be('invalid_input')
  wait('the form without Starting', function() return node(shown(form), 'starting') == nil or nil end, 10)
  expect(invalidated(form) > inv).to_be(true)
end)

-- A transient error keeps the operation pending and the form waiting. The injection fails every
-- switch write until the test has seen it consumed, the operation still pending and "Starting…";
-- then it is cancelled, and the next poll decides the switch.
test('a poll that fails with a transient error keeps Starting; the operation then succeeds', function()
  local a = app('starting-transient', {sessions = {}})
  local form, key, hold, switch = waiting('st-transient', 'st-transient')
  local gate = inject({match = {sql_commit_writes = 'switches'}, fail = 'switch record write unavailable', fail_code = 'unavailable', times = 'always'})
  wait('a refused switch write', function() return injection(gate).consumed >= 1 or nil end, 15)
  expect(operation(key).status).to_be('pending')
  expect(node(shown(form), 'starting')).not_to_be(nil)
  wait('another refused write', function() return injection(gate).consumed >= 2 or nil end, 15)
  expect(operation(key).status).to_be('pending')
  cancel_injection(gate)
  local op = form:settle(key, 15)
  cancel_injection(hold)
  a:close()
  expect(op.status).to_be('succeeded')
  expect(W.switch(switch).state).to_be('refused')
  -- The success result opens the panel in the form's place (its panel effect), so the form view
  -- is gone; its waiting state ended with the result (start_poll).
  expect(op.result.panel.route).to_be('/panels/templates')
end)
