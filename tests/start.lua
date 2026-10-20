-- Start Session: the form, the new session's tabs and panes, replays, the focus in an existing
-- session, nested layouts, and the Rex layout contract that the starts depend on.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')

local function view(s) return rex.call('session.view', {session_id = s}) end
local function cwd(s, block)
  local p = rex.call('com.superlogical.terminal.process', {session_id = s, block_id = block, args = {}})
  return p and p.child and p.child.cwd
end
local function tiled(window)
  for _, l in ipairs(window.layers) do if l.kind == 'tiled' then return l.layout end end
end
-- A template saved from repo A: tab code = api | web (0.4), tab logs = web over the root (0.5),
-- whose second pane runs the profile server.
local count = {t = 0} -- a table field (LazyRex docs/rex-protocol.md, "Rex Lua runtime")
local function template(alice)
  count.t = count.t + 1
  local t = count.t
  local A = W.repo('start-a' .. t)
  local s = W.new_session('start-src' .. t, {
    {window_label = 'code', layout = W.HS(0.4, W.sh(A .. '/api', 'api'), W.sh(A .. '/web', 'web'))},
    {window_label = 'logs', layout = W.VS(0.5, W.sh(A .. '/web', 'log'), W.sh(A, 'srv'))}})
  W.capture(alice, s, 4)
  local panes = {}
  panes[W.block_by_label(s, 'srv')] = 'profile:server'
  local name = 'start-' .. t
  alice:call('templates.save', {name = name, root = A, session_id = s, panes = panes, key = 'start-save-' .. t})
  return name
end
-- other: a session in repo B with one idle shell in B/web.
local function other(label)
  local B = W.repo(label)
  local O = W.new_session(label, {{window_label = 'b', layout = W.sh(B .. '/web', 'b')}})
  return O, B
end

test('lab 2 lab 3 a start from repo B: the root defaults to B; the new session has the saved tabs under B', function()
  local alice = agent('alice')
  local name = template(alice)
  local O, B = other('start-b1')
  rex.sleep(0.5)
  local form = W.open('start_session', '/forms/start', O, W.block_by_label(O, 'b'))
  local values = W.form_input(form:render(), 'start_session')
  expect(values.root).to_be(B)
  values.template, values.session_id = name, '@new'
  local op = form:action('start_session', 'submit', {values = values}, 'lab2-start')
  expect(op.status).to_be('succeeded')
  local run = W.wait_run(alice, op.result.run_id, 'open')
  expect(run.root).to_be(B)
  local N = run.session_id
  local nv = wait('both tabs', function() local v = view(N); return #v.windows == 2 and v or nil end, 20)
  expect(nv.windows[1].label).to_be('code')
  expect(nv.windows[2].label).to_be('logs')
  local code, logs = tiled(nv.windows[1]), tiled(nv.windows[2])
  expect(code.split.direction).to_be('horizontal')
  expect(code.split.ratio).to_be(0.4)
  expect(logs.split.direction).to_be('vertical')
  expect(logs.split.ratio).to_be(0.5)
  wait('the pane directories under B', function()
    return cwd(N, code.split.before.block_id) == B .. '/api' and cwd(N, code.split.after.block_id) == B .. '/web'
      and cwd(N, logs.split.before.block_id) == B .. '/web' and cwd(N, logs.split.after.block_id) == B
  end, 20)
  -- The server pane runs its profile (default arg port 3000); the user owns the panes.
  local server
  for _, w in ipairs(alice:hub('hub.workers', {}).workers) do
    if w.block_id == logs.split.after.block_id then server = w end
  end
  expect(server.profile).to_be('server')
  -- It ran its profile with the default arg: the command prints "serving on 3000".
  wait('the server prints its default port', function()
    local screen = rex.call('com.superlogical.terminal.format', {session_id = N, block_id = server.block_id, args = {format = 'text'}})
    return screen and rex.json.encode(screen):find('serving on 3000', 1, true)
  end, 15)
  -- lab 3: the run is in the panel's recent starts, open.
  local p = W.panel(O)
  local item = W.find(node(p:render(), 'runs').items, 'id', run.id)
  expect(item.detail).to_match('^open · 2/2 tabs')
end)

test('B a start replays the same run after its template was deleted', function()
  local alice = agent('alice')
  local name = template(alice)
  local _, B = other('start-b2')
  local first = alice:call('templates.start', {template = name, root = B, key = 'b-start'})
  expect(alice:call('templates.delete', {template = name, key = 'b-delete'})).to_equal({})
  expect(alice:call('templates.start', {template = name, root = B, key = 'b-start'})).to_equal(first)
  W.wait_run(alice, first.run_id, 'open')
end)

test('lab 5 a start into this session gives the first new tab the focus; no switch', function()
  local alice = agent('alice')
  local name = template(alice)
  local O, B = other('start-b3')
  rex.sleep(0.5)
  local before = #view(O).windows
  local form = W.open('start_session', '/forms/start', O, W.block_by_label(O, 'b'))
  local values = W.form_input(form:render(), 'start_session')
  values.template, values.session_id = name, O
  expect(form:action('start_session', 'submit', {values = values}, 'lab5-start').status).to_be('succeeded')
  local v = wait('two new tabs', function() local x = view(O); return #x.windows == before + 2 and x or nil end, 20)
  local code
  for _, w in ipairs(v.windows) do if w.label == 'code' then code = w end end
  expect(v.active_window_id).to_be(code.window_id)
  expect(code.focused_block_id).to_be(tiled(code).split.before.block_id)
  expect(W.switch_record('lab5-start')).to_be(nil)
end)

test('a nested layout starts with its ratios, its leaf order and each leaf\'s directory', function()
  local alice = agent('alice')
  local R = W.repo('nested')
  W.mkdir(R .. '/a', R .. '/b', R .. '/c', R .. '/d')
  local s = W.new_session('nested-src', {{window_label = 'nested', layout = W.HS(0.3,
    W.VS(0.6, W.sh(R .. '/a', 'a'), W.sh(R .. '/b', 'b')), W.VS(0.4, W.sh(R .. '/c', 'c'), W.sh(R .. '/d', 'd')))}})
  W.capture(alice, s, 4)
  alice:call('templates.save', {name = 'nested', root = R, session_id = s, key = 'nested-save'})
  local r = alice:call('templates.start', {template = 'nested', root = R, key = 'nested-start'})
  local run = W.wait_run(alice, r.run_id, 'open')
  local nv = view(run.session_id)
  local layout = tiled(nv.windows[1])
  expect(layout.split.ratio).to_be(0.3)
  expect(layout.split.before.split.direction).to_be('vertical')
  expect(layout.split.before.split.ratio).to_be(0.6)
  expect(layout.split.after.split.ratio).to_be(0.4)
  local leaves = {layout.split.before.split.before, layout.split.before.split.after, layout.split.after.split.before, layout.split.after.split.after}
  wait('each leaf in its directory', function()
    for i, d in ipairs({'a', 'b', 'c', 'd'}) do if cwd(run.session_id, leaves[i].block_id) ~= R .. '/' .. d then return nil end end
    return true
  end, 20)
end)

-- The Rex contract under hub.spawn_window: one new_window
-- creates a nested layout with depth-first block IDs, its ratios and each leaf's cwd. An invalid
-- leaf leaves no block and no window.
test('Rex contract: session.new_window keeps a nested layout; an invalid leaf creates nothing', function()
  local R = W.real(W.HOME)
  W.mkdir(R .. '/la', R .. '/lb', R .. '/lc')
  local dirs = {a = R .. '/la', b = R .. '/lb', c = R .. '/lc', d = R .. '/la'}
  local function leaf(label) return W.direct(dirs[label], label) end
  local s = W.new_session('layout-contract', {{window_label = 'first', layout = W.sh(R)}})
  local layout = W.HS(0.3, W.VS(0.6, leaf('a'), leaf('b')), W.VS(0.4, leaf('c'), leaf('d')))
  local created = rex.call('session.new_window', {session_id = s, window_label = 'nested', layout = layout, focus = false})
  expect(#created.block_ids).to_be(4)
  local window
  for _, w in ipairs(view(s).windows) do if w.window_id == created.window_id then window = w end end
  local seen = {index = 0} -- a table field (LazyRex docs/rex-protocol.md, "Rex Lua runtime")
  local function compare(want, got)
    if want.block then seen.index = seen.index + 1; expect(got.block_id).to_be(created.block_ids[seen.index]); return end
    expect(got.split.direction).to_be(want.split.direction)
    expect(got.split.ratio).to_be(want.split.ratio)
    compare(want.split.before, got.split.before)
    compare(want.split.after, got.split.after)
  end
  compare(layout, tiled(window))
  for i, l in ipairs({'a', 'b', 'c', 'd'}) do
    local b
    for _, x in ipairs(W.blocks(s)) do if x.block_id == created.block_ids[i] then b = x end end
    expect(b.label).to_be(l)
    expect(cwd(s, created.block_ids[i])).to_be(dirs[l])
  end
  local function block_set()
    local ids = {}
    for _, b in ipairs(W.blocks(s)) do ids[#ids + 1] = b.block_id end
    table.sort(ids)
    return ids
  end
  local before = block_set()
  local _, err = rex.call('session.new_window', {session_id = s, window_label = 'invalid',
    layout = W.HS(0.5, leaf('a'), {block = {flavor = 'invalid.templates.flavor'}})})
  expect(err ~= nil).to_be(true)
  expect(block_set()).to_equal(before)
  expect(#view(s).windows).to_be(2)
end)
