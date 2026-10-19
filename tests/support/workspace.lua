-- Shared helpers of the Templates tests (load_fixture). A source session has two tabs: "code"
-- splits two idle shells (api, web), "logs" has one shell in the root.
local W = {}
local HOME = H.args.lab .. '/home'

-- A source session: tab "code" splits two idle shells (api, web), tab "logs" has one (the root).
local function sh(cwd)
  return {block = {flavor = 'com.superlogical.terminal.shell', options = {command = {'/bin/sh'}, login = false, cwd = cwd}}}
end
local n = 0
local function workspace()
  n = n + 1
  local root = HOME .. '/ws' .. n
  local made, err = rex.exec({'mkdir', '-p', root .. '/api', root .. '/web'})
  if not made or not made.ok then error('mkdir: ' .. tostring(err or made.stderr)) end
  -- The real path: the lab's TMPDIR can be a symbolic link (/tmp on macOS).
  root = rex.exec({'pwd', '-P'}, {cwd = root}).stdout:gsub('\n$', '')
  local res, err = rex.call('session.create', {label = 'ws' .. n, initial_windows = {
    {window_label = 'code', layout = {split = {direction = 'horizontal', ratio = 0.4, before = sh(root .. '/api'), after = sh(root .. '/web')}}},
    {window_label = 'logs', layout = sh(root)}}})
  if err then error(err.message or tostring(err)) end
  return res.session_id, root
end
-- capture waits until every pane of the session is an idle shell with a known directory.
local function capture(a, session_id)
  return wait('the capture of ' .. session_id, function()
    local c = a:call('templates.capture', {session_id = session_id})
    if #c.panes ~= 3 then return nil end
    for _, p in ipairs(c.panes) do if p.guess ~= 'shell' or not p.dir then return nil end end
    return c
  end, 20)
end
-- panel opens the Templates panel from a pane of the session, as the palette command does.
local function panel(session_id)
  user:command('templates', {session = session_id, block = rex.call('session.list_blocks', {session_id = session_id}).blocks[1].block_id})
  return user:view('/panels/templates', nil, session_id)
end
local function first_block(session_id)
  return rex.call('session.list_blocks', {session_id = session_id}).blocks[1].block_id
end
local function form_input(tree, id)
  local values = {}
  for _, f in ipairs(node(tree, id).fields) do values[f.id] = f.value end
  return values
end
local function find(list, field, value)
  for _, x in ipairs(list) do if x[field] == value then return x end end
end
local function run_of(a, id)
  local r = a:call('templates.runs', {})
  if type(r.runs) ~= 'table' then error('templates.runs: ' .. rex.json.encode(r)) end
  return find(r.runs, 'id', id)
end
local function wait_run(a, id, status)
  return wait('run ' .. id .. ' ' .. status, function()
    local r = run_of(a, id)
    return r and r.status == status and r or nil
  end, 30)
end
W.workspace = workspace
W.capture = capture
W.first_block = first_block
W.panel = panel
W.form_input = form_input
W.find = find
W.run_of = run_of
W.wait_run = wait_run
return W
