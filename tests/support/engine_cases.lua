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
  local f = {records={}, rev=0, creates=0, sessions=0, calls={}, windows={}}
  function f.hub(action, args)
    if action == 'hub.store.get' then
      local out = {}; for _, key in ipairs(args.keys) do out[key] = copy(f.records[key] or {rev='0'}) end
      return {records=out}
    elseif action == 'hub.store.batch' then
      if f.fail_before then f.fail_before = nil; error('store unavailable') end
      if f.op_exists and args.op then f.op_exists = nil; return {op_exists={key=args.op.key}} end
      for _, op in ipairs(args.ops) do
        if (f.records[op.key] or {rev='0'}).rev ~= op.if_rev then return {conflict=true} end
      end
      local revs = {}
      for _, op in ipairs(args.ops) do
        f.rev = f.rev + 1
        f.records[op.key] = {rev=tostring(f.rev), value=copy(op.value)}
        revs[op.key] = tostring(f.rev)
      end
      if f.lose_store then f.lose_store = nil; error('lost committed store reply') end
      return {revs=revs}
    elseif action == 'hub.store.scan' then
      local out = {}
      for k, v in pairs(f.records) do if k:sub(1, #args.prefix) == args.prefix then out[k] = copy(v) end end
      return {records=out}
    elseif action == 'hub.session.ensure' then
      if not f.session then f.sessions = f.sessions + 1; f.session = 'session:1' end
      if f.lose_session then f.lose_session = nil; error('unknown session outcome') end
      return {session_id=f.session}
    end
    error('Unexpected hub action: ' .. action)
  end
  function f.start(request)
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
  f.revoked, f.lookups = {}, 0
  function f.engine()
    return Run.new({hub=f.hub, start_tab=f.start, find_grant=function(run)
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
    end})
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
    resolve_dir=function() return 'relative' end})
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
function tests.admission_refuses_an_invalid_session_id()
  local f=fixture(); local e=f.engine()
  for _, sid in ipairs({string.rep('s', 129), 'session:"x"', 'a b'}) do
    local r=request(); r.new_session_name=nil; r.session_id=sid
    expect_error(function() e.admit(r) end, 'invalid_input')
  end
  assert(f.records['run-counter'] == nil)
end
return tests
end
