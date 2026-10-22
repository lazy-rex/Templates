-- SQL storage of Templates (LazyRex docs/sql.md). This file owns the schema and the row writers.
-- Templates keeps every record in SQL and makes no hub.store call.
--
-- Request size. A value is a JSON text, and a hub.sql request carries it as a string parameter, so
-- it is JSON-encoded twice: each "\uXXXX" escape (<, >, & and others) gets one more byte, and each
-- '"' two more (observed on Rex 0.0.1792158932-g88fd41: a 60 023-byte record of "&" gave a 70 271-byte
-- request). A request is at most 64 KiB (the SDK refuses a larger one, and nothing is sent). So a
-- writer measures the complete frame (client ID, action, SQL text, every parameter, the token,
-- the envelope) and writes a long value in chunks: an INSERT with the first chunk, then
-- "value = value || ?" for each next chunk, all in the caller's transaction. A chunk is cut on a
-- UTF-8 boundary. The chunk budget is internal: the record limits (MAX_RUN, the save check) stay.
local M = {}
local FRAME_MAX = 60 * 1024 -- under the SDK limit of 64 KiB, with room for its own fields
local TOKEN = string.rep('0', 32) -- a hub.sql token is 32 hex digits (hub sqlsvc.go, newToken)
M.FRAME_MAX = FRAME_MAX

local SCHEMA = {
  'CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)',
  -- hex: the hex of the name. rev: the revision that a held reference (agent replace, the Delete
  -- confirmation route) names.
  'CREATE TABLE templates (hex TEXT PRIMARY KEY, rev INTEGER NOT NULL, value TEXT NOT NULL)',
  -- The saved replies of Templates operations (key: "<kind>/..."; Templates keeps its own replay:
  -- {store = false}, coordinator decision, 2026-10-22).
  'CREATE TABLE ops (key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL)',
}
-- The start records. A run ID is decimal text of up to 32 digits (MAX_RUN_ID, over an SQLite
-- INTEGER): runs sort by length(id), then id. status is a copy of value.status: each writer sets
-- both in one statement. ver counts the writes of a run: a write after a hub call checks the ver
-- that its read gave. A run_keys row with expired_at NULL names its live run; else it is the marker
-- of a retired run, and form_rev is the rev of its start form. A start_forms row is the frozen
-- request of a start: rev is a revision of meta 'rev', and at is its submit time. A switches row
-- is the app switch decision of a Start form ('attempted', then 'done', 'refused' or 'unknown').
local SCHEMA_2 = {
  'CREATE TABLE runs (id TEXT PRIMARY KEY, ver INTEGER NOT NULL, status TEXT NOT NULL, value TEXT NOT NULL)',
  'CREATE INDEX runs_order ON runs (length(id), id)',
  'CREATE INDEX runs_status ON runs (status)',
  'CREATE TABLE run_keys (key TEXT PRIMARY KEY, run_id TEXT NOT NULL, expired_at INTEGER, form_rev TEXT)',
  'CREATE INDEX run_keys_expired ON run_keys (expired_at) WHERE expired_at IS NOT NULL',
  'CREATE TABLE start_forms (key TEXT PRIMARY KEY, rev TEXT NOT NULL, fingerprint TEXT NOT NULL, request TEXT NOT NULL, at INTEGER)',
  'CREATE TABLE switches (start_key TEXT PRIMARY KEY, state TEXT NOT NULL, code TEXT, message TEXT)',
}

function M.new(app)
  local db = app.db
  local S = {}
  db.migrate({
    function(d) for _, sql in ipairs(SCHEMA) do d.exec(sql) end end,
    function(d) for _, sql in ipairs(SCHEMA_2) do d.exec(sql) end end,
  })

  local function fail(code, message) error({code = code, message = message}, 0) end
  local function meta(k) local row = db.first('SELECT v FROM meta WHERE k = ?', k); return row and row.v end
  local function set_meta(k, v) db.exec('INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT (k) DO UPDATE SET v = excluded.v', k, v) end
  local function frame(sql, params)
    return #rex.json.encode({client_id = app.hub_id, action = 'hub.sql.exec', timeout_ms = 10000,
      args = {sql = sql, params = params, tx = TOKEN}})
  end
  -- take returns the longest prefix of text from pos that fits the frame of sql with params, where
  -- the prefix takes the place of params[slot]. It never cuts a UTF-8 character.
  local function take(sql, params, slot, text, pos)
    params[slot] = ''
    local room = FRAME_MAX - frame(sql, params)
    if room <= 0 then fail('too_large', 'A Templates row has metadata over the request limit') end
    local lo, hi = 0, #text - pos + 1
    local function fits(n) return #rex.json.encode(text:sub(pos, pos + n - 1)) - 2 <= room end
    if fits(hi) then return hi end
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if fits(mid) then lo = mid else hi = mid - 1 end
    end
    -- Move the cut back to a character boundary (a continuation byte is 0x80 to 0xBF).
    local n = lo
    while n > 0 do
      local b = text:byte(pos + n)
      if not b or b < 0x80 or b >= 0xC0 then break end
      n = n - 1
    end
    if n == 0 then fail('too_large', 'A Templates row has metadata over the request limit') end
    return n
  end
  -- write_text writes text into one column of one row: first (its parameters are head, the value,
  -- then tail) with the first chunk, then append ("... || ?" with the chunk first, then where) for
  -- the rest. It runs in the caller's transaction, so no partial value is ever committed. It
  -- returns the changes of first: with 0 (a guard did not match) it writes no chunk after it.
  local function write_text(first, head, append, where, text, tail)
    tail = tail or {}
    local params = {}
    for i, v in ipairs(head) do params[i] = v end
    local slot = #head + 1
    for i, v in ipairs(tail) do params[slot + i] = v end
    local n = take(first, params, slot, text, 1)
    params[slot] = text:sub(1, n)
    local changes = db.exec(first, unpack(params, 1, slot + #tail)).changes
    if changes == 0 then return 0 end
    local pos = n + 1
    while pos <= #text do
      local p = {''}
      for i, v in ipairs(where) do p[i + 1] = v end
      local m = take(append, p, 1, text, pos)
      p[1] = text:sub(pos, pos + m - 1)
      db.exec(append, unpack(p, 1, #where + 1))
      pos = pos + m
    end
    return changes
  end

  -- next_rev returns a new revision of meta 'rev'. The first call on a new database gives 1.
  function S.next_rev()
    local r = db.exec("INSERT INTO meta (k, v) VALUES ('rev', '1') ON CONFLICT (k) DO UPDATE SET v = CAST(CAST(v AS INTEGER) + 1 AS TEXT) RETURNING v")
    return tostring(r.rows[1].v)
  end
  -- put_template writes the template row hx with rev and value (a Lua value; it is always encoded,
  -- also a string).
  function S.put_template(hx, rev, value)
    local text = rex.json.encode(value)
    write_text('INSERT INTO templates (hex, rev, value) VALUES (?, ?, ?) ON CONFLICT (hex) DO UPDATE SET rev = excluded.rev, value = excluded.value',
      {hx, app.int(rev)}, 'UPDATE templates SET value = value || ? WHERE hex = ?', {hx}, text)
  end
  function S.delete_template(hx) db.exec('DELETE FROM templates WHERE hex = ?', hx) end
  -- get_template returns {rev, value} of the row hx (rev as decimal text), or nil.
  function S.get_template(hx)
    local row = db.first('SELECT CAST(rev AS TEXT) AS rev, value FROM templates WHERE hex = ?', hx)
    if row then return {rev = row.rev, value = rex.json.decode(row.value)} end
  end
  -- put_op saves an operation reply (result: a Lua value; it is always encoded, also a string).
  function S.put_op(key, fingerprint, result)
    local text = rex.json.encode(result)
    write_text('INSERT INTO ops (key, fingerprint, result) VALUES (?, ?, ?) ON CONFLICT (key) DO UPDATE SET fingerprint = excluded.fingerprint, result = excluded.result',
      {key, fingerprint}, 'UPDATE ops SET result = result || ? WHERE key = ?', {key}, text)
  end
  -- get_op returns {fingerprint, result} of an operation, or nil.
  function S.get_op(key)
    local row = db.first('SELECT fingerprint, result FROM ops WHERE key = ?', key)
    if row then return {fingerprint = row.fingerprint, result = rex.json.decode(row.result)} end
  end

  -- Runs. get_run returns {ver, value} of run id, or nil.
  function S.get_run(id)
    local row = db.first('SELECT ver, value FROM runs WHERE id = ?', id)
    if row then return {ver = row.ver, value = rex.json.decode(row.value)} end
  end
  -- insert_run writes a new run (ver 1). The caller checked that id is free in its transaction.
  function S.insert_run(run)
    write_text('INSERT INTO runs (id, ver, status, value) VALUES (?, 1, ?, ?)', {run.id, run.status},
      'UPDATE runs SET value = value || ? WHERE id = ?', {run.id}, rex.json.encode(run))
  end
  -- update_run writes run over version ver. It returns false, and writes nothing, when the row has
  -- another version or is gone.
  function S.update_run(run, ver)
    return write_text('UPDATE runs SET ver = ver + 1, status = ?, value = ? WHERE id = ? AND ver = ?', {run.status},
      'UPDATE runs SET value = value || ? WHERE id = ?', {run.id}, rex.json.encode(run), {run.id, app.int(ver)}) > 0
  end
  function S.delete_run(id) db.exec('DELETE FROM runs WHERE id = ?', id) end
  -- run_summaries returns up to limit runs after run ID after (nil: from the first), in ID order,
  -- as {id, status, request = {by}, grant_id, grant_revoked}: the fields of the engine's rules
  -- (finished, owes_revoke, owes_grant_check, eligible). The -> operator keeps each JSON type. The
  -- page is read with db.each.
  function S.run_summaries(after, limit)
    local rows = {}
    db.each("SELECT id, status, value -> '$.request.by' AS by, value -> '$.grant_id' AS grant_id,"
      .. " value -> '$.grant_revoked' AS grant_revoked FROM runs"
      .. ' WHERE ?1 IS NULL OR length(id) > length(?1) OR (length(id) = length(?1) AND id > ?1)'
      .. ' ORDER BY length(id), id LIMIT ?2', after, limit, function(r) rows[#rows + 1] = r end)
    local out = {}
    for i, r in ipairs(rows) do
      local function json(v) if v ~= nil then return rex.json.decode(v) end end
      out[i] = {id = r.id, status = r.status, request = {by = json(r.by)}, grant_id = json(r.grant_id), grant_revoked = json(r.grant_revoked)}
    end
    return out
  end
  -- each_run calls fn(run) for the runs, newest first. opts: statuses (a list) with exclude (the
  -- runs not in it), before (a run ID: only older runs), limit.
  function S.each_run(opts, fn)
    local where, params = {}, {}
    if opts.statuses then
      local marks = {}
      for i, s in ipairs(opts.statuses) do marks[i], params[#params + 1] = '?', s end
      where[#where + 1] = 'status ' .. (opts.exclude and 'NOT IN' or 'IN') .. ' (' .. table.concat(marks, ', ') .. ')'
    end
    if opts.before then
      params[#params + 1], params[#params + 2], params[#params + 3] = opts.before, opts.before, opts.before
      where[#where + 1] = '(length(id) < length(?) OR (length(id) = length(?) AND id < ?))'
    end
    local sql = 'SELECT value FROM runs' .. (#where > 0 and ' WHERE ' .. table.concat(where, ' AND ') or '')
      .. ' ORDER BY length(id) DESC, id DESC'
    if opts.limit then sql, params[#params + 1] = sql .. ' LIMIT ?', opts.limit end
    params[#params + 1] = function(row) fn(rex.json.decode(row.value)) end
    return db.each(sql, unpack(params, 1, #params))
  end
  -- count_runs returns the number of runs with a status in statuses, and the number of all runs.
  function S.count_runs(statuses)
    local marks = {}
    for i in ipairs(statuses) do marks[i] = '?' end
    local row = db.first('SELECT count(*) AS n, coalesce(sum(status IN (' .. table.concat(marks, ', ') .. ')), 0) AS m FROM runs',
      unpack(statuses, 1, #statuses))
    return tonumber(row.m), tonumber(row.n)
  end
  -- The run counter: the last run ID as decimal text, or nil.
  function S.get_counter() return meta('run-counter') end
  function S.set_counter(id) set_meta('run-counter', id) end

  -- Run keys. get_run_key returns {run_id, expired_at, form_rev} of key, or nil.
  function S.get_run_key(key)
    return db.first('SELECT run_id, expired_at, form_rev FROM run_keys WHERE key = ?', key)
  end
  -- put_run_key makes key name the live run run_id (it replaces an expired marker).
  function S.put_run_key(key, run_id)
    db.exec('INSERT INTO run_keys (key, run_id) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET run_id = excluded.run_id,'
      .. ' expired_at = NULL, form_rev = NULL', key, run_id)
  end
  -- mark_run_key replaces the live key with the marker of its retired run.
  function S.mark_run_key(key, run_id, expired_at, form_rev)
    db.exec('UPDATE run_keys SET run_id = ?, expired_at = ?, form_rev = ? WHERE key = ?', run_id, app.int(expired_at), form_rev, key)
  end
  function S.delete_run_key(key) db.exec('DELETE FROM run_keys WHERE key = ?', key) end
  -- expired_markers returns up to limit markers with expired_at at most cutoff, after key after
  -- (nil: from the first), in key order, as {key, run_id, expired_at, form_rev}. A key can have
  -- about 2 KB, so the page is read with db.each.
  function S.expired_markers(after, cutoff, limit)
    local out = {}
    db.each('SELECT key, run_id, expired_at, form_rev FROM run_keys WHERE expired_at IS NOT NULL AND expired_at <= ?'
      .. ' AND (? IS NULL OR key > ?) ORDER BY key LIMIT ?', app.int(cutoff), after, after, limit,
      function(row) out[#out + 1] = row end)
    return out
  end

  -- Start forms. get_form returns {rev, fingerprint, request, at} of key, or nil.
  function S.get_form(key)
    local row = db.first('SELECT rev, fingerprint, request, at FROM start_forms WHERE key = ?', key)
    if row then return {rev = row.rev, fingerprint = row.fingerprint, request = rex.json.decode(row.request), at = row.at} end
  end
  -- put_form writes the form of key with a new revision (it replaces a form that the caller found
  -- free) and returns the revision.
  function S.put_form(key, fingerprint, request, at)
    local rev = S.next_rev()
    write_text("INSERT INTO start_forms (key, rev, fingerprint, request, at) VALUES (?, ?, ?, '', ?) ON CONFLICT (key) DO UPDATE"
      .. " SET rev = excluded.rev, fingerprint = excluded.fingerprint, request = '', at = excluded.at", {key, rev},
      'UPDATE start_forms SET fingerprint = fingerprint || ? WHERE key = ?', {key}, fingerprint, {app.int(at)})
    write_text('UPDATE start_forms SET request = ? WHERE key = ?', {},
      'UPDATE start_forms SET request = request || ? WHERE key = ?', {key}, rex.json.encode(request), {key})
    return rev
  end
  function S.delete_form(key) db.exec('DELETE FROM start_forms WHERE key = ?', key) end

  -- Switches. get_switch returns {state, code, message} of start_key, or nil.
  function S.get_switch(start_key)
    return db.first('SELECT state, code, message FROM switches WHERE start_key = ?', start_key)
  end
  -- insert_switch writes the first state of start_key. The caller found no row in its transaction.
  function S.insert_switch(start_key, v)
    db.exec('INSERT INTO switches (start_key, state, code, message) VALUES (?, ?, ?, ?)', start_key, v.state, v.code, v.message)
  end
  -- settle_switch changes an 'attempted' row to v. It returns false when the row has another state
  -- (or is gone): a decision is final.
  function S.settle_switch(start_key, v)
    return db.exec("UPDATE switches SET state = ?, code = ?, message = ? WHERE start_key = ? AND state = 'attempted'",
      v.state, v.code, v.message, start_key).changes > 0
  end
  function S.delete_switch(start_key) db.exec('DELETE FROM switches WHERE start_key = ?', start_key) end
  return S
end
return M
