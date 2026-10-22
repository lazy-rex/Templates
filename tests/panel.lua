-- The Templates panel: templates, recent starts and stuck starts; delete and dismiss.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')

test('C a retried delete keeps a newer template with the same name', function()
  local alice = agent('alice')
  local s, root = W.workspace()
  W.capture(alice, s)
  alice:call('templates.save', {name = 'web', root = root, session_id = s, key = 'c-save-1'})
  expect(alice:call('templates.delete', {template = 'web', key = 'c-delete'})).to_equal({})
  alice:call('templates.save', {name = 'web', root = root, session_id = s, key = 'c-save-2'})
  expect(alice:call('templates.delete', {template = 'web', key = 'c-delete'})).to_equal({})
  expect(W.template(W.hex('web'))).not_to_be(nil)
  -- The user's delete in the panel (the menu, then the confirmation) also commits with its result.
  expect(W.ui_delete(s, 'web', 'c-ui-delete').status).to_be('succeeded')
  expect(W.template(W.hex('web'))).to_be(nil)
end)

-- D: 55 runs: the oldest is stuck (an agent's start that has no grant: it dispatches nothing),
-- and 54 newer ones are open. The stuck one stays listed with Dismiss.
test('D an old stuck start stays listed with Dismiss behind 54 newer starts, and dismisses', function()
  local s = W.workspace()
  local root = W.real(W.HOME)
  local runs = {}
  for i = 900, 954 do
    local run = {id = tostring(i), status = i == 900 and 'authorizing' or 'open', next_tab = i == 900 and 1 or 2,
      tabs = {{key = 'templates/' .. i .. '/tab/1', title = 'x', layout = {shell = true, cwd = root}}}, root = root,
      request = {key = 'k' .. i, root = root, new_session_name = 't' .. i, template = {v = 1, name = 't' .. i, tabs = {}}},
      results = {}, session_key = 'templates/' .. i .. '/session'}
    if i == 900 then run.request.by = 'alice' end
    runs[#runs + 1] = run
  end
  W.put_runs(runs)
  local p = W.panel(s)
  local tree = p:render()
  local stuck = node(tree, 'stuck').items
  expect(#stuck).to_be(1)
  expect(stuck[1].id).to_be('dismiss:900')
  expect(stuck[1].action.name).to_be('dismiss')
  local recent = node(tree, 'runs').items
  expect(#recent).to_be(10)
  expect(recent[1].id).to_be('954')
  for _, item in ipairs(recent) do expect(item.action).to_be(nil) end
  expect(p:action('stuck', 'dismiss', {item_id = 'dismiss:900'}, 'd-dismiss').status).to_be('succeeded')
  expect(W.run('900').value.status).to_be('dismissed')
end)
