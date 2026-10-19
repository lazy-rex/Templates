-- The 64 KiB control-message bound on both start paths. A template is written directly (the
-- runner's write is also bounded), with the profile arg "port" of n bytes in each pane. For each
-- size, both paths have the same outcome (agent parity): the start opens, or admission refuses
-- it before anything is dispatched. A run never stays queued because its record outgrew the bound
-- (observed before the admission check: the session was made, no tab opened, and the run could
-- not be dismissed). Each result and the encoded sizes go to the runner log.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')

-- tpl: tabs tabs, each a vertical split of leaves panes; each pane's arg is n bytes (the hub
-- allows at most 16000 bytes for one arg).
local function tpl(name, tabs, leaves, n)
  local list = {}
  for i = 1, tabs do
    local layout
    for j = leaves, 1, -1 do
      local leaf = {launch = {profile = 'server', args = {port = string.rep(tostring(j % 10), n)}}, dir = '.'}
      layout = layout and {direction = 'vertical', ratio = 0.5, before = leaf, after = layout} or leaf
    end
    list[i] = {title = 'tab' .. i, layout = layout}
  end
  return {v = 1, name = name, saved_by = 'user', tabs = list}
end
local function size(v) return #rex.json.encode(v) end

local alice
-- settled waits up to 20 s until a run leaves queued, starting and authorizing, and returns its
-- status (also when it did not leave them).
local function settled(id)
  local ok, st = pcall(wait, 'run ' .. id .. ' settles', function()
    local r = W.run_of(alice, id)
    if r and r.status ~= 'queued' and r.status ~= 'starting' and r.status ~= 'authorizing' then return r.status end
    return nil
  end, 20)
  if ok then return st end
  local r = W.run_of(alice, id)
  return r and r.status or 'none'
end
local function try(tabs, leaves, n)
  local root = W.real(W.HOME)
  local name = 'big-' .. tabs .. '-' .. leaves .. '-' .. n
  local t = tpl(name, tabs, leaves, n)
  write({{key = 'template/' .. W.hex(name), value = t}})
  -- The user's start, from the Start form, into a new session.
  local s = W.workspace()
  local form = W.open('start_session', '/forms/start', s)
  local values = W.form_input(form:render(), 'start_session')
  values.template, values.root, values.session_id = name, root, '@new'
  local ui_id = W.next_run_id()
  local op = form:action('start_session', 'submit', {values = values}, 'ui-' .. name)
  local ui_status = op.status == 'succeeded' and settled(op.result.run_id) or ('admission ' .. op.status)
  local ui_ok = ui_status == 'open'
  local run = store('run/' .. ui_id).value
  -- The agent's start of the same template.
  local ok, r = pcall(alice.call, alice, 'templates.start', {template = name, root = root, key = 'agent-' .. name})
  local agent_status = ok and settled(r.run_id) or 'refused'
  local agent_ok = agent_status == 'open'
  local agent_run = ok and store('run/' .. r.run_id).value or nil
  print(string.format('limits: %d tab(s) x %d pane(s) x %d B: template %d B, run %s B; user %s, agent %s%s', tabs, leaves, n, size(t),
    run and tostring(size(run)) or '-', ui_status, agent_status,
    ok and '' or (' (' .. tostring(type(r) == 'table' and r.message or r) .. ')')))
  if not ui_ok then
    expect(ui_status).to_be('admission failed')
    expect(run).to_be(nil)
    expect(ok).to_be(false)
    expect(tostring(r.message)).to_match('too large to start')
  end
  expect(agent_ok).to_be(ui_ok)
  return ui_ok, agent_ok
end

test('near the 64 KiB bound both paths open, or both refuse at admission; no run stays queued', function()
  alice = agent('alice')
  local seen = {}
  for _, case in ipairs({{1, 1, 15000}, {1, 2, 9000}, {1, 2, 10000}, {1, 2, 11000}, {1, 3, 7000}, {3, 1, 6500}, {3, 1, 7500}}) do
    local ui_ok = try(case[1], case[2], case[3])
    seen[ui_ok and 'open' or 'failed'] = true
  end
  -- The sizes reach both sides of the bound.
  expect(seen.open).to_be(true)
  expect(seen.failed).to_be(true)
end)

-- The reviewer's case: the hub's refusal repeats an 18 000-byte profile name. The run stores a
-- bounded error, so it stays writable and ends blocked (it can be dismissed).
test('a long refusal from the hub is stored bounded; the run blocks and can be dismissed', function()
  local a = agent('alice')
  local name = 'long-profile'
  write({{key = 'template/' .. W.hex(name), value = {v = 1, name = name, saved_by = 'alice',
    tabs = {{title = 'one', layout = {launch = {profile = string.rep('z', 18000)}, dir = '.'}}}}}})
  local r = a:call('templates.start', {template = name, root = W.real(W.HOME), key = 'long-profile'})
  local run = W.wait_run(a, r.run_id, 'blocked')
  expect(#run.error <= 512).to_be(true)
  expect(run.error).to_match('…$')
  expect(a:call('templates.dismiss', {run_id = r.run_id, key = 'long-dismiss'}).status).to_be('dismissed')
end)

test('keys are bounded: a key over 200 bytes is refused before anything is written', function()
  local a = agent('alice')
  expect_error(function() a:call('templates.dismiss', {run_id = '1', key = string.rep('k', 201)}) end, 'invalid_input')
end)
