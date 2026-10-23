-- A new database: the plugin starts with the schema and no data. The revision counter (meta 'rev')
-- starts at the first write (templates_sql.lua, next_rev), and a restart continues it. Tests in
-- this file run in order on one hub and one database.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')

local function rev() local r = sql("SELECT v FROM meta WHERE k = 'rev'")[1]; return r and r.v end
local tpl = {}

test('a new database has no revision; the first save gets revision 1', function()
  expect(rev()).to_be(nil)
  local alice = agent('alice')
  local s, root = W.workspace()
  W.capture(alice, s)
  expect(alice:call('templates.save', {name = 'fresh', root = root, session_id = s, key = 'fresh-save'})).to_equal({name = 'fresh'})
  expect(W.template(W.hex('fresh')).rev).to_be('1')
  expect(rev()).to_be('1')
  tpl.s, tpl.root = s, root
end)

test('a Start form on the new database starts the template; its form gets the next revision', function()
  local alice = agent('alice')
  local form = W.open('start_session', '/forms/start', tpl.s)
  local values = W.form_input(form:render(), 'start_session')
  values.template, values.session_id, values.root = 'fresh', '@new', tpl.root
  local op = form:action('start_session', 'submit', {values = values}, 'fresh-start')
  expect(op.status).to_be('succeeded')
  W.wait_run(alice, op.result.run_id, 'open')
  expect(W.form(W.start_key('fresh-start')).rev).to_be('2')
end)

test('after a hub restart the counter continues: it is not set again', function()
  local before = tonumber(rev())
  expect(before >= 2).to_be(true)
  hub:restart()
  local alice = agent('alice')
  local s, root = W.workspace()
  W.capture(alice, s)
  alice:call('templates.save', {name = 'fresh-2', root = root, session_id = s, key = 'fresh-save-2'})
  expect(tonumber(W.template(W.hex('fresh-2')).rev)).to_be(before + 1)
  expect(tonumber(rev())).to_be(before + 1)
end)


-- Schema step 3 deletes the import markers in meta ('import', 'import/...'). Other meta rows stay.
-- After this step, a rollback to a release with the import (59b40b5) imports again: this step
-- lands only after the 4.2 release is live (coordinator plan for 4.3).
test('a start of a database at version 2 deletes the import markers and keeps meta rev', function()
  local counter = rev()
  for _, k in ipairs({'import', 'import/template-done', 'import/floor-2', 'import/counter-done'}) do
    W.sql_write('INSERT INTO meta (k, v) VALUES (?, ?)', {k, k == 'import' and 'done' or '1'})
  end
  W.sql_write('PRAGMA user_version = 2') -- the live schema
  hub:restart()
  agent('alice'):call('templates.list', {})
  expect(sql("SELECT count(*) AS n FROM meta WHERE k = 'import' OR k LIKE 'import/%'")[1].n).to_be(0)
  expect(sql('PRAGMA user_version')[1].user_version).to_be(3)
  expect(rev()).to_be(counter)
end)
