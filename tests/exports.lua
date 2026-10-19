-- Agent exports and their UI actions: each flow runs on both paths (agent(...):call, the MCP path,
-- and the user's view). Owner rules, key namespaces and the grant of an agent's start.

local HOME = H.args.lab .. '/home'

-- A source session: tab "code" splits two idle shells (api, web), tab "logs" has one (the root).
local function sh(cwd)
  return {block = {flavor = 'com.superlogical.terminal.shell', options = {command = {'/bin/sh'}, login = false, cwd = cwd}}}
end
local n = 0
local function workspace()
  n = n + 1
  local root = HOME .. '/ws' .. n
  local made, err = rex.exec({'mkdir', '-p', root .. '/api', root .. '/web'})
  if not made or not made.ok then error('mkdir: ' .. tostring(err or made.stderr)) end
  -- The real path: the lab's TMPDIR can be a symbolic link (/tmp on macOS).
  root = rex.exec({'pwd', '-P'}, {cwd = root}).stdout:gsub('\n$', '')
  local res, err = rex.call('session.create', {label = 'ws' .. n, initial_windows = {
    {window_label = 'code', layout = {split = {direction = 'horizontal', ratio = 0.4, before = sh(root .. '/api'), after = sh(root .. '/web')}}},
    {window_label = 'logs', layout = sh(root)}}})
  if err then error(err.message or tostring(err)) end
  return res.session_id, root
end
-- capture waits until every pane of the session is an idle shell with a known directory.
local function capture(a, session_id)
  return wait('the capture of ' .. session_id, function()
    local c = a:call('templates.capture', {session_id = session_id})
    if #c.panes ~= 3 then return nil end
    for _, p in ipairs(c.panes) do if p.guess ~= 'shell' or not p.dir then return nil end end
    return c
  end, 20)
end
-- panel opens the Templates panel from a pane of the session, as the palette command does.
local function panel(session_id)
  user:command('templates', {session = session_id, block = rex.call('session.list_blocks', {session_id = session_id}).blocks[1].block_id})
  return user:view('/panels/templates', nil, session_id)
end
local function first_block(session_id)
  return rex.call('session.list_blocks', {session_id = session_id}).blocks[1].block_id
end
local function form_input(tree, id)
  local values = {}
  for _, f in ipairs(node(tree, id).fields) do values[f.id] = f.value end
  return values
end
local function find(list, field, value)
  for _, x in ipairs(list) do if x[field] == value then return x end end
end
local function run_of(a, id)
  local r = a:call('templates.runs', {})
  if type(r.runs) ~= 'table' then error('templates.runs: ' .. rex.json.encode(r)) end
  return find(r.runs, 'id', id)
end
local function wait_run(a, id, status)
  return wait('run ' .. id .. ' ' .. status, function()
    local r = run_of(a, id)
    return r and r.status == status and r or nil
  end, 30)
end

test('an agent saves a session; a retry replays; other content with the key is a conflict', function()
  local alice = agent('alice')
  local s, root = workspace()
  local c = capture(alice, s)
  expect(c.root_guess).to_be(root)
  local saved = alice:call('templates.save', {name = 'ws-agent', root = root, session_id = s, key = 'save-1'})
  expect(saved).to_equal({name = 'ws-agent'})
  expect(alice:call('templates.save', {name = 'ws-agent', root = root, session_id = s, key = 'save-1'})).to_equal({name = 'ws-agent'})
  expect_error(function() alice:call('templates.save', {name = 'ws-other', root = root, session_id = s, key = 'save-1'}) end, 'operation_conflict')
  local t = find(alice:call('templates.list', {}).templates, 'name', 'ws-agent')
  expect(t.saved_by).to_be('alice')
  expect(#t.tabs).to_be(2)
  expect(t.tabs[1].layout.direction).to_be('horizontal')
  -- A pane choice of skip leaves the pane out.
  local skip = {}
  skip[c.panes[3].block_id] = 'skip'
  alice:call('templates.save', {name = 'ws-code', root = root, session_id = s, panes = skip, key = 'save-2'})
  expect(#find(alice:call('templates.list', {}).templates, 'name', 'ws-code').tabs).to_be(1)
end)

test('the user saves through the form; the template has no agent owner', function()
  local alice = agent('alice')
  local s, root = workspace()
  capture(alice, s)
  user:command('save_template', {session = s, block = first_block(s)})
  local form = user:view('/forms/save', nil, s)
  local tree = form:render()
  expect(node(tree, 'save_template').submit_action.tool).to_be('templates.save')
  local values = form_input(tree, 'save_template')
  values.name, values.root = 'ws-user', root
  local done = form:action('save_template', 'submit', {values = values}, 'ui-save-1')
  expect(done.status).to_be('succeeded')
  expect(find(alice:call('templates.list', {}).templates, 'name', 'ws-user').saved_by).to_be('user')
end)

test('agent and UI keys are separate: two agents and a crafted UI key use one key text', function()
  local alice, bob = agent('alice'), agent('bob')
  local s, root = workspace()
  capture(alice, s)
  alice:call('templates.save', {name = 'k-alice', root = root, session_id = s, key = 'shared'})
  bob:call('templates.save', {name = 'k-bob', root = root, session_id = s, key = 'shared'})
  -- A UI key that spells an agent key is a different operation.
  user:command('save_template', {session = s, block = first_block(s)})
  local form = user:view('/forms/save', nil, s)
  local values = form_input(form:render(), 'save_template')
  values.name, values.root = 'k-user', root
  expect(form:action('save_template', 'submit', {values = values}, 'agent/5alice6shared').status).to_be('succeeded')
  local names = {}
  for _, t in ipairs(alice:call('templates.list', {}).templates) do names[t.name] = t.saved_by end
  expect(names['k-alice']).to_be('alice')
  expect(names['k-bob']).to_be('bob')
  expect(names['k-user']).to_be('user')
end)

test('delete: an agent deletes only its own templates; the user deletes any', function()
  local alice, bob = agent('alice'), agent('bob')
  local s, root = workspace()
  capture(alice, s)
  alice:call('templates.save', {name = 'd-alice', root = root, session_id = s, key = 'd1'})
  alice:call('templates.save', {name = 'd-alice-2', root = root, session_id = s, key = 'd2'})
  expect_error(function() bob:call('templates.delete', {template = 'd-alice', key = 'del-1'}) end, 'refused')
  expect(alice:call('templates.delete', {template = 'd-alice', key = 'del-1'})).to_equal({})
  expect(alice:call('templates.delete', {template = 'd-alice', key = 'del-1'})).to_equal({})
  local p = panel(s)
  local tree = p:render()
  expect(node(tree, 'templates').items[1].action.tool).to_be('templates.delete')
  expect(p:action('templates', 'delete', {item_id = 'd-alice-2'}, 'ui-del-1').status).to_be('succeeded')
  local list = alice:call('templates.list', {}).templates
  expect(find(list, 'name', 'd-alice')).to_be(nil)
  expect(find(list, 'name', 'd-alice-2')).to_be(nil)
end)

test('an agent start opens its tabs as the agent, with a grant; a retry gives the same run', function()
  local alice = agent('alice')
  local s, root = workspace()
  capture(alice, s)
  alice:call('templates.save', {name = 'st-agent', root = root, session_id = s, key = 'st-save'})
  local r = alice:call('templates.start', {template = 'st-agent', root = root, new_session = 'st agent', key = 'st-1'})
  expect(type(r.run_id)).to_be('string')
  expect(alice:call('templates.start', {template = 'st-agent', root = root, new_session = 'st agent', key = 'st-1'})).to_equal(r)
  expect_error(function() alice:call('templates.start', {template = 'st-agent', root = root, key = 'st-1'}) end, 'operation_conflict')
  local run = wait_run(alice, r.run_id, 'open')
  expect(run.by).to_be('alice')
  -- Both tabs are the agent's windows.
  local mine = 0
  for _, w in ipairs(alice:hub('hub.workers', {}).workers) do
    if w.session_id == run.session_id and w.parent == 'alice' then mine = mine + 1 end
  end
  expect(mine >= 2).to_be(true)
  local g = store('run/' .. r.run_id).value
  expect(type(g.grant_id)).to_be('string')
  -- The finished run gives its grant back.
  wait('the revoke of the grant', function() return store('run/' .. r.run_id).value.grant_revoked == true end, 20)
end)

test('the user starts through the form into a new session', function()
  local alice = agent('alice')
  local s, root = workspace()
  capture(alice, s)
  alice:call('templates.save', {name = 'st-user', root = root, session_id = s, key = 'stu-save'})
  user:command('start_session', {session = s, block = first_block(s)})
  local form = user:view('/forms/start', nil, s)
  local tree = form:render()
  expect(node(tree, 'start_session').submit_action.tool).to_be('templates.start')
  local values = form_input(tree, 'start_session')
  values.template, values.root, values.session_id = 'st-user', root, '@new'
  local done = form:action('start_session', 'submit', {values = values}, 'ui-start-1')
  expect(done.status).to_be('succeeded')
  local runs = alice:call('templates.runs', {}).runs
  local run = find(runs, 'template', 'st-user')
  expect(run.by).to_be('user')
  wait_run(alice, run.id, 'open')
end)

test('dismiss and retry: an agent acts on its own runs; the user on any', function()
  local alice, bob = agent('alice'), agent('bob')
  local s, root = workspace()
  capture(alice, s)
  alice:call('templates.save', {name = 'never', root = root, session_id = s, key = 'sk-save'})
  -- A session that does not exist blocks the first tab.
  local a = alice:call('templates.start', {template = 'never', root = root, session_id = 'session:00000000-0000-0000-0000-000000000000', key = 'sk-1'})
  wait_run(alice, a.run_id, 'blocked')
  expect_error(function() bob:call('templates.retry', {run_id = a.run_id, key = 'r1'}) end, 'refused')
  expect_error(function() bob:call('templates.dismiss', {run_id = a.run_id, key = 'x1'}) end, 'refused')
  local retried = alice:call('templates.retry', {run_id = a.run_id, key = 'r1'})
  expect(retried).to_equal({run_id = a.run_id, woken = true})
  expect(alice:call('templates.retry', {run_id = a.run_id, key = 'r1'})).to_equal(retried)
  expect(alice:call('templates.dismiss', {run_id = a.run_id, key = 'x1'})).to_equal({run_id = a.run_id, status = 'dismissed'})
  expect(alice:call('templates.dismiss', {run_id = a.run_id, key = 'x1'})).to_equal({run_id = a.run_id, status = 'dismissed'})
  -- The user: Retry and Dismiss rows of another agent's stuck run in the panel.
  local b = alice:call('templates.start', {template = 'never', root = root, session_id = 'session:00000000-0000-0000-0000-000000000000', key = 'sk-2'})
  wait_run(alice, b.run_id, 'blocked')
  local p = panel(s)
  local tree = p:render()
  local items = node(tree, 'stuck').items
  if type(items) ~= 'table' then error('panel: ' .. rex.json.encode(tree)) end
  local retry = find(items, 'id', 'retry:' .. b.run_id)
  expect(retry.action.tool).to_be('templates.retry')
  expect(find(items, 'id', 'dismiss:' .. b.run_id).action.tool).to_be('templates.dismiss')
  expect(p:action('stuck', 'retry', {item_id = 'retry:' .. b.run_id}, 'ui-r1').status).to_be('succeeded')
  expect(p:action('stuck', 'dismiss', {item_id = 'dismiss:' .. b.run_id}, 'ui-x1').status).to_be('succeeded')
  expect(run_of(alice, b.run_id).status).to_be('dismissed')
end)

test('only the hub calls the plugin; a forward of a name that is not exported is refused', function()
  local alice = agent('alice')
  expect_error(function() user:plugin_view('render', {route = '/panels/templates'}) end, 'refused')
  expect_error(function() alice:direct('hub.forward', {action = 'templates.list', args = {}, requester_pid = 1}) end, 'refused')
  expect_error(function() alice:direct('templates.list', {}) end, 'refused')
end)
