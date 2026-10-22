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
-- Size bounds. A run record is an SQL row (templates_sql.lua). Its value is written in chunks:
-- write_text measures each statement as its complete frame (client ID, action, SQL text, every
-- parameter, the transaction token, the envelope) and cuts the value so that the frame is at most
-- FRAME_MAX (60 KiB, under the SDK's 64 KiB request limit). MAX_RUN (61 KiB as encoded JSON) stays
-- the bound of the record, so every field that a later write adds has a bound:
--   MAX_TEXT: an error text that the run stores (a longer one is cut; the full text goes to the
--     plugin log through opts.log).
--   MAX_ID: a session, window, block or grant ID, from the hub or from a request: 1 to MAX_ID
--     characters of [A-Za-z0-9.:_-] (valid_id), so its JSON is its length + 2. Another value is
--     refused in a request, and is an invalid result from the hub.
--   MAX_RUN_ID: the digits of a run ID (the run counter).
--   MAX_KEY: the key of an operation; with MAX_ID it bounds an operation key (at most 1992 B as
--     JSON, "<" encoded as 6 bytes) in the statements of dismiss and retry.
-- Sizes are measured with rex.json.encode, the encoder that writes the record. It encodes "<", ">"
-- and "&" as 6 bytes, as the hub does (observed on Rex 0.0.1792158932-g88fd41), so a count of the
-- raw bytes is not a bound.
-- Admission builds the record at its final size with these bounds (every tab request and result,
-- the IDs, an error at MAX_TEXT_JSON), measures it and refuses a run over MAX_RUN.
-- The frames of one write. As a parameter, the JSON text of a value is encoded once more: a '"' or
-- a '\' becomes 2 bytes, '<' becomes 7, so a value of at most MAX_RUN is at most 2 * MAX_RUN as a
-- parameter: at most 3 chunks. The largest transaction is admission (engine.admit): it reads the
-- run key, the start form and the counter (3 calls), writes the start form (its fingerprint and
-- its request, each at most 3 chunks), the run key, the counter and the run (at most 3 chunks):
-- at most 15 hub.sql calls between hub.sql.begin and the commit, and no other hub call. The hub
-- ends a transaction 5 s after its last call or 10 s after its start (LazyRex docs/sql.md). The
-- count bounds the calls, not their time: on a slow host the commit can fail (tx_expired), and
-- then nothing is committed (tests/sql_runs.lua refuses the commit to check that state).
local MAX_TEXT, MAX_ID, MAX_KEY, MAX_RUN_ID = 512, 128, 200, 32
local MAX_TEXT_JSON = 2 * MAX_TEXT + 2
local MAX_RUN = 61 * 1024
M.MAX_TEXT, M.MAX_TEXT_JSON, M.MAX_ID, M.MAX_KEY, M.MAX_RUN = MAX_TEXT, MAX_TEXT_JSON, MAX_ID, MAX_KEY, MAX_RUN
local function json_size(v) return #rex.json.encode(v) end
-- bounded replaces control characters with spaces and cuts a text on a UTF-8 character boundary,
-- with "…" at the end, so that it is at most MAX_TEXT bytes and its JSON at most MAX_TEXT_JSON
-- bytes (the ellipsis included in both).
local function bounded(text)
  text = tostring(text):gsub('%c', ' ')
  if #text <= MAX_TEXT and json_size(text) <= MAX_TEXT_JSON then return text end
  -- boundary moves a cut back over at most 3 continuation bytes (a valid character has no more).
  local function boundary(cut)
    local n = cut
    while n > 0 and cut - n < 3 and text:byte(n + 1) and text:byte(n + 1) >= 0x80 and text:byte(n + 1) < 0xC0 do n = n - 1 end
    return n
  end
  local cut = boundary(math.min(#text, MAX_TEXT - 3))
  while cut > 0 and json_size(text:sub(1, cut) .. '…') > MAX_TEXT_JSON do cut = boundary(cut - 1) end
  return text:sub(1, cut) .. '…'
end
M.bounded = bounded
-- SCAN_LIMIT: the rows in one page of the engine's run reads and of the marker cleanup.
local SCAN_LIMIT = 50
M.SCAN_LIMIT = SCAN_LIMIT
local function message(err)
  return type(err) == 'table' and (err.message or err.code or 'Request failed') or tostring(err)
end
local function valid_id(v) return type(v) == 'string' and #v >= 1 and #v <= MAX_ID and not v:find('[^%w%.:_%-]') end
M.valid_id = valid_id
local short_id = valid_id
local function count_leaves(node)
  if node.direction then return count_leaves(node.before) + count_leaves(node.after) end
  return 1
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

-- Retention (decision "Templates retention keeps 200 finished starts and frees their keys after 30
-- days", 2026-10-20; tests/templates-run.md, "Retention"). A run is eligible when it is finished,
-- owes no revoke, and is a user run or has a recorded grant (an agent run without one is the
-- evidence that find_grant uses). A run is retired when at least KEEP newer eligible runs exist.
-- opts.retirable can postpone a retirement (the plugin waits for a Start form's switch decision:
-- switch_settled); the step is tried again RETRY_DELAY seconds later, so retirement is eventual.
-- Newer runs get higher IDs and only older runs are retired, so the rank of a run only grows.
-- Retirement replaces the run key with a marker {run_id, expired_at, form_rev} and deletes the run
-- and its switch row, in one transaction that reads them again. The start form stays: Templates
-- writes it only when it is absent or its marker expired, so form_rev, its rev at retirement,
-- still names it later. A form rev is unique: meta 'rev' gives each new revision once
-- (templates_sql.lua, next_rev). A marker expires MARKER_TTL seconds after
-- expired_at: then the key is free again (checked on each use), and a cleanup deletes the marker
-- and its start form if that form still has rev form_rev.
local KEEP, MARKER_TTL, RETRY_DELAY, CLEANUP_EVERY = 200, 30 * 86400, 60, 86400
M.KEEP, M.MARKER_TTL, M.RETRY_DELAY, M.CLEANUP_EVERY = KEEP, MARKER_TTL, RETRY_DELAY, CLEANUP_EVERY
local function eligible(run) return finished(run) and not owes_revoke(run) and (not by_agent(run) or run.grant_id ~= nil) end
-- older compares decimal run IDs (by length, then as text): exact beyond 2^53.
local function older(a, b) return #a < #b or #a == #b and a < b end
-- expired: a run-key marker whose MARKER_TTL is over at time now.
function M.expired(marker, now)
  return type(marker) == 'table' and type(marker.expired_at) == 'number' and now - marker.expired_at >= MARKER_TTL
end
-- form_expired: a start form (a start_forms row) that counts as absent: its run key's marker (a
-- run_keys row) has expired and names this form (form_rev).
function M.form_expired(form, marker, now)
  return type(form) == 'table' and type(marker) == 'table' and M.expired(marker, now)
    and marker.form_rev == form.rev
end
-- switch_settled: a user start into a new session has a Start form that switches the app once
-- (templates.lua, switch_app). Its run is retirable only when the switch decision is final (a
-- switches row that is not 'attempted'), or when the form is at least bound seconds old (the form
-- was closed, or the decision was lost). Other starts never switch.
local FINAL = {done = true, refused = true, unknown = true}
function M.switch_settled(run, form, switch, now, bound)
  if by_agent(run) or not run.request.new_session_name then return true end
  if type(switch) == 'table' and FINAL[switch.state] then return true end
  return now - form.at >= bound
end

function M.new(opts)
  local hub = assert(opts.hub, 'hub is required')
  -- data: the SQL rows (templates_sql.lua). transaction: app.db.transaction. No hub call other
  -- than hub.sql runs inside a transaction: each step reads, calls the hub, then writes in a new
  -- transaction that checks what the read gave (a run's ver, a key's state).
  local data = assert(opts.data, 'data is required')
  local transaction = assert(opts.transaction, 'transaction is required')
  local start_tab = assert(opts.start_tab, 'start_tab is required')
  local resolve_root = assert(opts.resolve_root, 'resolve_root is required')
  local resolve_dir = assert(opts.resolve_dir, 'resolve_dir is required')
  local engine, queue, queued, checked = {}, {}, {}, {}
  -- The scan state is in a table: closures write it and pcall catches errors around them. After a
  -- caught error, a closure's write to a captured local can be lost (LazyRex docs/rex-protocol.md,
  -- "Rex Lua runtime"): no closure writes a captured local where a pcall can catch.
  local scan = {active = false, after = nil}
  local now, after = opts.now or os.time, opts.after or rex.after
  -- kept: the eligible run IDs (a set) and their count; ready after the first full scan.
  -- maint: maintenance steps {kind, id | key, expect, due}, the run IDs being retired, the cleanup
  -- scan, and one timer (gen supersedes an older callback: rex.after has no cancel).
  local kept = {ids = {}, n = 0, ready = false}
  local maint = {items = {}, retiring = {}, cleanup = nil, cleanup_due = nil, gen = 0, timer_due = nil}
  -- note bounds an error text for the run record; the full text goes to the plugin log.
  local function note(id, text)
    text = tostring(text)
    local cut = bounded(text)
    if cut ~= text and opts.log then pcall(opts.log, 'run ' .. tostring(id) .. ': ' .. text) end
    return cut
  end
  local function enqueue(id)
    if not queued[id] then queue[#queue + 1], queued[id] = id, true end
  end
  -- read returns run id and its ver, or nil.
  local function read(id)
    local r = data.get_run(id)
    if r then return r.value, r.ver end
  end
  -- put_op saves the caller's operation {key, fingerprint, result} in the caller's transaction. An
  -- operation that another call saved first gives op_exists: the caller answers from it, after its
  -- fingerprint check (templates.lua, prior_op).
  local function put_op(op)
    if data.get_op(op.key) then fail('op_exists', 'The operation is already saved') end
    data.put_op(op.key, op.fingerprint, op.result)
  end
  -- schedule makes the pump run at time due (opts.wake), unless a timer for an earlier time waits.
  local function schedule(due)
    if maint.timer_due and maint.timer_due <= due then return end
    maint.gen, maint.timer_due = maint.gen + 1, due
    local gen = maint.gen
    after(math.max(0, due - now()), function()
      if maint.gen ~= gen then return end -- superseded by an earlier timer
      maint.timer_due = nil
      if opts.wake then opts.wake() end
    end)
  end
  local function queue_step(item)
    maint.items[#maint.items + 1] = item
    schedule(item.due)
  end
  -- trim queues the oldest eligible runs over KEEP for retirement.
  local function trim()
    if not kept.ready or kept.n <= KEEP then return end
    local ids = {}
    for id in pairs(kept.ids) do ids[#ids + 1] = id end
    table.sort(ids, older)
    for i = 1, kept.n - KEEP do
      local id = ids[i]
      if not maint.retiring[id] then
        maint.retiring[id] = true
        queue_step({kind = 'retire', id = id, due = now()})
      end
    end
  end
  local function keep(run)
    if eligible(run) and not kept.ids[run.id] then
      kept.ids[run.id], kept.n = true, kept.n + 1
      trim()
    end
  end
  local function drop(id)
    if kept.ids[id] then kept.ids[id], kept.n = nil, kept.n - 1 end
    maint.retiring[id] = nil
  end
  -- committed runs after a run change commits: the retention index. (The views render again by
  -- the hub's read tracking: the panel reads the runs table.)
  local function committed(run)
    keep(run)
  end
  -- update writes run over the ver of its read, in the caller's transaction. A run that another
  -- step changed since that read (for example a dismiss during a tab start) gives conflict, and
  -- nothing is written.
  local function update(run, ver)
    if not data.update_run(run, ver) then fail('conflict', 'Template run changed; retry with the same key') end
  end
  -- save is the write of advance: advance reads the run, calls the hub (a revoke, find_grant,
  -- hub.session.ensure, a tab start), then writes over the ver of that read.
  local function save(run, ver)
    transaction(function() update(run, ver) end)
    committed(run)
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

  -- prepare validates a new run's request and compiles its tabs (admit and measure). It returns the
  -- resolved root and the compiled tabs.
  local function prepare(request)
    if (request.session_id ~= nil) == (request.new_session_name ~= nil) then fail('invalid_input', 'Choose one existing or new session') end
    if request.by ~= nil then text(request.by, 'by') end
    if request.session_id ~= nil and not valid_id(request.session_id) then fail('invalid_input', 'Invalid session ID') end
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
    return root, tabs
  end
  -- build returns the new run record of request with run ID id (the record that admit writes).
  local function build(request, root, tabs, id)
    local run = {id=id, request=copy(request), root=root, tabs=tabs, next_tab=1,
      status='queued', results={}, session_key='templates/' .. id .. '/session'}
    -- An agent's run waits for its grant (engine.authorize) before it dispatches anything.
    if by_agent(run) then run.status = 'authorizing' end
    if request.session_id then run.session_id = request.session_id end
    for i, tab in ipairs(tabs) do tab.key = 'templates/' .. id .. '/tab/' .. tostring(i) end
    return run
  end
  -- final_size returns the encoded size of run at its final size: every tab request and result,
  -- the IDs at MAX_ID and the errors at MAX_TEXT ("Admission" above).
  local function final_size(run)
    local request, tabs = run.request, run.tabs
    local final, id_max, text_max = copy(run), string.rep('x', MAX_ID), string.rep('"', MAX_TEXT)
    final.session_id, final.status, final.error = request.session_id or id_max, 'dismissed', text_max
    final.dismissed_from, final.grant_id, final.grant_revoked, final.next_tab = 'authorizing', id_max, true, #tabs + 1
    for i, tab in ipairs(final.tabs) do
      tab.request = {key = tab.key, session = final.session_id, title = tab.title, layout = copy(tab.layout),
        placement = copy(request.placement), grant_id = id_max}
      local blocks = {}
      for b = 1, count_leaves(tab.layout) do blocks[b] = id_max end
      final.results[i] = {status = 'unknown', window_id = id_max, block_ids = blocks, error = text_max}
    end
    return json_size(final)
  end

  -- check_form checks, in the admission transaction, that the start form of key is still the one
  -- that the caller read: form.expect is that row (absent: false), compared by rev and
  -- fingerprint. Then it writes form.write (a new form) if the caller has one.
  local function check_form(key, form)
    local cur = data.get_form(key)
    local e = form.expect
    if e then
      if not cur or cur.rev ~= e.rev or cur.fingerprint ~= e.fingerprint then
        fail('conflict', 'This start is being submitted twice; retry with the same key')
      end
    elseif cur then
      fail('conflict', 'This start is being submitted twice; retry with the same key')
    end
    if form.write then data.put_form(key, form.write.fingerprint, form.write.request, form.write.at) end
  end
  -- same_key: the run key row now is the one that admission read (both absent, or the same row).
  local function same_key(a, b)
    if a == nil or b == nil then return a == b end
    return a.run_id == b.run_id and a.expired_at == b.expired_at and a.form_rev == b.form_rev
  end
  -- Repeated admission uses the original request before checking today's directories or template.
  -- The frozen requests survive a changed profile, template, cwd, or plugin process. form
  -- (templates.lua start_core): the start form {expect, write}; its check and its write commit in
  -- the admission transaction. Every run has its start form from its admission.
  function engine.admit(request, form)
    assert(type(form) == 'table', 'admit needs the start form')
    fields(request, {key=true, template=true, root=true, session_id=true, new_session_name=true, placement=true, by=true}, 'run request')
    text(request.key, 'key')
    local key = request.key
    local read_key = data.get_run_key(key)
    local existing = read_key
    if existing and existing.expired_at ~= nil then
      -- A retired run's marker: the key is used until the marker expires, then it is free (the
      -- new run replaces the marker).
      if not M.expired(existing, now()) then
        fail('expired', 'This start finished and its record was removed. Use a new key.')
      end
      existing = nil
    end
    if existing then
      local run = engine.get(existing.run_id)
      if not same(run.request, request) then fail('operation_conflict', 'This key has different content') end
      if form.write then transaction(function() check_form(key, form) end) end
      if not finished(run) then enqueue(run.id) end
      return run
    end
    -- prepare checks the directories (hub calls): before the transaction.
    local root, tabs = prepare(request)
    local run = transaction(function()
      if not same_key(data.get_run_key(key), read_key) then
        fail('conflict', 'This start is being submitted twice; retry with the same key')
      end
      check_form(key, form)
      -- Decimal addition keeps operation IDs exact beyond Lua's integer precision.
      local digits, carry = tostring(data.get_counter() or '0'), 1
      local id = ''
      for i = #digits, 1, -1 do
        local n = tonumber(digits:sub(i, i)) + carry
        id, carry = tostring(n % 10) .. id, math.floor(n / 10)
      end
      if carry == 1 then id = '1' .. id end
      if #id > MAX_RUN_ID then fail('unavailable', 'The run counter is full') end
      local r = build(request, root, tabs, id)
      -- Refuse a run that cannot be written at its final size: it would stop at its first update
      -- with a session made and no tab (observed in the lab, tests/limits.lua). The size is of the
      -- compiled tabs that the transaction writes, with the actual run ID.
      local size = final_size(r)
      if size > MAX_RUN then
        fail('invalid_input', string.format('The template is too large to start: its start record needs about %d KiB, and the limit is %d KiB',
          math.ceil(size / 1024), math.floor(MAX_RUN / 1024)))
      end
      data.put_run_key(key, id)
      data.set_counter(id)
      data.insert_run(r)
      return r
    end)
    enqueue(run.id)
    return copy(run)
  end

  -- measure returns the final-record size (final_size) of a new run of request with a run ID of
  -- MAX_RUN_ID digits, after admit's validation and compile. It reads no row and writes
  -- nothing. The save check uses it (templates.lua, save_core).
  function engine.measure(request)
    fields(request, {key=true, template=true, root=true, session_id=true, new_session_name=true, placement=true, by=true}, 'run request')
    text(request.key, 'key')
    local root, tabs = prepare(request)
    return final_size(build(request, root, tabs, string.rep('9', MAX_RUN_ID)))
  end

  function engine.get(id)
    text(id, 'run id')
    local run = read(id)
    if not run then fail('not_found', 'Template run not found') end
    return copy(run)
  end

  -- Dismiss stops only this run's remaining orchestration. A sent Rex request can still finish.
  -- Keep its requests and results for inspection; never stop, close, or recreate its resources.
  -- op (optional) is the caller's operation record {key, fingerprint, result}: it commits in the
  -- same transaction as the dismissed state, so a lost reply cannot split them. The read and the
  -- write are in that transaction with no hub call between: no ver check is needed.
  function engine.dismiss(id, op)
    text(id, 'run id')
    local t = transaction(function()
      local r, ver = read(id)
      if not r then fail('not_found', 'Template run not found') end
      if r.status == 'dismissed' then
        if op then put_op(op) end
        return {run = r, changed = false}
      end
      if r.status ~= 'pending' and r.status ~= 'unknown' and r.status ~= 'blocked' and r.status ~= 'authorizing' then
        fail('conflict', 'Only a pending, unknown, blocked or unauthorized run can be dismissed')
      end
      r.dismissed_from, r.status = r.status, 'dismissed'
      update(r, ver)
      if op then put_op(op) end
      return {run = r, changed = true}
    end)
    local run = t.run
    if t.changed then
      committed(run)
      if owes_revoke(run) or owes_grant_check(run) then enqueue(id) end
    end
    return copy(run)
  end

  -- authorize records the grant of an agent's run and lets it dispatch. A run that is no longer
  -- waiting (finished, dismissed, or already authorized) keeps its state. One transaction: read
  -- and write with no hub call between.
  function engine.authorize(id, grant_id)
    text(id, 'run id')
    text(grant_id, 'grant id')
    if not short_id(grant_id) then fail('invalid_input', 'Invalid grant ID') end
    local t = transaction(function()
      local r, ver = read(id)
      if not r then fail('not_found', 'Template run not found') end
      if r.grant_id ~= nil then
        if r.grant_id ~= grant_id then fail('conflict', 'The run has another grant') end
        return {run = r, changed = false}
      end
      r.grant_id = grant_id
      if r.status == 'authorizing' then r.status, r.error = 'queued', nil end
      update(r, ver)
      return {run = r, changed = true}
    end)
    local run = t.run
    if t.changed then
      committed(run)
      enqueue(id)
    end
    return copy(run)
  end

  -- retry queues a blocked, pending or unknown run again. The queued state and the operation
  -- (op = {key, fingerprint, result}; result.woken is set here) commit in one transaction, so a
  -- lost reply cannot lose the retry: the run is queued durably, and any wake dispatches it.
  function engine.retry(id, op)
    text(id, 'run id')
    local t = transaction(function()
      local r, ver = read(id)
      if not r then fail('not_found', 'Template run not found') end
      local w = r.status == 'blocked' or r.status == 'pending' or r.status == 'unknown'
      op.result = {run_id = id, woken = w}
      if w then
        r.status, r.error = 'queued', nil
        update(r, ver)
      end
      put_op(op)
      return {run = r, woken = w}
    end)
    if t.woken then
      committed(t.run)
      enqueue(id)
    end
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
    local run, ver = read(id)
    if not run then return end
    if owes_revoke(run) then
      -- The final state is committed: give the grant back. A failure retries at the next wake.
      if opts.revoke and pcall(opts.revoke, run.grant_id) then
        run.grant_revoked = true
        save(run, ver)
      end
      return
    end
    if owes_grant_check(run) then
      -- Never dispatches: it only records the grant, then revokes it.
      if checked[id] then return end
      local grant_id = opts.find_grant and opts.find_grant(copy(run))
      checked[id] = true
      if short_id(grant_id) then
        run.grant_id = grant_id
        save(run, ver)
        enqueue(id)
      end
      return
    end
    if finished(run) then return end
    if by_agent(run) and run.grant_id == nil then
      -- No grant yet (a crash between admission and the grant): find it, or wait for a retry of
      -- the start in a new agent call. Nothing dispatches before it.
      local grant_id = opts.find_grant and opts.find_grant(copy(run))
      if short_id(grant_id) then engine.authorize(id, grant_id) return end
      local msg = 'The start is not authorized yet; retry the start with the same key'
      if run.error ~= msg then run.error = msg; save(run, ver) end
      return
    end
    if not run.session_id then
      -- The ensure key and name were committed at admission. Never replace an unknown session.
      local ok, result = pcall(hub, 'hub.session.ensure', {key=run.session_key, name=run.request.new_session_name})
      if not ok then
        run.status, run.error = 'blocked', note(id, message(result))
        save(run, ver)
        return
      end
      if not short_id(result.session_id) then
        run.status, run.error = 'blocked', 'Invalid session result; outcome unknown'
        save(run, ver)
        return
      end
      run.session_id, run.status, run.error = result.session_id, 'queued', nil
      save(run, ver)
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
      save(run, ver)
      enqueue(id)
      return
    end
    local ok, result = pcall(start_tab, copy(tab.request))
    -- Only bounded fields of a result are stored (see the size bounds).
    local stored
    if ok and type(result) == 'table' then
      stored = {status = result.status, block_ids = {}}
      if result.window_id ~= nil then stored.window_id = result.window_id end
      if result.error ~= nil then stored.error = note(id, result.error) end
      local blocks = type(result.block_ids) == 'table' and result.block_ids or {}
      if #blocks > count_leaves(tab.layout) or (stored.window_id ~= nil and not short_id(stored.window_id)) then stored = nil
      else
        for i, b in ipairs(blocks) do
          if not short_id(b) then stored = nil break end
          stored.block_ids[i] = b
        end
      end
    end
    if not ok then
      run.status, run.error = 'blocked', note(id, message(result))
    elseif not stored then
      run.status, run.error = 'blocked', 'Invalid tab start result; outcome unknown'
    elseif stored.status == 'open' then
      if stored.window_id == nil then
        run.status, run.error = 'blocked', 'Tab start has no window ID; outcome unknown'
      else
        run.results[run.next_tab] = stored
        run.next_tab = run.next_tab + 1
        run.error = nil
        run.status = run.next_tab > #run.tabs and 'open' or 'queued'
      end
    elseif stored.status == 'pending' or stored.status == 'unknown' then
      run.status, run.error = stored.status, stored.error
      run.results[run.next_tab] = stored
    elseif stored.status == 'failed' or stored.status == 'closed' then
      run.status, run.error = stored.status, stored.error or 'Tab start stopped'
      run.results[run.next_tab] = stored
    else
      run.status, run.error = 'blocked', 'Unrecognized tab start status; outcome unknown'
    end
    save(run, ver)
    if run.status == 'queued' or owes_revoke(run) then enqueue(id) end
  end

  -- Maintenance steps (one per tick, after the run work). A failed step waits RETRY_DELAY seconds
  -- (a timer wakes the pump); it never blocks the run queue.
  -- retire reads the run, its run key, start form and switch in one transaction (no hub call),
  -- and retires the run only if it is still eligible and its key names it (not a marker). Else it
  -- leaves the run (a lost commit reply: it is gone). It replaces the key with the marker
  -- {run_id, expired_at, form_rev = the form's rev} and deletes the run and the switch row.
  local function retire(id)
    local result = transaction(function()
      local run = read(id)
      if type(run) ~= 'table' or not eligible(run) then return 'drop' end
      local key = run.request.key
      local k = data.get_run_key(key)
      if not k or k.run_id ~= id or k.expired_at ~= nil then return 'drop' end
      local f, s = data.get_form(key), data.get_switch(key)
      -- opts.retirable (the plugin: switch_settled) can postpone the step: it is tried again later.
      if opts.retirable and not opts.retirable(copy(run), copy(f), s and copy(s), now()) then return 'later' end
      data.delete_run(id)
      data.mark_run_key(key, id, now(), f.rev)
      if s then data.delete_switch(key) end
      return 'retired'
    end)
    if result == 'later' then return 'later' end
    drop(id)
  end
  -- expire deletes a marker that still is the one the cleanup page saw (same run_id, expired_at
  -- and form_rev) and has expired, and its start form only if that has rev form_rev. One
  -- transaction.
  local function expire(key, expect)
    transaction(function()
      local k = data.get_run_key(key)
      if not k or k.run_id ~= expect.run_id or k.expired_at ~= expect.expired_at or k.form_rev ~= expect.form_rev
        or not M.expired(k, now()) then return end
      data.delete_run_key(key)
      local f = data.get_form(key)
      if f and f.rev == k.form_rev then data.delete_form(key) end
    end)
  end
  -- cleanup_page reads one page of expired markers (in key order) and queues each one.
  local function cleanup_page()
    local c = maint.cleanup
    local rows = data.expired_markers(c.after, now() - MARKER_TTL, SCAN_LIMIT)
    for _, row in ipairs(rows) do
      queue_step({kind = 'expire', key = row.key, expect = {run_id = row.run_id, expired_at = row.expired_at, form_rev = row.form_rev}, due = now()})
      c.after = row.key
    end
    if #rows < SCAN_LIMIT then
      maint.cleanup = nil
      maint.cleanup_due = now() + CLEANUP_EVERY
      schedule(maint.cleanup_due)
    end
  end
  local function step(item)
    if item.kind == 'retire' then return retire(item.id) else expire(item.key, item.expect) end
  end
  -- due_step returns the index of the first step that is due, or nil.
  local function due_step(t)
    for i, item in ipairs(maint.items) do if item.due <= t then return i end end
  end
  local function maintain()
    local t = now()
    if not maint.cleanup and maint.cleanup_due and maint.cleanup_due <= t then
      maint.cleanup, maint.cleanup_due = {after = nil}, nil
    end
    local i = due_step(t)
    if i then
      local item = table.remove(maint.items, i)
      local ok, result = pcall(step, item)
      if ok and result == 'later' then
        item.due = t + RETRY_DELAY
        queue_step(item)
      elseif not ok then
        item.due = t + RETRY_DELAY
        queue_step(item)
        if opts.log then pcall(opts.log, 'maintenance ' .. item.kind .. ' ' .. tostring(item.id or item.key) .. ': ' .. message(result)) end
      end
      return
    end
    if maint.cleanup then
      local ok, err = pcall(cleanup_page)
      if not ok then
        maint.cleanup, maint.cleanup_due = nil, t + RETRY_DELAY
        schedule(maint.cleanup_due)
        if opts.log then pcall(opts.log, 'maintenance cleanup: ' .. message(err)) end
      end
      return
    end
  end
  -- arm makes a timer wake the pump for the earliest step that is not due at time t. Each tick
  -- calls it, also a tick that read a scan page (no maintenance step): a timer that fired for an
  -- earlier step superseded the later step's timer.
  local function arm(t)
    local due = maint.cleanup_due and maint.cleanup_due > t and maint.cleanup_due or nil
    for _, item in ipairs(maint.items) do if item.due > t and (not due or item.due < due) then due = item.due end end
    if due then schedule(due) end
  end
  local function maintenance_due()
    local t = now()
    return due_step(t) ~= nil or maint.cleanup ~= nil or (maint.cleanup_due ~= nil and maint.cleanup_due <= t)
  end
  engine.maintenance = function() return {kept = kept.n, ready = kept.ready, steps = #maint.items, cleanup = maint.cleanup ~= nil} end

  -- Wake reads one page of run summaries per tick (data.run_summaries, in run ID order). Pending
  -- and unknown runs wait for a worker event, reconnect or explicit retry. A read failure also
  -- waits: no immediate retry loop.
  function engine.wake()
    if not scan.active then scan.active, scan.after = true, nil end
  end
  engine.resume = engine.wake
  function engine.tick()
    local ok, err = pcall(function()
      if scan.active then
        scan.paged = true
        local page = data.run_summaries(scan.after, SCAN_LIMIT)
        local more = #page == SCAN_LIMIT
        for _, run in ipairs(page) do
          scan.after = run.id
          if (not finished(run) or owes_revoke(run) or owes_grant_check(run)) then enqueue(run.id) end
          if type(run) == 'table' and type(run.id) == 'string' and eligible(run) and not kept.ids[run.id] then
            kept.ids[run.id], kept.n = true, kept.n + 1
          end
        end
        scan.active = more
        if not more and not kept.ready then
          -- The first full scan: the index is complete. The first cleanup starts now.
          kept.ready, maint.cleanup_due = true, now()
          trim()
        elseif not more then
          trim()
        end
        return
      end
      local id = table.remove(queue, 1)
      if id then queued[id] = nil; advance(id) end
    end)
    if not ok then scan.active, scan.after = false, nil end
    -- One maintenance step per tick, after the run work; its errors stay in maintain. A tick that
    -- read a scan page does none: one store scan per tick at most.
    if scan.paged then scan.paged = false else pcall(maintain) end
    pcall(arm, now())
    return scan.active or #queue > 0 or maintenance_due(), not ok and err or nil
  end
  return engine
end
return M
