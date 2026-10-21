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
  local f = {records={}, rev=0, creates=0, sessions=0, calls={}, windows={}, scans={}}
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
      f.batches = (f.batches or 0) + 1
      for _, op in ipairs(args.ops) do
        f.rev = f.rev + 1
        -- A deleted record is absent, as in the hub (a get gives rev '0').
        if op.delete then f.records[op.key] = nil else f.records[op.key] = {rev=tostring(f.rev), value=copy(op.value)} end
        revs[op.key] = tostring(f.rev)
      end
      if f.lose_store then f.lose_store = nil; error('lost committed store reply') end
      return {revs=revs}
    elseif action == 'hub.store.scan' then
      -- Pages as the hub does: keys in order after args.after, at most args.limit, next = the
      -- last key of a page that has more. f.scan_fail(args) can fail a call with an error.
      f.scans[#f.scans + 1] = {limit=args.limit, after=args.after, prefix=args.prefix}
      if f.scan_fail then local err = f.scan_fail(args); if err then error(err, 0) end end
      local keys = {}
      for k in pairs(f.records) do
        if k:sub(1, #args.prefix) == args.prefix and (not args.after or k > args.after) then keys[#keys + 1] = k end
      end
      table.sort(keys)
      local out, limit = {}, args.limit or 500
      for i = 1, math.min(#keys, limit) do out[keys[i]] = copy(f.records[keys[i]]) end
      return {records=out, next=#keys > limit and keys[limit] or nil}
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
    wake=function() f.wakes = f.wakes + 1 end}
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
-- Store scans (templates_run.lua, "Store scans"). admitted makes count runs that a new engine (a
-- plugin restart) must find by its scan: the first engine never ticks.
local function admitted(f, count)
  local e = f.engine()
  for i = 1, count do e.admit(request('scan-' .. i)) end
end
local too_large = {code='reply_too_large', message='reply too large'}
local function limits(f)
  local out = {}
  -- The run scans only (the retention cleanup scans run-key/).
  for _, s in ipairs(f.scans) do if s.prefix == 'run/' then out[#out + 1] = s.limit end end
  return out
end
function tests.a_scan_halves_its_limit_on_reply_too_large_and_keeps_its_cursor()
  local f=fixture(); admitted(f, 5)
  -- A page of more than 3 records is too large.
  f.scan_fail=function(args) if args.limit > 3 then return too_large end end
  local e=f.engine(); e.resume()
  -- One scan call per tick at most.
  for i=1, 60 do
    local before=#f.scans
    local more, err = e.tick(); assert(not err, tostring(err))
    assert(#f.scans - before <= 1, 'more than one scan call in a tick')
    if not more then break end
  end
  assert(equal(limits(f), {50, 25, 12, 6, 3, 3}), table.concat(limits(f), ','))
  -- The same page is asked again (same after) until it passes; then the cursor moves on.
  for i=1, 5 do assert(f.scans[i].after == nil, 'cursor moved before a page passed') end
  assert(f.scans[6].after == 'run/3')
  -- Every run was found once and opened once (2 tabs each).
  for i=1, 5 do assert(e.get(tostring(i)).status == 'open', 'run ' .. i) end
  assert(f.creates == 10, 'creates ' .. f.creates)
  -- A new scan starts at the full limit again.
  f.scans, f.scan_fail = {}, nil
  e.wake(); drain(e)
  assert(f.scans[1].limit == Run.SCAN_LIMIT)
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
function tests.a_scan_stops_when_a_page_of_one_is_too_large()
  local f=fixture(); admitted(f, 1)
  f.scan_fail=function() return too_large end
  local e=f.engine(); e.resume()
  local errors = 0
  for i=1, 20 do
    local more, err = e.tick()
    if err then errors = errors + 1; assert(err.code == 'reply_too_large') end
    if not more then break end
  end
  assert(errors == 1, 'the error is returned once')
  assert(equal(limits(f), {50, 25, 12, 6, 3, 1}), table.concat(limits(f), ','))
  assert(not select(1, e.tick()) and #f.scans == 6, 'no scan after the stop')
  assert(e.get('1').status == 'queued')
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
-- frame is the client.perform request that carries a hub.store.batch of the plugin.
local function frame(args)
  return {type='request', id='4294967295', method='client.perform', payload={
    client_id='client:01a156b7-98dc-7330-a826-228df9162450', action='hub.store.batch', timeout_ms=10000, args=args}}
end
local function fits(what, v, limit)
  assert(size(v) <= limit, what .. ': encoded ' .. size(v) .. ' bytes, limit ' .. limit)
end
for _, case in ipairs({{'a', '<'}, {'&', '<'}, {'<', '"'}}) do
  local args, errs = case[1], case[2]
  tests['the largest admitted run with args of ' .. args .. ' and errors of ' .. errs .. ' fits in every write'] = function()
    local run, f = largest(args)
    local final = worst_run(run, errs)
    fits('the final record', final, MAX_RUN)
    -- The admission batch, as the engine wrote it (the fixture kept the record).
    fits('the admission write', frame({ops={{key='run-key/' .. run.request.key, if_rev='0', value={id=RUN_ID}},
      {key='run-counter', if_rev=string.rep('9', 20), value=RUN_ID}, {key='run/' .. RUN_ID, if_rev='0', value=f.records['run/' .. RUN_ID].value}}}), MAX_MESSAGE)
    local record = {key='run/' .. RUN_ID, if_rev=string.rep('9', 20), value=final}
    fits('a state write', frame({ops={record}}), MAX_MESSAGE)
    fits('the dismiss write', frame({ops={record}, op={key=worst_op_key('dismiss'),
      fingerprint='dismiss-v1/' .. part(RUN_ID), result={run_id=RUN_ID, status='dismissed'}}}), MAX_MESSAGE)
    fits('the retry write', frame({ops={record}, op={key=worst_op_key('retry'),
      fingerprint='retry-v1/' .. part(RUN_ID), result={run_id=RUN_ID, woken=true}}}), MAX_MESSAGE)
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

function tests.retention_the_retirement_batch_is_small_with_the_largest_keys()
  local f = fixture32()
  local batches = {}
  local hub = f.hub
  f.hub = function(action, args)
    if action == 'hub.store.batch' then batches[#batches + 1] = copy(args) end
    return hub(action, args)
  end
  local key = worst_op_key('start')
  local hexkey = (key:gsub('.', function(c) return string.format('%02x', c:byte()) end))
  local keys = {form_key=function(k) return 'start-form/' .. (k:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end,
    switch_key=function(k) return 'switch/' .. (k:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end}
  local run = seed(f, RUN_ID, 'open')
  run.request.key = key
  f.records['run/' .. RUN_ID].value.request.key = key
  f.records['run-key/k' .. RUN_ID] = nil
  put(f, 'run-key/' .. key, {id=RUN_ID})
  put(f, 'start-form/' .. hexkey, {fingerprint=string.rep('<', 40000)})
  put(f, 'switch/' .. hexkey, {state='done'})
  -- 200 newer eligible runs: IDs of 33 digits are newer than RUN_ID (32 digits).
  for i = 1, 200 do seed(f, '2' .. string.format('%032d', i), 'open') end
  local logs = {}
  local e = f.engine({form_key=keys.form_key, switch_key=keys.switch_key, log=function(l) logs[#logs + 1] = l end}); e.resume(); rdrain(e)
  assert(f.records['run/' .. RUN_ID] == nil, 'retired: ' .. table.concat(logs, ' | ') .. ' ' .. rex.json.encode(e.maintenance()) .. ' batches ' .. #batches .. ' rk ' .. tostring(f.records['run-key/' .. key] ~= nil))
  local retire = batches[#batches]
  assert(#retire.ops == 3, 'run, marker and switch')
  fits('the retirement write', frame(retire), 4096)
end
return tests
end
