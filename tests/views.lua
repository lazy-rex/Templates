-- The panel and the Start form stay under the 64 KiB reply bound of a plugin (LazyRex
-- docs/rex-protocol.md, "Rex Lua runtime": a client.reply over the bound never arrives). The whole
-- reply {tree = ...} is at most 48 KiB (VIEW_BUDGET in templates.lua); hidden starts, templates and
-- sessions are counted in a widget. Tests in this file share one hub: each one adds its own records.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')
local BUDGET = 48 * 1024
local function size(tree) return #rex.json.encode({tree = tree}) end

local function finished(status) return status == 'open' or status == 'failed' or status == 'closed' or status == 'dismissed' end
-- seed writes runs with the IDs from first to last and this status, each with an error of err_len
-- bytes, in writes of at most 40 KB (a runner request is at most 64 KiB).
local function seed(first, last, status, err_len)
  local root = W.real(W.HOME)
  local ops, n = {}, 0
  for i = first, last do
    local run = {id = tostring(i), status = status, next_tab = 1, root = root,
      tabs = {{key = 'templates/' .. i .. '/tab/1', title = 'x', layout = {shell = true, cwd = root}}},
      request = {key = 'view' .. i, root = root, session_id = 'session:none', template = {v = 1, name = 'view' .. i, tabs = {}}},
      results = {}, session_key = 'templates/' .. i .. '/session', error = string.rep('e', err_len or 0)}
    local cost = #rex.json.encode(run)
    if #ops > 0 and n + cost > 40000 then write(ops); ops, n = {}, 0 end
    ops[#ops + 1], n = {key = 'run/' .. i, value = run}, n + cost
  end
  if #ops > 0 then write(ops) end
end
local function count(n, one, many) return n .. ' ' .. (n == 1 and one or many) end
-- check_panel checks the size, the pairs of rows of each blocked start, and the exact hidden
-- counts against templates.runs (every run, read in pages). It returns the shown run IDs.
local function check_panel(a, tree)
  expect(size(tree) <= BUDGET).to_be(true)
  local shown, rows = {}, {}
  local stuck = node(tree, 'stuck')
  for _, item in ipairs(stuck and stuck.items or {}) do
    local kind, id = item.id:match('^(%a+):(%d+)$')
    rows[id] = rows[id] or {}
    rows[id][kind] = true
    shown[id] = true
  end
  local recent = node(tree, 'runs')
  for _, item in ipairs(recent and recent.items or {}) do shown[item.id] = true end
  local unfinished, done = 0, 0
  for _, r in ipairs(W.all_runs(a)) do
    if r.status == 'blocked' and shown[r.id] then
      expect(rows[r.id] and rows[r.id].retry and rows[r.id].dismiss).to_be(true)
    end
    if not shown[r.id] then
      if finished(r.status) then done = done + 1 else unfinished = unfinished + 1 end
    end
  end
  local more = node(tree, 'more_runs')
  if unfinished + done == 0 then
    expect(more).to_be(nil)
  else
    local parts = {}
    if unfinished > 0 then parts[#parts + 1] = count(unfinished, 'more unfinished start', 'more unfinished starts') end
    if done > 0 then parts[#parts + 1] = done .. ' more finished' .. (#parts == 0 and (done == 1 and ' start' or ' starts') or '') end
    expect(more.text).to_be(table.concat(parts, ', ') .. ': use templates.runs')
  end
  return shown
end

test('the panel opens with 300 blocked starts; it shows pairs of rows and counts the hidden starts', function()
  local a = agent('alice')
  local s = W.workspace()
  seed(3001, 3300, 'blocked', 150)
  seed(3301, 3320, 'open')
  local tree = W.panel(s):render()
  local shown = check_panel(a, tree)
  -- The newest blocked start is shown, and the oldest is hidden.
  expect(shown['3300']).to_be(true)
  expect(shown['3001']).to_be(nil)
end)

-- The budget ends inside a blocked start: its Retry row fits in the space left, but not with its
-- Dismiss row. The test finds such a state: it adds a newer pending start (one Dismiss row, shown
-- first) with an error of a new length until the space left after the stuck starts is at least the
-- size of a Retry row. The stuck starts come first in the budget, so the space left for them is
-- VIEW_BUDGET minus the skeleton (each omitted-count widget at its largest text, the template and
-- recent lists empty) minus the stuck rows.
local MAXT = '9999999999 more templates: use templates.list'
local MAXR = '9999999999 more unfinished starts, 9999999999 more finished: use templates.runs'
local function stuck_left(tree)
  local nodes, have = {}, {}
  for _, n in ipairs(tree.nodes) do
    have[n.id] = true
    if n.id == 'more_templates' then nodes[#nodes + 1] = {id = n.id, type = n.type, text = MAXT}
    elseif n.id == 'more_runs' then nodes[#nodes + 1] = {id = n.id, type = n.type, text = MAXR}
    elseif n.id == 'templates' or n.id == 'runs' then nodes[#nodes + 1] = {id = n.id, type = n.type, label = n.label, items = {}}
    else nodes[#nodes + 1] = n end
  end
  if not have.more_templates then nodes[#nodes + 1] = {id = 'more_templates', type = 'widget', text = MAXT} end
  if not have.stuck then nodes[#nodes + 1] = {id = 'stuck', type = 'list', label = 'Unfinished starts', items = {}} end
  if not have.runs then nodes[#nodes + 1] = {id = 'runs', type = 'list', label = 'Recent starts', items = {}} end
  if not have.more_runs then nodes[#nodes + 1] = {id = 'more_runs', type = 'widget', text = MAXR} end
  return BUDGET - size({title = tree.title, nodes = nodes})
end
test('a blocked start whose Retry row fits, but not with its Dismiss row, shows no row and is counted once', function()
  local a = agent('alice')
  local s = W.workspace()
  local found
  for step = 0, 60 do
    local tree = W.panel(s):render()
    local shown = check_panel(a, tree)
    local hidden
    for i = 3300, 3001, -1 do if not shown[tostring(i)] then hidden = tostring(i); break end end
    -- The last stuck rows are the Retry and Dismiss rows of the oldest shown blocked start; every
    -- blocked start has rows of the same sizes (IDs of 4 digits, equal texts).
    local items = node(tree, 'stuck').items
    local retry = #rex.json.encode(items[#items - 1]) + 1
    expect(items[#items - 1].id:match('^retry:')).not_to_be(nil)
    if hidden and stuck_left(tree) >= retry then found = hidden; break end
    seed(3400 + step, 3400 + step, 'pending', 1 + step * 37)
  end
  expect(found ~= nil).to_be(true)
end)

-- 300 templates with names of 60 "<" (360 bytes encoded each): their options are over 64 KiB.
test('the Start form opens with 300 long template names; the default is the first shown option', function()
  local a = agent('alice')
  local s = W.workspace()
  local ops, n = {}, 0
  for i = 1, 300 do
    local name = string.format('%03d', i) .. string.rep('<', 57)
    local value = {v = 1, name = name, saved_by = 'user', tabs = {{title = 't', layout = {launch = {shell = true}, dir = '.'}}}}
    local cost = #rex.json.encode(value) + 200
    if #ops > 0 and n + cost > 40000 then write(ops); ops, n = {}, 0 end
    ops[#ops + 1], n = {key = 'template/' .. W.hex(name), value = value}, n + cost
  end
  write(ops)
  local tree = W.open('start_session', '/forms/start', s):render()
  expect(size(tree) <= BUDGET).to_be(true)
  local field = W.field(tree, 'start_session', 'template')
  expect(#field.options < 300).to_be(true)
  expect(field.value).to_be(field.options[1].value)
  expect(field.value).to_be('001' .. string.rep('<', 57))
  local sessions = W.field(tree, 'start_session', 'session_id')
  expect(sessions.options[1].value).to_be('@new')
  local total = #rex.call('session.list', {}).sessions
  local hidden_t, hidden_s = 300 - #field.options, total - (#sessions.options - 1)
  local parts = {}
  if hidden_t > 0 then parts[#parts + 1] = count(hidden_t, 'more template', 'more templates') end
  if hidden_s > 0 then parts[#parts + 1] = count(hidden_s, 'more session', 'more sessions') end
  expect(node(tree, 'more_options').text).to_be(table.concat(parts, ' and ') .. ' are not in the lists: use templates.start.')
  -- The panel with these templates: its reply is bounded, and it counts the hidden templates.
  local panel = W.panel(s):render()
  expect(size(panel) <= BUDGET).to_be(true)
  local shown = #node(panel, 'templates').items
  local more = node(panel, 'more_templates')
  expect(more ~= nil).to_be(true)
  expect(more.text).to_be(count(300 - shown, 'more template', 'more templates') .. ': use templates.list')
  check_panel(a, panel)
end)

-- The waiting Start form re-renders with its options: the same bound applies.
test('the waiting Start form stays under the budget', function()
  local alice = agent('alice')
  local s, root = W.workspace()
  W.capture(alice, s)
  alice:call('templates.save', {name = 'aaa-wait', root = root, session_id = s, key = 'views-save-wait'})
  local form = W.open('start_session', '/forms/start', s)
  local values = W.form_input(form:render(), 'start_session')
  values.template, values.root, values.session_id = 'aaa-wait', root, '@new'
  local ap = app('views-app', {sessions = {s}})
  local id = W.next_run_id()
  local inj = inject({match = {updates = 'run/' .. id}, fail = 'held by the test', times = 'always'})
  local _, key = form:admit('action', {node_id = 'start_session', action = 'submit', input = {values = values}, operation_key = 'views-start-wait'})
  local tree = wait('the waiting form', function()
    local t = form:render()
    return node(t, 'starting') and t or nil
  end, 10)
  expect(size(tree) <= BUDGET).to_be(true)
  expect(node(tree, 'start_session').submit_action.enabled).to_be(false)
  expect(W.field(tree, 'start_session', 'template').options[1].value).to_be('001' .. string.rep('<', 57))
  form:settle(key, 20)
  cancel_injection(inj)
  ap:close()
end)
