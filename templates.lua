-- Session templates (the maintainer, 2026-10-17). A template is a named group of tabs. Each pane has a
-- launch (a profile and its args, or a plain shell), a directory relative to a root, and its place
-- in the tab's layout. "Save as Template…" captures a session; "Start Session…" starts a template
-- in any root. The engine (templates_run.lua) owns durable starts; this file owns capture, the
-- forms, the panel and the adapter to hub.spawn_window.
local hub_id = assert(rex.args.hub_client_id, 'hub_client_id is required')
local instance_id = assert(rex.args.instance_id, 'instance_id is required')
local function fail(code, message) error({code = code, message = message}) end
local function text(value, name)
  if type(value) ~= 'string' or value == '' or value:find('%z') then fail('invalid_input', name .. ' must be nonempty text without NUL') end
  return value
end
local function part(value) return tostring(#value) .. ':' .. value end
local function hub(action, args)
  local response, err = rex.call('client.perform', {client_id = hub_id, action = action, args = args or {}, timeout_ms = 10000})
  if type(response) ~= 'table' or type(response.result) ~= 'table' then
    if type(err) == 'table' then fail(err.code or 'unavailable', err.message or 'Hub request failed') end
    -- Observed on Rex 1203 (lab): a perform error arrives as text that ends with
    -- "(status=500 code=<code>)", for example code=not_focused.
    local message = tostring(err or 'Invalid hub result')
    fail(message:match('code=([%w_]+)%)$') or 'unavailable', message)
  end
  return response.result
end
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

-- The engine is a sibling file. Observed on Rex 1203: debug.getinfo gives the script's absolute path.
local here = debug.getinfo(1, 'S').source:gsub('^@', '')
local run_module = dofile(assert(here:match('^(/.*)/[^/]*$'), 'the plugin path must be absolute') .. '/templates_run.lua')

-- Directories. Both return canonical absolute paths (symlinks resolved) of existing directories.
local function real_dir(path)
  local r = run({'realpath', path})
  if not r.ok then fail('invalid_input', path .. ' does not exist') end
  local out = line(r.stdout)
  if not run({'test', '-d', out}).ok then fail('invalid_input', path .. ' is not a directory') end
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
  local r = run({'git', '-C', dir, 'rev-parse', '--show-toplevel'})
  if r.ok then return real_dir(line(r.stdout)) end
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
-- cwd from the OS, else fallback. The result is canonical, or nil when the directory is gone.
local function file_url_path(url)
  local path = type(url) == 'string' and url:match('^file://[^/]*(/.*)$') or nil
  if path then path = path:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end) end
  return path
end
local function pane_dir(session_id, block_id, child, fallback)
  local ok, pwd = pcall(rex_ok, 'com.superlogical.terminal.pwd', {session_id = session_id, block_id = block_id, args = {}})
  for _, dir in ipairs({ok and file_url_path(pwd.pwd) or false, child.cwd or false, fallback or false}) do
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
            pane.dir = pane_dir(session_id, id, child, spec.found and spec.cwd or nil)
            if spec.found and spec.profile ~= SHELL_PROFILE then
              pane.guess, pane.args = 'profile:' .. spec.profile, spec.args or {}
              pane.detail = spec.title
            else
              local idle = child.pid and fg.pid == child.pid
              if idle and is_shell(child) then pane.guess = 'shell'
              elseif child.pid then pane.detail = 'running ' .. tostring((idle and child.name) or fg.name or 'a program') end
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

-- Storage: template/<hex name> = {v = 1, name, tabs}. hex keeps any name a valid key.
local function template_key(name) return 'template/' .. hex(name) end
local function templates()
  local list, after = {}, nil
  repeat
    local args = {prefix = 'template/', limit = 50}
    if after then args.after = after end
    local page = hub('hub.store.scan', args)
    for _, record in pairs(page.records or {}) do if type(record.value) == 'table' then list[#list + 1] = record.value end end
    after = page.next
  until not after
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end
local function load_template(name)
  local key = template_key(text(name, 'template'))
  local r = hub('hub.store.get', {keys = {key}}).records[key]
  if not r or type(r.value) ~= 'table' then fail('not_found', 'The template "' .. name .. '" no longer exists') end
  return r.value, r.rev, key
end

-- A form's operation key makes a submit safe to retry. The saved result answers a retry.
local function saved_op(op_key, fingerprint)
  local saved = hub('hub.store.op', {key = op_key})
  if not saved.found then return nil end
  if saved.fingerprint ~= fingerprint then fail('operation_conflict', 'Operation key already has different content') end
  return saved.result
end
local function op_key(prefix, operation_key) return prefix .. part(text(operation_key, 'operation key')) end

local function cancel_node()
  return {id = 'cancel', type = 'widget', text = '', action = {name = '$cancel', label = 'Cancel', enabled = true}}
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

local function to_layout(node, cap, launches, root)
  if node.split then
    local b = to_layout(node.split.before, cap, launches, root)
    local a = to_layout(node.split.after, cap, launches, root)
    if not b then return a end
    if not a then return b end
    return {direction = node.split.direction, ratio = node.split.ratio, before = b, after = a}
  end
  local launch = launches[node.block_id]
  if not launch then return nil end
  return {launch = launch, dir = relative(cap.panes[node.block_id].dir, root)}
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

local function save_template(args)
  local context = context_of(args)
  local values = form_values(args)
  local key = op_key('save/', args.operation_key)
  local fingerprint = values_fingerprint('save-v2/', context, values)
  local prior = saved_op(key, fingerprint)
  if prior then return prior end
  local name = text(values.name, 'Template name')
  if #name > 60 then fail('invalid_input', 'The template name is at most 60 characters') end
  local root = resolve_root(values.root)
  local cap = capture(context.session_id)
  -- The form shows the panes from its render. A pane added or closed since then needs a new form.
  for _, id in ipairs(cap.order) do
    if values['pane_' .. id] == nil then fail('conflict', 'The session changed. Open Save as Template… again.') end
  end
  for k in pairs(values) do
    if k:sub(1, 5) == 'pane_' and not cap.panes[k:sub(6)] then fail('conflict', 'The session changed. Open Save as Template… again.') end
  end
  local launches = {}
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
    end
  end
  local tabs = {}
  for _, tab in ipairs(cap.tabs) do
    local layout = to_layout(tab.layout, cap, launches, root)
    if layout then tabs[#tabs + 1] = {title = tab.title, layout = layout} end
  end
  if #tabs == 0 then fail('invalid_input', 'The template has no panes') end
  local template = {v = 1, name = name, tabs = tabs}
  local tkey = template_key(name)
  local existing = hub('hub.store.get', {keys = {tkey}}).records[tkey]
  if existing and existing.value ~= nil then fail('conflict', 'A template named "' .. name .. '" exists. Choose another name, or delete it in Templates.') end
  local result = {close_form = true}
  local stored = hub('hub.store.batch', {ops = {{key = tkey, if_rev = existing and existing.rev or '0', value = template}},
    op = {key = key, fingerprint = fingerprint, result = result}})
  if stored.op_exists then return saved_op(key, fingerprint) end
  if stored.conflict then fail('conflict', 'A template with this name was saved meanwhile. Choose another name.') end
  return result
end

-- The engine and its adapter to hub.spawn_window.
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
  local args = {['for'] = 'user', key = request.key, session = request.session, title = request.title, layout = hub_layout(request.layout)}
  if request.placement then args.placement = request.placement end
  local r = hub('hub.spawn_window', args)
  local blocks, err = {}, nil
  for _, leaf in ipairs(r.leaves or {}) do
    if leaf.block_id then blocks[#blocks + 1] = leaf.block_id end
    if not err and leaf.error and leaf.error ~= '' then err = leaf.error end
  end
  return {status = r.status, window_id = r.window_id, block_ids = blocks, error = err}
end
local invalidate
local engine = run_module.new({hub = hub, start_tab = start_tab, resolve_root = resolve_root, resolve_dir = resolve_dir,
  changed = function() if invalidate then pcall(invalidate) end end})
local tick_timer
-- Ticks run outside action handlers. An error stops the loop until the next wake (contract).
local function pump()
  if tick_timer then return end
  tick_timer = rex.after(0.05, function()
    tick_timer = nil
    local more, err = engine.tick()
    if err then print('templates: ' .. (type(err) == 'table' and tostring(err.message or err.code) or tostring(err))) end
    if more and not err then pump() end
  end)
end
local function wake() engine.wake(); pump() end

-- Start form.
local function source_dir(context)
  if type(context.source_block_id) ~= 'string' or context.source_block_id == '' then return nil end
  local ok, proc = pcall(rex_ok, 'com.superlogical.terminal.process', {session_id = context.session_id, block_id = context.source_block_id, args = {}})
  local cwd = pane_dir(context.session_id, context.source_block_id, ok and proc.child or {}, nil)
  if not cwd then return nil end
  return git_root(cwd) or cwd
end
local function start_fields(context, list)
  local options = {}
  for _, t in ipairs(list) do options[#options + 1] = {value = t.name, label = t.name .. ' · ' .. #t.tabs .. ' tab' .. (#t.tabs == 1 and '' or 's')} end
  local sessions = {{value = '@new', label = 'New session…'}}
  for _, s in ipairs(hub('hub.session.list').sessions or {}) do
    sessions[#sessions + 1] = {value = s.session_id, label = (s.label or '') ~= '' and s.label or s.session_id}
  end
  return {
    {id = 'template', label = 'Template', kind = 'select', required = true, value = list[1].name, options = options},
    {id = 'root', label = 'Root (the directory the panes are relative to)', kind = 'text', required = true, value = source_dir(context) or ''},
    {id = 'session_id', label = 'Session', kind = 'select', required = true, value = '@new', options = sessions},
    {id = 'session_name', label = 'New session name (default: the template name)', kind = 'text', value = ''},
  }
end
-- A start into a new session switches the app to it (the maintainer, 2026-10-19; coordinator's rules).
-- The form stays open ({status = 'running'}: the hub calls the action again about every 0.5 s)
-- until the first tab opens, the start stops, or SWITCH_WAIT seconds pass. Then the plugin asks
-- hub.app.select_session from the still-open form; the hub refuses when the user left the form.
-- The decision is one-shot under the start's operation key: 'attempted' commits before the call,
-- so a crash or lost answer after it reads as 'unknown' and never switches again.
local SWITCH_WAIT = tonumber(rex.args.switch_wait) or 15 -- tests pass a shorter wait
local starting = {} -- view_id -> true while its start form waits (render only)
local function switch_key(start_key) return 'switch/' .. hex(start_key) end
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

-- A start freezes its engine request under the form's operation key before admission, so a retry
-- after a lost reply admits the same request even if the template was edited or deleted since.
local function start_session(args)
  local context = context_of(args)
  local values = form_values(args)
  local key = 'start/' .. part(text(args.operation_key, 'operation key'))
  local fingerprint = values_fingerprint('start-v1/', context, values)
  local record_key = 'start-form/' .. hex(key)
  local request, at
  local saved = hub('hub.store.get', {keys = {record_key}}).records[record_key]
  if saved and type(saved.value) == 'table' then
    if saved.value.fingerprint ~= fingerprint then fail('operation_conflict', 'Operation key already has different content') end
    -- A record from before the switch has no time: its wait is over.
    request, at = saved.value.request, type(saved.value.at) == 'number' and saved.value.at or 0
  else
    local tpl = load_template(values.template)
    request = {key = key, template = tpl, root = text(values.root, 'Root')}
    -- Each tab focuses its first pane only while the form's tab is still the active one in the
    -- target session (hub.spawn_window). In a new session it never matches; switch_app moves the app.
    if type(context.window_id) == 'string' and context.window_id ~= '' then
      request.placement = {focus = {source_window_id = context.window_id}}
    end
    if values.session_id == '@new' then
      request.new_session_name = type(values.session_name) == 'string' and values.session_name ~= '' and values.session_name or tpl.name
    else request.session_id = text(values.session_id, 'Session') end
    at = os.time()
    local stored = hub('hub.store.batch', {ops = {{key = record_key, if_rev = saved and saved.rev or '0', value = {fingerprint = fingerprint, request = request, at = at}}}})
    if stored.conflict then fail('conflict', 'This start is being submitted twice; retry with the same key') end
  end
  local run_state = engine.admit(request)
  pump()
  local done = {panel = {route = '/panels/templates'}, run_id = run_state.id}
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

-- Templates panel: saved templates and recent starts.
local function recent_runs()
  local runs, after = {}, nil
  repeat
    local args = {prefix = 'run/', limit = 50}
    if after then args.after = after end
    local page = hub('hub.store.scan', args)
    for _, record in pairs(page.records or {}) do if type(record.value) == 'table' then runs[#runs + 1] = record.value end end
    after = page.next
  until not after
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
  if not r or not r.request.new_session_name then return nil end
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
local function render_panel()
  local items = {}
  for _, t in ipairs(templates()) do
    items[#items + 1] = {id = t.name, label = t.name, detail = #t.tabs .. ' tab' .. (#t.tabs == 1 and '' or 's'),
      action = {name = 'delete', label = 'Delete', enabled = true, tool = 'templates.delete'}}
  end
  local nodes = {
    {id = 'start', type = 'widget', text = '', action = {name = 'start', label = 'Start Session…', enabled = #items > 0, user_only = 'navigation'}},
    {id = 'save', type = 'widget', text = '', action = {name = 'save', label = 'Save this session as a template…', enabled = true, user_only = 'navigation'}},
    {id = 'templates', type = 'list', label = 'Templates', items = items},
  }
  -- Every stuck start is listed (its create answer was lost, or a call failed), so it can always be
  -- dismissed; Dismiss closes no pane. Then the 10 newest other starts. Retry wakes blocked starts;
  -- a pending start waits for the hub.
  local stuck_items, recent_items, blocked = {}, {}, false
  local runs = recent_runs()
  for _, r in ipairs(runs) do
    local label = r.request.template.name .. ' in ' .. short(r.root)
    if r.status == 'blocked' or r.status == 'pending' or r.status == 'unknown' then
      blocked = blocked or r.status == 'blocked'
      -- The label names the action, as the home's failed workers do ("· Dismiss").
      stuck_items[#stuck_items + 1] = {id = r.id, label = label .. ' · Dismiss', detail = run_detail(r), action = {name = 'dismiss', label = 'Dismiss', enabled = true, tool = 'templates.dismiss'}}
    elseif #recent_items < 10 then
      recent_items[#recent_items + 1] = {id = r.id, label = label, detail = run_detail(r)}
    end
  end
  local notice = switch_notice(runs)
  if notice then table.insert(nodes, 1, {id = 'switch', type = 'widget', text = notice}) end
  if #stuck_items > 0 then nodes[#nodes + 1] = {id = 'stuck', type = 'list', label = 'Unfinished starts', items = stuck_items} end
  if blocked then nodes[#nodes + 1] = {id = 'retry', type = 'widget', text = '', action = {name = 'retry', label = 'Retry stuck starts', enabled = true, tool = 'templates.retry'}} end
  if #recent_items > 0 then nodes[#nodes + 1] = {id = 'runs', type = 'list', label = 'Recent starts', items = recent_items} end
  return {title = 'Templates', nodes = nodes}
end

local function render(args)
  if args.route == '/panels/templates' then return {tree = render_panel()} end
  local context = context_of(args)
  local tree
  if args.route == '/forms/save' then
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
    tree = {title = 'Save as Template', nodes = nodes}
  elseif args.route == '/forms/start' then
    local list = templates()
    local nodes = {}
    if #list == 0 then
      nodes[1] = {id = 'empty', type = 'widget', text = 'No templates yet. Use Save as Template… in a session first.'}
    else
      nodes[1] = {id = 'start_session', type = 'form', fields = start_fields(context, list),
        submit_action = {name = 'submit', label = 'Start session', enabled = not starting[args.view_id], tool = 'templates.start'}}
    end
    if starting[args.view_id] then
      table.insert(nodes, 1, {id = 'starting', type = 'widget', text = 'Starting… The app goes to the new session when its first tab opens.'})
    end
    nodes[#nodes + 1] = cancel_node()
    tree = {title = 'Start Session', nodes = nodes}
    if starting[args.view_id] then
      tree.status = {state = 'working', msg = 'Starting'}
      return {tree = tree}
    end
  else
    fail('invalid_input', 'Unknown route')
  end
  tree.status = {state = 'blocked', kind = 'question', msg = 'Waiting for input'}
  return {tree = tree}
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
  if args.route == '/panels/templates' then
    if args.node_id == 'start' then return {form = '/forms/start'} end
    if args.node_id == 'save' then return {form = '/forms/save'} end
    local item = type(args.input) == 'table' and args.input.item_id
    if args.node_id == 'templates' and args.action == 'delete' then
      -- The deletion and its result commit together; a retry never deletes a newer template.
      local key = op_key('delete/', args.operation_key)
      local fingerprint = 'delete-v1/' .. part(tostring(item))
      local prior = saved_op(key, fingerprint)
      if prior then return prior end
      local _, rev, tkey = load_template(item)
      local stored = hub('hub.store.batch', {ops = {{key = tkey, if_rev = rev, delete = true}}, op = {key = key, fingerprint = fingerprint, result = {}}})
      if stored.op_exists then return saved_op(key, fingerprint) end
      if stored.conflict then fail('conflict', 'The template changed; try again') end
      return {}
    end
    if args.node_id == 'retry' then wake(); return {} end
    if args.node_id == 'stuck' and args.action == 'dismiss' then engine.dismiss(text(item, 'run')); return {} end
  end
  fail('invalid_input', 'Unknown view action')
end

local actions = {}
for _, name in ipairs({'view.render', 'view.action', 'view.seen', 'hub.changed'}) do
  actions[#actions + 1] = {name = name, kind = 'client', title = name, args = {type = 'object', additionalProperties = true}}
end
rex.call('client.keymap', {actions = actions})
hub('hub.register', {plugin = 'templates', instance_id = instance_id, exports = {}, commands = {
  {id = 'start_session', title = 'Start Session…', description = 'Start a saved session template in a directory', keywords = {'template', 'workspace'}, route = '/forms/start', action = 'templates.start'},
  {id = 'save_template', title = 'Save as Template…', description = 'Save the tabs of this session as a template', keywords = {'template', 'workspace'}, route = '/forms/save', action = 'templates.save'},
  {id = 'templates', title = 'Templates…', description = 'Saved session templates and recent starts', keywords = {'template'}, route = '/panels/templates', surface = 'panel', landing = true, user_only = 'navigation'},
}})
invalidate = function() hub('hub.ui.invalidate', {}) end
-- Starts that a restart interrupted continue from their durable records.
engine.resume(); pump()
rex.on('client_perform_requested', function(ctx, ev)
  local call_id = ev.call_id
  local ok, result = pcall(function()
    if not ev.requester or ev.requester.client_id ~= hub_id then fail('refused', 'Only the hub calls this plugin') end
    local args = ev.args or {}
    if ev.action == 'view.render' then return render(args) end
    if ev.action == 'view.action' then return action(args) end
    if ev.action == 'hub.changed' then
      if args.what == 'workers' then wake() end
      return {}
    end
    if ev.action == 'view.seen' then return {} end
    fail('not_supported', 'Unknown action')
  end)
  rex.call('client.reply', {call_id = call_id, result = ok and result or nil,
    error = not ok and (type(result) == 'table' and result or {code = 'internal', message = tostring(result)}) or nil})
end)
rex.call('client.set_label', {label = 'lazyrex-plugin:templates'})
