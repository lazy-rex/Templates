-- Durable template starts. The caller supplies hub access and the whole-tab launch adapter.
-- Load with dofile and an absolute path. No RPC runs at load time.
local M = {}
local function fail(code, message) error({code = code, message = message}) end
local function text(v, name)
  if type(v) ~= 'string' or v == '' or v:find('%z') then fail('invalid_input', name .. ' must be nonempty text without NUL') end
  return v
end
local function copy(v)
  if type(v) ~= 'table' then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
local function fields(v, allowed, name)
  if type(v) ~= 'table' then fail('invalid_input', name .. ' must be an object') end
  for k in pairs(v) do if not allowed[k] then fail('invalid_input', 'Unknown ' .. name .. ' field: ' .. tostring(k)) end end
end
local function list(v, name)
  if type(v) ~= 'table' or #v == 0 then fail('invalid_input', name .. ' must be a nonempty list') end
  for k in pairs(v) do
    if type(k) ~= 'number' or k % 1 ~= 0 or k < 1 or k > #v then fail('invalid_input', name .. ' must be a list') end
  end
end
local function relative(dir)
  text(dir, 'dir')
  if dir == '.' then return end
  if dir:sub(1, 1) == '/' or dir:sub(-1) == '/' or dir:find('//', 1, true) then fail('invalid_input', 'dir must be relative without empty segments') end
  for part in dir:gmatch('[^/]+') do
    if part == '.' or part == '..' then fail('invalid_input', 'dir cannot contain . or .. segments') end
  end
end
local function message(err)
  return type(err) == 'table' and (err.message or err.code or 'Request failed') or tostring(err)
end
local function finished(run)
  return run.status == 'open' or run.status == 'failed' or run.status == 'closed' or run.status == 'dismissed'
end

function M.new(opts)
  local hub = assert(opts.hub, 'hub is required')
  local start_tab = assert(opts.start_tab, 'start_tab is required')
  local resolve_root = assert(opts.resolve_root, 'resolve_root is required')
  local resolve_dir = assert(opts.resolve_dir, 'resolve_dir is required')
  local engine, queue, queued = {}, {}, {}
  local scanning, after = false, nil
  local function enqueue(id)
    if not queued[id] then queue[#queue + 1], queued[id] = id, true end
  end
  local function read(key)
    local result = hub('hub.store.get', {keys = {key}})
    local record = result.records and result.records[key]
    if not record or type(record.rev) ~= 'string' then fail('unavailable', 'Invalid store result') end
    return record.value, record.rev
  end
  local function batch(ops)
    local result = hub('hub.store.batch', {ops = ops})
    if result.conflict then fail('conflict', 'Template run changed; retry with the same key') end
    if not result.revs then fail('unavailable', 'Invalid store batch result') end
  end
  local function save(run, rev)
    batch({{key = 'run/' .. run.id, if_rev = rev, value = run}})
    if opts.changed then pcall(opts.changed, copy(run)) end
  end
  local function compile(node, root)
    if type(node) ~= 'table' then fail('invalid_input', 'layout must be an object') end
    if node.launch then
      fields(node, {launch=true, dir=true, label=true}, 'leaf')
      fields(node.launch, {profile=true, args=true, shell=true}, 'launch')
      local launch = node.launch
      if launch.shell ~= nil then
        if launch.shell ~= true or launch.profile ~= nil or launch.args ~= nil then fail('invalid_input', 'shell launch must contain only shell=true') end
      else
        text(launch.profile, 'profile')
        if launch.args ~= nil then
          if type(launch.args) ~= 'table' then fail('invalid_input', 'args must be an object') end
          for k, v in pairs(launch.args) do
            text(k, 'argument name')
            if type(v) ~= 'string' or v:find('%z') then fail('invalid_input', 'Argument values must be text without NUL') end
          end
        end
      end
      if node.label ~= nil then text(node.label, 'label') end
      relative(node.dir)
      local cwd = resolve_dir(root, node.dir)
      text(cwd, 'resolved directory')
      if cwd:sub(1, 1) ~= '/' then fail('invalid_input', 'Resolved directory must be absolute') end
      if root ~= '/' and cwd ~= root and cwd:sub(1, #root + 1) ~= root .. '/' then
        fail('invalid_input', 'Resolved directory is outside the root')
      end
      local out = copy(launch)
      out.cwd, out.label = cwd, node.label
      return out
    end
    fields(node, {direction=true, ratio=true, before=true, after=true}, 'split')
    if node.direction ~= 'horizontal' and node.direction ~= 'vertical' then fail('invalid_input', 'Invalid split direction') end
    if type(node.ratio) ~= 'number' or not (node.ratio > 0 and node.ratio < 1) then fail('invalid_input', 'Split ratio must be between 0 and 1') end
    return {direction=node.direction, ratio=node.ratio, before=compile(node.before, root), after=compile(node.after, root)}
  end

  -- Repeated admission uses the original request before checking today's directories or template.
  -- The frozen requests survive a changed profile, template, cwd, or plugin process.
  function engine.admit(request)
    fields(request, {key=true, template=true, root=true, session_id=true, new_session_name=true, placement=true}, 'run request')
    text(request.key, 'key')
    local admission_key = 'run-key/' .. request.key
    local existing, admission_rev = read(admission_key)
    if existing then
      local run = engine.get(existing.id)
      if not same(run.request, request) then fail('operation_conflict', 'This key has different content') end
      if not finished(run) then enqueue(run.id) end
      return run
    end
    if (request.session_id ~= nil) == (request.new_session_name ~= nil) then fail('invalid_input', 'Choose one existing or new session') end
    text(request.session_id or request.new_session_name, 'session')
    if request.placement ~= nil then
      fields(request.placement, {focus=true}, 'placement')
      if request.placement.focus ~= nil then
        fields(request.placement.focus, {source_window_id=true}, 'placement.focus')
        text(request.placement.focus.source_window_id, 'placement.focus.source_window_id')
      end
    end
    text(request.root, 'root')
    if request.root:sub(1, 1) ~= '/' then fail('invalid_input', 'root must be absolute') end
    fields(request.template, {v=true, name=true, tabs=true}, 'template')
    if request.template.v ~= 1 then fail('invalid_input', 'Unsupported template version') end
    text(request.template.name, 'template name')
    list(request.template.tabs, 'tabs')
    local root = resolve_root(request.root)
    text(root, 'resolved root')
    if root:sub(1, 1) ~= '/' or (#root > 1 and root:sub(-1) == '/') then fail('invalid_input', 'Resolved root must be canonical and absolute') end
    local tabs = {}
    for i, tab in ipairs(request.template.tabs) do
      fields(tab, {title=true, layout=true}, 'tab')
      text(tab.title, 'tab title')
      tabs[i] = {title=tab.title, layout=compile(tab.layout, root)}
    end
    local counter, counter_rev = read('run-counter')
    -- Decimal addition keeps operation IDs exact beyond Lua's integer precision.
    local digits, carry = tostring(counter or '0'), 1
    local id = ''
    for i = #digits, 1, -1 do
      local n = tonumber(digits:sub(i, i)) + carry
      id, carry = tostring(n % 10) .. id, math.floor(n / 10)
    end
    if carry == 1 then id = '1' .. id end
    local run = {id=id, request=copy(request), root=root, tabs=tabs, next_tab=1,
      status='queued', results={}, session_key='templates/' .. id .. '/session'}
    if request.session_id then run.session_id = request.session_id end
    for i, tab in ipairs(tabs) do tab.key = 'templates/' .. id .. '/tab/' .. tostring(i) end
    batch({{key=admission_key, if_rev=admission_rev, value={id=id}},
      {key='run-counter', if_rev=counter_rev, value=id}, {key='run/' .. id, if_rev='0', value=run}})
    enqueue(id)
    if opts.changed then pcall(opts.changed, copy(run)) end
    return copy(run)
  end

  function engine.get(id)
    text(id, 'run id')
    local run = read('run/' .. id)
    if not run then fail('not_found', 'Template run not found') end
    return copy(run)
  end

  -- Dismiss stops only this run's remaining orchestration. A sent Rex request can still finish.
  -- Keep its requests and results for inspection; never stop, close, or recreate its resources.
  function engine.dismiss(id)
    text(id, 'run id')
    local run, rev = read('run/' .. id)
    if not run then fail('not_found', 'Template run not found') end
    if run.status == 'dismissed' then return copy(run) end
    if run.status ~= 'pending' and run.status ~= 'unknown' and run.status ~= 'blocked' then
      fail('conflict', 'Only a pending, unknown or blocked run can be dismissed')
    end
    run.dismissed_from, run.status = run.status, 'dismissed'
    save(run, rev)
    return copy(run)
  end

  local function advance(id)
    local run, rev = read('run/' .. id)
    if not run or finished(run) then return end
    if not run.session_id then
      -- The ensure key and name were committed at admission. Never replace an unknown session.
      local ok, result = pcall(hub, 'hub.session.ensure', {key=run.session_key, name=run.request.new_session_name})
      if not ok then
        run.status, run.error = 'blocked', message(result)
        save(run, rev)
        return
      end
      if type(result.session_id) ~= 'string' or result.session_id == '' then fail('unavailable', 'Invalid session result') end
      run.session_id, run.status, run.error = result.session_id, 'queued', nil
      save(run, rev)
      enqueue(id)
      return
    end
    local tab = run.tabs[run.next_tab]
    if not tab.request then
      -- Commit the complete adapter input before the first call. Binding the session is a write.
      tab.request = {key=tab.key, session=run.session_id, title=tab.title, layout=copy(tab.layout)}
      if run.request.placement then tab.request.placement = copy(run.request.placement) end
      run.status = 'starting'
      save(run, rev)
      enqueue(id)
      return
    end
    local ok, result = pcall(start_tab, copy(tab.request))
    if not ok then
      run.status, run.error = 'blocked', message(result)
    elseif type(result) ~= 'table' then
      run.status, run.error = 'blocked', 'Invalid tab start result; outcome unknown'
    elseif result.status == 'open' then
      if type(result.window_id) ~= 'string' or result.window_id == '' then
        run.status, run.error = 'blocked', 'Tab start has no window ID; outcome unknown'
      else
        run.results[run.next_tab] = copy(result)
        run.next_tab = run.next_tab + 1
        run.error = nil
        run.status = run.next_tab > #run.tabs and 'open' or 'queued'
      end
    elseif result.status == 'pending' or result.status == 'unknown' then
      run.status, run.error = result.status, result.error
      run.results[run.next_tab] = copy(result)
    elseif result.status == 'failed' or result.status == 'closed' then
      run.status, run.error = result.status, result.error or 'Tab start stopped'
      run.results[run.next_tab] = copy(result)
    else
      run.status, run.error = 'blocked', 'Unrecognized tab start status; outcome unknown'
    end
    save(run, rev)
    if run.status == 'queued' then enqueue(id) end
  end

  -- Wake scans one store page per tick. Pending and unknown runs wait for a worker event,
  -- reconnect or explicit retry. A store failure also waits: no immediate retry loop.
  function engine.wake()
    if not scanning then scanning, after = true, nil end
  end
  engine.resume = engine.wake
  function engine.tick()
    local id
    local ok, err = pcall(function()
      if scanning then
        local args = {prefix='run/', limit=50}
        if after then args.after = after end
        local page = hub('hub.store.scan', args)
        if type(page.records) ~= 'table' then fail('unavailable', 'Invalid run scan') end
        for _, record in pairs(page.records) do
          local run = record.value
          if run and not finished(run) then enqueue(run.id) end
        end
        after, scanning = page.next, page.next ~= nil
        return
      end
      id = table.remove(queue, 1)
      if id then queued[id] = nil; advance(id) end
    end)
    if not ok then scanning, after = false, nil end
    return scanning or #queue > 0, not ok and err or nil
  end
  return engine
end
return M
