-- Scan errors (templates_run.lua, "Store scans"). A fault answers a hub.store.scan of the plugin
-- with an error. The store is small, so a scan that tried again would pass and the agent call
-- would succeed. This file opens no view and starts no run: no other scan takes a fault.

-- quiet waits until the engine's first scan (at plugin start) is over.
local function quiet(a)
  a:call('templates.runs', {})
  rex.sleep(0.5)
end

-- The encoding that the scan limits depend on: rex do writes "<" as \u003c (6 bytes), as the hub's
-- reply does (observed on Rex 0.0.1792158932-g88fd41).
test('rex do encodes "<" as 6 bytes', function()
  expect(rex.json.encode('<')).to_be('"\\u003c"')
end)

test('a scan error other than reply_too_large is not retried', function()
  local alice = agent('alice')
  quiet(alice)
  local f = fault({point = 'action', action = 'hub.store.scan', when = 'before', mode = 'fail', fail_code = 'unavailable'})
  expect_error(function() alice:call('templates.runs', {}) end, 'unavailable')
  expect(fault_fired(f)).to_be(true)
  alice:call('templates.runs', {})
end)

test('a scan stops when a page of 1 is too large: limits 50, 25, 12, 6, 3 and 1', function()
  local alice = agent('alice')
  quiet(alice)
  local faults = {}
  for n = 1, 6 do
    faults[n] = fault({point = 'action', action = 'hub.store.scan', when = 'before', mode = 'fail', fail_code = 'reply_too_large', nth = n})
  end
  expect_error(function() alice:call('templates.runs', {}) end, 'reply_too_large')
  for n = 1, 6 do expect(fault_fired(faults[n])).to_be(true) end
  alice:call('templates.runs', {})
end)
