-- Shared helpers of the Templates tests (load_fixture): lab directories and sessions, forms, the
-- panel, runs and the rows of the plugin.
local W = {}
-- W.sql_write runs sql_write as another writer would. The test writer fails at once with busy
-- while the plugin has an open transaction; a plugin call there waits for it (at most 5 s, LazyRex
-- docs/sql.md). The plugin opens short transactions at any time (a tick, a retirement), so the
-- test writer also waits: it tries again on busy for at most 5 s.
function W.sql_write(...)
  local deadline = os.time() + 5
  while true do
    local ok, result = pcall(sql_write, ...)
    if ok then return result end
    local busy = tostring(type(result) == 'table' and (result.code or result.message) or result):find('busy', 1, true)
    if not busy or os.time() >= deadline then error(result, 0) end
    rex.sleep(0.05)
  end
end
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
-- Rows of the plugin (templates_sql.lua). A test reads and writes them as another writer would.
-- Each reader returns the row, or nil when it is absent. Keys are the table keys: a run ID, an
-- operation key (W.start_key, W.agent_start_key), a template hex.
-- text reads one text column of one row in parts (a test client reply has a size limit), or nil.
local PART = 6000 -- characters; a character is at most 4 bytes, and the reply encodes it again
local function text(tbl, col, kcol, key)
  local n = sql('SELECT length(' .. col .. ') AS n FROM ' .. tbl .. ' WHERE ' .. kcol .. ' = ?', {key})[1]
  if not n then return nil end
  local parts = {}
  for pos = 1, tonumber(n.n), PART do
    parts[#parts + 1] = sql('SELECT substr(' .. col .. ', ?, ?) AS p FROM ' .. tbl .. ' WHERE ' .. kcol .. ' = ?', {pos, PART, key})[1].p
  end
  return table.concat(parts)
end
-- stage writes text to the staging row meta 'test-stage' in parts; the caller's next statement
-- reads it whole (the plugin never reads a partial value).
local function stage(text)
  local pos = 1
  W.sql_write("INSERT INTO meta (k, v) VALUES ('test-stage', '') ON CONFLICT (k) DO UPDATE SET v = ''")
  while pos <= #text do
    local n = math.min(8000, #text - pos + 1)
    while pos + n <= #text and text:byte(pos + n) >= 0x80 and text:byte(pos + n) < 0xC0 do n = n - 1 end
    W.sql_write("UPDATE meta SET v = v || ? WHERE k = 'test-stage'", {text:sub(pos, pos + n - 1)})
    pos = pos + n
  end
end
local function unstage() W.sql_write("DELETE FROM meta WHERE k = 'test-stage'") end
local NULL = {null = true}
local function null(v) if v == nil then return NULL end return v end
-- new_rev takes a revision from the plugin's counter (meta 'rev'), as a plugin write does (the
-- first revision on a new database is 1).
local function new_rev()
  local row = sql("SELECT v FROM meta WHERE k = 'rev'")[1]
  local rev = tostring((row and tonumber(row.v) or 0) + 1)
  W.sql_write("INSERT INTO meta (k, v) VALUES ('rev', ?) ON CONFLICT (k) DO UPDATE SET v = excluded.v", {rev})
  return rev
end

-- The operation key of a UI start with key, and of an agent's start.
function W.start_key(key) return 'start/' .. W.part(key) end
function W.agent_start_key(agent_id, key) return 'start/agent/' .. W.part(agent_id) .. W.part(key) end

-- Runs: {ver, status, value}. W.put_runs writes whole run values (an existing run gets ver + 1);
-- small values share one statement.
function W.run(id)
  local r = sql('SELECT ver, status FROM runs WHERE id = ?', {id})[1]
  if not r then return nil end
  return {ver = r.ver, status = r.status, value = rex.json.decode(text('runs', 'value', 'id', id))}
end
local SMALL = 12000 -- a run value of at most this many bytes goes in one statement with others
local UPSERT_RUN = ' ON CONFLICT (id) DO UPDATE SET ver = runs.ver + 1, status = excluded.status, value = excluded.value'
-- insert_runs writes a batch of small runs in one statement. It is not a closure over the batch: in
-- Rex Lua, an error that pcall catches (a busy retry of W.sql_write) detaches a closure's upvalues
-- from the locals of an active caller, so a closure could not reset a caller's batch.
local function insert_runs(batch)
  if #batch == 0 then return end
  local marks, params = {}, {}
  for i, run in ipairs(batch) do
    marks[i] = '(?, 1, ?, ?)'
    params[#params + 1] = run.id
    params[#params + 1] = run.status
    params[#params + 1] = run.text
  end
  W.sql_write('INSERT INTO runs (id, ver, status, value) VALUES ' .. table.concat(marks, ', ') .. UPSERT_RUN, params)
end
function W.put_runs(runs)
  local batch = {}
  for _, run in ipairs(runs) do
    local t = rex.json.encode(run)
    local status = type(run.status) == 'string' and run.status or ''
    if #t <= SMALL then
      batch[#batch + 1] = {id = run.id, status = status, text = t}
      if #batch * SMALL >= 40000 then insert_runs(batch); batch = {} end
    else
      insert_runs(batch); batch = {}
      stage(t)
      W.sql_write("INSERT INTO runs (id, ver, status, value) SELECT ?, 1, ?, v FROM meta WHERE k = 'test-stage'" .. UPSERT_RUN, {run.id, status})
      unstage()
    end
  end
  insert_runs(batch)
end
function W.delete_run(id) W.sql_write('DELETE FROM runs WHERE id = ?', {id}) end

-- The run counter: the last run ID as text, or nil. W.set_counter(nil) deletes it.
function W.counter() local r = sql("SELECT v FROM meta WHERE k = 'run-counter'")[1]; return r and r.v end
function W.set_counter(v)
  if v == nil then W.sql_write("DELETE FROM meta WHERE k = 'run-counter'") return end
  W.sql_write("INSERT INTO meta (k, v) VALUES ('run-counter', ?) ON CONFLICT (k) DO UPDATE SET v = excluded.v", {v})
end
-- next_run_id is the ID that the next admitted run gets (the run counter + 1; small numbers only).
function W.next_run_id() return tostring((tonumber(W.counter()) or 0) + 1) end

-- Run keys: {run_id, expired_at, form_rev}. expired_at nil: the key names its live run.
function W.run_key(key)
  return sql('SELECT run_id, expired_at, form_rev FROM run_keys WHERE key = ?', {key})[1]
end
function W.put_run_key(key, row)
  W.sql_write('INSERT INTO run_keys (key, run_id, expired_at, form_rev) VALUES (?, ?, ?, ?) ON CONFLICT (key) DO UPDATE'
    .. ' SET run_id = excluded.run_id, expired_at = excluded.expired_at, form_rev = excluded.form_rev',
    {key, row.run_id, null(row.expired_at), null(row.form_rev)})
end

-- Start forms: {rev, fingerprint, request, at}. W.put_form writes a form with a new revision and
-- returns it.
function W.form(key)
  local r = sql('SELECT rev, at FROM start_forms WHERE key = ?', {key})[1]
  if not r then return nil end
  return {rev = r.rev, fingerprint = text('start_forms', 'fingerprint', 'key', key),
    request = rex.json.decode(text('start_forms', 'request', 'key', key)), at = r.at}
end
function W.put_form(key, form)
  local rev = new_rev()
  stage(rex.json.encode(form.request))
  W.sql_write("INSERT INTO start_forms (key, rev, fingerprint, request, at) SELECT ?, ?, ?, v, ? FROM meta WHERE k = 'test-stage'"
    .. ' ON CONFLICT (key) DO UPDATE SET rev = excluded.rev, fingerprint = excluded.fingerprint, request = excluded.request, at = excluded.at',
    {key, rev, form.fingerprint, null(form.at)})
  unstage()
  return rev
end
-- put_run_forms writes the start form of each run with an ID from first to last (numbers), as
-- its admission does: the run's request, a new revision each, and at. One statement for all.
function W.put_run_forms(first, last, at)
  local row = sql("SELECT v FROM meta WHERE k = 'rev'")[1]
  local base = row and tonumber(row.v) or 0
  W.sql_write("INSERT INTO meta (k, v) VALUES ('rev', ?) ON CONFLICT (k) DO UPDATE SET v = excluded.v", {tostring(base + last - first + 1)})
  local r = W.sql_write("INSERT INTO start_forms (key, rev, fingerprint, request, at) SELECT value ->> '$.request.key',"
    .. " CAST(? + CAST(id AS INTEGER) - ? + 1 AS TEXT), 'fp', value -> '$.request', ? FROM runs"
    .. ' WHERE CAST(id AS INTEGER) BETWEEN ? AND ?', {base, first, at, first, last})
  assert(r.changes == last - first + 1, 'put_run_forms wrote ' .. tostring(r.changes) .. ' forms')
end

-- Switches: {state, code, message}, by the operation key of the start.
function W.switch(key) return sql('SELECT state, code, message FROM switches WHERE start_key = ?', {key})[1] end
function W.put_switch(key, row)
  W.sql_write('INSERT INTO switches (start_key, state, code, message) VALUES (?, ?, ?, ?) ON CONFLICT (start_key) DO UPDATE'
    .. ' SET state = excluded.state, code = excluded.code, message = excluded.message', {key, row.state, null(row.code), null(row.message)})
end

-- Templates: {rev, value}, by the hex of the name (any hex, also one that Templates did not
-- write). W.put_template writes a value with a new revision and returns it.
function W.template(hx)
  local row = sql('SELECT CAST(rev AS TEXT) AS rev FROM templates WHERE hex = ?', {hx})[1]
  if not row then return nil end
  return {rev = row.rev, value = rex.json.decode(text('templates', 'value', 'hex', hx))}
end
function W.put_template(hx, value)
  local rev = new_rev()
  stage(rex.json.encode(value))
  W.sql_write("INSERT INTO templates (hex, rev, value) SELECT ?, ?, v FROM meta WHERE k = 'test-stage'"
    .. ' ON CONFLICT (hex) DO UPDATE SET rev = excluded.rev, value = excluded.value', {hx, rev})
  unstage()
  return rev
end
function W.delete_template(hx) W.sql_write('DELETE FROM templates WHERE hex = ?', {hx}) end
-- put_op saves an operation reply in SQL, as the plugin saves it.
function W.put_op(op)
  W.sql_write('INSERT INTO ops (key, fingerprint, result) VALUES (?, ?, ?)', {op.key, op.fingerprint, rex.json.encode(op.result)})
end
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
  local rev = W.template(hx).rev
  menu:action('template_menu', 'delete', {item_id = 'delete'}, key .. '-menu')
  local confirm = user:view('/forms/delete/' .. hx .. '/' .. rev, nil, s)
  confirm:render()
  return confirm:action('confirm', 'submit', {values = {}}, key), confirm
end
-- W.restart replaces the plugin instance (hub.admin.replace): the new instance starts from the
-- SQL state. The hub's faults and injections stay armed (a hub restart would end them).
function W.restart()
  local st = H.hub('hub.test.status', {}).plugins.templates
  H.hub('hub.admin.replace', {plugin = 'templates', expect_instance = st.instance_id})
end
return W
