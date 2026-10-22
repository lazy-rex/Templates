-- Save and start sizes (tests/templates-run.md, "Save size"). A run record holds its template about
-- three times, so a template that its save accepts could be too large to start (engine admission,
-- MAX_RUN). The save measures four reference starts at its root and refuses such a template.
-- The boundary tests measure offline with the engine module (engine.measure, no database) to choose
-- their sizes, and then use the public paths.

local dir = H.args.file:match('^(.*)/')
local W = load_fixture(dir .. '/support/workspace.lua')
local Run = load_fixture(dir .. '/../templates_run.lua')
local offline = Run.new({hub = function(action) error('offline: ' .. action) end, start_tab = function() end,
  resolve_root = function(r) return r end, resolve_dir = function(root, d) return d == '.' and root or root .. '/' .. d end,
  now = function() return 0 end, after = function() end,
  data = setmetatable({}, {__index = function(_, name) return function() error('offline: data.' .. name) end end}),
  transaction = function() error('offline: transaction') end})
local function part(s) return #s .. ':' .. s end
local S = {n = 0} -- a table field (LazyRex docs/rex-protocol.md, "Rex Lua runtime")

-- server_pane makes a session of its own: a shell pane, and a server pane with the arg port =
-- value (hub.spawn placement), both in the home directory. It returns the session, the server
-- block and their directory.
local function server_pane(a, value)
  S.n = S.n + 1
  local home = W.real(W.HOME)
  local s = W.new_session('size-' .. S.n, {{window_label = 'sh', layout = W.sh(home, 'sh')}})
  local w = a:hub('hub.spawn', {profile = 'server', key = 'size-pane-' .. S.n, args = {port = value}, cwd = home, placement = {session = s}})
  local block = wait('the server pane', function()
    for _, x in ipairs(a:hub('hub.workers', {}).workers) do
      if x.spawn_id == w.spawn_id and x.block_id then return x.block_id end
    end
  end, 10)
  wait('the capture of ' .. s, function()
    local c = a:call('templates.capture', {session_id = s})
    local p = W.find(c.panes, 'block_id', block)
    return #c.panes == 2 and p and p.dir == home and p.guess == 'profile:server' or nil
  end, 20)
  return {session = s, block = block, dir = home}
end
-- reference measures a template as templates.lua start_size does: the largest of four references.
local function reference(t, root)
  local key, id = string.rep('<', Run.MAX_KEY), string.rep('<', Run.MAX_ID)
  local user_key, agent_key = 'start/' .. part(key), 'start/agent/' .. part(id) .. part(key)
  local session, placement = string.rep('x', Run.MAX_ID), {focus = {source_window_id = string.rep('x', Run.MAX_ID)}}
  local tpl = {v = t.v, name = t.name, tabs = t.tabs}
  local max = 0
  for _, r in ipairs({{key = user_key, new_session_name = t.name, placement = placement},
    {key = user_key, session_id = session, placement = placement},
    {key = agent_key, by = id, new_session_name = t.name}, {key = agent_key, by = id, session_id = session}}) do
    r.template, r.root = tpl, root
    max = math.max(max, offline.measure(r))
  end
  return max
end
-- lower measures a start with the shortest key and no by or placement: a real start is not smaller.
local function lower(t, root, name)
  return offline.measure({key = 'start/1:k', template = {v = t.v, name = t.name, tabs = t.tabs}, root = root, new_session_name = name or t.name})
end
-- with_port returns a copy of t with the server pane's port arg of n "&".
local function with_port(t, n)
  local c = rex.json.decode(rex.json.encode(t))
  for _, tab in ipairs(c.tabs) do
    local leaf = tab.layout
    if leaf.launch and leaf.launch.profile == 'server' then leaf.launch.args.port = string.rep('&', n) end
  end
  return c
end
local function sessions() return #rex.call('session.list', {}).sessions end

-- The defect (before the save check): templates.save accepted a template, and the start at the same
-- root was refused "too large to start" (a "&" is 6 bytes in JSON).
test('a template that cannot start at its save root is refused at save (agent path)', function()
  local alice = agent('alice')
  local pane = server_pane(alice, string.rep('&', 4000))
  local ok, err = pcall(alice.call, alice, 'templates.save', {name = 'size-big', root = pane.dir, session_id = pane.session, key = 'size-big'})
  if ok then
    -- Before the check: the start at the same root is refused.
    local sok, serr = pcall(alice.call, alice, 'templates.start', {template = 'size-big', root = pane.dir, key = 'size-big-start'})
    expect(sok).to_be(false)
    expect(serr.code).to_be('invalid_input')
    expect(serr.message).to_match('too large to start')
  end
  expect(ok).to_be(false)
  expect(err.code).to_be('invalid_input')
  expect(err.message).to_match('too large to start')
  expect(W.template(W.hex('size-big'))).to_be(nil)
  -- No save operation was saved: the same key saves another session.
  local small = server_pane(alice, 'small')
  expect(alice:call('templates.save', {name = 'size-big', root = small.dir, session_id = small.session, key = 'size-big'}).name).to_be('size-big')
end)

test('a template that cannot start at its save root is refused at save (form path)', function()
  local alice = agent('alice')
  local pane = server_pane(alice, string.rep('&', 4000))
  local form = W.open('save_template', '/forms/save', pane.session, pane.block)
  local values = W.form_input(form:render(), 'save_template')
  values.name, values.root = 'size-big-form', pane.dir
  values['pane_' .. pane.block] = 'profile:server'
  local op = form:action('save_template', 'submit', {values = values}, 'size-big-form')
  expect(op.status).to_be('failed')
  expect(op.error.code).to_be('invalid_input')
  expect(tostring(op.error.message)).to_match('too large to start')
  expect(W.template(W.hex('size-big-form'))).to_be(nil)
end)

-- The guarantee at its boundary: a template just under the save limit starts at its save root on
-- both paths. A start that breaks a condition can be refused at admission: a longer encoded root
-- (a), a longer encoded session name (c). The refusal makes no run, no session, no counter
-- change and no start form (admission writes the form in its transaction).
test('just under the save limit: it starts at its root; a longer root or name is refused at admission', function()
  local alice = agent('alice')
  -- Calibrate: the size of one "&" of the port arg, from the template that a small save writes.
  local small = server_pane(alice, '&')
  alice:call('templates.save', {name = 'size-cal', root = small.dir, session_id = small.session, key = 'size-cal'})
  local cal = W.template(W.hex('size-cal')).value
  local R = small.dir
  local per = reference(with_port(cal, 2), R) - reference(with_port(cal, 1), R)
  local n = 1 + math.floor((Run.MAX_RUN - reference(cal, R)) / per)
  expect(reference(with_port(cal, n), R) <= Run.MAX_RUN).to_be(true)
  expect(reference(with_port(cal, n + 1), R) > Run.MAX_RUN).to_be(true)
  -- The save path agrees: n + 1 is refused, n is saved.
  local over = server_pane(alice, string.rep('&', n + 1))
  expect_error(function()
    alice:call('templates.save', {name = 'size-over', root = over.dir, session_id = over.session, key = 'size-over'})
  end, 'invalid_input')
  local edge = server_pane(alice, string.rep('&', n))
  expect(edge.dir).to_be(R)
  alice:call('templates.save', {name = 'size-edge', root = R, session_id = edge.session, key = 'size-edge'})
  local t = W.template(W.hex('size-edge')).value
  expect(reference(t, R) <= Run.MAX_RUN).to_be(true)
  -- At the save root, both paths start it.
  local r = alice:call('templates.start', {template = 'size-edge', root = R, key = 'size-edge-a'})
  W.wait_run(alice, r.run_id, 'open')
  local s = W.workspace()
  local form = W.open('start_session', '/forms/start', s)
  local values = W.form_input(form:render(), 'start_session')
  values.template, values.root, values.session_id = 'size-edge', R, '@new'
  local op = form:action('start_session', 'submit', {values = values}, 'size-edge-u')
  expect(op.status).to_be('succeeded')
  W.wait_run(alice, op.result.run_id, 'open')
  -- (a) A longer encoded root: three directories of 200 "<" below R (6 bytes each in JSON).
  local long = R .. '/' .. string.rep('<', 200) .. '/' .. string.rep('<', 200) .. '/' .. string.rep('<', 200)
  W.mkdir(long)
  long = W.real(long)
  expect(lower(t, long) > Run.MAX_RUN).to_be(true)
  local counter, before = W.counter(), sessions()
  expect_error(function()
    alice:call('templates.start', {template = 'size-edge', root = long, key = 'size-edge-long'})
  end, 'invalid_input')
  expect(W.counter()).to_be(counter)
  expect(sessions()).to_be(before)
  -- The start form commits only with an admission: a refused start leaves none.
  expect(W.form(W.agent_start_key('alice', 'size-edge-long'))).to_be(nil)
  -- (c) A longer encoded session name than the template name, at R (user path).
  local name = string.rep('<', 1000)
  expect(lower(t, R, name) > Run.MAX_RUN).to_be(true)
  local form2 = W.open('start_session', '/forms/start', s)
  local values2 = W.form_input(form2:render(), 'start_session')
  values2.template, values2.root, values2.session_id, values2.session_name = 'size-edge', R, '@new', name
  local refused = form2:action('start_session', 'submit', {values = values2}, 'size-edge-name')
  expect(refused.status).to_be('failed')
  expect(tostring(refused.error.message)).to_match('too large to start')
  expect(W.counter()).to_be(counter)
  expect(sessions()).to_be(before)
  expect(W.form(W.start_key('size-edge-name'))).to_be(nil)
end)

-- A saved save operation answers before the size check: the replay returns the saved result.
test('a saved save operation replays before the size check', function()
  local alice = agent('alice')
  local pane = server_pane(alice, 'small')
  local first = alice:call('templates.save', {name = 'size-replay', root = pane.dir, session_id = pane.session, key = 'size-replay'})
  -- The template exists now: a new save would get conflict. The replay returns the saved result.
  local again = alice:call('templates.save', {name = 'size-replay', root = pane.dir, session_id = pane.session, key = 'size-replay'})
  expect(again).to_equal(first)
end)
