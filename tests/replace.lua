-- Replace a saved template (tests/templates-run.md, "Replace"). An agent replaces exactly the
-- revision that templates.get gave (templates.save replace = rev, no read). The form's "Replace it"
-- replaces the record as it is at the submit (one read just before the batch). Without either, a
-- save keeps an existing template (conflict). A replay answers before the capture and every check.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')
local S = {n = 0} -- a table field (LazyRex docs/rex-protocol.md, "Rex Lua runtime")
local function part(s) return #s .. ':' .. s end

-- source makes a session in root with one tab of one idle shell, with the tab label title.
local function source(a, root, title)
  S.n = S.n + 1
  local s = W.new_session('rp-src-' .. S.n, {{window_label = title, layout = W.sh(root)}})
  W.capture(a, s, 1)
  return s
end
-- saved: a template saved by a from a fresh workspace (two tabs: code, logs). Returns its root.
local function saved(a, name)
  local s, root = W.workspace()
  W.capture(a, s)
  a:call('templates.save', {name = name, root = root, session_id = s, key = name .. '-save'})
  return root
end
local function key(name) return W.hex(name) end
local function titles(t)
  local out = {}
  for i, tab in ipairs(t.tabs) do out[i] = tab.title end
  return out
end
-- form_save submits the Save form of session s with name, root and replace (nil: the field is
-- left as the form gives it).
local function form_save(s, name, root, replace, op_key)
  local form = W.open('save_template', '/forms/save', s)
  local values = W.form_input(form:render(), 'save_template')
  values.name, values.root = name, root
  if replace ~= nil then values.replace = replace end
  return form:action('save_template', 'submit', {values = values}, op_key)
end

test('agent: templates.get gives rev; save with replace = rev replaces exactly that revision', function()
  local alice, bob = agent('alice'), agent('bob')
  local root = saved(alice, 'rp-a')
  local got = alice:call('templates.get', {template = 'rp-a'})
  expect(got.rev).to_be(W.template(key('rp-a')).rev)
  expect(titles(got.template)).to_equal({'code', 'logs'})
  local s = source(bob, root, 'solo')
  -- Without replace: the name is kept.
  local err = expect_error(function()
    bob:call('templates.save', {name = 'rp-a', root = root, session_id = s, key = 'rp-a-keep'})
  end, 'conflict')
  expect(tostring(err.message)).to_match('templates.get gives its rev')
  expect(W.template(key('rp-a')).rev).to_be(got.rev)
  -- With replace: new tabs and saved_by; a new rev.
  expect(bob:call('templates.save', {name = 'rp-a', root = root, session_id = s, replace = got.rev, key = 'rp-a-rep'})).to_equal({name = 'rp-a'})
  local again = alice:call('templates.get', {template = 'rp-a'})
  expect(titles(again.template)).to_equal({'solo'})
  expect(again.template.saved_by).to_be('bob')
  expect(again.rev ~= got.rev).to_be(true)
end)

test('agent: a stale rev (replaced or deleted since) and a name with no record give conflict', function()
  local alice = agent('alice')
  local root = saved(alice, 'rp-stale')
  local old = alice:call('templates.get', {template = 'rp-stale'}).rev
  local s = source(alice, root, 'solo')
  -- Replaced since the read.
  alice:call('templates.save', {name = 'rp-stale', root = root, session_id = s, replace = old, key = 'rp-stale-1'})
  local now = W.template(key('rp-stale'))
  local err = expect_error(function()
    alice:call('templates.save', {name = 'rp-stale', root = root, session_id = s, replace = old, key = 'rp-stale-2'})
  end, 'conflict')
  expect(tostring(err.message)).to_match('changed or was deleted after you read it')
  expect(W.template(key('rp-stale')).rev).to_be(now.rev)
  -- Deleted since the read.
  alice:call('templates.delete', {template = 'rp-stale', key = 'rp-stale-del'})
  expect_error(function()
    alice:call('templates.save', {name = 'rp-stale', root = root, session_id = s, replace = now.rev, key = 'rp-stale-3'})
  end, 'conflict')
  expect(W.template(key('rp-stale'))).to_be(nil)
  -- No record at all.
  expect_error(function()
    alice:call('templates.save', {name = 'rp-none', root = root, session_id = s, replace = '1', key = 'rp-none'})
  end, 'conflict')
  expect(W.template(key('rp-none'))).to_be(nil)
end)

test('agent: replace must be a canonical nonzero rev string', function()
  local alice = agent('alice')
  local root = saved(alice, 'rp-bad')
  local s = source(alice, root, 'solo')
  local before = W.template(key('rp-bad')).rev
  for i, bad in ipairs({'0', '00', '01', '', 'abc', '1a', ' 1', '-1', '1.0', '1' .. string.rep('0', 20), 5, true, {}}) do
    local ok, err = pcall(alice.call, alice, 'templates.save', {name = 'rp-bad', root = root, session_id = s, replace = bad, key = 'rp-bad-' .. i})
    expect(ok).to_be(false)
    expect(err.code == 'invalid_input' or err.code == 'bad_request').to_be(true)
  end
  expect(W.template(key('rp-bad')).rev).to_be(before)
end)

test('agent: a replay answers first; other args give operation_conflict; a lost reply after a recreation', function()
  local alice = agent('alice')
  local root = saved(alice, 'rp-replay')
  local rev = alice:call('templates.get', {template = 'rp-replay'}).rev
  local s = source(alice, root, 'solo')
  local args = {name = 'rp-replay', root = root, session_id = s, replace = rev, key = 'rp-replay-1'}
  local first = alice:call('templates.save', args)
  expect(alice:call('templates.save', args)).to_equal(first)
  local other = {name = 'rp-replay', root = root, session_id = s, replace = W.template(key('rp-replay')).rev, key = 'rp-replay-1'}
  expect_error(function() alice:call('templates.save', other) end, 'operation_conflict')
  -- A lost commit reply: the replacement committed and the agent got a transient error. Then the
  -- template was recreated. The retry returns the saved result and keeps the recreated template.
  local rev2 = W.template(key('rp-replay')).rev
  local args2 = {name = 'rp-replay', root = root, session_id = s, replace = rev2, key = 'rp-replay-2'}
  local inj = inject({match = {sql_commit_writes = 'templates'}, fail = 'reply lost by the test', fail_code = 'unavailable', after = true})
  expect_error(function() alice:call('templates.save', args2) end, 'unavailable')
  expect(injection(inj).consumed).to_be(1)
  W.put_template(key('rp-replay'), {v = 1, name = 'rp-replay', saved_by = 'user', tabs = {{title = 'recreated', layout = {launch = {shell = true}, dir = '.'}}}})
  expect(alice:call('templates.save', args2)).to_equal({name = 'rp-replay'})
  expect(titles(W.template(W.hex('rp-replay')).value)).to_equal({'recreated'})
end)

-- A save without replace has no replace in its fingerprint: a saved operation of that
-- fingerprint replays. The replay answers before the capture, so a source session or root that no
-- longer works does not matter.
test('a save operation without replace replays unchanged (agent and form)', function()
  local alice = agent('alice')
  -- Agent: save-agent-v1/ + canon{name, panes, root, session_id}, without replace.
  W.put_op({key = 'save/agent/' .. part('alice') .. part('rp-old-agent'),
    fingerprint = 'save-agent-v1/{4:names6:rp-old5:panes{}4:roots9:/old-root10:session_ids5:old-s}',
    result = {name = 'rp-old'}})
  expect(alice:call('templates.save', {name = 'rp-old', root = '/old-root', session_id = 'old-s', key = 'rp-old-agent'})).to_equal({name = 'rp-old'})
  -- Form: save-v2/ + session + the values of a form without the replace field. The values name no
  -- pane, so without the replay the save would fail (the session changed).
  local s = W.workspace()
  W.put_op({key = 'save/' .. part('rp-old-form'),
    fingerprint = 'save-v2/' .. part(s) .. part('name') .. part('rp-old-f') .. part('root') .. part('/old-root'),
    result = {close_form = true}})
  local form = W.open('save_template', '/forms/save', s)
  form:render()
  local op = form:action('save_template', 'submit', {values = {name = 'rp-old-f', root = '/old-root'}}, 'rp-old-form')
  expect(op.status).to_be('succeeded')
  expect(op.result).to_equal({close_form = true})
  expect(W.template(key('rp-old-f'))).to_be(nil)
end)

test('form: Keep it (the default) refuses an existing name; Replace it replaces; a new name saves', function()
  local alice = agent('alice')
  local root = saved(alice, 'rp-form')
  local before = W.template(key('rp-form'))
  local s = source(alice, root, 'solo')
  local tree = W.open('save_template', '/forms/save', s):render()
  local field = W.field(tree, 'save_template', 'replace')
  expect(field.value).to_be('keep')
  expect(#field.options).to_be(2)
  local kept = form_save(s, 'rp-form', root, nil, 'rp-form-keep')
  expect(kept.status).to_be('failed')
  expect(kept.error.code).to_be('conflict')
  expect(tostring(kept.error.message)).to_match('choose Replace it')
  expect(W.template(key('rp-form')).rev).to_be(before.rev)
  local done = form_save(s, 'rp-form', root, 'replace', 'rp-form-rep')
  expect(done.status).to_be('succeeded')
  expect(done.result).to_equal({close_form = true})
  expect(titles(W.template(W.hex('rp-form')).value)).to_equal({'solo'})
  expect(W.template(W.hex('rp-form')).value.saved_by).to_be('user')
  local fresh = form_save(s, 'rp-form-new', root, 'replace', 'rp-form-new')
  expect(fresh.status).to_be('succeeded')
  expect(titles(W.template(W.hex('rp-form-new')).value)).to_equal({'solo'})
end)

test('form: a replace value other than keep or replace is invalid_input', function()
  local alice = agent('alice')
  local root = saved(alice, 'rp-fbad')
  local before = W.template(key('rp-fbad')).rev
  local s = source(alice, root, 'solo')
  for i, bad in ipairs({'yes', '', 'Replace', 1, true}) do
    local op = form_save(s, 'rp-fbad', root, bad, 'rp-fbad-' .. i)
    expect(op.status).to_be('failed')
    expect(op.error.code).to_be('invalid_input')
  end
  expect(W.template(key('rp-fbad')).rev).to_be(before)
end)

-- The form's Replace it replaces the template as it is at the commit: one transaction reads and
-- writes it (templates.lua, save_core), so no change can come between the read and the write.
test('form: Replace it replaces the template as another writer left it, also after a delete', function()
  local alice = agent('alice')
  local root = saved(alice, 'rp-race')
  local s = source(alice, root, 'solo')
  local other = {v = 1, name = 'rp-race', saved_by = 'user', tabs = {{title = 'other', layout = {launch = {shell = true}, dir = '.'}}}}
  W.put_template(key('rp-race'), other)
  expect(form_save(s, 'rp-race', root, 'replace', 'rp-race-1').status).to_be('succeeded')
  expect(titles(W.template(W.hex('rp-race')).value)).to_equal({'solo'})
  W.delete_template(key('rp-race'))
  expect(form_save(s, 'rp-race', root, 'replace', 'rp-race-2').status).to_be('succeeded')
  expect(titles(W.template(W.hex('rp-race')).value)).to_equal({'solo'})
end)

-- server_pane: a session with a shell pane and a server pane with the arg port = value (as in
-- tests/save_size.lua).
local function server_pane(a, value)
  S.n = S.n + 1
  local home = W.real(W.HOME)
  local s = W.new_session('rp-size-' .. S.n, {{window_label = 'sh', layout = W.sh(home, 'sh')}})
  local w = a:hub('hub.spawn', {profile = 'server', key = 'rp-size-pane-' .. S.n, args = {port = value}, cwd = home, placement = {session = s}})
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
  return s, home
end

test('a replacement too large to start at its root is refused; the old template and rev stay', function()
  local alice = agent('alice')
  local small, home = server_pane(alice, 'small')
  alice:call('templates.save', {name = 'rp-big', root = home, session_id = small, key = 'rp-big-save'})
  local before = W.template(key('rp-big'))
  local big = server_pane(alice, string.rep('&', 4000))
  local err = expect_error(function()
    alice:call('templates.save', {name = 'rp-big', root = home, session_id = big, replace = before.rev, key = 'rp-big-agent'})
  end, 'invalid_input')
  expect(tostring(err.message)).to_match('too large to start')
  local op = form_save(big, 'rp-big', home, 'replace', 'rp-big-form')
  expect(op.status).to_be('failed')
  expect(tostring(op.error.message)).to_match('too large to start')
  local after = W.template(key('rp-big'))
  expect(after.rev).to_be(before.rev)
  expect(after.value).to_equal(before.value)
end)

-- Cross-feature checks: a delete confirmation of the old revision, and a running start.
test('a delete confirmation opened before a replacement cannot delete it; its form then has no submit', function()
  local alice = agent('alice')
  local root = saved(alice, 'rp-del')
  local s = W.workspace()
  local hx = W.hex('rp-del')
  local p = W.panel(s)
  p:render()
  expect(p:action('templates', 'open', {item_id = hx}, 'rp-del-open').status).to_be('succeeded')
  local menu = user:view('/forms/template/' .. hx, nil, s)
  menu:render()
  local rev = W.template(key('rp-del')).rev
  expect(menu:action('template_menu', 'delete', {item_id = 'delete'}, 'rp-del-menu').status).to_be('succeeded')
  local confirm = user:view('/forms/delete/' .. hx .. '/' .. rev, nil, s)
  confirm:render()
  alice:call('templates.save', {name = 'rp-del', root = root, session_id = source(alice, root, 'solo'), replace = rev, key = 'rp-del-rep'})
  local op = confirm:action('confirm', 'submit', {values = {}}, 'rp-del-submit')
  expect(op.status).to_be('failed')
  expect(op.error.code).to_be('conflict')
  expect(titles(W.template(W.hex('rp-del')).value)).to_equal({'solo'})
  local tree = confirm:render()
  expect(node(tree, 'changed')).not_to_be(nil)
  expect(node(tree, 'confirm')).to_be(nil)
end)

test('a running start keeps its frozen template after a replacement', function()
  local alice = agent('alice')
  local root = saved(alice, 'rp-run')
  -- The second tab fails once: the run is blocked after its first tab.
  local id = fault({point = 'action', action = 'hub.spawn_window', when = 'before', mode = 'fail', nth = 2})
  local r = alice:call('templates.start', {template = 'rp-run', root = root, key = 'rp-run-start'})
  W.wait_run(alice, r.run_id, 'blocked')
  expect(fault_fired(id)).to_be(true)
  local rev = alice:call('templates.get', {template = 'rp-run'}).rev
  alice:call('templates.save', {name = 'rp-run', root = root, session_id = source(alice, root, 'solo'), replace = rev, key = 'rp-run-rep'})
  expect(titles(W.template(W.hex('rp-run')).value)).to_equal({'solo'})
  alice:call('templates.retry', {run_id = r.run_id, key = 'rp-run-retry'})
  local run = W.wait_run(alice, r.run_id, 'open')
  local labels = {}
  for _, w in ipairs(rex.call('session.view', {session_id = W.run(r.run_id).value.session_id}).windows) do labels[#labels + 1] = w.label end
  expect(labels).to_equal({'code', 'logs'})
  expect(run.tabs).to_be(2)
end)
