-- Shared helpers of the Templates tests (load_fixture): lab directories and sessions, forms, the
-- panel, runs and the plugin's store keys.
local W = {}
local HOME = H.args.lab .. '/home'
W.HOME = HOME

local function exec(argv, opts)
  local r, err = rex.exec(argv, opts)
  if not r or not r.ok then error(table.concat(argv, ' ') .. ': ' .. tostring(err or r.stderr)) end
  return r
end
-- real is the path without symbolic links: the lab's TMPDIR can be one (/tmp on macOS).
function W.real(dir) return (exec({'pwd', '-P'}, {cwd = dir}).stdout:gsub('\n$', '')) end
function W.mkdir(...) exec({'mkdir', '-p', ...}) end
-- repo makes a git repository with the directories api and web, and returns its real path.
function W.repo(name)
  local dir = HOME .. '/' .. name
  W.mkdir(dir .. '/api', dir .. '/web')
  exec({'git', 'init', '-q', dir})
  return W.real(dir)
end
function W.hex(s) return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
function W.part(s) return #s .. ':' .. s end

-- Panes. sh: an idle shell. ish: an interactive shell that runs cmd in the foreground. direct: a
-- program that is not a shell.
local function pane(command, cwd, label)
  return {block = {flavor = 'com.superlogical.terminal.shell', label = label, options = {command = command, login = false, cwd = cwd}}}
end
function W.sh(cwd, label) return pane({'/bin/sh'}, cwd, label) end
function W.ish(cwd, label, cmd) return pane({'/bin/sh', '-i', '-c', (cmd or 'sleep 600') .. '; :'}, cwd, label) end
function W.direct(cwd, label) return pane({'/bin/sleep', '600'}, cwd, label) end
-- login: a default pane (no command). On macOS its child is /usr/bin/login (root, no cwd), and the
-- login shell is its foreground.
function W.login(cwd, label) return {block = {flavor = 'com.superlogical.terminal.shell', label = label, options = {cwd = cwd}}} end
function W.HS(ratio, before, after) return {split = {direction = 'horizontal', ratio = ratio, before = before, after = after}} end
function W.VS(ratio, before, after) return {split = {direction = 'vertical', ratio = ratio, before = before, after = after}} end
-- new_session creates a lab session of windows {{window_label, layout}, ...}.
function W.new_session(label, windows)
  local res, err = rex.call('session.create', {label = label, initial_windows = windows})
  if err then error(err.message or tostring(err)) end
  return res.session_id
end
function W.blocks(session_id) return rex.call('session.list_blocks', {session_id = session_id}).blocks end
function W.block_by_label(session_id, label)
  for _, b in ipairs(W.blocks(session_id)) do if b.label == label then return b.block_id end end
end
function W.first_block(session_id) return W.blocks(session_id)[1].block_id end

-- workspace: a session with tab "code" (two idle shells: api, web; ratio 0.4) and tab "logs" (one
-- idle shell in the root). Returns the session and the root.
local count = {n = 0} -- a table field (LazyRex docs/rex-protocol.md, "Rex Lua runtime")
function W.workspace()
  count.n = count.n + 1
  local n = count.n
  local root = HOME .. '/ws' .. n
  W.mkdir(root .. '/api', root .. '/web')
  root = W.real(root)
  return W.new_session('ws' .. n, {
    {window_label = 'code', layout = W.HS(0.4, W.sh(root .. '/api'), W.sh(root .. '/web'))},
    {window_label = 'logs', layout = W.sh(root)}}), root
end
-- capture waits until the session has count panes (default 3) and every pane is an idle shell
-- with a known directory (shells start after the session).
function W.capture(a, session_id, count)
  return wait('the capture of ' .. session_id, function()
    local c = a:call('templates.capture', {session_id = session_id})
    if #c.panes ~= (count or 3) then return nil end
    for _, p in ipairs(c.panes) do if p.guess ~= 'shell' or not p.dir then return nil end end
    return c
  end, 20)
end

-- Views. form opens a palette command's form or panel from a pane, as the Rex palette does.
function W.open(command, route, session_id, block)
  user:command(command, {session = session_id, block = block or W.first_block(session_id)})
  return user:view(route, nil, session_id)
end
function W.panel(session_id) return W.open('templates', '/panels/templates', session_id) end
function W.form_input(tree, id)
  local values = {}
  for _, f in ipairs(node(tree, id).fields) do values[f.id] = f.value end
  return values
end
function W.field(tree, form, id)
  for _, f in ipairs(node(tree, form).fields) do if f.id == id then return f end end
end
function W.find(list, field, value)
  for _, x in ipairs(list) do if x[field] == value then return x end end
end

-- Runs and records of the plugin.
-- all_runs reads every page of templates.runs and returns the runs, newest first.
function W.all_runs(a)
  local list, before = {}, nil
  repeat
    local args = {limit = 100}
    if before then args.before = before end
    local r = a:call('templates.runs', args)
    for _, x in ipairs(r.runs) do list[#list + 1] = x end
    before = r.next_before
  until not before
  return list
end
-- run_of reads the pages of templates.runs until it finds the run (or the last page).
function W.run_of(a, id)
  local before
  repeat
    local args = {limit = 100}
    if before then args.before = before end
    local r = a:call('templates.runs', args)
    if type(r.runs) ~= 'table' then error('templates.runs: ' .. rex.json.encode(r)) end
    local found = W.find(r.runs, 'id', id)
    if found then return found end
    before = r.next_before
  until not before
end
function W.wait_run(a, id, status)
  return wait('run ' .. id .. ' ' .. status, function()
    local r = W.run_of(a, id)
    return r and r.status == status and r or nil
  end, 30)
end
-- next_run_id is the ID that the next admitted run gets (run-counter + 1; small numbers only).
function W.next_run_id() return tostring((tonumber(store('run-counter').value) or 0) + 1) end
-- Template rows (templates_sql.lua). A test reads and writes them as another writer would, with
-- the old record shapes: W.trow(key) is like store(key) for a key 'template/<hex>' ({rev, value},
-- or {} when absent), and W.twrite(ops) is like write(ops): a 'template/' op goes to the SQL row
-- (with a new revision from the plugin's counter), any other op to the store.
function W.trow(key)
  local row = sql('SELECT CAST(rev AS TEXT) AS rev, value FROM templates WHERE hex = ?', {key:sub(#'template/' + 1)})[1]
  if not row then return {} end
  return {rev = row.rev, value = rex.json.decode(row.value)}
end
function W.twrite(ops)
  local rest = {}
  for _, op in ipairs(ops) do
    if op.key:sub(1, #'template/') == 'template/' then
      local hx = op.key:sub(#'template/' + 1)
      if op.delete then
        sql_write('DELETE FROM templates WHERE hex = ?', {hx})
      else
        local rev = tonumber(sql("SELECT v FROM meta WHERE k = 'rev'")[1].v) + 1
        sql_write("UPDATE meta SET v = ? WHERE k = 'rev'", {tostring(rev)})
        -- A large value goes to a staging row in parts (a request is at most 64 KiB), then into the
        -- template row in one statement: the plugin never reads a partial value.
        local text, pos = rex.json.encode(op.value), 1
        sql_write("INSERT INTO meta (k, v) VALUES ('test-stage', '') ON CONFLICT (k) DO UPDATE SET v = ''")
        while pos <= #text do
          local n = math.min(8000, #text - pos + 1)
          while pos + n <= #text and text:byte(pos + n) >= 0x80 and text:byte(pos + n) < 0xC0 do n = n - 1 end
          sql_write("UPDATE meta SET v = v || ? WHERE k = 'test-stage'", {text:sub(pos, pos + n - 1)})
          pos = pos + n
        end
        sql_write("INSERT INTO templates (hex, rev, value) SELECT ?, ?, v FROM meta WHERE k = 'test-stage'"
          .. ' ON CONFLICT (hex) DO UPDATE SET rev = excluded.rev, value = excluded.value', {hx, rev})
        sql_write("DELETE FROM meta WHERE k = 'test-stage'")
      end
    else
      rest[#rest + 1] = op
    end
  end
  if #rest > 0 then write(rest) end
end
-- put_op saves an operation reply in SQL, as an older version saved it (and the import copied it).
function W.put_op(op)
  sql_write('INSERT INTO ops (key, fingerprint, result) VALUES (?, ?, ?)', {op.key, op.fingerprint, rex.json.encode(op.result)})
end
function W.template(name) return W.trow('template/' .. W.hex(name)).value end
-- The records of a UI start with operation key key.
function W.start_form_key(key) return 'start-form/' .. W.hex('start/' .. W.part(key)) end
-- The start record of an agent's start: 'start/agent/' .. part(agent) .. part(key).
function W.start_form_key_agent(agent_id, key) return 'start-form/' .. W.hex('start/agent/' .. W.part(agent_id) .. W.part(key)) end
function W.switch_record(key) return store('switch/' .. W.hex('start/' .. W.part(key))).value end
-- ui_delete deletes a template as the user does in session s: the panel row opens the template
-- menu, Delete… opens the confirmation (with the revision of that choice), and Delete submits it.
-- It returns the final operation of the submit and the confirmation view.
function W.ui_delete(s, name, key)
  local hx = W.hex(name)
  local p = W.panel(s)
  p:render()
  p:action('templates', 'open', {item_id = hx}, key .. '-open')
  local menu = user:view('/forms/template/' .. hx, nil, s)
  menu:render()
  local rev = W.trow('template/' .. hx).rev
  menu:action('template_menu', 'delete', {item_id = 'delete'}, key .. '-menu')
  local confirm = user:view('/forms/delete/' .. hx .. '/' .. rev, nil, s)
  confirm:render()
  return confirm:action('confirm', 'submit', {values = {}}, key), confirm
end
return W
