-- Agent outputs stay under the 64 KiB reply bound of a plugin (LazyRex docs/rex-protocol.md, "Rex
-- Lua runtime": a client.reply over the bound never arrives). templates.runs is paged: at most
-- limit runs and at most 40 KB (RUNS_BUDGET in templates.lua). Tests in this file share one hub.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')
local BUDGET = 40 * 1024

-- runs writes finished runs with the IDs from first to last, each with a root of root_len bytes
-- and an error of err_len bytes, in writes of at most 40 KB (a runner request is at most 64 KiB).
local function runs(first, last, root_len, err_len)
  local root = '/' .. string.rep('r', root_len - 1)
  local ops, size = {}, 0
  for i = first, last do
    local run = {id = tostring(i), status = 'open', next_tab = 2, root = root,
      tabs = {{key = 'templates/' .. i .. '/tab/1', title = 'x', layout = {shell = true, cwd = root}}},
      request = {key = 'out' .. i, root = root, new_session_name = 'out' .. i, template = {v = 1, name = 'out' .. i, tabs = {}}},
      results = {}, session_key = 'templates/' .. i .. '/session'}
    if err_len then run.error = string.rep('e', err_len) end
    local n = #rex.json.encode(run)
    if #ops > 0 and size + n > 40000 then W.twrite(ops); ops, size = {}, 0 end
    ops[#ops + 1], size = {key = 'run/' .. i, value = run}, size + n
  end
  if #ops > 0 then W.twrite(ops) end
end

-- pages reads every page of templates.runs with this limit and returns the IDs in reply order and
-- the size of each page in rows.
local function pages(a, limit)
  local ids, rows, before = {}, {}, nil
  repeat
    local args = {limit = limit}
    if before then args.before = before end
    local page = a:call('templates.runs', args)
    expect(#rex.json.encode(page) <= BUDGET).to_be(true)
    rows[#rows + 1] = #page.runs
    for _, r in ipairs(page.runs) do ids[#ids + 1] = r.id end
    before = page.next_before
  until not before
  return ids, rows
end
-- descending checks that ids is first, first - 1, ..., last: each ID once, newest first.
local function descending(ids, first, last)
  expect(#ids).to_be(first - last + 1)
  for i, id in ipairs(ids) do expect(id).to_be(tostring(first - i + 1)) end
end
-- refused checks that the hub (the export schema: bad_request) or the plugin (invalid_input)
-- refuses the arguments.
local function refused(a, args)
  local ok, err = pcall(a.call, a, 'templates.runs', args)
  expect(ok).to_be(false)
  expect(err.code == 'invalid_input' or err.code == 'bad_request').to_be(true)
end

test('templates.runs pages every run once, newest first (the row limit)', function()
  local a = agent('alice')
  runs(1001, 1300, 300)
  local ids, rows = pages(a)
  descending(ids, 1300, 1001)
  expect(#rows).to_be(6)
  for _, n in ipairs(rows) do expect(n).to_be(50) end
end)

test('templates.runs takes a limit', function()
  local a = agent('alice')
  local ids, rows = pages(a, 7)
  descending(ids, 1300, 1001)
  expect(#rows).to_be(43)
end)

-- Runs with a root of 900 bytes and an error of 1000 bytes (about 2 KB each): a page of 100 is
-- over the budget, so the page stops on the budget, with fewer rows than the limit.
test('templates.runs stops a page at the byte budget, before the row limit', function()
  local a = agent('alice')
  runs(5001, 5060, 900, 1000)
  local first = a:call('templates.runs', {limit = 100})
  expect(#first.runs < 60).to_be(true)
  expect(#rex.json.encode(first) <= BUDGET).to_be(true)
  expect(first.runs[1].id).to_be('5060')
  local ids, rows = pages(a, 100)
  expect(rows[1] < 60).to_be(true)
  local big = {}
  for i = 1, 60 do big[i] = ids[i] end
  descending(big, 5060, 5001)
  local rest = {}
  for i = 61, #ids do rest[#rest + 1] = ids[i] end
  descending(rest, 1300, 1001)
end)

test('templates.runs gives an empty page after the oldest run, and accepts a removed run as cursor', function()
  local a = agent('alice')
  local last = a:call('templates.runs', {before = '1001'})
  expect(#last.runs).to_be(0)
  expect(last.next_before).to_be(nil)
  W.twrite({{key = 'run/1250', delete = true}})
  local page = a:call('templates.runs', {before = '1250', limit = 3})
  expect(page.runs[1].id).to_be('1249')
  expect(page.next_before).to_be('1247')
end)

test('templates.runs refuses bad arguments', function()
  local a = agent('alice')
  refused(a, {limit = 0})
  refused(a, {limit = 101})
  refused(a, {limit = 1.5})
  refused(a, {limit = 'ten'})
  refused(a, {before = ''})
  refused(a, {before = 'x'})
  refused(a, {before = '0123'})
  refused(a, {before = string.rep('9', 33)})
  refused(a, {before = 12})
end)

-- A run from another writer whose view alone is over the budget: the page refuses it with an
-- explicit error that names the cursor to skip it.
test('a run view over the budget is refused explicitly, and the next page skips it', function()
  local a = agent('alice')
  -- The long root is only in run.root (the view shows it), so the record fits one write.
  W.twrite({{key = 'run/9000', value = {id = '9000', status = 'open', next_tab = 2, root = '/' .. string.rep('r', 45000),
    tabs = {{key = 'templates/9000/tab/1', title = 'x', layout = {shell = true, cwd = '/'}}},
    request = {key = 'out9000', root = '/', new_session_name = 'out9000', template = {v = 1, name = 'out9000', tabs = {}}},
    results = {}, session_key = 'templates/9000/session'}}})
  local err = expect_error(function() a:call('templates.runs', {}) end, 'too_large')
  expect(tostring(err.message)).to_match('before = "9000"')
  expect(a:call('templates.runs', {before = '9000', limit = 1}).runs[1].id).to_be('5060')
end)
