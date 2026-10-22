-- Session templates (the maintainer, 2026-10-17). A template is a named group of tabs. Each pane has a
-- launch (a profile and its args, or a plain shell), a directory relative to a root, and its place
-- in the tab's layout. "Save as Template…" captures a session; "Start Session…" starts a template
-- in any root. The engine (templates_run.lua) owns durable starts; this file owns capture, the
-- forms, the panel and the adapter to hub.spawn_window.
-- The Plugin SDK (LazyRex sdk/lua) registers the plugin and dispatches the hub calls. The data
-- stays in hub.store: each action and view has {tx = false, store = false}, so the SDK makes no
-- hub.sql call and saves no reply (docs/sdk-port.md, stage 1).
local app = require('lazyrex').plugin('templates')
local function fail(code, message) error({code = code, message = message}) end
local function text(value, name)
  if type(value) ~= 'string' or value == '' or value:find('%z') then fail('invalid_input', name .. ' must be nonempty text without NUL') end
  return value
end
local function part(value) return tostring(#value) .. ':' .. value end
local function hub(action, args) return app.hub(action, args) end
local function rex_ok(method, args)
  local result, err = rex.call(method, args)
  if not result then fail('unavailable', type(err) == 'table' and err.message or tostring(err)) end
  return result
end
-- Git override variables from the plugin's environment must not change the answer (worktrees.lua).
local git_env = {GIT_DIR = false, GIT_WORK_TREE = false, GIT_COMMON_DIR = false,
  GIT_INDEX_FILE = false, GIT_CONFIG_COUNT = false, GIT_CONFIG_PARAMETERS = false}
local function run(argv, cwd)
  local result, err = rex.exec(argv, {cwd = cwd, env = git_env, timeout = 10})
  if not result then fail('unavailable', tostring(err or 'Command did not start')) end
  return result
end
local function line(value) return (value:gsub('\n$', '')) end
local function within(path, root) return path == root or root == '/' and path:sub(1, 1) == '/' or path:sub(1, #root + 1) == root .. '/' end
local function hex(value) return (value:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
-- unhex: the text of a lowercase hex string of even length, or nil.
local function unhex(s)
  if #s % 2 ~= 0 or s:find('[^0-9a-f]') then return nil end
  return (s:gsub('..', function(h) return string.char(tonumber(h, 16)) end))
end
local function json_size(v) return #rex.json.encode(v) end

-- The engine is a sibling file. Observed on Rex 1203: debug.getinfo gives the script's absolute path.
local here = debug.getinfo(1, 'S').source:gsub('^@', '')
local run_module = dofile(assert(here:match('^(/.*)/[^/]*$'), 'the plugin path must be absolute') .. '/templates_run.lua')
-- The SQL storage (templates_sql.lua): the templates and the save and delete operations.
local sql = dofile(here:match('^(/.*)/[^/]*$') .. '/templates_sql.lua')
local data = sql.new(app)

-- Directories. Both return canonical absolute paths (symlinks resolved) of existing directories.
-- dir_memo: during one Save form render (with_dir_memo), real_dir and git_root check each path
-- once. Many panes share a directory, and each check starts processes. The maps are set only
-- for that render and are cleared on every exit, so each render checks again. They are table
-- fields (LazyRex docs/rex-protocol.md, "Rex Lua runtime"). A module-level request scope relies on
-- the plugin running handlers one at a time (same section); it is not safe under concurrent handlers.
local dir_memo = {real = nil, git = nil}
local function real_dir(path)
  if dir_memo.real and dir_memo.real[path] then return dir_memo.real[path] end
  local r = run({'realpath', path})
  if not r.ok then fail('invalid_input', path .. ' does not exist') end
  local out = line(r.stdout)
  if not run({'test', '-d', out}).ok then fail('invalid_input', path .. ' is not a directory') end
  if dir_memo.real then dir_memo.real[path] = out end
  return out
end
local function resolve_root(path)
  text(path, 'root')
  if path:sub(1, 1) ~= '/' then fail('invalid_input', 'The root must be an absolute directory') end
  return real_dir(path)
end
local function resolve_dir(root, rel)
  local dir = rel == '.' and root or real_dir(root .. '/' .. rel)
  if not within(dir, root) then fail('invalid_input', rel .. ' leaves the root (a symlink?)') end
  return dir
end
local function git_root(dir)
  if dir_memo.git and dir_memo.git[dir] ~= nil then return dir_memo.git[dir] or nil end
  local r = run({'git', '-C', dir, 'rev-parse', '--show-toplevel'})
  local root = r.ok and real_dir(line(r.stdout)) or nil
  if dir_memo.git then dir_memo.git[dir] = root or false end
  return root
end
-- with_dir_memo runs f(...) with fresh memo maps and clears them on every exit. An error is
-- raised again unchanged (a structured error stays a table).
local function with_dir_memo(f, ...)
  dir_memo.real, dir_memo.git = {}, {}
  local result = {pcall(f, ...)}
  dir_memo.real, dir_memo.git = nil, nil
  if not result[1] then error(result[2], 0) end
  return unpack(result, 2, table.maxn(result))
end
-- The common root: the git root when every directory is in one repository, else the deepest
-- common parent.
local function common_root(dirs)
  if #dirs == 0 then return nil end
  local git, same = git_root(dirs[1]), true
  for i = 2, #dirs do if git_root(dirs[i]) ~= git then same = false end end
  if git and same then return git end
  local root = dirs[1]
  for i = 2, #dirs do
    while not within(dirs[i], root) do root = root:match('^(.*)/[^/]*$'); if root == '' then root = '/' end end
  end
  return root
end
local function relative(dir, root)
  if dir == root then return '.' end
  if root == '/' then return dir:sub(2) end
  return dir:sub(#root + 2)
end

-- Profiles. A plain shell is the built-in "shell" profile (the Profiles pair builds it).
local SHELL_PROFILE = 'shell'
local function profiles()
  local ok, result = pcall(hub, 'hub.profiles')
  local list = {}
  if ok then for _, p in ipairs(result.profiles or {}) do if p.id ~= SHELL_PROFILE then list[#list + 1] = p end end end
  return list
end

-- Capture. LazyRex's own panes (views, forms, panels, plugins, placeholders) are not part of a
-- template; a pane the hub spawned keeps its label "lazyrex-spawn:<id>" and is captured.
local function infrastructure(label)
  return type(label) == 'string' and label:sub(1, 8) == 'lazyrex-' and label:sub(1, 14) ~= 'lazyrex-spawn:'
end
local function prune(node, keep)
  if not node then return nil end
  if not node.split then return keep[node.block_id] and {block_id = node.block_id} or nil end
  local b, a = prune(node.split.before, keep), prune(node.split.after, keep)
  if not b then return a end
  if not a then return b end
  return {split = {direction = node.split.direction, ratio = node.split.ratio, before = b, after = a}}
end
local function leaves(node, out)
  if not node then return out end
  if node.split then return leaves(node.split.after, leaves(node.split.before, out)) end
  out[#out + 1] = node.block_id
  return out
end
-- A shell guess needs a shell as the pane's child, in the foreground. A pane that runs a program
-- directly, or a shell that runs one, has no guess: the user chooses.
local shells = {sh = true, bash = true, zsh = true, fish = true, dash = true, ksh = true, tcsh = true, csh = true, nu = true}
local function is_shell(proc)
  local name = type(proc.name) == 'string' and proc.name:gsub('^%-', '') or ''
  return shells[name] or (proc.path and proc.path == os.getenv('SHELL'))
end
local function short(path)
  local home = os.getenv('HOME') or ''
  if home ~= '' and within(path, home) then return '~' .. path:sub(#home + 1) end
  return path
end

-- pane_dir is the directory the pane's shell last reported (terminal.pwd, OSC 7), else its child's
-- cwd from the OS, else its foreground's cwd, else fallback. The result is canonical, or nil when
-- the directory is gone. A default macOS pane's child is /usr/bin/login (root): Rex reports no cwd
-- for it, only for the login shell in the foreground (observed on Rex 0.0.1792158932-g88fd41, lab).
local function file_url_path(url)
  local path = type(url) == 'string' and url:match('^file://[^/]*(/.*)$') or nil
  if path then path = path:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end) end
  return path
end
local function pane_dir(session_id, block_id, child, fg, fallback)
  local ok, pwd = pcall(rex_ok, 'com.superlogical.terminal.pwd', {session_id = session_id, block_id = block_id, args = {}})
  for _, dir in ipairs({ok and file_url_path(pwd.pwd) or false, child.cwd or false, fg.cwd or false, fallback or false}) do
    if dir then
      local found, real = pcall(real_dir, dir)
      if found then return real end
    end
  end
end

-- capture returns {tabs = {{title, layout}}, panes = {block -> pane}, order = {block...}} for a
-- session. Each pane has its directory and a launch guess: the spawn's profile and args, a shell
-- when the shell itself is in the foreground, else none (the user must choose).
local function capture(session_id)
  rex_ok('session.attach', {session_id = session_id, event_scope = 'session'})
  local view = rex_ok('session.view', {session_id = session_id})
  local labels = {}
  for _, b in ipairs(rex_ok('session.list_blocks', {session_id = session_id}).blocks or {}) do labels[b.block_id] = b.label or '' end
  local result, dropped = {tabs = {}, panes = {}, order = {}}, 0
  for _, window in ipairs(view.windows or {}) do
    for i, layer in ipairs(window.layers or {}) do
      -- v1 keeps the tiled layer only. A floating pane is left out (counted for the form).
      if layer.kind ~= 'tiled' then dropped = dropped + #leaves(layer.layout, {}) end
      if layer.kind == 'tiled' and layer.layout then
        local keep = {}
        for _, id in ipairs(leaves(layer.layout, {})) do if not infrastructure(labels[id]) then keep[id] = true end end
        local tree = prune(layer.layout, keep)
        if tree then
          result.tabs[#result.tabs + 1] = {title = window.label ~= '' and window.label or ('Tab ' .. tostring(#result.tabs + 1)), layout = tree}
          for _, id in ipairs(leaves(tree, {})) do
            local pane = {block_id = id, tab = #result.tabs}
            local spec = hub('hub.spawn.spec', {block_id = id})
            local ok, proc = pcall(rex_ok, 'com.superlogical.terminal.process', {session_id = session_id, block_id = id, args = {}})
            local child = ok and proc.child or {}
            local fg = ok and proc.foreground or {}
            pane.dir = pane_dir(session_id, id, child, fg, spec.found and spec.cwd or nil)
            -- A spawned pane: its profile, and the title that its caller requested (hub.spawn.spec
            -- requested_title, only when title_source is request). A resolved title (a default, a
            -- generated agent name) is display text only (tests/templates-run.md, "Titles").
            local title = spec.found and type(spec.title) == 'string' and spec.title ~= '' and spec.title or nil
            if spec.found then
              pane.spawn_profile = spec.profile
              if spec.title_source == 'request' and type(spec.requested_title) == 'string' and spec.requested_title ~= '' then
                pane.requested_title = spec.requested_title
              end
            end
            if spec.found and spec.profile ~= SHELL_PROFILE then
              pane.guess, pane.args = 'profile:' .. spec.profile, spec.args or {}
              pane.detail = title
            else
              local idle = child.pid and fg.pid == child.pid
              if idle and is_shell(child) then pane.guess, pane.detail = 'shell', title
              elseif child.pid then
                pane.detail = (title and title .. ' · ' or '') .. 'running ' .. tostring((idle and child.name) or fg.name or 'a program')
              else pane.detail = title end
            end
            if not pane.dir then pane.detail = 'directory unknown'; pane.guess = nil end
            result.panes[id], result.order[#result.order + 1] = pane, id
          end
        end
      end
    end
  end
  result.dropped = dropped
  return result
end

-- scan_all returns the values (tables) of every record under prefix. A page that is too large for
-- a hub reply is asked for again with a smaller limit (templates_run.lua, "Store scans").
local function scan_all(prefix)
  local list, after, limit = {}, nil, run_module.SCAN_LIMIT
  repeat
    local args = {prefix = prefix, limit = limit}
    if after then args.after = after end
    local ok, page = pcall(hub, 'hub.store.scan', args)
    if ok then
      for _, record in pairs(page.records or {}) do
        if type(record.value) == 'table' then list[#list + 1] = record.value end
      end
      after = page.next
    else
      limit = run_module.smaller(limit, page)
      if not limit then error(page, 0) end
    end
  until ok and not after
  return list
end

-- Storage: the SQL row templates(hex, rev, value) with value {v = 1, name, tabs, saved_by} as JSON
-- (templates_sql.lua). hex is the hex of the name (the old store key was "template/" .. hex), so any
-- name is a valid key. A template's identity is its hex: value.name can differ in a row that
-- Templates did not write (an imported record). The panel and the forms name a template by its hex.
-- json_safe: the text comes back unchanged from a JSON round trip (rex.json.encode replaces an
-- invalid UTF-8 byte with U+FFFD), so a form option or field can carry it.
local function json_safe(s) return rex.json.decode(rex.json.encode(s)) == s end
-- templates returns {hex, name, value} for each template record in key order. name is the name of
-- the key when it is JSON-safe, else nil.
local function templates()
  local list, after = {}, nil
  repeat
    local rows, more = app.db.query('SELECT hex, value FROM templates WHERE ? IS NULL OR hex > ? ORDER BY hex', after, after)
    for _, row in ipairs(rows) do
      local value = rex.json.decode(row.value)
      if type(value) == 'table' then
        local name = unhex(row.hex)
        list[#list + 1] = {hex = row.hex, name = name and json_safe(name) and name or nil, value = value}
      end
      after = row.hex
    end
  until not more
  return list
end
-- display returns a text for a view: control characters become spaces, and a text over 200 bytes
-- is cut on a UTF-8 boundary, with "…".
local DISPLAY_MAX = 200
local function display(s)
  s = tostring(s):gsub('%c', ' ')
  if #s <= DISPLAY_MAX then return s end
  local cut = DISPLAY_MAX - 3
  while cut > 0 and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
  return s:sub(1, cut) .. '…'
end
-- named cuts a name for a message: at most 60 bytes on a UTF-8 boundary, no control characters.
local function named(name)
  name = name:gsub('%c', ' ')
  if #name <= 60 then return '"' .. name .. '"' end
  local cut = 57
  while cut > 0 and cut > 54 and name:byte(cut + 1) >= 0x80 and name:byte(cut + 1) < 0xC0 do cut = cut - 1 end
  return '"' .. name:sub(1, cut) .. '…"'
end
-- Template routes (the panel's navigation). Each is an exact pattern; the hex must be the
-- lowercase hex of a name and the rev 1 to 20 digits. A route over ROUTE_MAX bytes is not used:
-- the panel row of such a template has no action.
local ROUTE_MAX = 1024
-- navigable: the longest route of a panel row (the delete confirmation, a 20-digit rev) fits.
local function navigable(hx) return #('/forms/delete/' .. hx .. '/' .. string.rep('9', 20)) <= ROUTE_MAX end
local function route_hex(route, prefix)
  local hx = route:match('^' .. prefix .. '(%x+)$')
  if not hx or not unhex(hx) or hex(unhex(hx)) ~= hx then fail('invalid_input', 'Unknown route') end
  return hx
end
local function delete_route(route)
  local hx, rev = route:match('^/forms/delete/(%x+)/(%d+)$')
  if not hx or not unhex(hx) or hex(unhex(hx)) ~= hx or #rev > 20 then fail('invalid_input', 'Unknown route') end
  return hx, rev
end
-- read_template returns the record template/<hx> ({rev, value}) or nil when it has no table value.
local function read_template(hx)
  local r = data.get_template(hx)
  if r and type(r.value) == 'table' then return r end
end
local function load_template(name)
  local key = hex(text(name, 'template'))
  local r = data.get_template(key)
  if not r or type(r.value) ~= 'table' then fail('not_found', 'The template "' .. name .. '" no longer exists') end
  return r.value, r.rev, key
end

-- A form's operation key makes a submit safe to retry. The saved result answers a retry.

local function cancel_node(label)
  return {id = 'cancel', type = 'widget', text = '', action = {name = '$cancel', label = label or 'Cancel', enabled = true}}
end
local function context_of(args)
  local context = args.context
  if type(context) ~= 'table' or type(context.session_id) ~= 'string' or context.session_id == '' then
    fail('invalid_input', 'The form has no source session')
  end
  return context
end

-- Save form. One select per captured pane, keyed by its block ID.
local function save_fields(cap, session_label)
  local dirs = {}
  for _, id in ipairs(cap.order) do if cap.panes[id].dir then dirs[#dirs + 1] = cap.panes[id].dir end end
  local fields = {
    {id = 'name', label = 'Template name', kind = 'text', required = true, value = session_label or ''},
    {id = 'root', label = 'Root (panes are saved relative to it)', kind = 'text', required = true, value = common_root(dirs) or ''},
    {id = 'replace', label = 'If a template has this name', kind = 'select', required = true, value = 'keep',
      options = {{value = 'keep', label = 'Keep it (do not save)'}, {value = 'replace', label = 'Replace it'}}},
  }
  local profile_options = {{value = '@choose', label = 'Choose…'}, {value = '@skip', label = 'Leave out'}, {value = 'shell', label = 'Shell'}}
  for _, p in ipairs(profiles()) do profile_options[#profile_options + 1] = {value = 'profile:' .. p.id, label = p.name or p.id} end
  for _, id in ipairs(cap.order) do
    local pane = cap.panes[id]
    local label = cap.tabs[pane.tab].title .. ' · ' .. (pane.dir and short(pane.dir) or '?')
    if pane.detail and pane.detail ~= '' then label = label .. ' · ' .. pane.detail end
    local options = profile_options
    -- A profile that is not in the list now (removed or renamed) stays a choice for its pane.
    if pane.guess and pane.guess:sub(1, 8) == 'profile:' then
      local found = false
      for _, o in ipairs(options) do if o.value == pane.guess then found = true end end
      if not found then
        options = {}
        for _, o in ipairs(profile_options) do options[#options + 1] = o end
        options[#options + 1] = {value = pane.guess, label = pane.guess:sub(9)}
      end
    end
    fields[#fields + 1] = {id = 'pane_' .. id, label = label, kind = 'select', required = true,
      value = pane.dir and (pane.guess or '@choose') or '@skip', options = options}
  end
  return fields
end

local function session_label(session_id)
  for _, s in ipairs(hub('hub.session.list').sessions or {}) do
    if s.session_id == session_id then return s.label end
  end
end

local function to_layout(node, cap, launches, root, labels)
  if node.split then
    local b = to_layout(node.split.before, cap, launches, root, labels)
    local a = to_layout(node.split.after, cap, launches, root, labels)
    if not b then return a end
    if not a then return b end
    return {direction = node.split.direction, ratio = node.split.ratio, before = b, after = a}
  end
  local launch = launches[node.block_id]
  if not launch then return nil end
  return {launch = launch, dir = relative(cap.panes[node.block_id].dir, root), label = labels and labels[node.block_id] or nil}
end

-- values_fingerprint covers the submitted values and the source session in a stable order, so a
-- retry finds its saved result before anything live (the session, the root, the store) is read.
local function values_fingerprint(prefix, context, values)
  local keys = {}
  for k in pairs(values) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local fp = prefix .. part(context.session_id)
  for _, k in ipairs(keys) do fp = fp .. part(k) .. part(tostring(values[k])) end
  return fp
end
local function form_values(args)
  return type(args.input) == 'table' and type(args.input.values) == 'table' and args.input.values or {}
end

-- Callers (agent parity). The UI user acts through views; an agent through an export, forwarded by
-- the hub or called directly. The SDK identifies the agent from the requester PID that the hub or
-- Rex gives (hub.identify), never from an argument. caller = {id, ids, session_id, pid}: ids
-- are every ID of the agent (its identity and the legacy IDs it took over), so an operation
-- recorded under an older ID still matches. An agent may act on anything that the user can
-- (decision "Agents may act on anything", 2026-10-19): there is no owner check.
local USER = {id = 'user', ids = {'user'}}
-- caller_of turns the SDK context of an agent call (ctx.agent, ctx.aliases: the legacy IDs) into a caller.
local function caller_of(ctx)
  if type(ctx.agent) ~= 'string' or ctx.agent == '' then fail('refused', 'The hub does not recognize this agent') end
  local ids = {ctx.agent}
  for _, l in ipairs(type(ctx.aliases) == 'table' and ctx.aliases or {}) do
    if type(l) == 'string' and l ~= '' then ids[#ids + 1] = l end
  end
  -- Every ID can be part of an operation key that a run write carries (templates_run.lua, size
  -- bounds). An agent with a longer ID is refused as a whole; no ID is left out.
  for _, id in ipairs(ids) do
    if #id > run_module.MAX_ID or id:find('%c') then fail('refused', 'An ID of this agent is longer than ' .. run_module.MAX_ID .. ' bytes or has control characters') end
  end
  return {id = ctx.agent, ids = ids, session_id = ctx.session_id, pid = ctx.requester_pid}
end

-- Operation keys. The UI keeps its key format: '<kind>/' .. part(view key) (part starts with a
-- digit). An agent key is '<kind>/agent/' .. part(agent ID) .. part(key), so the two can never be
-- equal. op_keys lists the store keys to look up for a caller: one per ID of the agent.
local function op_keys(kind, caller, key)
  text(key, caller.id == 'user' and 'operation key' or 'key')
  -- Bounded: dismiss and retry commit the key in the batch of a run record (templates_run.lua).
  if #key > run_module.MAX_KEY or key:find('%c') then
    fail('invalid_input', 'A key is at most ' .. run_module.MAX_KEY .. ' bytes, without control characters')
  end
  if caller.id == 'user' then return {kind .. '/' .. part(key)} end
  local list = {}
  for _, id in ipairs(caller.ids) do list[#list + 1] = kind .. '/agent/' .. part(id) .. part(key) end
  return list
end
-- prior_op returns the saved result of the first key that has one (the caller's current ID
-- first), or nil. Two IDs of one agent that both saved the key are a conflict. A save or a delete
-- reads its operation from SQL (sql.SQL_KINDS); the other kinds from hub.store.
local function saved_op(k)
  if sql.kind_in_sql(k) then
    local op = data.get_op(k)
    return op and {found = true, fingerprint = op.fingerprint, result = op.result} or {found = false}
  end
  return hub('hub.store.op', {key = k})
end
local function prior_op(keys, fingerprint)
  local found, result = 0, nil
  for _, k in ipairs(keys) do
    local saved = saved_op(k)
    if saved.found then
      found = found + 1
      if saved.fingerprint ~= fingerprint then fail('operation_conflict', 'Operation key already has different content') end
      result = result or saved.result
    end
  end
  if found > 1 then fail('conflict', 'Two IDs of this agent used the key; use a new key') end
  return result
end

-- canon is a canonical text of an agent's arguments for a fingerprint: type-tagged, part-framed,
-- object keys sorted. The caller checks the types first; anything else is refused here too.
local function canon(v)
  local t = type(v)
  if t == 'nil' then return 'N' end
  if t == 'boolean' then return v and 'T' or 'F' end
  if t == 'string' then return 's' .. part(v) end
  if t == 'number' then return 'n' .. part(string.format('%.17g', v)) end
  if t == 'table' then
    -- An array (keys 1..n, n > 0) keeps its order; an empty table is an empty object.
    local n = #v
    if n > 0 then
      local out, count = {'['}, 0
      for _ in pairs(v) do count = count + 1 end
      if count ~= n then fail('invalid_input', 'A list must not have other keys') end
      for i = 1, n do out[#out + 1] = canon(v[i]) end
      out[#out + 1] = ']'
      return table.concat(out)
    end
    local keys = {}
    for k in pairs(v) do
      if type(k) ~= 'string' then fail('invalid_input', 'Object keys must be text') end
      keys[#keys + 1] = k
    end
    table.sort(keys)
    local out = {'{'}
    for _, k in ipairs(keys) do out[#out + 1] = part(k) .. canon(v[k]) end
    out[#out + 1] = '}'
    return table.concat(out)
  end
  fail('invalid_input', 'Unsupported argument value')
end
local function opt_text(v, name)
  if v == nil then return nil end
  return text(v, name)
end
local function only(args, allowed)
  if type(args) ~= 'table' then fail('invalid_input', 'Arguments must be an object') end
  for k in pairs(args) do if not allowed[k] then fail('invalid_input', 'Unknown argument: ' .. tostring(k)) end end
end

-- start_size(template, root): the largest final-record size of a start of template at root (it is
-- set after the engine, below).
local start_size
-- Save. The form submit and templates.save call save_core. values are the form's values
-- ({name, root, pane_<block> = choice}); fill = true takes the capture's guess for a pane that
-- has no value (the agent path), else such a pane means the session changed (the form path).
-- replace (tests/templates-run.md, "Replace"): nil keeps an existing template (conflict); {rev = r}
-- replaces exactly revision r (the agent path); {form = v} is the form's field: nil or "keep" keeps,
-- "replace" replaces the record as it is at the submit.
local function save_core(caller, keys, fingerprint, session_id, values, fill, replace)
  local prior = prior_op(keys, fingerprint)
  if prior then return prior end
  local latest = false
  if replace and replace.rev == nil then
    if replace.form == 'replace' then latest = true
    elseif replace.form ~= nil and replace.form ~= 'keep' then fail('invalid_input', 'If a template has this name: choose keep or replace') end
  end
  local name = text(values.name, 'Template name')
  if #name > 60 then fail('invalid_input', 'The template name is at most 60 characters') end
  local root = resolve_root(values.root)
  local cap = capture(session_id)
  for k in pairs(values) do
    if k:sub(1, 5) == 'pane_' and not cap.panes[k:sub(6)] then fail('conflict', 'The session changed. Open Save as Template… again.') end
  end
  for _, id in ipairs(cap.order) do
    if values['pane_' .. id] == nil then
      if not fill then fail('conflict', 'The session changed. Open Save as Template… again.') end
      local pane = cap.panes[id]
      values['pane_' .. id] = pane.dir and (pane.guess or '@choose') or '@skip'
    end
  end
  local launches, labels = {}, {}
  for _, id in ipairs(cap.order) do
    local choice, pane = values['pane_' .. id], cap.panes[id]
    if choice == '@choose' then fail('invalid_input', 'Choose a launch or Leave out for each pane') end
    if choice ~= '@skip' then
      if not pane.dir then fail('invalid_input', 'A pane has no known directory. Leave it out.') end
      if not within(pane.dir, root) then
        fail('invalid_input', short(pane.dir) .. ' is outside the root. Choose a wider root, or leave the pane out.')
      end
      if choice == 'shell' then launches[id] = {shell = true}
      elseif type(choice) == 'string' and choice:sub(1, 8) == 'profile:' then
        local profile = choice:sub(9)
        local launch = {profile = profile}
        -- The spawn's args belong to the profile it ran; another profile starts with its defaults.
        if pane.guess == choice and pane.args and next(pane.args) then launch.args = pane.args end
        launches[id] = launch
      else fail('invalid_input', 'Unknown launch choice') end
      -- The requested title belongs to the profile that the pane ran: a leaf keeps it only when
      -- the chosen launch is that profile (also an explicit Shell for a busy shell spawn).
      local same = (choice == 'shell' and pane.spawn_profile == SHELL_PROFILE) or
        (choice:sub(1, 8) == 'profile:' and choice:sub(9) == pane.spawn_profile)
      if pane.requested_title and same then labels[id] = pane.requested_title end
    end
  end
  local tabs = {}
  for _, tab in ipairs(cap.tabs) do
    local layout = to_layout(tab.layout, cap, launches, root, labels)
    if layout then tabs[#tabs + 1] = {title = tab.title, layout = layout} end
  end
  if #tabs == 0 then fail('invalid_input', 'The template has no panes') end
  -- The save check (tests/templates-run.md, "Save size"): refuse a template that cannot start at
  -- this root. The template of a start has no saved_by (start_core).
  local size = start_size({v = 1, name = name, tabs = tabs}, root)
  if size > run_module.MAX_RUN then
    fail('invalid_input', string.format('The template is too large to start: its start record needs about %d KiB at this root, and the limit is %d KiB. Leave out panes.',
      math.ceil(size / 1024), math.floor(run_module.MAX_RUN / 1024)))
  end
  -- saved_by: who saved it (information only; anyone may delete it).
  local template = {v = 1, name = name, tabs = tabs, saved_by = caller.id}
  local result = caller.id == 'user' and {close_form = true} or {name = name}
  -- One short transaction reads the template and writes it with the operation, after the
  -- capture and the size check. A replay that committed meanwhile answers. Revision guard: an
  -- agent's replace names the revision that it read (templates.get), so only that revision is
  -- replaced. The form's Replace it replaces the template as it is at the commit.
  local outcome = app.db.transaction(function()
    local again = prior_op(keys, fingerprint)
    if again then return {result = again} end
    local existing = data.get_template(hex(name))
    if replace and replace.rev then
      if not existing or existing.rev ~= replace.rev then
        fail('conflict', 'The template ' .. named(name) .. ' changed or was deleted after you read it. Read it again with templates.get.')
      end
    elseif existing and not latest then
      fail('conflict', 'A template named ' .. named(name) .. ' exists. Choose another name, or ' ..
        (caller.id == 'user' and 'choose Replace it.' or 'replace it: templates.get gives its rev.'))
    end
    data.put_template(hex(name), data.next_rev(), template)
    data.put_op(keys[1], fingerprint, result)
    return {result = result}
  end)
  return outcome.result
end

local function save_template(args)
  local context = context_of(args)
  local values = form_values(args)
  return save_core(USER, op_keys('save', USER, args.operation_key), values_fingerprint('save-v2/', context, values), context.session_id, values, false, {form = values.replace})
end

-- templates.save {name, root, session_id?, panes?, key}. panes maps a block ID to 'shell',
-- 'profile:<id>' or 'skip'; a pane without an entry takes the capture's guess. The fingerprint
-- covers the raw arguments (an omitted session is 'default'), so a retry answers before anything
-- live is read.
local function agent_save(caller, args)
  only(args, {name = true, root = true, session_id = true, panes = true, replace = true, key = true})
  text(args.name, 'name'); text(args.root, 'root'); opt_text(args.session_id, 'session_id')
  if args.panes ~= nil then
    if type(args.panes) ~= 'table' then fail('invalid_input', 'panes must be an object') end
    for id, choice in pairs(args.panes) do
      text(id, 'pane block ID')
      if type(choice) ~= 'string' or not (choice == 'shell' or choice == 'skip' or choice:match('^profile:.+')) then
        fail('invalid_input', 'A pane choice is shell, skip or profile:<id>')
      end
    end
  end
  -- replace: a canonical nonzero revision from templates.get, kept as text. An omitted replace
  -- leaves the fingerprint as it was before replace existed.
  if args.replace ~= nil and (type(args.replace) ~= 'string' or #args.replace > 20 or not args.replace:match('^[1-9]%d*$')) then
    fail('invalid_input', 'replace is the rev that templates.get gives (a decimal number without leading zeros, not 0)')
  end
  local fp_args = {name = args.name, root = args.root, session_id = args.session_id or false, panes = args.panes or {}}
  if args.replace ~= nil then fp_args.replace = args.replace end
  local fingerprint = 'save-agent-v1/' .. canon(fp_args)
  local session_id = args.session_id or caller.session_id
  local values = {name = args.name, root = args.root}
  for id, choice in pairs(args.panes or {}) do values['pane_' .. id] = choice == 'skip' and '@skip' or choice end
  if type(session_id) ~= 'string' or session_id == '' then
    local prior = prior_op(op_keys('save', caller, args.key), fingerprint)
    if prior then return prior end
    fail('invalid_input', 'You have no session; set session_id')
  end
  return save_core(caller, op_keys('save', caller, args.key), fingerprint, session_id, values, true, args.replace and {rev = args.replace} or nil)
end

-- The engine and its adapter to hub.spawn_window. A user's start acts for "user"; an agent's
-- start sends each tab with the run's grant (grant_id), exactly as the grant names it.
local function hub_layout(node)
  if node.direction then
    return {split = {direction = node.direction, ratio = node.ratio, before = hub_layout(node.before), after = hub_layout(node.after)}}
  end
  local leaf = {cwd = node.cwd}
  if node.shell then leaf.profile = SHELL_PROFILE else
    leaf.profile = node.profile
    if node.args and next(node.args) then leaf.args = node.args end
  end
  if node.label then leaf.title = node.label end
  return {leaf = leaf}
end
local function start_tab(request)
  local args = {key = request.key, session = request.session, title = request.title, layout = hub_layout(request.layout)}
  if request.grant_id then args.grant_id = request.grant_id else
    args['for'] = 'user'
    if request.placement then args.placement = request.placement end
  end
  local r = hub('hub.spawn_window', args)
  local blocks, err = {}, nil
  for _, leaf in ipairs(r.leaves or {}) do
    if leaf.block_id then blocks[#blocks + 1] = leaf.block_id end
    if not err and leaf.error and leaf.error ~= '' then err = leaf.error end
  end
  return {status = r.status, window_id = r.window_id, block_ids = blocks, error = err}
end
-- grant_entries are the exact requests that an agent's run will send: one hub.spawn_window per
-- tab. A new session is named by its ensure key (the hub resolves it); a chosen one by its ID.
local function grant_entries(run)
  local entries = {}
  for _, tab in ipairs(run.tabs) do
    entries[#entries + 1] = {action = 'hub.spawn_window', key = tab.key, request = {
      session = run.session_id or {ensure_key = run.session_key}, title = tab.title, layout = hub_layout(tab.layout)}}
  end
  return entries
end
local function grant_key(run) return 'run/' .. run.id end
-- find_grant (engine recovery): the grant of this run if the hub has it, active and with exactly
-- the run's requests. It never creates one: that needs the agent's call. The agent is not compared:
-- the grant's agent can be a later ID of the run's agent (an identity that took over request.by),
-- and the plugin can identify only a caller, not an ID. The grant key run/<id> is the plugin's own
-- (the hub scopes grant keys to the plugin), and start_core creates it only in the initial call
-- or a replay with this run's operation key, which only the run's agent (any of its IDs) can make.
local function find_grant(run)
  local g = hub('hub.grant.get', {key = grant_key(run)})
  if not g.found or g.state ~= 'active' then return nil end
  if canon(g.entries) ~= canon(grant_entries(run)) then return nil end
  return g.grant_id
end
local invalidate
-- Ticks run outside action handlers. An error stops the loop until the next wake (contract).
-- loop.timer and loop.pump are table fields: pump and its callback write them, and pcall catches
-- errors in the handlers that call pump (LazyRex docs/rex-protocol.md, "Rex Lua runtime"). The
-- engine's maintenance timer calls loop.pump.
local loop = {timer = nil, pump = nil}
local function form_key(key) return 'start-form/' .. hex(key) end
local function switch_key(start_key) return 'switch/' .. hex(start_key) end
-- SWITCH_WAIT: the Start form's switch wait (switch_app). A run with a form that can still switch
-- is retired only after its switch decision, or SWITCH_WAIT + SWITCH_GRACE seconds after the
-- form's submit (switch_settled, templates_run.lua). The grace is a policy delay, not proof that
-- every poll has ended: a later poll gets the retired run's ID (start_core).
local SWITCH_WAIT = tonumber(rex.args.switch_wait) or 15 -- tests pass a shorter wait
local SWITCH_GRACE = 60
local engine = run_module.new({hub = hub, start_tab = start_tab, resolve_root = resolve_root, resolve_dir = resolve_dir,
  find_grant = find_grant, revoke = function(grant_id) hub('hub.grant.revoke', {grant_id = grant_id}) end,
  log = function(line) print('templates: ' .. line) end,
  changed = function() if invalidate then pcall(invalidate) end end,
  form_key = form_key, switch_key = switch_key, wake = function() if loop.pump then loop.pump() end end,
  retirable = function(run, form, switch, now) return run_module.switch_settled(run, form, switch, now, SWITCH_WAIT + SWITCH_GRACE) end})
-- start_size measures four references (engine.measure): a user and an agent start, each into a new
-- and an existing session. The keys are built as op_keys builds them, with the longest agent ID
-- and key of "<" (6 bytes each in JSON). The new session name is the template name (the default).
-- The window ID and the session ID are MAX_ID bytes.
start_size = function(template, root)
  local key, id = string.rep('<', run_module.MAX_KEY), string.rep('<', run_module.MAX_ID)
  local user_key, agent_key = 'start/' .. part(key), 'start/agent/' .. part(id) .. part(key)
  local session = string.rep('x', run_module.MAX_ID)
  local placement = {focus = {source_window_id = session}}
  local refs = {
    {key = user_key, new_session_name = template.name, placement = placement},
    {key = user_key, session_id = session, placement = placement},
    {key = agent_key, by = id, new_session_name = template.name},
    {key = agent_key, by = id, session_id = session}}
  local max = 0
  for _, ref in ipairs(refs) do
    ref.template, ref.root = template, root
    max = math.max(max, engine.measure(ref))
  end
  return max
end
local function pump()
  if loop.timer then return end
  loop.timer = rex.after(0.05, function()
    loop.timer = nil
    local more, err = engine.tick()
    if err then print('templates: ' .. (type(err) == 'table' and tostring(err.message or err.code) or tostring(err))) end
    if more and not err then pump() end
  end)
end
loop.pump = pump
local function wake() engine.wake(); pump() end

-- Start form.
local function source_dir(context)
  if type(context.source_block_id) ~= 'string' or context.source_block_id == '' then return nil end
  local ok, proc = pcall(rex_ok, 'com.superlogical.terminal.process', {session_id = context.session_id, block_id = context.source_block_id, args = {}})
  local cwd = pane_dir(context.session_id, context.source_block_id, ok and proc.child or {}, ok and proc.foreground or {}, nil)
  if not cwd then return nil end
  return git_root(cwd) or cwd
end
-- A start into a new session switches the app to it (the maintainer, 2026-10-19; coordinator's rules).
-- The form stays open ({status = 'running'}: the hub calls the action again about every 0.5 s)
-- until the first tab opens, the start stops, or SWITCH_WAIT seconds pass. Then the plugin asks
-- hub.app.select_session from the still-open form; the hub refuses when the user left the form.
-- The decision is one-shot under the start's operation key: 'attempted' commits before the call,
-- so a crash or lost answer after it reads as 'unknown' and never switches again. An agent's
-- start never switches the app: it has no form.
local starting = {} -- view_id -> true while its start form waits (render only)
local function switch_app(view_id, start_key, run_id, at)
  local skey = switch_key(start_key)
  local saved = hub('hub.store.get', {keys = {skey}}).records[skey]
  if saved and type(saved.value) == 'table' then
    if saved.value.state ~= 'attempted' then return saved.value end
    local value = {state = 'unknown', message = 'The outcome of the switch is unknown'}
    local stored = hub('hub.store.batch', {ops = {{key = skey, if_rev = saved.rev, value = value}}})
    if stored.conflict then return switch_app(view_id, start_key, run_id, at) end
    return value
  end
  local function decide(value)
    local stored = hub('hub.store.batch', {ops = {{key = skey, if_rev = '0', value = value}}})
    if stored.conflict then return switch_app(view_id, start_key, run_id, at) end
    return value
  end
  -- Expiry comes first: a recovered or legacy start (no at) never switches late, even when its
  -- first tab is open now (Codex's review).
  if os.time() - at >= SWITCH_WAIT then
    return decide({state = 'refused', code = 'timeout', message = 'The automatic-switch wait (' .. SWITCH_WAIT .. ' s) expired'})
  end
  local run = engine.get(run_id)
  local first = run.results and run.results[1]
  if type(first) ~= 'table' or first.status ~= 'open' or type(first.window_id) ~= 'string' or first.window_id == '' or not run.session_id then
    if run.status ~= 'queued' and run.status ~= 'starting' then
      return decide({state = 'refused', code = 'not_started', message = 'The first tab did not open'})
    end
    return nil
  end
  local stored = hub('hub.store.batch', {ops = {{key = skey, if_rev = '0', value = {state = 'attempted'}}}})
  if stored.conflict then return switch_app(view_id, start_key, run_id, at) end
  local ok, err = pcall(hub, 'hub.app.select_session', {view_id = view_id, session_id = run.session_id, window_id = first.window_id})
  local value = {state = 'done'}
  if not ok then
    local code = type(err) == 'table' and err.code or 'unavailable'
    local refused = code == 'not_focused' or code == 'no_app' or code == 'ambiguous_app' or code == 'refused'
    value = {state = refused and 'refused' or 'unknown', code = code, message = type(err) == 'table' and err.message or tostring(err)}
  end
  -- A failed write leaves 'attempted', which a later read turns into 'unknown'.
  pcall(hub, 'hub.store.batch', {ops = {{key = skey, if_rev = stored.revs[skey], value = value}}})
  return value
end

-- start_core admits a start for a caller. It freezes the engine request under the operation key
-- before admission, so a retry after a lost reply admits the same request even if the template
-- was edited or deleted since. intent = {template, root, session_id | new_session_name,
-- placement?}. An agent's start also gets the grant of its exact tab requests, in the agent's
-- call (caller.pid); the run dispatches nothing before it (templates_run.lua).
local function start_core(caller, key, fingerprint, intent)
  local record_key, marker_key = form_key(key), 'run-key/' .. key
  local request, at
  local got = hub('hub.store.get', {keys = {record_key, marker_key}}).records
  local saved = got[record_key]
  -- A record whose retired run's marker has expired counts as absent (before the fingerprint
  -- check): the key starts a new run, and the new record replaces it (if_rev).
  if saved and type(saved.value) == 'table' and not run_module.form_expired(saved, got[marker_key], os.time()) then
    if saved.value.fingerprint ~= fingerprint then fail('operation_conflict', 'Operation key already has different content') end
    -- A Start form that runs again after its run was retired (a late poll, or the operation again
    -- after a hub restart) gets that run's ID: no new run, no switch. The marker must name this
    -- form record (form_rev). An agent's replay gets expired (engine.admit).
    local m = got[marker_key] and got[marker_key].value
    if caller.id == 'user' and type(m) == 'table' and m.expired_at ~= nil and m.form_rev ~= nil and m.form_rev == saved.rev then
      return saved.value.request, {id = m.id, retired = true}
    end
    -- A record from before the switch has no time: its wait is over.
    request, at = saved.value.request, type(saved.value.at) == 'number' and saved.value.at or 0
  else
    -- Checked before the frozen request is written: the run repeats the session ID in each tab.
    if intent.session_id ~= nil and not run_module.valid_id(intent.session_id) then fail('invalid_input', 'Invalid session ID') end
    local tpl = load_template(intent.template)
    request = {key = key, template = {v = tpl.v, name = tpl.name, tabs = tpl.tabs}, root = text(intent.root, 'Root')}
    if intent.placement then request.placement = intent.placement end
    if intent.session_id then request.session_id = intent.session_id
    else request.new_session_name = intent.new_session_name or tpl.name end
    if caller.id ~= 'user' then request.by = caller.id end
    at = os.time()
    local stored = hub('hub.store.batch', {ops = {{key = record_key, if_rev = saved and saved.rev or '0', value = {fingerprint = fingerprint, request = request, at = at}}}})
    if stored.conflict then fail('conflict', 'This start is being submitted twice; retry with the same key') end
  end
  local run = engine.admit(request)
  if run.request.by and run.grant_id == nil then
    if run.status == 'authorizing' then
      if not caller.pid then fail('refused', 'Only the agent that started the run can authorize it') end
      local g = hub('hub.grant.create', {on_behalf = caller.pid, key = grant_key(run), entries = grant_entries(run)})
      if g.state ~= 'active' then fail('conflict', 'The grant of this start was revoked') end
      run = engine.authorize(run.id, g.grant_id)
    else
      -- The run ended (dismissed) before it recorded its grant. A grant made by an earlier call
      -- is recorded now, so the engine revokes it. Nothing dispatches: the run is finished.
      local grant_id = find_grant(run)
      if grant_id then run = engine.authorize(run.id, grant_id) end
    end
  end
  pump()
  return request, run, at
end

local function start_poll(args)
  local context = context_of(args)
  local values = form_values(args)
  local key = op_keys('start', USER, args.operation_key)[1]
  local intent = {template = values.template, root = values.root}
  -- Each tab focuses its first pane only while the form's tab is still the active one in the
  -- target session (hub.spawn_window). In a new session it never matches; switch_app moves the app.
  if type(context.window_id) == 'string' and context.window_id ~= '' then
    intent.placement = {focus = {source_window_id = context.window_id}}
  end
  if values.session_id == '@new' then
    intent.new_session_name = type(values.session_name) == 'string' and values.session_name ~= '' and values.session_name or nil
  else intent.session_id = text(values.session_id, 'Session') end
  local request, run_state, at = start_core(USER, key, values_fingerprint('start-v1/', context, values), intent)
  local done = {panel = {route = '/panels/templates'}, run_id = run_state.id}
  if run_state.retired then
    if type(args.view_id) == 'string' then starting[args.view_id] = nil end
    return done
  end
  -- "Add to existing session" never switches: the first new tab already has the focus there.
  if not request.new_session_name then return done end
  local view_id = text(args.view_id, 'view ID')
  if not switch_app(view_id, key, run_state.id, at) then
    if not starting[view_id] then starting[view_id] = true; pcall(invalidate) end
    return {status = 'running', run_id = run_state.id}
  end
  starting[view_id] = nil
  return done
end

-- TRANSIENT: the error codes after which the hub runs the operation again (hub viewsvc.go,
-- definiteFailure). Any other error ends the operation, so its form must not keep "Starting…".
local TRANSIENT = {disconnected = true, client_unavailable = true, timeout = true, deadline_exceeded = true,
  unavailable = true, outcome_unknown = true}
local function start_session(args)
  local ok, result = pcall(start_poll, args)
  if ok then return result end
  local code = type(result) == 'table' and type(result.code) == 'string' and result.code:lower() or nil
  local view_id = args.view_id
  if not (code and TRANSIENT[code]) and type(view_id) == 'string' and starting[view_id] then
    starting[view_id] = nil
    pcall(invalidate)
  end
  error(result, 0)
end

-- templates.start {template, root, session_id? | new_session?, key} -> {run_id}. Neither session
-- field: a new session named after the template (the form's default). The result is the stable
-- admission; templates.runs gives the live state.
local function agent_start(caller, args)
  only(args, {template = true, root = true, session_id = true, new_session = true, key = true})
  text(args.template, 'template'); text(args.root, 'root')
  opt_text(args.session_id, 'session_id'); opt_text(args.new_session, 'new_session')
  if args.session_id and args.new_session then fail('invalid_input', 'Set session_id or new_session, not both') end
  local fingerprint = 'start-agent-v1/' .. canon({template = args.template, root = args.root,
    session_id = args.session_id or false, new_session = args.new_session or false})
  local keys = op_keys('start', caller, args.key)
  -- A start of another ID of this agent with this key is the same operation (its record). Two IDs
  -- that both started with the key are a conflict, also with equal arguments (prior_op).
  local key, found = keys[1], 0
  local records = {}
  for _, k in ipairs(keys) do
    records[#records + 1] = form_key(k)
    records[#records + 1] = 'run-key/' .. k
  end
  local got = hub('hub.store.get', {keys = records}).records
  for _, k in ipairs(keys) do
    -- A record whose retired run's marker has expired does not count (start_core).
    local r = got[form_key(k)]
    if r and r.value ~= nil and not run_module.form_expired(r, got['run-key/' .. k], os.time()) then
      found = found + 1
      if found == 1 then key = k end
    end
  end
  if found > 1 then fail('conflict', 'Two IDs of this agent used the key; use a new key') end
  local _, run = start_core(caller, key, fingerprint, {template = args.template, root = args.root,
    session_id = args.session_id, new_session_name = args.new_session})
  return {run_id = run.id}
end

-- Templates panel: saved templates and recent starts.
local function recent_runs()
  local runs = scan_all('run/')
  table.sort(runs, function(a, b) return #a.id > #b.id or #a.id == #b.id and a.id > b.id end)
  return runs
end
local function run_detail(r)
  local done = (r.next_tab or 1) - 1
  local detail = r.status .. ' · ' .. done .. '/' .. #r.tabs .. ' tabs'
  if r.error and r.error ~= '' then detail = detail .. ' · ' .. r.error end
  return detail
end
-- The newest start into a new session that did not switch the app says how to switch by hand.
local switch_reasons = {
  not_focused = 'you left the form before its first tab opened',
  no_app = 'no Rex app shows the session of the form',
  ambiguous_app = 'more than one Rex app shows the session of the form',
}
local function switch_notice(runs)
  local r = runs[1]
  if not r or not r.request.new_session_name or r.request.by then return nil end
  local skey = switch_key(r.request.key)
  local saved = hub('hub.store.get', {keys = {skey}}).records[skey]
  local sw = saved and type(saved.value) == 'table' and saved.value
  if not sw or sw.state == 'done' or sw.code == 'not_started' then return nil end
  local name, session = r.request.template.name, '"' .. r.request.new_session_name .. '"'
  if sw.state ~= 'refused' then
    return name .. ': the app may not have switched to the new session ' .. session .. '. If it did not, use Go to Session in the Rex app.'
  end
  if sw.code == 'timeout' then
    -- The session can still be on its way, or the action resumed late (recovery).
    return name .. ': the wait for the automatic switch to the new session ' .. session .. ' expired, so the app did not switch.'
      .. ' When the session is available, use Go to Session in the Rex app.'
  end
  return name .. ' started in the new session ' .. session .. '. The app did not switch to it: '
    .. (switch_reasons[sw.code] or tostring(sw.message)) .. '. To go there, use Go to Session in the Rex app.'
end
local function stuck(r) return r.status == 'blocked' or r.status == 'pending' or r.status == 'unknown' or r.status == 'authorizing' end
local function finished(r) return r.status == 'open' or r.status == 'failed' or r.status == 'closed' or r.status == 'dismissed' end

-- View size. render replies with the whole view tree, and a plugin reply over 64 KiB never
-- arrives (LazyRex docs/rex-protocol.md, "Rex Lua runtime"). The panel and the Start form keep the
-- encoded reply {tree = ...} at most VIEW_BUDGET bytes. Each view builds a skeleton first: the
-- constant parts, every list empty, each value that can be long empty, and each omitted-count
-- widget at its largest text (MAX_COUNT). Then it adds rows in priority order while they fit. JSON
-- is a concatenation, so the size of the reply is the skeleton plus each added row and its comma.
-- The view then sets the real counts and drops the empty parts (the reply only gets smaller), and
-- a last encode checks it. A view over the budget at either check is replaced by too_large_view.
local VIEW_BUDGET, MAX_COUNT = 48 * 1024, 9999999999
-- add appends the items to list, all or none, when they fit. extra is a change of size outside the
-- list (a value that the first item sets).
local function add(budget, list, items, extra)
  local cost, n = extra or 0, #list
  for _, item in ipairs(items) do
    cost = cost + json_size(item) + (n > 0 and 1 or 0)
    n = n + 1
  end
  if budget.size + cost > VIEW_BUDGET then return false end
  for _, item in ipairs(items) do list[#list + 1] = item end
  budget.size = budget.size + cost
  return true
end
local function count(n, one, many) return n .. ' ' .. (n == 1 and one or many) end
local function too_large_view(title, form)
  local nodes = {{id = 'too_large', type = 'widget', text = 'This view is too large to show. Use the templates agent tools.'}}
  if form then nodes[2] = cancel_node() end
  return {tree = {title = title, nodes = nodes}}
end
local function checked(reply, title, form)
  if json_size(reply) > VIEW_BUDGET then return too_large_view(title, form) end
  return reply
end

-- Templates panel. Display order: the switch notice, Start, Save, the templates, the unfinished
-- starts (stuck: blocked, pending, unknown, authorizing; each with Dismiss, a blocked one also with
-- Retry) and the 10 newest other starts. Budget priority: the notice, the stuck starts (newest
-- first; the rows of one start fit together or not at all), the templates, the 10 newest other
-- starts. The omitted-count widgets count hidden starts and templates, not rows.
local function more_runs_text(unfinished, done)
  local parts = {}
  if unfinished > 0 then parts[#parts + 1] = count(unfinished, 'more unfinished start', 'more unfinished starts') end
  if done > 0 then parts[#parts + 1] = done .. ' more finished' .. (#parts == 0 and (done == 1 and ' start' or ' starts') or '') end
  return table.concat(parts, ', ') .. ': use templates.runs'
end
local function more_templates_text(n) return count(n, 'more template', 'more templates') .. ': use templates.list' end
local function render_panel()
  local list, runs = templates(), recent_runs()
  local template_items, stuck_items, recent_items = {}, {}, {}
  local start = {id = 'start', type = 'widget', text = '', action = {name = 'start', label = 'Start Session…', enabled = #list > 0, user_only = 'navigation'}}
  local save = {id = 'save', type = 'widget', text = '', action = {name = 'save', label = 'Save this session as a template…', enabled = true, user_only = 'navigation'}}
  local tlist = {id = 'templates', type = 'list', label = 'Templates', items = template_items}
  local more_templates = {id = 'more_templates', type = 'widget', text = more_templates_text(MAX_COUNT)}
  local slist = {id = 'stuck', type = 'list', label = 'Unfinished starts', items = stuck_items}
  local rlist = {id = 'runs', type = 'list', label = 'Recent starts', items = recent_items}
  local more_runs = {id = 'more_runs', type = 'widget', text = more_runs_text(MAX_COUNT, MAX_COUNT)}
  local nodes = {start, save, tlist, more_templates, slist, rlist, more_runs}
  local reply = {tree = {title = 'Templates', nodes = nodes}}
  local budget = {size = json_size(reply)}
  if budget.size > VIEW_BUDGET then return too_large_view('Templates') end
  -- The notice goes before the other nodes: its comma is counted with it (extra = 1).
  local text = switch_notice(runs)
  local notice = text and {id = 'switch', type = 'widget', text = text}
  if notice and not add(budget, {}, {notice}, 1) then notice = nil end
  local shown = {}
  for _, r in ipairs(runs) do
    if stuck(r) then
      -- The label names the action, as the home's failed workers do ("· Dismiss").
      local label, detail = r.request.template.name .. ' in ' .. short(r.root), run_detail(r)
      local rows = {}
      if r.status == 'blocked' then
        rows[1] = {id = 'retry:' .. r.id, label = label .. ' · Retry', detail = detail,
          action = {name = 'retry', label = 'Retry', enabled = true, tool = 'templates.retry'}}
      end
      rows[#rows + 1] = {id = 'dismiss:' .. r.id, label = label .. ' · Dismiss', detail = detail,
        action = {name = 'dismiss', label = 'Dismiss', enabled = true, tool = 'templates.dismiss'}}
      if add(budget, stuck_items, rows) then shown[r.id] = true end
    end
  end
  local hidden_templates = 0
  for _, t in ipairs(list) do
    -- The row opens the template's menu (Start session…, Delete…); its ID is the hex of the key.
    local tabs = type(t.value.tabs) == 'table' and #t.value.tabs or 0
    local item = {id = t.hex, label = display(t.name or t.value.name or t.hex), detail = count(tabs, 'tab', 'tabs'),
      action = {name = 'open', label = 'Open', enabled = true, user_only = 'navigation'}}
    if not navigable(t.hex) then
      item.action.enabled = false
      item.detail = 'Name too long for this panel: use templates.get or templates.delete'
    end
    if not add(budget, template_items, {item}) then hidden_templates = hidden_templates + 1 end
  end
  local others = 0
  for _, r in ipairs(runs) do
    if not stuck(r) and others < 10 then
      others = others + 1
      local item = {id = r.id, label = r.request.template.name .. ' in ' .. short(r.root), detail = run_detail(r)}
      if add(budget, recent_items, {item}) then shown[r.id] = true end
    end
  end
  local hidden_unfinished, hidden_finished = 0, 0
  for _, r in ipairs(runs) do
    if not shown[r.id] then
      if finished(r) then hidden_finished = hidden_finished + 1 else hidden_unfinished = hidden_unfinished + 1 end
    end
  end
  local display = {}
  if notice then display[1] = notice end
  display[#display + 1] = start
  display[#display + 1] = save
  display[#display + 1] = tlist
  if hidden_templates > 0 then
    more_templates.text = more_templates_text(hidden_templates)
    display[#display + 1] = more_templates
  end
  if #stuck_items > 0 then display[#display + 1] = slist end
  if #recent_items > 0 then display[#display + 1] = rlist end
  if hidden_unfinished + hidden_finished > 0 then
    more_runs.text = more_runs_text(hidden_unfinished, hidden_finished)
    display[#display + 1] = more_runs
  end
  reply.tree.nodes = display
  return checked(reply, 'Templates')
end

-- Start form. Budget priority: the template options (by name; the first one is the default value),
-- the root default (a path), then the session options. The @new option is part of the skeleton.
-- When no template option fits, the form is not shown: an agent can use templates.start.
local function more_options_text(t, s)
  local parts = {}
  if t > 0 then parts[#parts + 1] = count(t, 'more template', 'more templates') end
  if s > 0 then parts[#parts + 1] = count(s, 'more session', 'more sessions') end
  return table.concat(parts, ' and ') .. ' are not in the lists: use templates.start.'
end
-- start_view renders the Start form. hx (from /forms/start/<hex>): the template of that key is the
-- selected option, reserved before the others; the form never selects another template instead.
local function start_view(context, view_id, hx)
  local waiting = starting[view_id]
  local nodes = {}
  if waiting then nodes[1] = {id = 'starting', type = 'widget', text = 'Starting… The app goes to the new session when its first tab opens.'} end
  local tree = {title = 'Start Session', nodes = nodes,
    status = waiting and {state = 'working', msg = 'Starting'} or {state = 'blocked', kind = 'question', msg = 'Waiting for input'}}
  local want
  if hx then
    local r, name, reason = read_template(hx), unhex(hx), nil
    if not r then reason = 'This template no longer exists.'
    elseif not json_safe(name) then reason = 'The name of this template cannot be used in a form. Use templates.start.'
    else want = {hex = hx, name = name, value = r.value} end
    if reason then
      nodes[#nodes + 1] = {id = 'no_template', type = 'widget', text = reason}
      nodes[#nodes + 1] = cancel_node()
      return checked({tree = tree}, 'Start Session', true)
    end
  end
  local list = templates()
  if #list == 0 then
    nodes[#nodes + 1] = {id = 'empty', type = 'widget', text = 'No templates yet. Use Save as Template… in a session first.'}
    nodes[#nodes + 1] = cancel_node()
    return checked({tree = tree}, 'Start Session', true)
  end
  local options, sessions = {}, {{value = '@new', label = 'New session…'}}
  local fields = {
    {id = 'template', label = 'Template', kind = 'select', required = true, value = '', options = options},
    {id = 'root', label = 'Root (the directory the panes are relative to)', kind = 'text', required = true, value = ''},
    {id = 'session_id', label = 'Session', kind = 'select', required = true, value = '@new', options = sessions},
    {id = 'session_name', label = 'New session name (default: the template name)', kind = 'text', value = ''},
  }
  local form = {id = 'start_session', type = 'form', fields = fields,
    submit_action = {name = 'submit', label = 'Start session', enabled = not waiting, tool = 'templates.start'}}
  local more = {id = 'more_options', type = 'widget', text = more_options_text(MAX_COUNT, MAX_COUNT)}
  local first = #nodes + 1
  nodes[first], nodes[first + 1], nodes[first + 2] = form, more, cancel_node()
  local reply = {tree = tree}
  local budget = {size = json_size(reply)}
  if budget.size > VIEW_BUDGET then return too_large_view('Start Session', true) end
  local hidden_templates, hidden_sessions = 0, 0
  -- An option's value is the name of the record's key (its identity); a key whose name is not
  -- JSON-safe has no option. The first option is also the default value ('' in the skeleton: 2
  -- bytes).
  local function option(t)
    local tabs = type(t.value.tabs) == 'table' and #t.value.tabs or 0
    return {value = t.name, label = display(t.name) .. ' · ' .. count(tabs, 'tab', 'tabs')}
  end
  if want then
    if not add(budget, options, {option(want)}, json_size(want.name) - 2) then
      nodes[first], nodes[first + 1], nodes[first + 2] = {id = 'no_template', type = 'widget',
        text = 'This template does not fit in this form. Use templates.start.'}, cancel_node(), nil
      return checked({tree = tree}, 'Start Session', true)
    end
    fields[1].value = want.name
  end
  for _, t in ipairs(list) do
    if not (want and t.hex == want.hex) then
      if t.name and add(budget, options, {option(t)}, #options == 0 and json_size(t.name) - 2 or 0) then
        if #options == 1 then fields[1].value = t.name end
      else hidden_templates = hidden_templates + 1 end
    end
  end
  if #options == 0 then
    nodes[first], nodes[first + 1], nodes[first + 2] = {id = 'no_template', type = 'widget',
      text = 'The template list is too large for this form. Use templates.start.'}, cancel_node(), nil
    return checked({tree = tree}, 'Start Session', true)
  end
  local root = source_dir(context)
  if root and budget.size + json_size(root) - 2 <= VIEW_BUDGET then
    fields[2].value = root
    budget.size = budget.size + json_size(root) - 2
  end
  for _, s in ipairs(hub('hub.session.list').sessions or {}) do
    local opt = {value = s.session_id, label = (s.label or '') ~= '' and s.label or s.session_id}
    if not add(budget, sessions, {opt}) then hidden_sessions = hidden_sessions + 1 end
  end
  if hidden_templates + hidden_sessions > 0 then
    more.text = more_options_text(hidden_templates, hidden_sessions)
  else
    table.remove(nodes, first + 1)
  end
  return checked(reply, 'Start Session', true)
end

local WAITING = {state = 'blocked', kind = 'question', msg = 'Waiting for input'}
-- The template menu (/forms/template/<hex>): the panel row's action. It names the template by its
-- key and offers Start session… and Delete… (navigation only).
local function menu_view(hx)
  local r, nodes = read_template(hx), {}
  if not r then
    nodes[1] = {id = 'missing', type = 'widget', text = 'This template no longer exists.'}
  else
    local summary = count(type(r.value.tabs) == 'table' and #r.value.tabs or 0, 'tab', 'tabs')
    if type(r.value.saved_by) == 'string' then summary = summary .. ' · saved by ' .. display(r.value.saved_by) end
    nodes[1] = {id = 'summary', type = 'widget', text = summary}
    nodes[2] = {id = 'template_menu', type = 'list', label = 'Template', items = {
      {id = 'start', label = 'Start session…', action = {name = 'start', label = 'Start session…', enabled = true, user_only = 'navigation'}},
      {id = 'delete', label = 'Delete…', action = {name = 'delete', label = 'Delete…', enabled = true, user_only = 'navigation'}}}}
  end
  nodes[#nodes + 1] = cancel_node('Close')
  return checked({tree = {title = display(unhex(hx)), menu = true, nodes = nodes, status = WAITING}}, 'Template', true)
end
-- The delete confirmation (/forms/delete/<hex>/<rev>): <rev> is the template's revision when the
-- user chose Delete…. It shows that revision only; another revision, or no record, has no submit.
local function delete_view(hx, rev)
  local r, nodes = read_template(hx), {}
  if not r or r.rev ~= rev then
    nodes[1] = {id = 'changed', type = 'widget', text = 'The template changed or was deleted after you chose Delete.'}
  else
    local tabs = count(type(r.value.tabs) == 'table' and #r.value.tabs or 0, 'tab', 'tabs')
    nodes[1] = {id = 'question', type = 'widget', text = 'Delete the template ' .. display(unhex(hx)) .. ' (' .. tabs .. ')? This cannot be undone.'}
    nodes[2] = {id = 'confirm', type = 'form', fields = {},
      submit_action = {name = 'submit', label = 'Delete', enabled = true, tool = 'templates.delete'}}
  end
  nodes[#nodes + 1] = cancel_node()
  return checked({tree = {title = 'Delete Template', nodes = nodes, status = WAITING}}, 'Delete Template', true)
end

-- save_tree is the Save form: a fresh capture of the source session at each render.
local function save_tree(context)
  local cap = capture(context.session_id)
  local nodes = {}
  if #cap.order == 0 then
    nodes[1] = {id = 'empty', type = 'widget', text = 'This session has no panes to save.'}
  else
    nodes[1] = {id = 'save_template', type = 'form', fields = save_fields(cap, session_label(context.session_id)),
      submit_action = {name = 'submit', label = 'Save template', enabled = true, tool = 'templates.save'}}
    local help = 'A pane started from a profile keeps its profile and args. Other panes start as a shell unless you choose a profile.'
    if cap.dropped > 0 then help = help .. ' ' .. cap.dropped .. ' floating pane(s) are left out.' end
    nodes[2] = {id = 'save_help', type = 'widget', text = help}
  end
  nodes[#nodes + 1] = cancel_node()
  return {title = 'Save as Template', nodes = nodes}
end

local function render(args)
  if args.route == '/panels/templates' then return render_panel() end
  local context = context_of(args)
  if args.route == '/forms/start' then return start_view(context, args.view_id) end
  if args.route:sub(1, 13) == '/forms/start/' then return start_view(context, args.view_id, route_hex(args.route, '/forms/start/')) end
  if args.route:sub(1, 16) == '/forms/template/' then return menu_view(route_hex(args.route, '/forms/template/')) end
  if args.route:sub(1, 14) == '/forms/delete/' then return delete_view(delete_route(args.route)) end
  local tree
  if args.route == '/forms/save' then
    tree = with_dir_memo(save_tree, context)
  else
    fail('invalid_input', 'Unknown route')
  end
  tree.status = {state = 'blocked', kind = 'question', msg = 'Waiting for input'}
  return {tree = tree}
end

-- Delete: the deletion and its result commit together; a retry never deletes a newer template.
-- The operation answers first. An agent deletes any template, as the user does.
local function delete_core(caller, keys, name)
  local fingerprint = 'delete-v1/' .. part(tostring(name))
  local prior = prior_op(keys, fingerprint)
  if prior then return prior end
  -- One short transaction: the replay, the read and the deletion with its operation. An agent
  -- deletes the template by name as it is at the commit, so no revision guard is needed.
  return app.db.transaction(function()
    local again = prior_op(keys, fingerprint)
    if again then return again end
    local _, _, hx = load_template(name)
    data.delete_template(hx)
    data.put_op(keys[1], fingerprint, {})
    return {}
  end)
end
-- The panel's delete (/forms/delete/<hex>/<rev>): the key and the revision come from the route that
-- the user confirmed, never from submitted values. The replay answers first.
local function delete_ui(keys, hx, rev)
  local fingerprint = 'delete-ui-v1/' .. part(hx) .. part(rev)
  local prior = prior_op(keys, fingerprint)
  if prior then return prior end
  local result = {close_form = true}
  -- Revision guard: the user confirmed the revision in the route, so only that revision is
  -- deleted; a template replaced after the choice is kept.
  return app.db.transaction(function()
    local again = prior_op(keys, fingerprint)
    if again then return again end
    local existing = data.get_template(hx)
    if not existing or existing.rev ~= rev then fail('conflict', 'The template changed after you chose Delete. Open it again.') end
    data.delete_template(hx)
    data.put_op(keys[1], fingerprint, result)
    return result
  end)
end

-- Dismiss and retry act on one run, from the user or any agent. An agent's run still dispatches
-- only with its own grant (find_grant), whoever retries it.
local function find_run(id)
  text(id, 'run')
  if #id > 32 or not id:match('^%d+$') then fail('not_found', 'Template run not found') end
  return engine.get(id)
end
local function dismiss_core(caller, keys, id)
  local fingerprint = 'dismiss-v1/' .. part(tostring(id))
  local prior = prior_op(keys, fingerprint)
  if prior then return prior end
  find_run(id)
  -- The dismissed state and the operation result commit in one batch (engine.dismiss).
  local ok, err = pcall(engine.dismiss, id, {key = keys[1], fingerprint = fingerprint, result = {run_id = id, status = 'dismissed'}})
  if not ok then
    if type(err) == 'table' and err.code == 'op_exists' then return prior_op(keys, fingerprint) end
    error(err, 0)
  end
  pump()
  return {run_id = id, status = 'dismissed'}
end
-- Retry queues a stuck run again. The queued state commits with the operation (engine.retry), so
-- a lost reply loses no retry. A replay answers from the saved operation and schedules the run
-- (wake_one): a queued run dispatches, and a run that is stuck again is not retried again.
local function retry_core(caller, keys, id)
  local fingerprint = 'retry-v1/' .. part(tostring(id))
  local prior = prior_op(keys, fingerprint)
  if prior then
    if prior.woken then engine.wake_one(id); pump() end
    return prior
  end
  find_run(id)
  local ok, result = pcall(engine.retry, id, {key = keys[1], fingerprint = fingerprint})
  if not ok then
    if type(result) == 'table' and result.code == 'op_exists' then return retry_core(caller, keys, id) end
    error(result, 0)
  end
  pump()
  return result
end

local function action(args)
  if args.route == '/forms/save' then
    if args.node_id ~= 'save_template' or args.action ~= 'submit' then fail('invalid_input', 'Unknown form action') end
    return save_template(args)
  end
  if args.route == '/forms/start' then
    if args.node_id ~= 'start_session' or args.action ~= 'submit' then fail('invalid_input', 'Unknown form action') end
    return start_session(args)
  end
  if args.route:sub(1, 13) == '/forms/start/' then
    route_hex(args.route, '/forms/start/')
    if args.node_id ~= 'start_session' or args.action ~= 'submit' then fail('invalid_input', 'Unknown form action') end
    return start_session(args)
  end
  if args.route:sub(1, 16) == '/forms/template/' then
    local hx = route_hex(args.route, '/forms/template/')
    if args.node_id == 'template_menu' and args.action == 'start' then return {form = '/forms/start/' .. hx} end
    if args.node_id == 'template_menu' and args.action == 'delete' then
      -- The confirmation keeps the revision of this choice ('0': the record is gone).
      local r = read_template(hx)
      return {form = '/forms/delete/' .. hx .. '/' .. (r and r.rev or '0')}
    end
    fail('invalid_input', 'Unknown form action')
  end
  if args.route:sub(1, 14) == '/forms/delete/' then
    local hx, rev = delete_route(args.route)
    if args.node_id ~= 'confirm' or args.action ~= 'submit' then fail('invalid_input', 'Unknown form action') end
    return delete_ui(op_keys('delete', USER, args.operation_key), hx, rev)
  end
  if args.route == '/panels/templates' then
    if args.node_id == 'start' then return {form = '/forms/start'} end
    if args.node_id == 'save' then return {form = '/forms/save'} end
    local item = type(args.input) == 'table' and args.input.item_id
    if args.node_id == 'templates' and args.action == 'open' and type(item) == 'string' then
      local hx = route_hex('/forms/template/' .. item, '/forms/template/')
      if not navigable(hx) then
        fail('invalid_input', 'Name too long for this panel: use templates.get or templates.delete')
      end
      return {form = '/forms/template/' .. hx}
    end
    if args.node_id == 'stuck' and type(item) == 'string' then
      if args.action == 'dismiss' and item:sub(1, 8) == 'dismiss:' then
        dismiss_core(USER, op_keys('dismiss', USER, args.operation_key), item:sub(9)); return {}
      end
      if args.action == 'retry' and item:sub(1, 6) == 'retry:' then
        retry_core(USER, op_keys('retry', USER, args.operation_key), item:sub(7)); return {}
      end
    end
  end
  fail('invalid_input', 'Unknown view action')
end

-- Agent actions (exports; the hub forwards them as MCP tools). Each calls the handler of its UI
-- action with the same checks.
local function run_view(r)
  return {id = r.id, template = r.request.template.name, root = r.root, status = r.status, next_tab = r.next_tab,
    tabs = #r.tabs, error = r.error, by = r.request.by or 'user', session_id = r.session_id}
end
-- templates.runs pages. A plugin reply over 64 KiB never arrives (LazyRex docs/rex-protocol.md,
-- "Rex Lua runtime"), so one page, encoded as the reply carries it, is at most RUNS_BUDGET bytes.
-- Run IDs are decimal text (up to 32 digits): they compare by length, then as text, which is exact
-- beyond 2^53. before is a canonical ID (no leading zero); the page holds runs older than it.
local RUNS_BUDGET, RUNS_LIMIT, RUNS_MAX = 40 * 1024, 50, 100
local function older(a, b) return #a < #b or #a == #b and a < b end
local function run_page(before, limit)
  if limit == nil then limit = RUNS_LIMIT end
  if type(limit) ~= 'number' or limit % 1 ~= 0 or limit < 1 or limit > RUNS_MAX then
    fail('invalid_input', 'limit is an integer from 1 to ' .. RUNS_MAX)
  end
  if before ~= nil and (type(before) ~= 'string' or #before > 32 or not before:match('^[1-9]%d*$')) then
    fail('invalid_input', 'before is a run ID: 1 to 32 digits, without a leading zero')
  end
  -- The reply is {"runs":[v1,...],"next_before":"<ID>"}: at most 64 bytes of names, brackets and a
  -- 32-digit cursor, plus each view and its comma.
  local page, size, next_before = {}, 64, nil
  for _, r in ipairs(recent_runs()) do
    if before == nil or older(r.id, before) then
      if #page == limit then next_before = page[#page].id break end
      local view = run_view(r)
      local n = json_size(view) + 1
      if size + n > RUNS_BUDGET then
        if #page == 0 then
          fail('too_large', 'Run ' .. r.id .. ' is too large to list (' .. n .. ' bytes). For older runs, use before = "' .. r.id .. '".')
        end
        next_before = page[#page].id
        break
      end
      page[#page + 1], size = view, size + n
    end
  end
  return {runs = page, next_before = next_before}
end

-- templates.list pages summaries {name, tabs = count, saved_by}, in the byte order of names. The
-- storage key template/<hex name> is a template's identity: a row's name comes from its key, not
-- from value.name, and the cursor after is a name (the scan starts after template/<hex after>).
-- One page, encoded as the reply carries it with next_after, is at most LIST_BUDGET bytes; the
-- page adds a row only when the result with that row and its name as next_after fits.
-- next_after is the name of the last key that the page processed (listed, or passed over because
-- its value is not a template), never the scan's own cursor: rows that a scan returned but the page
-- did not use are read again by the next page. A key is cursorable when its suffix is hex and its
-- name comes back unchanged from JSON within MAX_AFTER_JSON bytes, the bound of the after argument.
-- A key that is not cursorable (only another writer makes one: save allows names of 60 bytes from
-- a JSON request) blocks the list: a page ends before it, and a page that starts at it fails with
-- too_large, as no cursor skips it.
-- templates.get returns one template; its encoded reply is at most GET_BUDGET bytes.
local LIST_BUDGET, LIST_LIMIT, LIST_MAX, MAX_AFTER_JSON, GET_BUDGET = 40 * 1024, 50, 100, 8192, 60 * 1024
local NEXT_AFTER = #',"next_after":'
-- cursorable: the name comes back unchanged from the JSON round trip that an agent's after takes
-- (the encoder replaces an invalid UTF-8 byte with U+FFFD, so such a name would give a cursor
-- that sorts before its key: the list would repeat), and it is within the bound of after.
local function cursorable(name)
  if name == nil then return false end
  local encoded = rex.json.encode(name)
  return #encoded <= MAX_AFTER_JSON and rex.json.decode(encoded) == name
end
-- list_result checks the encoded page again (a failure is a defect of the accounting).
local function list_result(page, next_after)
  local r = {templates = page, next_after = next_after}
  if json_size(r) > LIST_BUDGET then fail('internal', 'A templates.list page is over its size bound') end
  return r
end
local function list_page(after, limit)
  if limit == nil then limit = LIST_LIMIT end
  if type(limit) ~= 'number' or limit % 1 ~= 0 or limit < 1 or limit > LIST_MAX then
    fail('invalid_input', 'limit is an integer from 1 to ' .. LIST_MAX)
  end
  if after ~= nil and (type(after) ~= 'string' or json_size(after) > MAX_AFTER_JSON) then
    fail('invalid_input', 'after is a template name of at most ' .. MAX_AFTER_JSON .. ' bytes as JSON')
  end
  local page, size, last = {}, json_size({templates = {}}), nil
  -- The rows in hex order (the order of the old store keys). SQL reads only the summary of each
  -- template: a row's JSON stays in the database. saved_by comes as JSON text (the -> operator),
  -- so it keeps its JSON type. A reply that holds fewer rows than the query
  -- gives more = true; the next query starts after the last row.
  local from = after and hex(after) or nil
  while true do
    local rows, more = app.db.query("SELECT hex, json_type(value, '$.tabs') AS tabs_type, json_array_length(value, '$.tabs') AS tabs,"
      .. " value -> '$.saved_by' AS saved_by FROM templates WHERE ? IS NULL OR hex > ? ORDER BY hex LIMIT ?", from, from, LIST_MAX + 1)
    for _, r in ipairs(rows) do
      local k = 'template/' .. r.hex
      local name = unhex(r.hex)
      if not cursorable(name) then
        if last ~= nil then return list_result(page, last) end
        fail('too_large', 'The record ' .. named(k) .. ' is not a Templates record: its key is'
          .. ' not hex, or its name is not valid UTF-8 or is over ' .. MAX_AFTER_JSON .. ' bytes as JSON. No cursor skips it.')
      end
      local row, cost = nil, 0
      if r.tabs_type == 'array' or r.tabs_type == 'object' then
        if #page == limit then return list_result(page, last) end
        row = {name = name, tabs = r.tabs, saved_by = r.saved_by and rex.json.decode(r.saved_by)}
        cost = json_size(row) + (#page > 0 and 1 or 0)
      end
      if size + cost + NEXT_AFTER + json_size(name) > LIST_BUDGET then
        if #page == 0 and row then
          fail('too_large', 'The template ' .. named(name) .. ' is too large to list (' .. json_size(row) ..
            ' bytes). To list the templates after it, set after to its name: ' .. name)
        end
        return list_result(page, last)
      end
      if row then page[#page + 1], size = row, size + cost end
      last = name
      from = r.hex
    end
    if not more and #rows <= LIST_MAX then return list_result(page, nil) end
  end
end
local function get_template(name)
  local r = data.get_template(hex(text(name, 'template')))
  if not r or type(r.value) ~= 'table' or type(r.value.tabs) ~= 'table' then
    fail('not_found', 'The template ' .. named(name) .. ' does not exist')
  end
  -- The template and its rev come from one record response; the budget counts the whole reply.
  local reply = {template = {name = name, tabs = r.value.tabs, saved_by = r.value.saved_by}, rev = r.rev}
  local n = json_size(reply)
  if n > GET_BUDGET then
    fail('too_large', 'The template ' .. named(name) .. ' is too large to read (' .. n .. ' bytes; the limit is ' .. GET_BUDGET .. ')')
  end
  return reply
end
local agent_handlers = {
  ['templates.list'] = function(_, args)
    only(args, {after = true, limit = true})
    return list_page(args.after, args.limit)
  end,
  ['templates.get'] = function(_, args)
    only(args, {template = true})
    return get_template(args.template)
  end,
  ['templates.capture'] = function(caller, args)
    only(args, {session_id = true})
    local session_id = opt_text(args.session_id, 'session_id') or caller.session_id
    if type(session_id) ~= 'string' or session_id == '' then fail('invalid_input', 'You have no session; set session_id') end
    local cap = capture(session_id)
    local dirs, panes = {}, {}
    for _, id in ipairs(cap.order) do
      local p = cap.panes[id]
      if p.dir then dirs[#dirs + 1] = p.dir end
      panes[#panes + 1] = {block_id = id, tab = p.tab, tab_title = cap.tabs[p.tab].title, dir = p.dir,
        guess = p.guess, args = p.args, detail = p.detail, requested_title = p.requested_title}
    end
    local profile_list = {}
    for _, p in ipairs(profiles()) do profile_list[#profile_list + 1] = {id = p.id, name = p.name or p.id} end
    return {session_id = session_id, root_guess = common_root(dirs), profiles = profile_list, panes = panes, dropped = cap.dropped}
  end,
  ['templates.save'] = agent_save,
  ['templates.start'] = agent_start,
  ['templates.runs'] = function(_, args)
    only(args, {before = true, limit = true})
    return run_page(args.before, args.limit)
  end,
  ['templates.delete'] = function(caller, args)
    only(args, {template = true, key = true})
    return delete_core(caller, op_keys('delete', caller, args.key), text(args.template, 'template'))
  end,
  ['templates.dismiss'] = function(caller, args)
    only(args, {run_id = true, key = true})
    return dismiss_core(caller, op_keys('dismiss', caller, args.key), text(args.run_id, 'run_id'))
  end,
  ['templates.retry'] = function(caller, args)
    only(args, {run_id = true, key = true})
    return retry_core(caller, op_keys('retry', caller, args.key), text(args.run_id, 'run_id'))
  end,
}
local key_arg = {type = 'string', minLength = 1, description = 'Your operation key. Retry with the same key and content after an unknown outcome.'}
local exports = {
  {name = 'templates.list', title = 'List session templates',
    description = 'List the saved session templates by name, one page at a time: name, tabs (the number of tabs) and saved_by. A page has at most limit templates (default 50, at most 100) and at most about 40 KB. When more templates exist, the reply has next_after: pass it as after for the next page. templates.get gives one template with its tabs.',
    args = {type = 'object', properties = {after = {type = 'string', description = 'A template name: list the templates after it (next_after of the previous page).'},
      limit = {type = 'integer', minimum = 1, maximum = 100, description = 'The most templates in the page (default 50).'}}, additionalProperties = false}},
  {name = 'templates.get', title = 'Get a session template',
    description = 'Get one saved template: name, tabs (title and layout; each pane has a launch and a directory relative to the root) and saved_by. rev is the revision of the record: pass it to templates.save as replace. A template over about 60 KB gives too_large.',
    args = {type = 'object', properties = {template = {type = 'string', minLength = 1}}, required = {'template'}, additionalProperties = false}},
  {name = 'templates.capture', title = 'Capture a session for a template',
    description = 'Read what Save as Template would save from a session (default: yours): each pane with its tab, directory, launch guess (shell or profile:<id>) and profile args, the profiles, and a root guess.',
    args = {type = 'object', properties = {session_id = {type = 'string', minLength = 1}}, additionalProperties = false}},
  {name = 'templates.save', title = 'Save a session as a template',
    description = 'Save the tabs of a session (default: yours) as a template. panes maps a block_id from templates.capture to shell, profile:<id> or skip; a pane without an entry takes its guess. Every pane must be under root. A template with the same name is kept (conflict) unless replace is its rev from templates.get: then exactly that revision is replaced, and a template that changed or was deleted since gives conflict.',
    args = {type = 'object', properties = {name = {type = 'string', minLength = 1, maxLength = 60}, root = {type = 'string', minLength = 1},
      session_id = {type = 'string', minLength = 1}, panes = {type = 'object', additionalProperties = {type = 'string'}}, replace = {type = 'string'}, key = key_arg},
      required = {'name', 'root', 'key'}, additionalProperties = false}},
  {name = 'templates.start', title = 'Start a session template',
    description = 'Start a template in a root directory: in an open session (session_id) or a new session (new_session, a name). With neither, a new session named after the template. The tabs open after this call returns; templates.runs shows the progress. You own the started panes. A finished start is removed when at least 200 newer eligible finished starts exist (eligible: finished, no revoke owed, and a user start or an agent start with a recorded grant). A replay of a removed start\'s key within 30 days of its removal gives expired; after 30 days the key starts a new start.',
    args = {type = 'object', properties = {template = {type = 'string', minLength = 1}, root = {type = 'string', minLength = 1},
      session_id = {type = 'string', minLength = 1}, new_session = {type = 'string', minLength = 1}, key = key_arg},
      required = {'template', 'root', 'key'}, additionalProperties = false}},
  {name = 'templates.runs', title = 'List template starts',
    description = 'List template starts, newest first, one page at a time: id, template, root, status (authorizing, queued, starting, pending, unknown, blocked, open, failed, closed, dismissed), tabs, error, by and session_id. A page has at most limit starts (default 50, at most 100) and at most about 40 KB. When older starts exist, the reply has next_before: pass it as before for the next page. Without before, the page starts at the newest start.',
    args = {type = 'object', properties = {before = {type = 'string', minLength = 1, maxLength = 32, description = 'A run ID: list the starts older than it (next_before of the previous page).'},
      limit = {type = 'integer', minimum = 1, maximum = 100, description = 'The most starts in the page (default 50).'}}, additionalProperties = false}},
  {name = 'templates.delete', title = 'Delete a session template',
    description = 'Delete a template, also one that the user or another agent saved.',
    args = {type = 'object', properties = {template = {type = 'string', minLength = 1}, key = key_arg}, required = {'template', 'key'}, additionalProperties = false}},
  {name = 'templates.dismiss', title = 'Dismiss a template start',
    description = 'Stop the rest of a start that is pending, unknown, blocked or not authorized, also a start of the user or another agent. It closes no pane.',
    args = {type = 'object', properties = {run_id = {type = 'string', minLength = 1}, key = key_arg}, required = {'run_id', 'key'}, additionalProperties = false}},
  {name = 'templates.retry', title = 'Retry a template start',
    description = 'Try a blocked start again now, also a start of the user or another agent. An agent\'s start still opens its tabs as that agent.',
    args = {type = 'object', properties = {run_id = {type = 'string', minLength = 1}, key = key_arg}, required = {'run_id', 'key'}, additionalProperties = false}},
}

-- The exports. The SDK checks each schema and gives the agent's key as ctx.key, not in the
-- arguments. A handler that changes something gets it back as args.key; the read-only handlers
-- refuse a key argument (only), and the SDK accepts and ignores one.
local MUTATIONS = {['templates.save'] = true, ['templates.start'] = true, ['templates.delete'] = true,
  ['templates.dismiss'] = true, ['templates.retry'] = true}
-- boundary keeps the error codes of the Templates handlers: a structured error passes unchanged,
-- and any other error is internal (the SDK would say failed). An error of the SDK itself (a schema
-- check, an unknown agent) keeps the SDK code.
local function boundary(fn)
  return function(...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    if type(result) == 'table' and type(result.code) == 'string' then error(result, 0) end
    error({code = 'internal', message = tostring(result)}, 0)
  end
end
local OPTS = {tx = false, store = false}
for _, e in ipairs(exports) do
  local handler, mutation = agent_handlers[e.name], MUTATIONS[e.name]
  app.action(e.name, e.args, boundary(function(ctx, args)
    if mutation then args.key = ctx.key end
    return handler(caller_of(ctx), args)
  end), {tx = false, store = false, title = e.title, description = e.description})
end
-- Every route of the plugin: the panel and the forms. The handlers get the raw view arguments
-- (route, context, input, view_id, operation_key).
app.view('/*', {
  render = boundary(function(_, args) return render(args).tree end),
  ['view.action'] = boundary(function(_, args) return action(args) end),
}, OPTS)
app.on('hub.changed', boundary(function(args) if args.what == 'workers' then wake() end end), OPTS)
app.command({id = 'start_session', title = 'Start Session…', description = 'Start a saved session template in a directory', keywords = {'template', 'workspace'}, route = '/forms/start', action = 'templates.start'})
app.command({id = 'save_template', title = 'Save as Template…', description = 'Save the tabs of this session as a template', keywords = {'template', 'workspace'}, route = '/forms/save', action = 'templates.save'})
app.command({id = 'templates', title = 'Templates…', description = 'Saved session templates and recent starts', keywords = {'template'}, route = '/panels/templates', surface = 'panel', landing = true, user_only = 'navigation'})
invalidate = function() hub('hub.ui.invalidate', {}) end
-- After the registration: the one-time import into SQL (templates_sql.lua), then the starts that a
-- restart interrupted continue from their durable records.
app.start(function()
  data.import({scan_limit = run_module.SCAN_LIMIT, smaller = run_module.smaller})
  engine.resume(); pump()
end, {after_register = true, tx = false})
