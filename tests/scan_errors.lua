-- Scan errors of the import (templates_sql.lua, S.import; templates_run.lua, "Store scans"). Only
-- the import scans hub.store. A fault answers a hub.store.scan of the plugin with an error: a
-- reply_too_large asks for the same page with half the limit; another error stops the start, and
-- the hub starts the plugin again at once (its next start continues the import).

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')

-- The encoding that the scan limits depend on: rex do writes "<" as < (6 bytes), as the hub's
-- reply does (observed on Rex 0.0.1792158932-g88fd41).
test('rex do encodes "<" as 6 bytes', function()
  expect(rex.json.encode('<')).to_be('"\\u003c"')
end)

-- seed writes a template and a run to the store, as an older version left them.
local function seed(name, id)
  write({{key = 'template/' .. W.hex(name), value = {v = 1, name = name, saved_by = 'user', tabs = {}}},
    {key = 'run/' .. id, value = {id = id, status = 'open', next_tab = 1, root = '/', results = {}, tabs = {},
      session_key = 'templates/' .. id .. '/session', request = {key = 'start/' .. W.part(name), root = '/',
      template = {v = 1, name = name, tabs = {}}, new_session_name = name}}}})
end

test('a scan page that is too large is asked for again with a smaller limit; the import completes', function()
  agent('alice')
  W.imported()
  seed('se-small', '7001')
  W.reset_import()
  local faults = {}
  for n = 1, 3 do
    faults[n] = fault({point = 'action', action = 'hub.store.scan', when = 'before', mode = 'fail', fail_code = 'reply_too_large', nth = n})
  end
  W.restart()
  W.imported()
  for n = 1, 3 do expect(fault_fired(faults[n])).to_be(true) end
  expect(W.trow('template/' .. W.hex('se-small')).value.name).to_be('se-small')
  expect(W.rec('run/7001').value.status).to_be('open')
end)

test('another scan error stops the start; the next start completes the import', function()
  agent('alice')
  W.imported()
  seed('se-fail', '7002')
  W.reset_import()
  local f = fault({point = 'action', action = 'hub.store.scan', when = 'before', mode = 'fail', fail_code = 'unavailable', nth = 1})
  W.restart()
  W.imported()
  expect(fault_fired(f)).to_be(true)
  expect(W.trow('template/' .. W.hex('se-fail')).value.name).to_be('se-fail')
  expect(W.rec('run/7002').value.status).to_be('open')
end)
