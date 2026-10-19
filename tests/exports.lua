-- Agent exports and their UI actions: each flow runs on both paths (agent(...):call, the MCP path,
-- and the user's view). Owner rules, key namespaces and the grant of an agent's start.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')
local workspace, capture, first_block, panel, form_input, find, run_of, wait_run =
  W.workspace, W.capture, W.first_block, W.panel, W.form_input, W.find, W.run_of, W.wait_run

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
  expect(form:action('save_template', 'submit', {values = values}, 'agent/5:alice6:shared').status).to_be('succeeded')
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
  -- The retry queued the run; it blocks again (the session does not exist).
  wait_run(alice, a.run_id, 'blocked')
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
  wait_run(alice, b.run_id, 'blocked')
  expect(p:action('stuck', 'dismiss', {item_id = 'dismiss:' .. b.run_id}, 'ui-x1').status).to_be('succeeded')
  expect(run_of(alice, b.run_id).status).to_be('dismissed')
end)

test('only the hub calls the plugin; a forward of a name that is not exported is refused', function()
  local alice = agent('alice')
  expect_error(function() user:plugin_view('render', {route = '/panels/templates'}) end, 'refused')
  expect_error(function() alice:direct('hub.forward', {action = 'templates.list', args = {}, requester_pid = 1}) end, 'refused')
  expect_error(function() alice:direct('templates.list', {}) end, 'refused')
end)

-- The reviewer's cases (2da0f11 review). A template that alice saved, started into a session that
-- does not exist, so its first tab blocks.
local function seed_blocked()
  write({{key = 'template/726576696577', value = {v = 1, name = 'review', saved_by = 'alice',
    tabs = {{title = 'one', layout = {launch = {shell = true}, dir = '.'}}}}}})
end
local function blocked_args(key)
  return {template = 'review', root = H.args.lab .. '/home', session_id = 'session:00000000-0000-0000-0000-000000000000', key = key}
end

test('a retry whose reply was lost: the replay recovers the queued run and retries nothing twice', function()
  seed_blocked()
  local a = agent('alice')
  local r = a:call('templates.start', blocked_args('retry-start'))
  wait('blocked', function() return store('run/' .. r.run_id).value.status == 'blocked' end)
  rex.sleep(1)
  local run = store('run/' .. r.run_id).value
  run.error = 'the retry has not run'
  write({{key = 'run/' .. r.run_id, value = run}})
  with_injection({match = {op_prefix = 'retry/agent/'}, replay = true, fail = 'lost retry reply'}, 1, function()
    expect_error(function() a:call('templates.retry', {run_id = r.run_id, key = 'retry-lost'}) end, 'lost retry reply')
  end)
  expect(a:call('templates.retry', {run_id = r.run_id, key = 'retry-lost'}).woken).to_be(true)
  wait('the queued run ran', function()
    local v = store('run/' .. r.run_id).value
    return v.status == 'blocked' and v.error ~= 'the retry has not run'
  end, 20)
  -- The run is stuck again: a replay of the same retry does not dispatch it again.
  local stuck = store('run/' .. r.run_id)
  expect(a:call('templates.retry', {run_id = r.run_id, key = 'retry-lost'}).woken).to_be(true)
  rex.sleep(1)
  expect(store('run/' .. r.run_id).rev).to_be(stuck.rev)
end)

test('start refuses a key that two IDs of one agent used, after the identities merge', function()
  seed_blocked()
  local a, b = agent('alice'), agent('bob')
  a:report({kind = 'claude', conversation_id = 'review-alias'})
  local one = a:call('templates.start', blocked_args('both'))
  local two = b:call('templates.start', blocked_args('both'))
  expect(one.run_id).not_to_be(two.run_id)
  b:report({kind = 'claude', conversation_id = 'review-alias'})
  expect_error(function() b:call('templates.start', blocked_args('both')) end, 'conflict')
end)
