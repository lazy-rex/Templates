-- The Save form checks each directory once per render (templates.lua, dir_memo and with_dir_memo).
-- Panes that share a directory share one realpath and one git check. Nothing is kept after the
-- render: each render, templates.capture and the submit check again. These tests guard the output
-- and the freshness; the process count is not observable here (tests/templates-run.md, "Save form
-- renders").

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')
local S = {n = 0} -- a table field (LazyRex docs/rex-protocol.md, "Rex Lua runtime")
local function sh(...) local r = rex.exec({'/bin/sh', '-c', ...}, {}); if not r.ok then error(r.stderr) end end
local function dir(name)
  S.n = S.n + 1
  local d = W.HOME .. '/' .. name .. '-' .. S.n
  W.mkdir(d)
  return W.real(d)
end
-- labels returns the pane field labels of a Save form tree, in order.
local function labels(tree)
  local out = {}
  for _, f in ipairs(node(tree, 'save_template').fields) do
    if f.id:sub(1, 5) == 'pane_' then out[#out + 1] = f.label end
  end
  return out
end
local function has(label, path) return label:find(path, 1, true) ~= nil end
local function capture_dirs(a, s)
  local out = {}
  for _, p in ipairs(a:call('templates.capture', {session_id = s}).panes) do out[#out + 1] = p.dir or false end
  return out
end

test('panes that share a directory, a symlink and a pane outside the repository: same directories and root', function()
  local alice = agent('alice')
  local repo = dir('dd-repo')
  W.mkdir(repo .. '/a', repo .. '/b')
  sh('git init -q "$0" && ln -s a "$0/lnk"', repo)
  local s = W.new_session('dd-shared', {
    {window_label = 'one', layout = W.HS(0.5, W.sh(repo .. '/a'), W.sh(repo .. '/a'))},
    {window_label = 'two', layout = W.HS(0.5, W.sh(repo .. '/lnk'), W.sh(repo .. '/b'))}})
  W.capture(alice, s, 4)
  expect(capture_dirs(alice, s)).to_equal({repo .. '/a', repo .. '/a', repo .. '/a', repo .. '/b'})
  local form = W.open('save_template', '/forms/save', s)
  local tree = form:render()
  expect(W.field(tree, 'save_template', 'root').value).to_be(repo)
  local l = labels(tree)
  expect(#l).to_be(4)
  for i, want in ipairs({'/a', '/a', '/a', '/b'}) do
    expect(has(l[i], 'dd-repo-' .. (S.n) .. want)).to_be(true)
  end
  -- A pane outside the repository: the root is the deepest common parent, not the repository.
  local outside = dir('dd-outside')
  local s2 = W.new_session('dd-outside', {{window_label = 'one', layout = W.HS(0.5, W.sh(repo .. '/a'), W.sh(outside))}})
  W.capture(alice, s2, 2)
  local tree2 = W.open('save_template', '/forms/save', s2):render()
  expect(W.field(tree2, 'save_template', 'root').value).to_be(W.real(W.HOME))
  local l2 = labels(tree2)
  expect(has(l2[1], '/a')).to_be(true)
  expect(has(l2[2], outside:match('[^/]+$'))).to_be(true)
end)

test('a pane that changes its directory: the next render shows the new directory', function()
  local alice = agent('alice')
  local d = dir('dd-move')
  W.mkdir(d .. '/sub')
  local s = W.new_session('dd-move', {{window_label = 'one', layout = W.HS(0.5, W.sh(d),
    W.ish(d, 'mover', 'while [ ! -e ' .. d .. '/flag ]; do sleep 0.1; done; cd ' .. d .. '/sub; sleep 600'))}})
  wait('both directories', function() local c = capture_dirs(alice, s); return #c == 2 and c[2] == d or nil end, 20)
  local form = W.open('save_template', '/forms/save', s)
  expect(has(labels(form:render())[2], d .. '/sub')).to_be(false)
  sh('touch "$0/flag"', d)
  wait('the move', function() return capture_dirs(alice, s)[2] == d .. '/sub' or nil end, 20)
  expect(has(labels(form:render())[2], d:match('[^/]+$') .. '/sub')).to_be(true)
end)

test('a directory that becomes a git repository: the next render has the repository root', function()
  local alice = agent('alice')
  local d = dir('dd-git')
  W.mkdir(d .. '/a/x')
  local s = W.new_session('dd-git', {{window_label = 'one', layout = W.HS(0.5, W.sh(d .. '/a'), W.sh(d .. '/a/x'))}})
  W.capture(alice, s, 2)
  local form = W.open('save_template', '/forms/save', s)
  expect(W.field(form:render(), 'save_template', 'root').value).to_be(d .. '/a')
  sh('git init -q "$0"', d)
  expect(W.field(form:render(), 'save_template', 'root').value).to_be(d)
end)

-- A render that fails after it checked a directory leaves no memo: templates.capture and the next
-- render resolve the path again. The pane reports a symlink with OSC 7 (terminal.pwd), so the path
-- stays the same while its target changes.
test('a failed render leaves no memo: the next capture and render resolve the path again', function()
  local alice = agent('alice')
  local d = dir('dd-fail')
  W.mkdir(d .. '/x', d .. '/y')
  sh('ln -s x "$0/link"', d)
  local link = d .. '/link'
  local s = W.new_session('dd-fail', {{window_label = 'one',
    layout = W.ish(d, 'osc', "printf '\\033]7;file://localhost%s\\007' '" .. link .. "'; sleep 600")}})
  wait('the reported directory', function() return capture_dirs(alice, s)[1] == d .. '/x' or nil end, 20)
  local form = W.open('save_template', '/forms/save', s)
  expect(has(labels(form:render())[1], d:match('[^/]+$') .. '/x')).to_be(true)
  -- session_label (hub.session.list) runs after capture checked the directory. A gate refuses
  -- every such call until its release, so a render that the hub starts by itself cannot take the
  -- fault in place of this one.
  local id = fault({point = 'action', action = 'hub.session.list', when = 'before', mode = 'gate'})
  local failed = form:try_render()
  expect(failed.status).to_be('failed')
  expect(fault_fired(id)).to_be(true)
  H.fault_release(id)
  sh('ln -sfn y "$0/link"', d)
  expect(capture_dirs(alice, s)[1]).to_be(d .. '/y')
  expect(has(labels(form:render())[1], d:match('[^/]+$') .. '/y')).to_be(true)
end)
