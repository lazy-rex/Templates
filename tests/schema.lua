-- The schema of a new database (templates_sql.lua). The expected objects are the schema of the
-- migration steps 1 and 2 that the 4.2 pin ships (3d93b39), written out here: a base step that
-- replaces those steps must make the same schema (LazyRex docs/plugin-sdk.md, "A base step").
-- Step 3 changes rows only, so the schema stays the same after it.

-- The schema objects of the steps 1 and 2, in the order of their statements.
local OLD = {
  {'table', 'meta', 'CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)'},
  {'table', 'templates', 'CREATE TABLE templates (hex TEXT PRIMARY KEY, rev INTEGER NOT NULL, value TEXT NOT NULL)'},
  {'table', 'ops', 'CREATE TABLE ops (key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL)'},
  {'table', 'runs', 'CREATE TABLE runs (id TEXT PRIMARY KEY, ver INTEGER NOT NULL, status TEXT NOT NULL, value TEXT NOT NULL)'},
  {'index', 'runs_order', 'CREATE INDEX runs_order ON runs (length(id), id)'},
  {'index', 'runs_status', 'CREATE INDEX runs_status ON runs (status)'},
  {'table', 'run_keys', 'CREATE TABLE run_keys (key TEXT PRIMARY KEY, run_id TEXT NOT NULL, expired_at INTEGER, form_rev TEXT)'},
  {'index', 'run_keys_expired', 'CREATE INDEX run_keys_expired ON run_keys (expired_at) WHERE expired_at IS NOT NULL'},
  {'table', 'start_forms', 'CREATE TABLE start_forms (key TEXT PRIMARY KEY, rev TEXT NOT NULL, fingerprint TEXT NOT NULL, request TEXT NOT NULL, at INTEGER)'},
  {'table', 'switches', 'CREATE TABLE switches (start_key TEXT PRIMARY KEY, state TEXT NOT NULL, code TEXT, message TEXT)'},
}

-- normal gives the SQL text with each run of white space as one space, and no space at the ends.
local function normal(s) return (s:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')) end

test('a new database has the schema of the steps 1 and 2, at version 3', function()
  agent('alice'):call('templates.list', {})
  -- The plugin's own objects only: not SQLite's (sqlite_*) or the hub's (lazyrex_*). An automatic
  -- index (a PRIMARY KEY) has no SQL text.
  local rows = sql("SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name NOT LIKE 'lazyrex\\_%' ESCAPE '\\' AND sql IS NOT NULL ORDER BY rowid")
  local got = {}
  for _, r in ipairs(rows) do got[#got + 1] = {r.type, r.name, normal(r.sql)} end
  expect(got).to_equal(OLD)
  expect(sql('PRAGMA user_version')[1].user_version).to_be(3)
end)
