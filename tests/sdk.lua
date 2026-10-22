-- The Plugin SDK port (docs/sdk-port.md, "Stage 1" and "Stage 2"). The SDK registers the plugin
-- and dispatches the hub calls. Stage 2, slice 1 keeps the templates and the save and delete
-- operations in SQL (templates_sql.lua): no hub.store call reads or writes them after the import.
-- An agent can call an export directly: the SDK identifies it from the requester PID that Rex gives.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')

-- no_template_store_after checks the plugin's hub calls after seq base (the complete record: no
-- call dropped): no hub.store call names a template record or a save or delete operation. It
-- returns the number of hub.sql calls.
local function no_template_store_after(base)
  local list, out = calls('', {after = base})
  expect(out.dropped).to_be(false)
  local bad, n = {}, 0
  local function check(action, key)
    if type(key) == 'string' and (key:sub(1, 9) == 'template/' or key:match('^save/') or key:match('^delete/')) then
      bad[#bad + 1] = action .. ' ' .. key
    end
  end
  for _, c in ipairs(list) do
    local a = c.args or {}
    if c.action:sub(1, 8) == 'hub.sql.' then n = n + 1 end
    if c.action == 'hub.store.scan' then check(c.action, a.prefix or 'template/') end
    if c.action == 'hub.store.get' then for _, k in ipairs(a.keys or {}) do check(c.action, k) end end
    if c.action == 'hub.store.op' then check(c.action, a.key) end
    if c.action == 'hub.store.batch' then
      for _, op in ipairs(a.ops or {}) do check(c.action, op.key) end
      if a.op then check(c.action, a.op.key) end
    end
  end
  expect(bad).to_equal({})
  return n
end

test('templates and their operations use SQL only: agent actions, a start, the panel and the Save form', function()
  local alice = agent('alice')
  local s, root = W.workspace()
  local _, base = calls('')
  W.capture(alice, s)
  alice:call('templates.save', {name = 'sdk-a', root = root, session_id = s, key = 'sdk-save'})
  alice:call('templates.list', {})
  alice:call('templates.get', {template = 'sdk-a'})
  local r = alice:call('templates.start', {template = 'sdk-a', root = root, new_session = 'sdk a', key = 'sdk-start'})
  W.wait_run(alice, r.run_id, 'open')
  alice:call('templates.runs', {})
  W.panel(s):render()
  local form = W.open('save_template', '/forms/save', s)
  local values = W.form_input(form:render(), 'save_template')
  values.name, values.root = 'sdk-u', root
  expect(form:action('save_template', 'submit', {values = values}, 'sdk-ui-save').status).to_be('succeeded')
  alice:call('templates.delete', {template = 'sdk-a', key = 'sdk-del'})
  expect(no_template_store_after(base.next) > 0).to_be(true)
end)

test('a direct call and a forwarded call of one agent share its keys; an unknown peer is refused', function()
  local alice = agent('alice')
  W.twrite({{key = 'template/' .. W.hex('sdk-d'), value = {v = 1, name = 'sdk-d', saved_by = 'user',
    tabs = {{title = 'one', layout = {launch = {shell = true}, dir = '.'}}}}}})
  local first = alice:direct('templates.delete', {template = 'sdk-d', key = 'sdk-d1'})
  -- The template is gone, so only a replay of the direct call's result can answer the forward.
  expect(alice:call('templates.delete', {template = 'sdk-d', key = 'sdk-d1'})).to_equal(first)
  expect_error(function() alice:call('templates.delete', {template = 'sdk-other', key = 'sdk-d1'}) end, 'operation_conflict')
  -- The test runner is a local peer that is not an agent.
  local client = H.hub('hub.test.status', {}).plugins.templates.client_id
  expect_error(function() H.perform(client, 'templates.list', {}) end, 'refused')
  -- A requester PID in the arguments gives no identity: only the hub forwards.
  expect_error(function() alice:direct('hub.forward', {action = 'templates.list', args = {}, requester_pid = 1}) end, 'refused')
end)
