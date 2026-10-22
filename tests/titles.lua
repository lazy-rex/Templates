-- Launch titles (tests/templates-run.md, "Titles"). A save keeps the title that the caller of a
-- spawn requested (hub.spawn.spec requested_title, title_source request) as the leaf label, when the
-- pane keeps the profile that it ran. A resolved title (a profile name, a generated agent name) is
-- not saved. Pane renames and plain Rex panes are outside this scope. Needs a hub with
-- requested_title (LazyRex 03ef95f or later).

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')
local S = {n = 0} -- a table field (LazyRex docs/rex-protocol.md, "Rex Lua runtime")
local PROFILES = {profiles = {
  {id = 'server', name = 'Server', kind = 'accessory', command = {'/bin/sh', '-c', 'echo serving on $1; exec sleep 100000', 'server', '${port}'}, args = {{name = 'port', default = '3000'}}},
  {id = 'watcher', name = 'Watcher', kind = 'accessory', command = {'/bin/sleep', '100000'}},
  {id = 'bot', name = 'Bot', kind = 'agent', command = {'/bin/sleep', '100000'}}}}
local function leaf(launch, label) return {launch = launch, dir = '.', label = label} end
local function server(port, label) return leaf({profile = 'server', args = {port = port}}, label) end
local function hs(before, after) return {direction = 'horizontal', ratio = 0.5, before = before, after = after} end
-- The source template: API (server), no title (server), "Server" (server, equal to the profile
-- name), "Logs" (shell), no title (agent profile bot).
local SOURCE = {
  {title = 't1', layout = hs(server('1', 'API'), server('2'))},
  {title = 't2', layout = hs(server('3', 'Server'), leaf({shell = true}, 'Logs'))},
  {title = 't3', layout = leaf({profile = 'bot'})}}

-- started starts template name (written with tabs) as alice, and returns the session, its root and
-- the workers of its panes (block -> {profile, title}).
local function started(alice, name, tabs, root)
  S.n = S.n + 1
  W.twrite({{key = 'template/' .. W.hex(name), value = {v = 1, name = name, saved_by = 'user', tabs = tabs}}})
  local r = alice:call('templates.start', {template = name, root = root, key = name .. '-start-' .. S.n})
  W.wait_run(alice, r.run_id, 'open')
  local s = W.rec('run/' .. r.run_id).value.session_id
  local all, workers, by_title = {}, {}, {}
  for _, x in ipairs(alice:hub('hub.workers', {}).workers) do if x.block_id then all[x.block_id] = x end end
  for _, b in ipairs(W.blocks(s)) do
    local x = all[b.block_id]
    if x then
      workers[b.block_id] = x
      by_title[x.title] = by_title[x.title] or b.block_id
    end
  end
  return s, workers, by_title
end
local function capture_of(alice, s)
  local out = {}
  for _, p in ipairs(alice:call('templates.capture', {session_id = s}).panes) do out[p.block_id] = p end
  return out
end
-- labels lists the leaf labels of a template in depth-first order (false for none).
local function labels(t)
  local out = {}
  local function walk(n)
    if n.direction then walk(n.before); walk(n.after) else out[#out + 1] = n.label or false end
  end
  for _, tab in ipairs(t.tabs) do walk(tab.layout) end
  return out
end

test('a round trip keeps requested titles only; a default and a generated agent name are not frozen', function()
  local alice = agent('alice')
  write_profiles(PROFILES)
  local _, root = W.workspace()
  local s, workers, by_title = started(alice, 'tt-src', SOURCE, root)
  -- The untitled agent pane has a generated title (profile name and a number).
  local bot
  for id, x in pairs(workers) do if x.profile == 'bot' then bot = x end end
  expect(bot.title).to_match('^Bot %d+$')
  -- A profile renamed after the spawn: its old default title must not look like a request.
  PROFILES.profiles[1].name = 'Server Renamed'
  write_profiles(PROFILES)
  local cap = capture_of(alice, s)
  local requested = {}
  for _, p in pairs(cap) do if p.requested_title then requested[#requested + 1] = p.requested_title end end
  table.sort(requested)
  expect(requested).to_equal({'API', 'Logs', 'Server'})
  alice:call('templates.save', {name = 'tt-saved', root = root, session_id = s, key = 'tt-saved'})
  local saved = W.template('tt-saved')
  expect(labels(saved)).to_equal({'API', false, 'Server', 'Logs', false})
  -- A second start: the requested titles come back; the untitled server pane gets the profile's
  -- current name, and the agent pane a new generated name.
  local _, workers2 = started(alice, 'tt-saved', saved.tabs, root)
  local titles, bots = {}, 0
  for _, x in pairs(workers2) do
    titles[#titles + 1] = x.title
    if x.profile == 'bot' then bots = bots + 1; expect(x.title).to_match('^Bot %d+$'); expect(x.title ~= bot.title).to_be(true) end
  end
  table.sort(titles)
  expect(bots).to_be(1)
  expect(#titles).to_be(5)
  expect(titles[1]).to_be('API')
  expect(titles[3]).to_be('Logs')
  expect(titles[4]).to_be('Server')
  expect(titles[5]).to_be('Server Renamed')
  PROFILES.profiles[1].name = 'Server'
  write_profiles(PROFILES)
end)

test('a busy shell spawn keeps its title only with an explicit Shell; another launch drops a title', function()
  local alice = agent('alice')
  write_profiles(PROFILES)
  local _, root = W.workspace()
  local s, _, by_title = started(alice, 'tt-busy', {{title = 't', layout = hs(leaf({shell = true}, 'Logs'), server('1', 'API'))}}, root)
  local logs, api = by_title['Logs'], by_title['API']
  local w, err = rex.call('com.superlogical.terminal.write', {session_id = s, block_id = logs, args = {data = 'sleep 600\r'}})
  expect(err).to_be(nil)
  wait('no shell guess', function() local p = capture_of(alice, s)[logs]; return p and p.guess == nil or nil end, 15)
  expect(capture_of(alice, s)[logs].requested_title).to_be('Logs')
  -- An explicit Shell keeps it; the API pane keeps its profile.
  alice:call('templates.save', {name = 'tt-busy-1', root = root, session_id = s, panes = {[logs] = 'shell'}, key = 'tt-busy-1'})
  expect(labels(W.template('tt-busy-1'))).to_equal({'Logs', 'API'})
  -- Another profile for each pane: no label.
  alice:call('templates.save', {name = 'tt-busy-2', root = root, session_id = s, panes = {[logs] = 'profile:watcher', [api] = 'profile:watcher'}, key = 'tt-busy-2'})
  expect(labels(W.template('tt-busy-2'))).to_equal({false, false})
  -- A skipped pane has no leaf.
  alice:call('templates.save', {name = 'tt-busy-3', root = root, session_id = s, panes = {[logs] = 'skip'}, key = 'tt-busy-3'})
  expect(labels(W.template('tt-busy-3'))).to_equal({'API'})
end)

test('the Save form shows the title of every spawned pane, also a shell', function()
  local alice = agent('alice')
  write_profiles(PROFILES)
  local _, root = W.workspace()
  local s, _, by_title = started(alice, 'tt-form', {{title = 't', layout = hs(leaf({shell = true}, 'Logs'), server('1', 'API'))}}, root)
  local form = W.open('save_template', '/forms/save', s)
  local function label(id) return W.field(form:render(), 'save_template', 'pane_' .. id).label end
  wait('the idle shell', function() return capture_of(alice, s)[by_title['Logs']].guess == 'shell' or nil end, 15)
  expect(label(by_title['Logs'])).to_match(' · Logs$')
  expect(label(by_title['API'])).to_match(' · API$')
  rex.call('com.superlogical.terminal.write', {session_id = s, block_id = by_title['Logs'], args = {data = 'sleep 600\r'}})
  wait('the busy shell', function() return capture_of(alice, s)[by_title['Logs']].guess == nil or nil end, 15)
  expect(label(by_title['Logs'])).to_match(' · Logs · running sleep$')
end)
