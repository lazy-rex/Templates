-- The Plugin SDK. The SDK registers the plugin and dispatches the hub calls. Templates keeps every
-- record in SQL (templates_sql.lua): no hub.store call. An agent can call an export directly: the
-- SDK identifies it from the requester PID that Rex gives.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')

-- sql_only_after checks the plugin's hub calls after seq base (the complete record: no call
-- dropped): no hub.store call, and no call other than hub.sql while a transaction is open (from
-- hub.sql.begin to its commit or rollback; Rex Lua runs one handler at a time, so a call in that
-- interval is a call of the handler that holds the transaction). It returns the number of hub.sql
-- calls and the number of transactions.
local function sql_only_after(base)
  local list, out = calls('', {after = base})
  expect(out.dropped).to_be(false)
  local bad, n, txs, open = {}, 0, 0, false
  for _, c in ipairs(list) do
    if c.action:sub(1, 8) == 'hub.sql.' then
      n = n + 1
      if c.action == 'hub.sql.begin' then open, txs = true, txs + 1 end
      if c.action == 'hub.sql.commit' or c.action == 'hub.sql.rollback' then open = false end
    else
      if c.action:sub(1, 10) == 'hub.store.' then bad[#bad + 1] = c.action end
      if open then bad[#bad + 1] = c.action .. ' in a transaction' end
    end
  end
  expect(bad).to_equal({})
  return n, txs
end

test('every record uses SQL only, with no other hub call in a transaction: agent actions, starts, a dismiss, a retry, the panel and the Save form', function()
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
  expect(alice:call('templates.retry', {run_id = r.run_id, key = 'sdk-retry'}).woken).to_be(false)
  expect_error(function() alice:call('templates.dismiss', {run_id = r.run_id, key = 'sdk-dismiss'}) end, 'conflict')
  W.panel(s):render()
  local form = W.open('save_template', '/forms/save', s)
  local values = W.form_input(form:render(), 'save_template')
  values.name, values.root = 'sdk-u', root
  expect(form:action('save_template', 'submit', {values = values}, 'sdk-ui-save').status).to_be('succeeded')
  alice:call('templates.delete', {template = 'sdk-a', key = 'sdk-del'})
  local n, txs = sql_only_after(base.next)
  expect(n > 0 and txs > 0).to_be(true)
end)

test('a direct call and a forwarded call of one agent share its keys; an unknown peer is refused', function()
  local alice = agent('alice')
  W.put_template(W.hex('sdk-d'), {v = 1, name = 'sdk-d', saved_by = 'user',
    tabs = {{title = 'one', layout = {launch = {shell = true}, dir = '.'}}}})
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
