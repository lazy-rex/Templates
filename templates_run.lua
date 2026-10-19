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
-- An agent's run sends its tabs with a durable grant of the hub (hub.grant.create, made while the
-- agent's call ran). Without an active grant it dispatches nothing: no session, no tab.
local function by_agent(run) return run.request.by ~= nil and run.request.by ~= 'user' end
-- A finished agent run gives its grant back (hub.grant.revoke) after its final state commits.
local function owes_revoke(run) return finished(run) and run.grant_id ~= nil and not run.grant_revoked end
-- A grant can commit in the hub before the run records it (a lost reply or a crash before
-- engine.authorize), or after the run finished (a start call that was still running). A finished
-- agent run without a grant ID looks for it once per engine (checked, in memory), to revoke it.
-- Each new engine (a plugin start) looks again, so a late grant is found without a loop.
local function owes_grant_check(run) return finished(run) and by_agent(run) and run.grant_id == nil end

function M.new(opts)
  local hub = assert(opts.hub, 'hub is required')
  local start_tab = assert(opts.start_tab, 'start_tab is required')
  local resolve_root = assert(opts.resolve_root, 'resolve_root is required')
  local resolve_dir = assert(opts.resolve_dir, 'resolve_dir is required')
  local engine, queue, queued, checked = {}, {}, {}, {}
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
  local function batch(ops, op)
    local result = hub('hub.store.batch', {ops = ops, op = op})
    -- The caller answers from the saved operation (another call saved it first).
    if result.op_exists then fail('op_exists', 'The operation is already saved') end
    if result.conflict then fail('conflict', 'Template run changed; retry with the same key') end
    if not result.revs then fail('unavailable', 'Invalid store batch result') end
  end
  local function save(run, rev, op)
    batch({{key = 'run/' .. run.id, if_rev = rev, value = run}}, op)
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
    fields(request, {key=true, template=true, root=true, session_id=true, new_session_name=true, placement=true, by=true}, 'run request')
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
    if request.by ~= nil then text(request.by, 'by') end
    if request.by ~= nil and request.by ~= 'user' and request.placement ~= nil then fail('invalid_input', 'An agent start has no placement') end
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
    -- An agent's run waits for its grant (engine.authorize) before it dispatches anything.
    if by_agent(run) then run.status = 'authorizing' end
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
  -- op (optional) is the caller's operation record {key, fingerprint, result}: it commits in the
  -- same batch as the dismissed state, so a lost reply cannot split them.
  function engine.dismiss(id, op)
    text(id, 'run id')
    local run, rev = read('run/' .. id)
    if not run then fail('not_found', 'Template run not found') end
    if run.status == 'dismissed' then
      if op then batch({}, op) end
      return copy(run)
    end
    if run.status ~= 'pending' and run.status ~= 'unknown' and run.status ~= 'blocked' and run.status ~= 'authorizing' then
      fail('conflict', 'Only a pending, unknown, blocked or unauthorized run can be dismissed')
    end
    run.dismissed_from, run.status = run.status, 'dismissed'
    save(run, rev, op)
    if owes_revoke(run) or owes_grant_check(run) then enqueue(id) end
    return copy(run)
  end

  -- authorize records the grant of an agent's run and lets it dispatch. A run that is no longer
  -- waiting (finished, dismissed, or already authorized) keeps its state.
  function engine.authorize(id, grant_id)
    text(id, 'run id')
    text(grant_id, 'grant id')
    local run, rev = read('run/' .. id)
    if not run then fail('not_found', 'Template run not found') end
    if run.grant_id ~= nil then
      if run.grant_id ~= grant_id then fail('conflict', 'The run has another grant') end
      return copy(run)
    end
    run.grant_id = grant_id
    if run.status == 'authorizing' then run.status, run.error = 'queued', nil end
    save(run, rev)
    enqueue(id)
    return copy(run)
  end

  -- retry queues a blocked, pending or unknown run again. The queued state and the operation
  -- (op = {key, fingerprint, result}; result.woken is set here) commit in one batch, so a lost
  -- reply cannot lose the retry: the run is queued durably, and any wake dispatches it.
  function engine.retry(id, op)
    text(id, 'run id')
    local run, rev = read('run/' .. id)
    if not run then fail('not_found', 'Template run not found') end
    local woken = run.status == 'blocked' or run.status == 'pending' or run.status == 'unknown'
    op.result = {run_id = id, woken = woken}
    if not woken then
      batch({}, op)
      return op.result
    end
    run.status, run.error = 'queued', nil
    save(run, rev, op)
    enqueue(id)
    return op.result
  end

  -- wake_one schedules one run now if it is queued or starting (a replayed retry recovers its
  -- queued state). A run that is stuck again or finished is not scheduled: that is a new retry.
  function engine.wake_one(id)
    local run = engine.get(id)
    if run.status == 'queued' or run.status == 'starting' then enqueue(id) end
    return run
  end

  local function advance(id)
    local run, rev = read('run/' .. id)
    if not run then return end
    if owes_revoke(run) then
      -- The final state is committed: give the grant back. A failure retries at the next wake.
      if opts.revoke and pcall(opts.revoke, run.grant_id) then
        run.grant_revoked = true
        save(run, rev)
      end
      return
    end
    if owes_grant_check(run) then
      -- Never dispatches: it only records the grant, then revokes it.
      if checked[id] then return end
      local grant_id = opts.find_grant and opts.find_grant(copy(run))
      checked[id] = true
      if grant_id then
        run.grant_id = grant_id
        save(run, rev)
        enqueue(id)
      end
      return
    end
    if finished(run) then return end
    if by_agent(run) and run.grant_id == nil then
      -- No grant yet (a crash between admission and the grant): find it, or wait for a retry of
      -- the start in a new agent call. Nothing dispatches before it.
      local grant_id = opts.find_grant and opts.find_grant(copy(run))
      if grant_id then engine.authorize(id, grant_id) return end
      local msg = 'The start is not authorized yet; retry the start with the same key'
      if run.error ~= msg then run.error = msg; save(run, rev) end
      return
    end
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
      if run.grant_id then tab.request.grant_id = run.grant_id end
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
    if run.status == 'queued' or owes_revoke(run) then enqueue(id) end
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
          if run and (not finished(run) or owes_revoke(run) or owes_grant_check(run)) then enqueue(run.id) end
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
