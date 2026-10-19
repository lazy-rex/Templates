-- A start into a new session switches the app once, from the open form (hub.app.select_session).
-- Fake Rex apps (app()) show the form's session and answer the switch. The plugin's switch wait
-- is 3 s in tests (lazyrex.json, switch_wait).
-- A late first tab: an injection holds the run's first update (match updates) until the test
-- cancels it, and a worker change wakes the engine again.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')

local k = 0
local alice
local holds = {} -- active holds: a failed test must not hold the engine for the next one
-- prepare saves a template of a new workspace and opens the Start form from that session. It
-- returns {s, root, name, form, values, key}: values start the template in a new session.
local function prepare()
  for id in pairs(holds) do cancel_injection(id); holds[id] = nil end
  k = k + 1
  alice = agent('alice')
  local s, root = W.workspace()
  W.capture(alice, s)
  local name = 'sw-' .. k
  alice:call('templates.save', {name = name, root = root, session_id = s, key = 'sw-save-' .. k})
  local anchor = W.first_block(s)
  local form = W.open('start_session', '/forms/start', s, anchor)
  local values = W.form_input(form:render(), 'start_session')
  values.template, values.root, values.session_id = name, root, '@new'
  return {s = s, root = root, name = name, form = form, values = values, key = 'sw-start-' .. k, anchor = anchor}
end
local function submit(c) return c.form:action('start_session', 'submit', {values = c.values}, c.key) end
local function notice(s)
  local w = node(W.panel(s):render(), 'switch')
  return w and w.text
end
local function run_named(name) return W.find(alice:call('templates.runs', {}).runs, 'template', name) end
-- hold makes the next run's first update fail until release: its first tab is late. release waits
-- until the hold stopped an update (else the test proves nothing), ends it and wakes the engine.
local function hold()
  local id = W.next_run_id()
  local inj = inject({match = {updates = 'run/' .. id}, fail = 'held by the test', times = 'always'})
  holds[inj] = true
  return id, function()
    wait('the held update of run ' .. id, function() return injection(inj).consumed >= 1 end, 10)
    cancel_injection(inj)
    holds[inj] = nil
    -- A worker change wakes the engine (hub.changed workers).
    local w = alice:hub('hub.spawn', {profile = 'watcher', key = 'wake-' .. id})
    alice:hub('hub.stop', {spawn_id = w.spawn_id})
  end
end

test('F1 one app shows the form\'s session: it switches once to the first tab', function()
  local a
  local c = prepare()
  a = app('sw-app-1', {sessions = {c.s}})
  local op = submit(c)
  expect(op.status).to_be('succeeded')
  local run = W.wait_run(alice, op.result.run_id, 'open')
  local calls = a:calls()
  expect(#calls).to_be(1)
  expect(calls[1].action).to_be('session.select')
  expect(calls[1].args.session_id).to_be(run.session_id)
  expect(calls[1].args.window_id).to_be(store('run/' .. run.id).value.results[1].window_id)
  expect(W.switch_record(c.key).state).to_be('done')
  expect(notice(c.s)).to_be(nil)
  a:close()
end)

test('F2 a start into an existing session never switches', function()
  local c = prepare()
  local a = app('sw-app-2', {sessions = {c.s}})
  c.values.session_id = c.s
  expect(submit(c).status).to_be('succeeded')
  W.wait_run(alice, run_named(c.name).id, 'open')
  rex.sleep(0.5)
  expect(#a:calls()).to_be(0)
  expect(W.switch_record(c.key)).to_be(nil)
  a:close()
end)

test('F3 no app: refused with no_app; the panel says why', function()
  local c = prepare()
  expect(submit(c).status).to_be('succeeded')
  local sw = W.switch_record(c.key)
  expect(sw.state).to_be('refused')
  expect(sw.code).to_be('no_app')
  expect(notice(c.s)).to_match('no Rex app shows the session of the form')
end)

test('F3 the user leaves the form before the first tab opens: not_focused, the panel says why', function()
  local c = prepare()
  local a = app('sw-app-3', {sessions = {c.s}})
  local id, release = hold()
  local _, key = c.form:admit('action', {node_id = 'start_session', action = 'submit', input = {values = c.values}, operation_key = c.key})
  wait('the held update', function() return store('run/' .. id).value end, 10)
  -- The user goes to another pane of the session: not the form, and not its source pane (the hub
  -- gives the focus back to a form from its source pane, forms.go).
  local other
  for _, b in ipairs(W.blocks(c.s)) do
    if b.block_id ~= c.form.block and b.block_id ~= c.anchor then other = other or b.block_id end
  end
  rex.call('session.focus_block', {session_id = c.s, block_id = other})
  local sv = rex.call('session.view', {session_id = c.s})
  local focused
  for _, w in ipairs(sv.windows) do if w.window_id == sv.active_window_id then focused = w.focused_block_id end end
  expect(focused).to_be(other)
  expect(focused).not_to_be(c.form.block)
  rex.sleep(1)
  sv = rex.call('session.view', {session_id = c.s})
  for _, w in ipairs(sv.windows) do if w.window_id == sv.active_window_id then focused = w.focused_block_id end end
  if focused ~= other then error('the focus moved back to ' .. tostring(focused) .. ' (form ' .. tostring(c.form.block) .. ')') end
  release()
  expect(c.form:settle(key, 20).status).to_be('succeeded')
  local sw = W.switch_record(c.key)
  expect(sw.state).to_be('refused')
  expect(sw.code).to_be('not_focused')
  expect(#a:calls()).to_be(0)
  expect(notice(c.s)).to_match('did not switch to it: you left the form before its first tab opened%. To go there, use Go to Session')
  a:close()
end)

test('an app that answers the switch with an error: the outcome is unknown', function()
  local c = prepare()
  local a = app('sw-app-8', {sessions = {c.s}})
  a:fail('refused')
  expect(submit(c).status).to_be('succeeded')
  expect(W.switch_record(c.key).state).to_be('unknown')
  expect(#a:calls()).to_be(1)
  expect(notice(c.s)).to_match('may not have switched')
  a:close()
end)

test('lab 6 two apps show the form\'s session: ambiguous_app, no app is asked, the panel says how', function()
  local c = prepare()
  local a1, a2 = app('sw-app-4', {sessions = {c.s}}), app('sw-app-5', {sessions = {c.s}})
  expect(submit(c).status).to_be('succeeded')
  W.wait_run(alice, run_named(c.name).id, 'open')
  expect(W.switch_record(c.key).code).to_be('ambiguous_app')
  expect(#a1:calls() + #a2:calls()).to_be(0)
  local text = notice(c.s)
  expect(text).to_match('more than one Rex app shows the session of the form')
  expect(text).to_match('Go to Session')
  a1:close(); a2:close()
end)

test('F4 an earlier attempt reads as unknown and never switches again', function()
  local c = prepare()
  local a = app('sw-app-6', {sessions = {c.s}})
  write({{key = 'switch/' .. W.hex('start/' .. W.part(c.key)), value = {state = 'attempted'}}})
  expect(submit(c).status).to_be('succeeded')
  expect(#a:calls()).to_be(0)
  expect(W.switch_record(c.key).state).to_be('unknown')
  expect(notice(c.s)).to_match('may not have switched.*If it did not, use Go to Session')
  a:close()
end)

test('F5 F6 the form waits and says Starting; the wait expires; the late first tab never switches', function()
  local c = prepare()
  local a = app('sw-app-7', {sessions = {c.s}})
  local id, release = hold()
  local _, key = c.form:admit('action', {node_id = 'start_session', action = 'submit', input = {values = c.values}, operation_key = c.key})
  -- F6: while it waits, the form says so and cannot submit again.
  local tree = wait('the waiting form', function()
    local t = c.form:render()
    return node(t, 'starting') and t or nil
  end, 10)
  expect(node(tree, 'starting').text).to_match('^Starting')
  local snap = c.form:get()
  if type(snap.status) ~= 'table' then error('the view snapshot: ' .. rex.json.encode(snap)) end
  expect(snap.status.state).to_be('working')
  expect(node(tree, 'start_session').submit_action.enabled).to_be(false)
  local op = c.form:settle(key, 20)
  expect(op.status).to_be('succeeded')
  expect(W.switch_record(c.key).code).to_be('timeout')
  expect(store('run/' .. id).value.status).to_be('queued')
  release()
  W.wait_run(alice, id, 'open')
  rex.sleep(1)
  expect(#a:calls()).to_be(0)
  expect(notice(c.s)).to_match('wait for the automatic switch .* expired, so the app did not switch%. When the session is available, use Go to Session')
  a:close()
end)

-- F7 F8: a recovered start whose wait is over never switches, even when its first tab is open now:
-- a legacy start record without at, and one older than the wait.
for _, case in ipairs({{'F7 a legacy start record without at', function(v) v.at = nil end},
    {'F8 a start record older than the wait', function(v) v.at = v.at - 60 end}}) do
  test(case[1] .. ' never switches late', function()
    local c = prepare()
    local a = app('sw-app-' .. case[1]:sub(1, 2), {sessions = {c.s}})
    local id, release = hold()
    local _, key = c.form:admit('action', {node_id = 'start_session', action = 'submit', input = {values = c.values}, operation_key = c.key})
    local rk = W.start_form_key(c.key)
    local rec = wait('the start record', function() return store(rk).value end, 10)
    case[2](rec)
    write({{key = rk, value = rec}})
    release()
    W.wait_run(alice, id, 'open')
    expect(c.form:settle(key, 20).status).to_be('succeeded')
    expect(W.switch_record(c.key).code).to_be('timeout')
    expect(#a:calls()).to_be(0)
    a:close()
  end)
end
