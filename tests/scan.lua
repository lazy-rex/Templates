-- Store scans of run and template records: a page of records must fit in one hub reply (about
-- 1 MiB), and a record can be up to 64 KiB. A scan asks for a page again with half the limit
-- after reply_too_large (templates_run.lua, "Store scans"). The records here are padded with "<":
-- rex do and the hub both encode it as \u003c (6 bytes), so 10 000 "<" are about 60 KB written
-- and in a reply. Tests in this file share one hub: each one uses its own record IDs and names.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')

-- big_runs writes finished runs with the IDs from first to last, each with pad "<" (6 * pad
-- bytes). One write per record: a runner request is at most 64 KiB.
local function big_runs(first, last, pad)
  local root = W.real(W.HOME)
  for i = first, last do
    write({{key = 'run/' .. i, value = {id = tostring(i), status = 'open', next_tab = 2, root = root,
      tabs = {{key = 'templates/' .. i .. '/tab/1', title = 'x', layout = {shell = true, cwd = root}}},
      request = {key = 'big' .. i, root = root, new_session_name = 'big' .. i, template = {v = 1, name = 'big' .. i, tabs = {}}},
      results = {}, session_key = 'templates/' .. i .. '/session', pad = string.rep('<', pad)}}})
  end
end
-- once checks that list has every ID from first to last exactly once (other IDs can be there too).
local function once(list, first, last)
  local seen = {}
  for _, id in ipairs(list) do
    local n = tonumber(id)
    if n and n >= first and n <= last then
      if seen[n] then error('ID ' .. id .. ' is listed twice') end
      seen[n] = true
    end
  end
  for n = first, last do if not seen[n] then error('ID ' .. n .. ' is missing') end end
end
local function run_ids(a)
  local ids = {}
  for _, r in ipairs(W.all_runs(a)) do ids[#ids + 1] = r.id end
  return ids
end

-- 18 runs of 60 KB in a reply: a page of 50 (1.08 MB) and of 25 are too large; pages of 12 pass.
test('the panel renders with more than 1 MiB of runs in the store', function()
  local s = W.workspace()
  big_runs(1001, 1018, 10000)
  local tree = W.panel(s):render()
  expect(#node(tree, 'runs').items).to_be(10)
  expect(node(tree, 'runs').items[1].id).to_be('1018')
end)

test('templates.runs lists every run once over more than 1 MiB of runs, on more than one page', function()
  big_runs(1101, 1118, 10000)
  once(run_ids(agent('alice')), 1101, 1118)
end)

-- 17 runs at the write bound (about 63 KB each): pages of 50 and 25 are too large, 12 fit.
test('runs at the 64 KiB write bound are all read', function()
  big_runs(1201, 1217, 10500)
  once(run_ids(agent('alice')), 1201, 1217)
end)

-- Templates are scanned the same way: the panel, the Start form and templates.list.
test('every template is listed once over more than 1 MiB of templates', function()
  local alice = agent('alice')
  local s = W.workspace()
  for i = 1, 18 do
    local name = string.format('big-template-%02d', i)
    W.twrite({{key = 'template/' .. W.hex(name), value = {v = 1, name = name, saved_by = 'user',
      tabs = {{title = 't', layout = {launch = {shell = true}, dir = '.'}}}, pad = string.rep('<', 10000)}}})
  end
  local names = {}
  for _, t in ipairs(alice:call('templates.list', {}).templates) do names[#names + 1] = t.name:match('^big%-template%-(%d+)$') end
  once(names, 1, 18)
  names = {}
  for _, item in ipairs(node(W.panel(s):render(), 'templates').items) do names[#names + 1] = item.label:match('^big%-template%-(%d+)$') end
  once(names, 1, 18)
  names = {}
  local start = W.open('start_session', '/forms/start', s)
  for _, o in ipairs(W.field(start:render(), 'start_session', 'template').options) do names[#names + 1] = o.value:match('^big%-template%-(%d+)$') end
  once(names, 1, 18)
end)

-- The engine scan after a restart: a queued user run sorts after 18 runs of about 60 KB each.
-- The run is read from the store, not with templates.runs (that is another scan).
test('a queued run behind more than 1 MiB of runs resumes after a hub restart', function()
  local root = W.real(W.HOME)
  big_runs(2001, 2018, 10000)
  write({{key = 'run/2019', value = {id = '2019', status = 'queued', next_tab = 1, root = root,
    tabs = {{key = 'templates/2019/tab/1', title = 'resumed', layout = {shell = true, cwd = root}}},
    request = {key = 'resume-2019', root = root, new_session_name = 'resumed', template = {v = 1, name = 'resumed', tabs = {}}},
    results = {}, session_key = 'templates/2019/session'}}})
  hub:restart()
  local run = wait('run 2019 open', function()
    local r = store('run/2019').value
    return r and r.status == 'open' and r or nil
  end, 30)
  local windows = rex.call('session.view', {session_id = run.session_id}).windows
  expect(#windows).to_be(1)
  expect(windows[1].label).to_be('resumed')
end)
