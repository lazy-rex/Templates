-- The engine cases (templates_run.lua) with a controlled hub. tests/engine.lua runs each one.
return function(Run)
local tests = {}
local function copy(v)
  if type(v) ~= 'table' then return v end
  local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
end
local function equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
local function expect_error(fn, code)
  local ok, err = pcall(fn)
  assert(not ok and type(err) == 'table' and err.code == code, 'Expected ' .. code)
end
local function fixture()
  local f = {records={}, ops={}, rev=0, creates=0, sessions=0, calls={}, windows={}, scans={}}
  -- f.records keeps the old store keys and record shapes {rev, value}: 'run/<id>' (rev is the
  -- run's ver), 'run-key/<key>' {id, expired_at, form_rev}, 'run-counter', 'start-form/<key>'
  -- {fingerprint, request, at} and 'switch/<key>'. f.data is the engine's data layer
  -- (templates_sql.lua) on that map; f.transaction is app.db.transaction: a failed function
  -- restores the map. f.fail_before fails the next transaction before it writes; f.lose_store
  -- commits it and then fails, as a lost commit reply; f.op_exists makes the next get_op find a row.
  local function put(key, value) f.rev, f.writes = f.rev + 1, (f.writes or 0) + 1; f.records[key] = {rev=tostring(f.rev), value=copy(value)}; return tostring(f.rev) end
  local function drop(key) if f.records[key] then f.writes = (f.writes or 0) + 1 end; f.records[key] = nil end
  local function value(key) local r = f.records[key]; return r and copy(r.value) end
  local function older(a, b) return #a < #b or #a == #b and a < b end
  local d = {}
  function d.get_run(id) local r = f.records['run/' .. id]; if r then return {ver=tonumber(r.rev), value=copy(r.value)} end end
  function d.insert_run(run) put('run/' .. run.id, run) end
  function d.update_run(run, ver)
    local r = f.records['run/' .. run.id]
    if not r or tonumber(r.rev) ~= ver then return false end
    put('run/' .. run.id, run)
    return true
  end
  function d.delete_run(id) drop('run/' .. id) end
  function d.run_summaries(after, limit)
    f.scans[#f.scans + 1] = {limit=limit, after=after, prefix='run/'}
    if f.scan_fail then local err = f.scan_fail({limit=limit, after=after}); if err then error(err, 0) end end
    local ids = {}
    for k in pairs(f.records) do
      local id = k:match('^run/(%d+)$')
      if id and (not after or older(after, id)) then ids[#ids + 1] = id end
    end
    table.sort(ids, older)
    local out = {}
    for i = 1, math.min(#ids, limit) do
      local run = f.records['run/' .. ids[i]].value
      out[i] = {id=run.id, status=run.status, request={by=run.request.by}, grant_id=run.grant_id, grant_revoked=run.grant_revoked}
    end
    return out
  end
  function d.get_counter() return value('run-counter') end
  function d.set_counter(id) put('run-counter', id) end
  function d.get_run_key(key)
    local v = value('run-key/' .. key)
    if v then return {run_id=v.id, expired_at=v.expired_at, form_rev=v.form_rev} end
  end
  function d.put_run_key(key, run_id) put('run-key/' .. key, {id=run_id}) end
  function d.mark_run_key(key, run_id, expired_at, form_rev) put('run-key/' .. key, {id=run_id, expired_at=expired_at, form_rev=form_rev}) end
  function d.delete_run_key(key) drop('run-key/' .. key) end
  function d.expired_markers(after, cutoff, limit)
    f.scans[#f.scans + 1] = {limit=limit, after=after, prefix='run-key/'}
    local keys = {}
    for k, r in pairs(f.records) do
      local key = k:match('^run%-key/(.*)$')
      if key and r.value.expired_at ~= nil and r.value.expired_at <= cutoff and (not after or key > after) then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local out = {}
    for i = 1, math.min(#keys, limit) do
      local v = f.records['run-key/' .. keys[i]].value
      out[i] = {key=keys[i], run_id=v.id, expired_at=v.expired_at, form_rev=v.form_rev}
    end
    return out
  end
  function d.get_form(key)
    local r = f.records['start-form/' .. key]
    if r then return {rev=r.rev, fingerprint=r.value.fingerprint, request=copy(r.value.request), at=r.value.at} end
  end
  function d.put_form(key, fingerprint, request, at) return put('start-form/' .. key, {fingerprint=fingerprint, request=request, at=at}) end
  function d.delete_form(key) drop('start-form/' .. key) end
  function d.get_switch(key) local v = value('switch/' .. key); if v then return {state=v.state, code=v.code, message=v.message} end end
  function d.delete_switch(key) drop('switch/' .. key) end
  function d.get_op(key)
    if f.op_exists then f.op_exists = nil; return {fingerprint='other', result={}} end
    return copy(f.ops[key])
  end
  function d.put_op(key, fingerprint, result) f.writes = (f.writes or 0) + 1; f.ops[key] = {fingerprint=fingerprint, result=copy(result)} end
  f.data = d
  function f.transaction(fn)
    if f.fail_before then f.fail_before = nil; error('store unavailable') end
    local records, ops, rev, writes = copy(f.records), copy(f.ops), f.rev, f.writes or 0
    local ok, result = pcall(fn)
    if not ok then f.records, f.ops, f.rev, f.writes = records, ops, rev, writes; error(result, 0) end
    -- f.batches counts the transactions that wrote (as the store fake counted its batches).
    if (f.writes or 0) > writes then f.batches = (f.batches or 0) + 1 end
    if f.lose_store then f.lose_store = nil; error('lost committed store reply') end
    return result
  end
  function f.hub(action, args)
    if action == 'hub.session.ensure' then
      if not f.session then f.sessions = f.sessions + 1; f.session = 'session:1' end
      if f.lose_session then f.lose_session = nil; error('unknown session outcome') end
      return {session_id=f.session}
    end
    error('Unexpected hub action: ' .. action)
  end
  function f.start(request)
    if f.on_start then local hook = f.on_start; f.on_start = nil; hook(request) end
    f.calls[#f.calls + 1] = copy(request)
    if f.pending then return {status='unknown', error='awaiting reconciliation'} end
    if f.failure then return {status=f.failure, error='deliberate failure'} end
    local saved = f.windows[request.key]
    if saved then assert(equal(saved.request, request), 'Retry changed request'); return copy(saved.result) end
    f.creates = f.creates + 1
    local result = {status='open', window_id='window:' .. f.creates, block_ids={'block:' .. f.creates}}
    f.windows[request.key] = {request=copy(request), result=result}
    if f.lose_spawn then f.lose_spawn = nil; error('lost spawn reply') end
    if f.lose_progress then f.lose_progress = nil; f.lose_store = true end
    return copy(result)
  end
  -- A fake clock (f.now, seconds) and fake timers: f.timers gets {due, fn}; f.fire(t) runs the
  -- timers due at time t.
  f.revoked, f.lookups, f.now, f.timers, f.wakes = {}, 0, 1000000000, {}, 0
  function f.fire(t)
    f.now = t
    local due = {}
    for i = #f.timers, 1, -1 do if f.timers[i].due <= t then due[#due + 1] = table.remove(f.timers, i) end end
    for i = #due, 1, -1 do due[i].fn() end
  end
  function f.engine(extra)
    local o = {hub=f.hub, start_tab=f.start, find_grant=function(run)
      f.lookups = f.lookups + 1
      return f.grant
    end, revoke=function(grant_id)
      if f.revoke_fails then f.revoke_fails = nil; error('lost revoke reply') end
      f.revoked[#f.revoked + 1] = grant_id
    end, resolve_root=function(root)
      assert(not f.no_dirs, 'Directory was removed'); return root
    end, resolve_dir=function(root, dir)
      if f.escape then return '/outside' end
      return dir == '.' and root or root .. '/' .. dir
    end,
    now=function() return f.now end, after=function(delay, fn) f.timers[#f.timers + 1] = {due=f.now + delay, fn=fn} end,
    wake=function() f.wakes = f.wakes + 1 end, data=f.data, transaction=f.transaction}
    for k, v in pairs(extra or {}) do o[k] = v end
    return Run.new(o)
  end
  return f
end
local function leaf(dir) return {launch={profile='test', args={task='hello'}}, dir=dir or '.'} end
local function request(key)
  return {key=key or 'start-1', root='/root', new_session_name='Example', template={v=1, name='Example', tabs={
    {title='One', layout={direction='horizontal', ratio=0.3, before=leaf(), after=leaf('sub')}},
    {title='Two', layout={launch={shell=true}, dir='.'}}}}}
end
local function drain(engine)
  for i=1, 30 do local more, err = engine.tick(); assert(not err, tostring(err)); if not more then return end end
  error('Engine did not settle')
end
function tests.roundtrip()
  local f = fixture(); local e = f.engine(); local req = request(); local run = e.admit(req)
  assert(f.creates == 0 and f.sessions == 0, 'Admission must not create resources')
  req.template.tabs[1].title = 'mutated after admission'
  drain(e)
  assert(e.get(run.id).status == 'open' and f.creates == 2 and f.sessions == 1)
  assert(f.calls[1].title == 'One' and f.calls[1].layout.ratio == 0.3)
  assert(f.calls[1].layout.after.cwd == '/root/sub')
  assert(f.calls[2].layout.shell == true)
  f.no_dirs = true
  assert(e.admit(request()).id == run.id, 'Retry should not resolve deleted directories')
  expect_error(function() e.admit(req) end, 'operation_conflict')
  drain(e); assert(f.creates == 2)
end
function tests.admission_lost_reply()
  local f = fixture(); local e = f.engine(); f.lose_store = true
  assert(not pcall(e.admit, request()))
  e = f.engine(); local run = e.admit(request()); drain(e)
  assert(run.id == '1' and f.creates == 2 and f.records['run-counter'].value == '1')
end
function tests.no_send_before_commit()
  local f = fixture(); local e = f.engine(); local req = request(); req.session_id='session:existing'; req.new_session_name=nil
  e.admit(req); f.fail_before = true
  local more, err = e.tick(); assert(not more and err and f.creates == 0)
  e = f.engine(); e.resume(); drain(e); assert(f.creates == 2)
end
function tests.spawn_lost_reply_restart()
  local f = fixture(); local e = f.engine(); local run=e.admit(request()); f.lose_spawn=true
  drain(e); assert(e.get(run.id).status == 'blocked' and f.creates == 1)
  e = f.engine(); e.resume(); drain(e)
  assert(f.creates == 2 and equal(f.calls[1], f.calls[2]), 'Restart must retry identical request')
end
function tests.progress_lost_reply_restart()
  local f = fixture(); local e = f.engine(); local run=e.admit(request()); f.lose_progress=true
  local err
  for i=1, 10 do local more; more, err=e.tick(); if err then break end end
  assert(err and f.creates == 1)
  e = f.engine(); e.resume(); drain(e)
  assert(f.creates == 2 and e.get(run.id).status == 'open')
end
function tests.pending_blocks_later_tabs()
  local f = fixture(); local e = f.engine(); local run=e.admit(request()); f.pending=true
  for i=1, 8 do e.tick() end
  assert(f.creates == 0 and e.get(run.id).next_tab == 1)
  assert(#f.calls == 1, 'Unknown result must not poll forever')
  e.wake(); drain(e)
  assert(#f.calls == 2 and equal(f.calls[1], f.calls[2]), 'A worker event retries the same request once')
  f.pending=false; e.wake(); drain(e); assert(f.creates == 2)
end
function tests.partial_failure()
  for _, status in ipairs({'failed', 'closed'}) do
    local f = fixture(); local e = f.engine(); local run=e.admit(request())
    for i=1, 3 do e.tick() end
    assert(f.creates == 1)
    f.failure=status; drain(e)
    local saved=e.get(run.id)
    assert(saved.status == status and saved.results[1].status == 'open' and f.creates == 1)
    e=f.engine(); e.resume(); drain(e); assert(f.creates == 1)
  end
end
function tests.session_unknown()
  local f=fixture(); local e=f.engine(); local run=e.admit(request()); f.lose_session=true
  drain(e); assert(e.get(run.id).status == 'blocked' and f.creates == 0)
  e=f.engine(); e.resume(); drain(e); assert(f.sessions == 1 and f.creates == 2)
end
function tests.validation()
  for _, dir in ipairs({'../outside', '/outside', 'a//b', 'a/../b', 'a/', './a', ''}) do
    local f=fixture(); local e=f.engine(); local req=request(); req.template.tabs[1].layout.before.dir=dir
    expect_error(function() e.admit(req) end, 'invalid_input'); assert(f.records['run-counter'] == nil)
  end
  local f=fixture(); f.escape=true
  expect_error(function() f.engine().admit(request()) end, 'invalid_input')
  local req=request(); req.template.tabs[1].layout.ratio=0/0
  expect_error(function() fixture().engine().admit(req) end, 'invalid_input')
end
function tests.store_error_waits_for_wake()
  local f=fixture(); local e=f.engine(); local run=e.admit(request())
  e.tick() -- session creation
  f.fail_before=true
  local more, err=e.tick()
  assert(not more and err and f.creates == 0)
  for i=1, 8 do more, err=e.tick(); assert(not more and not err) end
  assert(f.creates == 0, 'A failed store must not spin or dispatch')
  e.wake(); drain(e); assert(e.get(run.id).status == 'open' and f.creates == 2)
end
function tests.relative_resolver_result()
  local f=fixture()
  local e=Run.new({hub=f.hub, start_tab=f.start, resolve_root=function() return '/' end,
    resolve_dir=function() return 'relative' end, data=f.data, transaction=f.transaction})
  expect_error(function() e.admit(request()) end, 'invalid_input')
end
function tests.focus_intent_is_frozen()
  local f=fixture(); local e=f.engine(); local req=request()
  req.placement={focus={source_window_id='window:source'}}
  local original=copy(req)
  local run=e.admit(req)
  req.placement.focus.source_window_id='window:changed'
  f.lose_spawn=true; drain(e)
  assert(e.get(run.id).status == 'blocked')
  e=f.engine(); e.resume(); drain(e)
  assert(f.creates == 2 and equal(f.calls[1], f.calls[2]))
  for _, call in ipairs(f.calls) do
    assert(call.placement.focus.source_window_id == 'window:source')
  end
  assert(e.admit(original).id == run.id)
  expect_error(function() e.admit(req) end, 'operation_conflict')
end
function tests.focus_validation()
  for _, placement in ipairs({false, {focus=true}, {focus={}}, {focus={source_window_id=42}},
    {focus={source_window_id='window:x', enabled=true}}, {beside='block:x'}}) do
    local f=fixture(); local req=request(); req.placement=placement
    expect_error(function() f.engine().admit(req) end, 'invalid_input')
    assert(f.records['run-counter'] == nil)
  end
end
function tests.dismiss_stops_only_orchestration()
  for _, status in ipairs({'pending', 'unknown', 'blocked'}) do
    local f=fixture(); local e=f.engine(); local run=e.admit(request())
    for i=1, 3 do e.tick() end -- the first tab exists
    f.pending=true; drain(e)
    local key='run/' .. run.id
    f.records[key].value.status=status
    e.wake(); e.tick() -- enqueue before dismissal to test stale queued work
    local before=copy(f.windows)
    local calls=#f.calls
    local dismissed=e.dismiss(run.id)
    assert(dismissed.status == 'dismissed' and dismissed.dismissed_from == status)
    assert(dismissed.results[1].status == 'open' and equal(before, f.windows))
    drain(e)
    e=f.engine(); e.resume(); drain(e)
    assert(e.admit(request()).status == 'dismissed'); drain(e)
    assert(#f.calls == calls and f.creates == 1 and equal(before, f.windows))
    assert(equal(e.dismiss(run.id), dismissed), 'Dismiss must be idempotent')
  end
end
function tests.dismiss_lost_commit_reply()
  local f=fixture(); local e=f.engine(); local run=e.admit(request()); f.pending=true; drain(e)
  f.lose_store=true
  assert(not pcall(e.dismiss, run.id))
  e=f.engine()
  assert(e.dismiss(run.id).status == 'dismissed')
  e.resume(); drain(e); assert(f.creates == 0)
end
function tests.dismiss_refuses_active_or_finished()
  local f=fixture(); local e=f.engine(); local run=e.admit(request())
  for _, status in ipairs({'queued', 'starting', 'open', 'failed', 'closed'}) do
    f.records['run/' .. run.id].value.status=status
    expect_error(function() e.dismiss(run.id) end, 'conflict')
    assert(e.get(run.id).status == status)
  end
  expect_error(function() e.dismiss('missing') end, 'not_found')
end

-- Agent runs (by): nothing dispatches before the grant; the grant goes back after the end.
local function agent_request(key)
  local r = request(key); r.by = 'alice'; return r
end
function tests.agent_run_waits_for_its_grant()
  local f=fixture(); local e=f.engine(); local run=e.admit(agent_request())
  assert(run.status == 'authorizing', run.status)
  drain(e)
  assert(#f.calls == 0 and f.sessions == 0, 'An unauthorized run dispatched')
  assert(e.get(run.id).error:find('not authorized', 1, true))
  assert(e.authorize(run.id, 'grant:1').status == 'queued')
  drain(e)
  local got = e.get(run.id)
  assert(got.status == 'open', got.status)
  for _, call in ipairs(f.calls) do assert(call.grant_id == 'grant:1' and call.placement == nil) end
  assert(equal(f.revoked, {'grant:1'}) and e.get(run.id).grant_revoked == true)
end
function tests.agent_run_finds_its_grant_at_resume()
  local f=fixture(); local e=f.engine(); local run=e.admit(agent_request())
  e=f.engine(); f.grant='grant:7'
  e.resume(); drain(e)
  assert(f.lookups >= 1 and e.get(run.id).grant_id == 'grant:7' and e.get(run.id).status == 'open')
end
function tests.agent_run_keeps_its_grant()
  local f=fixture(); local e=f.engine(); local run=e.admit(agent_request())
  e.authorize(run.id, 'grant:1')
  assert(e.authorize(run.id, 'grant:1').grant_id == 'grant:1')
  expect_error(function() e.authorize(run.id, 'grant:2') end, 'conflict')
end
function tests.agent_run_has_no_placement()
  local f=fixture(); local e=f.engine(); local r=agent_request()
  r.placement={focus={source_window_id='window:1'}}
  expect_error(function() e.admit(r) end, 'invalid_input')
end
function tests.revoke_retries_at_the_next_wake()
  local f=fixture(); local e=f.engine(); local run=e.admit(agent_request())
  e.authorize(run.id, 'grant:1'); f.revoke_fails=true
  drain(e)
  assert(#f.revoked == 0 and not e.get(run.id).grant_revoked)
  e.wake(); drain(e)
  assert(equal(f.revoked, {'grant:1'}) and e.get(run.id).grant_revoked == true)
end
function tests.dismiss_of_an_authorizing_run_revokes_nothing()
  local f=fixture(); local e=f.engine(); local run=e.admit(agent_request())
  assert(e.dismiss(run.id).status == 'dismissed')
  drain(e)
  assert(#f.revoked == 0 and #f.calls == 0)
end
function tests.dismiss_of_a_blocked_agent_run_revokes_its_grant()
  local f=fixture(); local e=f.engine(); local run=e.admit(agent_request())
  e.authorize(run.id, 'grant:1'); f.pending=true; drain(e)
  e.dismiss(run.id); drain(e)
  assert(equal(f.revoked, {'grant:1'}))
end
function tests.retry_commits_with_its_operation()
  local f=fixture(); local e=f.engine(); local run=e.admit(request()); f.failure='blocked'
  -- A failed tab start blocks the run (the fixture answers status blocked as unrecognized).
  drain(e); assert(e.get(run.id).status == 'blocked', e.get(run.id).status)
  f.failure=nil; f.lose_store=true
  local op={key='retry/1', fingerprint='fp'}
  assert(not pcall(e.retry, run.id, op))
  -- The reply was lost after the commit: the run is queued durably, and a new engine starts it.
  assert(e.get(run.id).status == 'queued')
  e=f.engine(); e.wake_one(run.id); drain(e)
  assert(e.get(run.id).status == 'open')
end
function tests.retry_of_a_run_that_is_not_stuck_wakes_nothing()
  local f=fixture(); local e=f.engine(); local run=e.admit(request()); drain(e)
  local result=e.retry(run.id, {key='retry/2', fingerprint='fp'})
  assert(result.woken == false and e.get(run.id).status == 'open')
end
function tests.wake_one_schedules_only_a_queued_run()
  local f=fixture(); local e=f.engine(); local run=e.admit(request()); f.failure='blocked'; drain(e)
  local calls=#f.calls
  e.wake_one(run.id); drain(e)
  assert(#f.calls == calls, 'a blocked run was dispatched again')
end
function tests.dismissed_run_revokes_a_grant_that_it_did_not_record()
  -- The reviewer's case: the grant committed in the hub, the run was dismissed before it saved
  -- the grant ID. A new engine finds the grant, records it and revokes it; nothing dispatches.
  local f=fixture(); local e=f.engine(); local run=e.admit(agent_request())
  e.dismiss(run.id)
  f.grant='grant:9'
  e=f.engine(); e.resume(); drain(e)
  assert(f.creates == 0 and f.sessions == 0 and #f.calls == 0, 'a dismissed run dispatched')
  assert(equal(f.revoked, {'grant:9'}) and e.get(run.id).grant_revoked == true)
end
function tests.finished_run_without_a_grant_checks_once_per_engine()
  local f=fixture(); local e=f.engine(); local run=e.admit(agent_request())
  e.dismiss(run.id); drain(e)
  local lookups=f.lookups
  e.wake(); drain(e)
  assert(f.lookups == lookups and #f.revoked == 0, 'a second lookup in one engine')
  e=f.engine(); e.resume(); drain(e)
  assert(f.lookups == lookups + 1, 'a new engine looks again')
end
function tests.late_grant_is_found_after_restart()
  -- The reviewer's case: the grant commits after the first lookup (a start call still ran).
  local f=fixture(); local e=f.engine(); local run=e.admit(agent_request())
  e.dismiss(run.id); drain(e)
  f.grant='grant:late'
  e=f.engine(); e.resume(); drain(e)
  assert(equal(f.revoked, {'grant:late'}), 'resume missed the late grant')
  assert(#f.calls == 0 and f.sessions == 0)
end
function tests.op_exists_is_its_own_error()
  local f=fixture(); local e=f.engine(); local run=e.admit(request()); f.pending=true; drain(e)
  f.op_exists=true
  expect_error(function() e.dismiss(run.id, {key='d', fingerprint='fp', result={}}) end, 'op_exists')
end
function tests.admission_refuses_a_run_too_large_at_its_final_size()
  local f=fixture(); local e=f.engine(); local r=request()
  r.template.tabs[1].layout.before.launch.args={task=string.rep('x', 40000)}
  expect_error(function() e.admit(r) end, 'invalid_input')
  assert(f.records['run-counter'] == nil, 'a refused run was admitted')
end
function tests.long_errors_are_stored_bounded()
  local f=fixture(); f.failure='failed'
  local start=f.start
  f.start=function(req) local r=start(req); r.error=string.rep('e', 20000) .. '\n'; return r end
  local e=f.engine(); local run=e.admit(request())
  drain(e)
  local got=e.get(run.id)
  assert(got.status == 'failed' and #got.error <= Run.MAX_TEXT, #got.error)
  assert(#got.results[1].error <= Run.MAX_TEXT and not got.error:find('%c'))
end
function tests.an_oversized_id_from_the_hub_is_an_invalid_result()
  local f=fixture()
  local start=f.start
  f.start=function(req) local r=start(req); r.window_id=string.rep('w', Run.MAX_ID + 1); return r end
  local e=f.engine(); local run=e.admit(request())
  drain(e)
  local got=e.get(run.id)
  assert(got.status == 'blocked' and got.error:find('Invalid tab start result', 1, true), got.status)
end
-- Run pages (data.run_summaries, in run ID order). admitted makes count runs that a new engine (a
-- plugin restart) must find by its pages: the first engine never ticks.
local function admitted(f, count)
  local e = f.engine()
  for i = 1, count do e.admit(request('scan-' .. i)) end
end
function tests.a_scan_reads_pages_of_scan_limit_after_the_last_run_id()
  local f=fixture(); admitted(f, Run.SCAN_LIMIT + 3)
  local e=f.engine(); e.resume()
  -- One page per tick at most.
  for i=1, 400 do
    local before=#f.scans
    local more, err = e.tick(); assert(not err, tostring(err))
    local runs = 0
    for j = before + 1, #f.scans do if f.scans[j].prefix == 'run/' then runs = runs + 1 end end
    assert(runs <= 1, 'more than one page in a tick')
    if not more then break end
  end
  local pages = {}
  for _, s in ipairs(f.scans) do if s.prefix == 'run/' then pages[#pages + 1] = s end end
  assert(#pages == 2 and pages[1].after == nil and pages[2].after == tostring(Run.SCAN_LIMIT), 'two pages, the second after the last ID')
  for i=1, Run.SCAN_LIMIT + 3 do assert(e.get(tostring(i)).status == 'open', 'run ' .. i) end
end
function tests.a_scan_does_not_retry_another_error()
  local f=fixture(); admitted(f, 1)
  f.scan_fail=function() return {code='unavailable', message='store unavailable'} end
  local e=f.engine(); e.resume()
  local more, err = e.tick()
  assert(err and err.code == 'unavailable' and not more, 'the error stops the scan')
  assert(not select(1, e.tick()) and #f.scans == 1, 'no retry before a wake')
  f.scan_fail=nil; e.wake(); drain(e)
  assert(e.get('1').status == 'open')
end
-- Size bounds at their encoded size (templates_run.lua, "Size bounds"). rex do and the hub encode
-- "<", ">" and "&" as 6 bytes; every size here is measured with rex.json.encode.
local MAX_RUN, MAX_MESSAGE = 61 * 1024, 65536
local function size(v) return #rex.json.encode(v) end
local function part(s) return #s .. ':' .. s end
-- The worst agent: an ID of MAX_ID "<" and a key of MAX_KEY "<" (both accepted, as before).
local WORST_ID, WORST_KEY = string.rep('<', Run.MAX_ID), string.rep('<', Run.MAX_KEY)
local function worst_op_key(kind) return kind .. '/agent/' .. part(WORST_ID) .. part(WORST_KEY) end
-- The largest run ID: the counter is 31 nines and an 8, so the run is 32 nines.
local RUN_ID = string.rep('9', 32)
local function sized(ch, n)
  local r = request(worst_op_key('start'))
  r.template.tabs = {{title='One', layout={launch={profile='test', args={port=string.rep(ch, n)}}, dir='.'}}}
  return r
end
local function fixture32()
  local f = fixture(); f.records['run-counter'] = {rev='1', value=string.rep('9', 31) .. '8'}
  return f
end
-- largest returns the admitted run with the largest arg (n bytes of ch, one pane), and its fixture.
local function largest(ch)
  local lo, hi = 0, 70000
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if pcall(fixture32().engine().admit, sized(ch, mid)) then lo = mid else hi = mid - 1 end
  end
  local f = fixture32()
  local run = f.engine().admit(sized(ch, lo))
  assert(run.id == RUN_ID and lo > 0, 'largest ' .. ch .. ': ' .. lo)
  return run, f
end
-- worst_run fills a run with the largest values that later writes can add: every ID at MAX_ID,
-- every error a bounded text of err_char.
local function worst_run(run, err_char)
  local id_max = string.rep('x', Run.MAX_ID)
  local err = Run.bounded(string.rep(err_char, 4 * Run.MAX_TEXT))
  local final = copy(run)
  final.session_id, final.status, final.error = id_max, 'dismissed', err
  final.dismissed_from, final.grant_id, final.grant_revoked, final.next_tab = 'authorizing', id_max, true, #run.tabs + 1
  for i, tab in ipairs(final.tabs) do
    tab.request = {key=tab.key, session=id_max, title=tab.title, layout=copy(tab.layout), grant_id=id_max}
    final.results[i] = {status='unknown', window_id=id_max, block_ids={id_max}, error=err}
  end
  return final
end
-- The run's writes are SQL statements that templates_sql.lua measures and cuts in chunks
-- (write_text, FRAME_MAX): only the record bound (MAX_RUN) is checked here.
local function fits(what, v, limit)
  assert(size(v) <= limit, what .. ': encoded ' .. size(v) .. ' bytes, limit ' .. limit)
end
for _, case in ipairs({{'a', '<'}, {'&', '<'}, {'<', '"'}}) do
  local args, errs = case[1], case[2]
  tests['the largest admitted run with args of ' .. args .. ' and errors of ' .. errs .. ' fits MAX_RUN at its final size'] = function()
    local run = largest(args)
    fits('the final record', worst_run(run, errs), MAX_RUN)
  end
end
-- bounded against the real encoder: at most MAX_TEXT bytes and MAX_TEXT_JSON encoded bytes, the
-- ellipsis included, cut on a character boundary, and short texts unchanged.
local ELLIPSIS = string.char(0xE2, 0x80, 0xA6)
local function valid_utf8(s)
  local i = 1
  while i <= #s do
    local c = s:byte(i)
    local n = c < 0x80 and 0 or c >= 0xF0 and c < 0xF8 and 3 or c >= 0xE0 and 2 or c >= 0xC2 and c < 0xE0 and 1 or nil
    if not n then return false end
    for j = 1, n do local d = s:byte(i + j); if not d or d < 0x80 or d >= 0xC0 then return false end end
    i = i + n + 1
  end
  return true
end
function tests.bounded_texts_fit_both_limits_for_every_character_class()
  local classes = {plain='a', angle='<>&', quote='"', backslash='\\', ls=string.char(0xE2, 0x80, 0xA8),
    ps=string.char(0xE2, 0x80, 0xA9), e_acute=string.char(0xC3, 0xA9), malformed=string.char(0xFF),
    mixed='a<' .. string.char(0xC3, 0xA9) .. '"'}
  for name, unit in pairs(classes) do
    for _, n in ipairs({1, 3, 2000}) do
      local text = string.rep(unit, n)
      local out = Run.bounded(text)
      assert(#out <= Run.MAX_TEXT, name .. ': ' .. #out .. ' bytes')
      assert(size(out) <= Run.MAX_TEXT_JSON, name .. ': ' .. size(out) .. ' encoded bytes')
      if #text <= Run.MAX_TEXT and size(text) <= Run.MAX_TEXT_JSON then
        assert(out == text, name .. ': a short text changed')
      else
        assert(out:sub(-3) == ELLIPSIS, name .. ': no ellipsis')
        local prefix = out:sub(1, -4)
        assert(text:sub(1, #prefix) == prefix, name .. ': not a prefix')
        if name ~= 'malformed' then assert(valid_utf8(prefix), name .. ': cut inside a character') end
      end
    end
  end
end
-- The encoding the bounds rely on (observed on Rex 0.0.1792158932-g88fd41). Admission measures with
-- this encoder, so these values document it; they are not part of the bound.
function tests.rex_json_encodes_angle_brackets_and_line_separators_as_6_bytes()
  for _, s in ipairs({'<', '>', '&', string.char(0xE2, 0x80, 0xA8), string.char(0xE2, 0x80, 0xA9)}) do
    assert(size(s) == 8, s .. ': ' .. size(s))
  end
  -- A malformed byte becomes U+FFFD, written as its 3 UTF-8 bytes (not escaped).
  assert(size(string.char(0xFF)) == 5, 'a malformed byte: ' .. size(string.char(0xFF)))
end
-- A run admitted before this bound, larger than it now allows, keeps its replay: the same request
-- with its key returns the run, and another request with that key conflicts (no size check first).
function tests.a_run_over_the_new_bound_replays_its_key()
  local f = fixture()
  -- About 63 KB: over the new bound, under the 64 KiB write limit (as an old admission could be).
  local r = sized('&', 5250); r.key = 'old-start'
  local run = {id='7', request=copy(r), root='/root', tabs={{title='One', key='templates/7/tab/1',
    layout={profile='test', args={port=string.rep('&', 5250)}, cwd='/root'}}}, next_tab=1, status='blocked',
    error='an older failure', results={}, session_key='templates/7/session'}
  f.records['run-key/old-start'] = {rev='1', value={id='7'}}
  f.records['run/7'] = {rev='2', value=run}
  assert(size(run) > MAX_RUN and size(run) < MAX_MESSAGE, 'seeded run: ' .. size(run))
  local e = f.engine()
  local got = e.admit(copy(r))
  assert(got.id == '7' and got.status == 'blocked')
  local other = copy(r); other.root = '/other'
  expect_error(function() e.admit(other) end, 'operation_conflict')
  assert(f.records['run/8'] == nil)
end
function tests.admission_refuses_an_invalid_session_id()
  local f=fixture(); local e=f.engine()
  for _, sid in ipairs({string.rep('s', 129), 'session:"x"', 'a b'}) do
    local r=request(); r.new_session_name=nil; r.session_id=sid
    expect_error(function() e.admit(r) end, 'invalid_input')
  end
  assert(f.records['run-counter'] == nil)
end

-- Retention (templates_run.lua, "Retention"; tests/templates-run.md). The fixture's records hold
-- the runs, their run-key records and their start-form records (form_key: 'start-form/' .. key in
-- these tests); f.now is the clock and f.timers the timers.
local RKEYS = {form_key=function(k) return 'start-form/' .. k end, switch_key=function(k) return 'switch/' .. k end}
local function put(f, key, value)
  f.rev = f.rev + 1
  f.records[key] = {rev=tostring(f.rev), value=value}
  return tostring(f.rev)
end
-- seed writes run id (a number) with this status and its records; extra fields go into the run.
local function seed(f, id, status, extra, by)
  id = tostring(id)
  local key = 'k' .. id
  local run = {id=id, status=status, root='/root', tabs={}, next_tab=1, results={}, session_key='templates/' .. id .. '/session',
    request={key=key, root='/root', new_session_name='S', template={v=1, name='T', tabs={}}, by=by}}
  for k, v in pairs(extra or {}) do run[k] = v end
  put(f, 'run/' .. id, run)
  put(f, 'run-key/' .. key, {id=id})
  put(f, 'start-form/' .. key, {fingerprint='fp' .. id, request=run.request, at=1})
  return run
end
local function seed_open(f, first, last) for i = first, last do seed(f, i, 'open') end end
local function rdrain(e)
  for i = 1, 3000 do local more, err = e.tick(); assert(not err, tostring(err)); if not more then return end end
  error('Engine did not settle')
end
local function present(f, first, last)
  local n = 0
  for i = first, last do if f.records['run/' .. i] then n = n + 1 end end
  return n
end
-- ready ticks until the first full scan is done (the retirements are queued, none ran yet).
local function ready(e)
  for i = 1, 100 do if e.maintenance().ready then return end; e.tick() end
  error('The scan did not finish')
end

function tests.retention_keeps_the_200_newest_eligible_runs_and_every_unfinished_run()
  local f = fixture()
  seed_open(f, 1, 205)
  -- Unfinished: agent runs that wait for their grant (no grant: they dispatch nothing).
  for i = 206, 208 do seed(f, i, 'authorizing', nil, 'alice') end
  local form1 = f.records['start-form/k1']
  local e = f.engine(RKEYS); e.resume(); rdrain(e)
  assert(present(f, 1, 5) == 0, 'the 5 oldest are retired')
  assert(present(f, 6, 205) == 200, 'the 200 newest eligible runs stay')
  assert(present(f, 206, 208) == 3, 'every unfinished run stays')
  for i = 1, 5 do
    local m = f.records['run-key/k' .. i].value
    assert(m.id == tostring(i) and m.expired_at == f.now and m.form_rev == f.records['start-form/k' .. i].rev, 'marker ' .. i)
  end
  -- The start-form record is not changed by a retirement.
  assert(equal(f.records['start-form/k1'], form1), 'start-form unchanged')
  -- A new engine (a plugin restart) over the same store retires nothing more.
  local batches = f.batches
  local e2 = f.engine(RKEYS); e2.resume(); rdrain(e2)
  assert(present(f, 6, 205) == 200 and f.batches == batches, 'nothing more after a restart')
end

function tests.retention_the_201st_eligible_run_retires_the_oldest_without_a_wake()
  local f = fixture()
  seed_open(f, 1, 200)
  put(f, 'run-counter', '300')
  local e = f.engine(RKEYS); e.resume(); rdrain(e)
  assert(present(f, 1, 200) == 200, 'nothing retired at 200')
  -- A new start opens after the scan; no wake.
  local run = e.admit(request('new-start'))
  rdrain(e)
  assert(e.get(run.id).status == 'open')
  assert(f.records['run/1'] == nil, 'the oldest is retired')
  assert(present(f, 2, 200) == 199 and f.records['run/' .. run.id] ~= nil)
end

function tests.retention_a_run_that_owes_a_revoke_is_retired_only_after_its_revoke()
  local f = fixture()
  seed(f, 1, 'open', {grant_id='grant:1'}, 'alice')
  seed_open(f, 2, 201)
  f.revoke_fails = true
  local e = f.engine(RKEYS); e.resume(); rdrain(e)
  assert(f.records['run/1'] ~= nil and present(f, 2, 201) == 200, 'kept while it owes the revoke')
  -- The revoke passes at the next wake; the run is then eligible and the oldest.
  e.wake(); rdrain(e)
  assert(f.records['run/1'] == nil and f.revoked[1] == 'grant:1', 'retired after its revoke')
  assert(present(f, 2, 201) == 200)
end

function tests.retention_never_retires_an_agent_run_without_a_recorded_grant()
  local f = fixture()
  seed(f, 1, 'dismissed', {dismissed_from='authorizing'}, 'alice')
  seed_open(f, 2, 202)
  local e = f.engine(RKEYS); e.resume(); rdrain(e)
  assert(f.records['run/1'] ~= nil, 'protected')
  assert(f.records['run/2'] == nil and present(f, 3, 202) == 200, 'the oldest eligible run is retired')
end

function tests.retention_a_lost_reply_is_not_retired_twice()
  local f = fixture()
  seed_open(f, 1, 201)
  local e = f.engine(RKEYS); e.resume(); ready(e)
  f.lose_store = true
  local batches = f.batches or 0
  e.tick()
  assert(f.records['run/1'] == nil and f.records['run-key/k1'].value.expired_at, 'committed')
  assert(f.batches == batches + 1)
  -- The step waits RETRY_DELAY; then it finds the run gone and writes nothing.
  local marker = f.records['run-key/k1']
  rdrain(e)
  f.fire(f.now + Run.RETRY_DELAY); rdrain(e)
  assert(f.batches == batches + 1 and equal(f.records['run-key/k1'], marker), 'no second batch')
end

function tests.retention_a_failed_batch_waits_and_is_not_retried_at_once()
  local f = fixture()
  seed_open(f, 1, 201)
  local e = f.engine(RKEYS); e.resume(); ready(e)
  f.fire(f.now) -- the timer of the queued retirement (due now)
  f.fail_before = true
  e.tick()
  assert(f.records['run/1'] ~= nil, 'not retired')
  local batches = f.batches or 0
  for i = 1, 20 do e.tick() end
  assert((f.batches or 0) == batches, 'no retry before the delay')
  assert(#f.timers >= 1, 'a timer waits')
  local wakes = f.wakes
  f.fire(f.now + Run.RETRY_DELAY)
  assert(f.wakes == wakes + 1, 'the timer wakes the pump')
  rdrain(e)
  assert(f.records['run/1'] == nil and (f.batches or 0) == batches + 1, 'retired once')
end

function tests.retention_rechecks_the_run_key_before_it_retires()
  local f = fixture()
  seed_open(f, 1, 201)
  local e = f.engine(RKEYS); e.resume(); ready(e)
  -- The key names another run (changed after the queue): not retired.
  put(f, 'run-key/k1', {id='999'})
  local batches = f.batches or 0
  rdrain(e)
  assert(f.records['run/1'] ~= nil and (f.batches or 0) == batches, 'not retired')
end

function tests.retention_an_earlier_timer_supersedes_a_later_one()
  local f = fixture()
  seed_open(f, 1, 201)
  put(f, 'run-counter', '300')
  local e = f.engine(RKEYS); e.resume(); ready(e)
  f.fire(f.now) -- the timer of the queued retirement (due now)
  f.fail_before = true
  e.tick()
  local late
  for _, t in ipairs(f.timers) do if t.due == f.now + Run.RETRY_DELAY then late = t end end
  assert(late, 'a timer for the retry')
  -- A new eligible run queues a retirement that is due now: an earlier timer replaces the late one.
  e.admit(request('newer')); rdrain(e)
  local wakes = f.wakes
  late.fn()
  assert(f.wakes == wakes, 'the superseded callback does nothing')
end

function tests.retention_a_marker_frees_its_key_after_30_days_exactly()
  local f = fixture()
  put(f, 'run-key/kx', {id='5', expired_at=f.now - Run.MARKER_TTL + 1, form_rev='1'})
  local e = f.engine(RKEYS)
  expect_error(function() e.admit(request('kx')) end, 'expired')
  f.now = f.now + 1
  local run = e.admit(request('kx'))
  assert(f.records['run-key/kx'].value.id == run.id and f.records['run-key/kx'].value.expired_at == nil, 'a new run')
end

function tests.retention_cleanup_deletes_expired_markers_and_only_their_own_forms()
  local f = fixture()
  local old = f.now - Run.MARKER_TTL - 1
  -- a: expired, its form; b: expired, the form was replaced (another rev); c: not expired;
  -- d: legacy (no form_rev) with a form written later.
  local ra = put(f, 'start-form/a', {fingerprint='fa'})
  put(f, 'run-key/a', {id='1', expired_at=old, form_rev=ra})
  local rb = put(f, 'start-form/b', {fingerprint='fb'})
  put(f, 'start-form/b', {fingerprint='fb2'})
  put(f, 'run-key/b', {id='2', expired_at=old, form_rev=rb})
  put(f, 'run-key/c', {id='3', expired_at=f.now - Run.MARKER_TTL + 100, form_rev='1'})
  put(f, 'start-form/d', {fingerprint='fd'})
  put(f, 'run-key/d', {id='4', expired_at=old})
  local e = f.engine(RKEYS); e.resume(); rdrain(e)
  assert(f.records['run-key/a'] == nil and f.records['start-form/a'] == nil, 'a')
  assert(f.records['run-key/b'] == nil and f.records['start-form/b'].value.fingerprint == 'fb2', 'b keeps its new form')
  assert(f.records['run-key/c'] ~= nil, 'c is not expired')
  assert(f.records['run-key/d'] == nil and f.records['start-form/d'] ~= nil, 'd keeps the later form')
  -- The next cleanup runs 24 hours later.
  put(f, 'run-key/e', {id='6', expired_at=old})
  rdrain(e)
  assert(f.records['run-key/e'] ~= nil, 'not before 24 hours')
  f.fire(f.now + Run.CLEANUP_EVERY); rdrain(e)
  assert(f.records['run-key/e'] == nil, 'the daily cleanup')
end

function tests.retention_cleanup_leaves_a_key_reused_after_its_scan()
  local f = fixture()
  local old = f.now - Run.MARKER_TTL - 1
  local ra = put(f, 'start-form/a', {fingerprint='fa'})
  put(f, 'run-key/a', {id='1', expired_at=old, form_rev=ra})
  local e = f.engine(RKEYS); e.resume()
  -- Tick until the cleanup scan queued the marker, then reuse the key before the step.
  for i = 1, 50 do
    e.tick()
    if e.maintenance().steps > 0 then break end
  end
  assert(e.maintenance().steps == 1, 'queued')
  put(f, 'start-form/a', {fingerprint='new'})
  put(f, 'run-key/a', {id='7'})
  rdrain(e)
  assert(f.records['run-key/a'].value.id == '7' and f.records['start-form/a'].value.fingerprint == 'new', 'the reuse stays')
end

function tests.retention_retires_a_run_with_the_largest_keys()
  -- The largest operation key and a large start form. Each SQL statement of the retirement is a
  -- frame that templates_sql.lua measures (write_text); here the retirement itself is checked.
  local f = fixture32()
  local key = worst_op_key('start')
  local run = seed(f, RUN_ID, 'open')
  run.request.key = key
  f.records['run/' .. RUN_ID].value.request.key = key
  f.records['run-key/k' .. RUN_ID] = nil
  put(f, 'run-key/' .. key, {id=RUN_ID})
  local form_rev = put(f, 'start-form/' .. key, {fingerprint=string.rep('<', 40000)})
  put(f, 'switch/' .. key, {state='done'})
  -- 200 newer eligible runs: IDs of 33 digits are newer than RUN_ID (32 digits).
  for i = 1, 200 do seed(f, '2' .. string.format('%032d', i), 'open') end
  local e = f.engine(); e.resume(); rdrain(e)
  assert(f.records['run/' .. RUN_ID] == nil, 'retired')
  local m = f.records['run-key/' .. key].value
  assert(m.id == RUN_ID and m.form_rev == form_rev and m.expired_at == f.now, 'the marker names the form')
  assert(f.records['switch/' .. key] == nil and f.records['start-form/' .. key] ~= nil, 'the switch is deleted; the form stays')
end

-- switch_settled (the plugin's retirable): a user start into a new session waits for its switch
-- decision, or for the bound after the form's submit.
function tests.switch_settled_waits_for_a_final_switch_decision_or_the_bound()
  -- The rows of templates_sql.lua: a start form {rev, fingerprint, at} and a switch {state}.
  local run = {request={key='k', new_session_name='S'}}
  local form = {rev='5', fingerprint='fp', at=1000}
  local S = Run.switch_settled
  assert(not S(run, form, nil, 1010, 78), 'no decision, within the bound: wait')
  assert(not S(run, form, {state='attempted'}, 1010, 78), 'attempted: wait')
  assert(not S(run, form, {state='other'}, 1010, 78), 'an unknown state is not final')
  for _, state in ipairs({'done', 'refused', 'unknown'}) do
    assert(S(run, form, {state=state}, 1010, 78), state .. ' is final')
  end
  assert(S(run, form, nil, 1078, 78), 'no decision at the bound: retirable')
  assert(S(run, form, {state='attempted'}, 1078, 78), 'attempted at the bound: retirable')
  assert(S(run, {rev='5', fingerprint='fp'}, nil, 1010, 78), 'a form without at never switches')
  assert(S(run, {rev='5', fingerprint='fp', at='x'}, nil, 1010, 78), 'an invalid at never switches')
  assert(S(run, nil, nil, 1010, 78), 'no form: nothing switches')
  assert(S({request={key='k', session_id='session:1'}}, form, nil, 1010, 78), 'an existing session: no switch')
  assert(S({request={key='k', new_session_name='S', by='alice'}}, form, nil, 1010, 78), 'an agent start: no switch')
end

function tests.retention_a_postponed_step_retires_later_by_its_timer_and_does_not_block_starts()
  local f = fixture()
  seed_open(f, 1, 201)
  put(f, 'run-counter', '300')
  local asked = {}
  local e = f.engine({form_key=RKEYS.form_key, switch_key=RKEYS.switch_key, retirable=function(run, form, switch, now)
    asked[#asked + 1] = {id=run.id, form=form, switch=switch, now=now}
    return now >= f.settle_at
  end})
  f.settle_at = f.now + 100
  e.resume(); rdrain(e)
  assert(f.records['run/1'] ~= nil and f.records['run-key/k1'].value.expired_at == nil, 'postponed')
  assert(#asked == 1 and asked[1].id == '1' and asked[1].form.rev == f.records['start-form/k1'].rev, 'asked with the fresh records')
  -- A new start opens while the step waits.
  local run = e.admit(request('new-start')); rdrain(e)
  assert(e.get(run.id).status == 'open', 'starts are not blocked')
  -- The step is tried again after RETRY_DELAY, by its timer (no other wake).
  local wakes = f.wakes
  f.fire(f.now + Run.RETRY_DELAY)
  assert(f.wakes == wakes + 1, 'the timer wakes the pump')
  rdrain(e)
  assert(f.records['run/1'] ~= nil and #asked >= 2, 'still within the bound')
  f.fire(f.now + Run.RETRY_DELAY); rdrain(e)
  assert(f.records['run/1'] == nil and f.records['run-key/k1'].value.id == '1', 'retired after the bound')
  -- The new start made run 2 the oldest over 200.
  assert(f.records['run/2'] == nil and present(f, 3, 201) == 199)
end

-- A step due now supersedes the timer of a later step (one timer: the earliest). Its timer fires
-- after the step ran; the ticks that follow read scan pages (a wake), which run no maintenance.
-- The later step must still get a timer.
function tests.retention_a_later_step_keeps_its_timer_after_an_earlier_step()
  local f = fixture()
  seed_open(f, 1, 201)
  put(f, 'run-counter', '300')
  local e = f.engine(RKEYS); e.resume(); ready(e)
  f.fire(f.now) -- the timer of the queued retirement (due now)
  f.fail_before = true
  e.tick() -- the retirement of run 1 fails: it waits RETRY_DELAY
  assert(f.records['run/1'] ~= nil)
  -- A new start retires run 2 now: its step is due now.
  local run = e.admit(request('new-start')); rdrain(e)
  assert(e.get(run.id).status == 'open' and f.records['run/2'] == nil, 'run 2 retired')
  e.wake() -- a worker change: the next ticks read scan pages
  f.fire(f.now); rdrain(e)
  -- RETRY_DELAY later, a timer wakes the pump for run 1.
  local wakes = f.wakes
  f.fire(f.now + Run.RETRY_DELAY)
  assert(f.wakes > wakes, 'a timer wakes the pump for the later step')
  rdrain(e)
  assert(f.records['run/1'] == nil, 'run 1 retired')
end

-- engine.measure (the save check, templates.lua start_size): the final-record size with a run ID of
-- 32 digits. admit measures with the actual run ID.
function tests.measure_agrees_with_admit_at_the_largest_run_id()
  local run = largest('a')
  local n = #run.request.template.tabs[1].layout.launch.args.port
  local e = fixture().engine()
  assert(e.measure(sized('a', n)) <= MAX_RUN, 'the largest admitted run fits')
  assert(e.measure(sized('a', n + 1)) > MAX_RUN, 'one more byte does not fit')
end

function tests.admit_keeps_its_actual_run_id_size()
  local n = #largest('a').request.template.tabs[1].layout.launch.args.port
  local f = fixture()
  assert(f.engine().measure(sized('a', n + 1)) > MAX_RUN, 'over the limit with 32 digits')
  -- Run ID "1": the same request fits, and admission accepts it as before.
  local run = f.engine().admit(sized('a', n + 1))
  assert(run.id == '1')
end

function tests.measure_reads_and_writes_nothing()
  local f = fixture()
  local e = f.engine()
  local before = copy(f.records)
  local batches = f.batches
  local get = f.hub
  f.hub = function(action, args)
    assert(action ~= 'hub.store.get' and action ~= 'hub.store.batch' and action ~= 'hub.store.scan', 'measure called ' .. action)
    return get(action, args)
  end
  e = f.engine()
  assert(e.measure(request('m-1')) > 0)
  f.hub = get
  assert(equal(f.records, before) and f.batches == batches, 'nothing written')
  local more = e.tick()
  assert(not more, 'nothing queued')
end

-- The guarantee's conditions (tests/templates-run.md, "Save size"): each variable string adds its
-- encoded size. An omitted optional field is not larger than its reference.
function tests.measure_grows_only_with_the_encoded_size_of_each_variable_string()
  local e = fixture().engine()
  local function m(edit) local r = request('m-key'); edit(r); return e.measure(r) end
  local id = string.rep('x', Run.MAX_ID)
  local ref_window = m(function(r) r.placement = {focus={source_window_id=id}} end)
  assert(m(function(r) end) <= ref_window, 'no placement')
  assert(m(function(r) r.placement = {focus={source_window_id='window:01a15fa8-f805-73d4-b14f-ec1c999a5bf4'}} end) <= ref_window)
  assert(m(function(r) r.placement = {focus={source_window_id=string.rep('<', Run.MAX_ID)}} end) > ref_window, 'a longer encoded window ID')
  -- Equal encoded size, equal size: the root and the name.
  assert(m(function(r) r.root = '/abcde' end) == m(function(r) r.root = '/vwxyz' end))
  assert(m(function(r) r.root = '/<' end) > m(function(r) r.root = '/abcde' end), 'a longer encoded root')
  assert(m(function(r) r.new_session_name = 'xxxxxx' end) == m(function(r) r.new_session_name = '<' end))
  -- An existing-session start is not larger than its reference session ID of MAX_ID.
  local existing = m(function(r) r.new_session_name = nil; r.session_id = id end)
  assert(m(function(r) r.new_session_name = nil; r.session_id = 'session:1' end) <= existing)
  -- An agent start: no by is not larger than the reference by.
  local agent = m(function(r) r.by = string.rep('<', Run.MAX_ID) end)
  assert(m(function(r) r.by = 'alice' end) <= agent and m(function(r) end) <= agent)
end
-- The ver check (templates_run.lua, save): advance reads the run, calls the hub, then saves over
-- the ver of its read. Another writer that changes the run during the call wins: the save writes
-- nothing and fails with conflict, and the next wake continues from the new version.
function tests.a_save_after_a_hub_call_over_a_changed_run_writes_nothing()
  local f = fixture(); local e = f.engine(); local run = e.admit(request())
  f.on_start = function()
    local r = f.records['run/' .. run.id]
    local v = copy(r.value); v.error = 'set by another writer'
    f.rev = f.rev + 1; f.records['run/' .. run.id] = {rev=tostring(f.rev), value=v}
  end
  local err
  for i = 1, 10 do
    local more, e2 = e.tick()
    if e2 then err = e2 break end
    if not more then break end
  end
  assert(type(err) == 'table' and err.code == 'conflict', 'the save conflicts')
  local v = f.records['run/' .. run.id].value
  assert(v.error == 'set by another writer' and v.results[1] == nil and v.next_tab == 1, 'nothing written over the change')
  e.wake(); drain(e)
  assert(e.get(run.id).status == 'open' and f.creates == 2, 'the next wake opens each tab once')
end
return tests
end
