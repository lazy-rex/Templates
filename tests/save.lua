-- Save as Template: the capture, the form, the stored template, replays and profiles.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')

-- project: a session in a git repository. Tab "code": api | (web over busy), ratios 0.4 and 0.7.
-- Tab "logs": log (web) over tail (the root), ratio 0.5. busy is an interactive shell that runs
-- sleep in the foreground; tail runs sleep directly (not a shell).
local count = {p = 0} -- a table field (LazyRex docs/rex-protocol.md, "Rex Lua runtime")
local function project()
  count.p = count.p + 1
  local p = count.p
  local A = W.repo('repo-a' .. p)
  local s = W.new_session('proj' .. p, {
    {window_label = 'code', layout = W.HS(0.4, W.sh(A .. '/api', 'api'), W.VS(0.7, W.sh(A .. '/web', 'web'), W.ish(A, 'busy')))},
    {window_label = 'logs', layout = W.VS(0.5, W.sh(A .. '/web', 'log'), W.direct(A, 'tail'))}})
  -- Wait until the shells are idle and busy runs sleep.
  local alice = agent('alice')
  wait('the panes of ' .. s, function()
    local c = alice:call('templates.capture', {session_id = s})
    if #c.panes ~= 5 then return nil end
    local shells, busy = 0, false
    for _, pane in ipairs(c.panes) do
      if pane.guess == 'shell' then shells = shells + 1 end
      if pane.detail == 'running sleep' and pane.dir == A then busy = true end
    end
    return shells == 3 and busy or nil
  end, 20)
  return s, A
end
local function pane_field(s, label) return 'pane_' .. W.block_by_label(s, label) end

test('lab 1 the form: the git root, no form pane, shells guessed, other programs undecided', function()
  local s, A = project()
  local form = W.open('save_template', '/forms/save', s, W.block_by_label(s, 'api'))
  local tree = form:render()
  local values = W.form_input(tree, 'save_template')
  expect(values.root).to_be(A)
  local panes = 0
  for k in pairs(values) do if k:sub(1, 5) == 'pane_' then panes = panes + 1 end end
  expect(panes).to_be(5)
  expect(values['pane_' .. form.block]).to_be(nil)
  for _, l in ipairs({'api', 'web', 'log'}) do expect(values[pane_field(s, l)]).to_be('shell') end
  expect(values[pane_field(s, 'busy')]).to_be('@choose')
  expect(values[pane_field(s, 'tail')]).to_be('@choose')
  expect(W.field(tree, 'save_template', pane_field(s, 'tail')).label).to_match('running sleep')
end)

test('lab 1 a pane left undecided is refused; Leave out removes the pane and its split', function()
  local s, A = project()
  local form = W.open('save_template', '/forms/save', s, W.block_by_label(s, 'api'))
  local values = W.form_input(form:render(), 'save_template')
  local refused = form:action('save_template', 'submit', {values = values}, 'lab1-undecided')
  expect(refused.status).to_be('failed')
  expect(tostring(refused.error.message)).to_match('Choose a launch or Leave out for each pane')
  values[pane_field(s, 'busy')] = '@skip'
  values[pane_field(s, 'tail')] = 'profile:server'
  expect(form:action('save_template', 'submit', {values = values}, 'lab1-save').status).to_be('succeeded')
  expect(W.template(W.hex(values.name)).value).to_equal({v = 1, name = values.name, saved_by = 'user', tabs = {
    {title = 'code', layout = {direction = 'horizontal', ratio = 0.4, before = {launch = {shell = true}, dir = 'api'}, after = {launch = {shell = true}, dir = 'web'}}},
    {title = 'logs', layout = {direction = 'vertical', ratio = 0.5, before = {launch = {shell = true}, dir = 'web'}, after = {launch = {profile = 'server'}, dir = '.'}}}}})
end)

-- A default pane has one of two process shapes. The test accepts only these two:
-- - login (observed on macOS): the shell runs through login. The child (login) has no cwd, the
--   foreground shell has it. Without terminal.pwd, the directory comes from the foreground. The
--   child is not a shell, so the pane has no launch guess: the user chooses Shell.
-- - shell (observed on Linux, Rex 0.0.1792593189-g3f4a0a): the child is the shell itself, in the
--   foreground (the same pid, path and cwd). The pane is an idle shell, so it has the guess shell.
local SHELLS = {bash = true, zsh = true, sh = true, dash = true, fish = true}
local function shape_of(p)
  local c, f = p.child, p.foreground
  if not (c and f) then return nil end
  if c.name == 'login' and not c.cwd and f.cwd then return 'login' end
  if c.pid and c.pid == f.pid and c.path == f.path and c.cwd and c.cwd == f.cwd and SHELLS[c.name] then return 'shell' end
  return nil
end
test('a default pane has the directory of its foreground shell; a login child gives no launch guess', function()
  local alice = agent('alice')
  local root = W.repo('login-shell')
  local s = W.new_session('login-shell', {{window_label = 'shell', layout = W.login(root .. '/api')}})
  local b = W.first_block(s)
  local shape
  wait('the default shell', function()
    shape = shape_of(rex.call('com.superlogical.terminal.process', {session_id = s, block_id = b, args = {}}))
    return shape
  end, 10)
  local choice = ({login = '@choose', shell = 'shell'})[shape] -- the form value of the pane
  local pane = alice:call('templates.capture', {session_id = s}).panes[1]
  expect(pane.dir).to_be(root .. '/api')
  expect(pane.guess).to_be(shape == 'shell' and 'shell' or nil)
  expect(pane.detail).not_to_be('directory unknown')
  -- The form: the pane is undecided (login) or a shell (shell), not left out. An explicit Shell
  -- saves it.
  local form = W.open('save_template', '/forms/save', s, b)
  local values = W.form_input(form:render(), 'save_template')
  expect(values.root).to_be(root)
  expect(values['pane_' .. b]).to_be(choice)
  values.name, values['pane_' .. b] = 'login-form', 'shell'
  expect(form:action('save_template', 'submit', {values = values}, 'login-save').status).to_be('succeeded')
  expect(W.template(W.hex('login-form')).value.tabs).to_equal({{title = 'shell', layout = {launch = {shell = true}, dir = 'api'}}})
  -- The agent path: the same pane with an explicit shell.
  expect(alice:call('templates.save', {name = 'login-agent', root = root, session_id = s, panes = {[b] = 'shell'}, key = 'login-agent'}))
    .to_equal({name = 'login-agent'})
  -- The Start form's root default comes from the same directory (the git root of the source pane).
  local start = W.open('start_session', '/forms/start', s, b)
  expect(W.form_input(start:render(), 'start_session').root).to_be(root)
end)

-- A: the plugin replays a save (save_core, on both paths) after its source changed. Through the hub,
-- a UI key belongs to its view action: another form with the same key is refused by the hub, so
-- the UI replay is the hub's (the agent path tests the plugin's replay).
test('A a save replays after the source and the root changed; other content with the key conflicts', function()
  local alice = agent('alice')
  local s, root = W.workspace()
  W.capture(alice, s)
  local function form_values()
    local form = W.open('save_template', '/forms/save', s)
    local values = W.form_input(form:render(), 'save_template')
    values.name, values.root = 'replay-a', root
    return form, values
  end
  local form, values = form_values()
  expect(form:action('save_template', 'submit', {values = values}, 'a-save-1').status).to_be('succeeded')
  -- The agent path: the same key and content replay too.
  expect(alice:call('templates.save', {name = 'replay-a-agent', root = root, session_id = s, key = 'a-agent-1'})).to_equal({name = 'replay-a-agent'})
  -- The source changes: a pane closes and a directory goes away.
  local web
  for _, b in ipairs(W.blocks(s)) do
    if rex.call('com.superlogical.terminal.process', {session_id = s, block_id = b.block_id, args = {}}).child.cwd == root .. '/web' then web = b.block_id end
  end
  rex.call('block.close', {session_id = s, block_id = web})
  rex.exec({'rm', '-rf', root .. '/api'})
  expect(alice:call('templates.save', {name = 'replay-a-agent', root = root, session_id = s, key = 'a-agent-1'})).to_equal({name = 'replay-a-agent'})
  local again = W.open('save_template', '/forms/save', s)
  again:render()
  expect_error(function() again:action('save_template', 'submit', {values = values}, 'a-save-1') end, 'operation_conflict')
  expect_error(function() alice:call('templates.save', {name = 'other', root = root, session_id = s, key = 'a-agent-1'}) end, 'operation_conflict')
end)

test('E a pane whose profile was removed keeps every option and its own profile', function()
  local alice = agent('alice')
  local w = alice:hub('hub.spawn', {profile = 'watcher', key = 'e-watcher'})
  -- The callback returns the pane; it assigns no outer local (LazyRex docs/testing.md, "Waiting").
  local pane = wait('the watcher pane', function()
    for _, x in ipairs(alice:hub('hub.workers', {}).workers) do
      if x.spawn_id == w.spawn_id and x.block_id then return {block = x.block_id, session = x.session_id} end
    end
  end, 10)
  local block, session = pane.block, pane.session
  expect(W.find(alice:call('templates.capture', {session_id = session}).panes, 'block_id', block).guess).to_be('profile:watcher')
  write_profiles([[{"profiles": [{"id": "server", "name": "Server", "kind": "accessory", "command": ["/bin/sh", "-c", "exec sleep 100000"]}]}]])
  local form = W.open('save_template', '/forms/save', session, block)
  local field = W.field(form:render(), 'save_template', 'pane_' .. block)
  local options = {}
  for _, o in ipairs(field.options) do options[#options + 1] = o.value end
  expect(options[1]).to_be('@choose')
  expect(options[2]).to_be('@skip')
  expect(options[3]).to_be('shell')
  expect(options).to_contain('profile:server')
  expect(options[#options]).to_be('profile:watcher')
  expect(field.value).to_be('profile:watcher')
  alice:hub('hub.stop', {spawn_id = w.spawn_id})
end)
