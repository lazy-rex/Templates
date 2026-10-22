-- SQL storage of Templates (docs/sdk-port.md, "Stage 2"; LazyRex docs/sql.md). This file owns the
-- schema, the row writers and the one-time import from hub.store. Slice 1 moves the templates and
-- the operations of save and delete; the other records stay in hub.store until their slice.
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
  -- hex: the hex of the name (the old store key without "template/"). rev: the revision that a
  -- held reference (agent replace, the Delete confirmation route) names.
  'CREATE TABLE templates (hex TEXT PRIMARY KEY, rev INTEGER NOT NULL, value TEXT NOT NULL)',
  -- The saved replies of Templates operations (key: "<kind>/..."; Templates keeps its own replay:
  -- {store = false}, coordinator decision, 2026-10-22).
  'CREATE TABLE ops (key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL)',
}
-- The operation kinds that slice 1 keeps in SQL. The other kinds stay in hub.store.
M.SQL_KINDS = {save = true, delete = true}
function M.kind_in_sql(key) return M.SQL_KINDS[key:match('^(%a+)/')] == true end

function M.new(app)
  local db = app.db
  local S = {}
  db.migrate({function(d) for _, sql in ipairs(SCHEMA) do d.exec(sql) end end})

  local function fail(code, message) error({code = code, message = message}, 0) end
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
  -- write_text writes text into one column of one row: insert (its last parameter is the value)
  -- with the first chunk, then append ("... || ?" with the chunk first, then where) for the rest.
  -- It runs in the caller's transaction, so no partial value is ever committed.
  local function write_text(insert, head, append, where, text)
    local params = {}
    for i, v in ipairs(head) do params[i] = v end
    local n = take(insert, params, #head + 1, text, 1)
    params[#head + 1] = text:sub(1, n)
    db.exec(insert, unpack(params, 1, #head + 1))
    local pos = n + 1
    while pos <= #text do
      local p = {''}
      for i, v in ipairs(where) do p[i + 1] = v end
      local m = take(append, p, 1, text, pos)
      p[1] = text:sub(pos, pos + m - 1)
      db.exec(append, unpack(p, 1, #where + 1))
      pos = pos + m
    end
  end

  -- next_rev returns a new revision, above every revision that hub.store gave before the import.
  function S.next_rev()
    local r = db.exec("UPDATE meta SET v = CAST(CAST(v AS INTEGER) + 1 AS TEXT) WHERE k = 'rev' RETURNING v")
    local row = r.rows and r.rows[1]
    if not row then fail('unavailable', 'The Templates revision counter is missing: the import did not run') end
    return tostring(row.v)
  end
  -- put_template writes the template row hx with rev and value (a Lua value or a JSON text).
  function S.put_template(hx, rev, value)
    local text = type(value) == 'string' and value or rex.json.encode(value)
    write_text('INSERT INTO templates (hex, rev, value) VALUES (?, ?, ?) ON CONFLICT (hex) DO UPDATE SET rev = excluded.rev, value = excluded.value',
      {hx, app.int(rev)}, 'UPDATE templates SET value = value || ? WHERE hex = ?', {hx}, text)
  end
  function S.delete_template(hx) db.exec('DELETE FROM templates WHERE hex = ?', hx) end
  -- get_template returns {rev, value} of the row hx (rev as decimal text), or nil.
  function S.get_template(hx)
    local row = db.first('SELECT CAST(rev AS TEXT) AS rev, value FROM templates WHERE hex = ?', hx)
    if row then return {rev = row.rev, value = rex.json.decode(row.value)} end
  end
  -- put_op saves an operation reply (result: a Lua value or a JSON text).
  function S.put_op(key, fingerprint, result)
    local text = type(result) == 'string' and result or rex.json.encode(result)
    write_text('INSERT INTO ops (key, fingerprint, result) VALUES (?, ?, ?) ON CONFLICT (key) DO UPDATE SET fingerprint = excluded.fingerprint, result = excluded.result',
      {key, fingerprint}, 'UPDATE ops SET result = result || ? WHERE key = ?', {key}, text)
  end
  -- get_op returns {fingerprint, result} of an operation, or nil.
  function S.get_op(key)
    local row = db.first('SELECT fingerprint, result FROM ops WHERE key = ?', key)
    if row then return {fingerprint = row.fingerprint, result = rex.json.decode(row.result)} end
  end

  -- Import (once, at start, after the registration and before the plugin serves: the SDK runs the
  -- start code in its registration callback, and Rex Lua runs one handler at a time). Each record
  -- commits in its own short transaction with the cursor of its prefix, so a crash or a lost
  -- commit reply continues at the next record (a write again is the same row). An error stops
  -- the start: the SDK ends the process, and the hub starts it again. The old store records stay.
  local function meta(k) local row = db.first('SELECT v FROM meta WHERE k = ?', k); return row and row.v end
  local function set_meta(k, v) db.exec('INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT (k) DO UPDATE SET v = excluded.v', k, v) end
  function S.import(opts)
    if meta('import') == 'done' then return end
    -- The revision floor: a store write gives a revision above every revision the store gave, so
    -- a held revision of an old record never names a new row.
    if not meta('rev') then
      local key = 'sql-import'
      local r = app.hub('hub.store.batch', {ops = {{key = key, value = {at = os.time()}}}})
      local floor = r.revs and r.revs[key]
      if type(floor) ~= 'string' or not floor:match('^%d+$') then fail('internal', 'The store gave no revision for the import marker') end
      db.transaction(function() if not meta('rev') then set_meta('rev', floor) end end)
    end
    -- Templates: every record under template/, also one that Templates did not write.
    local after, limit = meta('import/template'), opts.scan_limit
    while meta('import/template-done') == nil do
      local args = {prefix = 'template/', limit = limit}
      if after then args.after = after end
      local ok, page = pcall(app.hub, 'hub.store.scan', args)
      if not ok then
        limit = opts.smaller(limit, page)
        if not limit then error(page, 0) end
      else
        local keys = {}
        for k in pairs(page.records or {}) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
          local record = page.records[k]
          db.transaction(function()
            S.put_template(k:sub(#'template/' + 1), record.rev, record.value)
            set_meta('import/template', k)
          end)
          after = k
        end
        if not page.next then db.transaction(function() set_meta('import/template-done', '1') end) end
      end
    end
    -- Operations of the kinds that this slice keeps in SQL.
    local cursor = meta('import/ops')
    while meta('import/ops-done') == nil do
      local args = {limit = 100}
      if cursor then args.after = cursor end
      local page = app.hub('hub.store.ops_scan', args)
      for _, op in ipairs(page.ops or {}) do
        db.transaction(function()
          if M.kind_in_sql(op.key) then S.put_op(op.key, op.fingerprint, op.result) end
          set_meta('import/ops', op.key)
        end)
        cursor = op.key
      end
      if not page.next then db.transaction(function() set_meta('import/ops-done', '1') end) end
    end
    db.transaction(function() set_meta('import', 'done') end)
  end
  return S
end
return M
