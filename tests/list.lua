-- templates.list and templates.get stay under the 64 KiB reply bound of a plugin (LazyRex
-- docs/rex-protocol.md, "Rex Lua runtime": a client.reply over the bound never arrives).
-- templates.list pages summaries: at most limit templates and at most 40 KB with next_after
-- (LIST_BUDGET in templates.lua). templates.get returns one template, at most 60 KiB (GET_BUDGET).
-- Tests in this file share one hub, and the order matters: a test that pages to the end of the
-- store runs before the tests that write records with a later name or a blocking key.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')
local BUDGET = 40 * 1024

local function tpl(name, title_len, saved_by)
  return {v = 1, name = name, saved_by = saved_by or 'user', tabs = {{title = string.rep('<', title_len or 1), layout = {launch = {shell = true}, dir = '.'}}}}
end
-- put writes a template with a tab title of title_len "<" (6 bytes each when encoded).
local function put(name, title_len, saved_by)
  write({{key = 'template/' .. W.hex(name), value = tpl(name, title_len, saved_by)}})
end
-- pages reads every page of templates.list with this limit, from after, and checks the size of
-- each page with its next_after. It returns the names in reply order and the pages.
local function pages(a, limit, after)
  local names, list = {}, {}
  repeat
    local page = a:call('templates.list', {limit = limit, after = after})
    expect(#rex.json.encode(page) <= BUDGET).to_be(true)
    list[#list + 1] = page
    for _, t in ipairs(page.templates) do
      expect(type(t.tabs)).to_be('number')
      names[#names + 1] = t.name
    end
    after = page.next_after
  until after == nil
  return names, list
end
local function refused(a, action, args)
  local ok, err = pcall(a.call, a, action, args)
  expect(ok).to_be(false)
  expect(err.code == 'invalid_input' or err.code == 'bad_request').to_be(true)
end
local function size(v) return #rex.json.encode(v) end

test('templates.list arrives when the full templates are over 64 KiB', function()
  local a = agent('alice')
  -- Two templates of about 36 KB each (encoded): the full list is about 72 KB.
  put('a-big-1', 6000)
  put('a-big-2', 6000)
  local names = pages(a)
  expect(names[1]).to_be('a-big-1')
  expect(names[2]).to_be('a-big-2')
end)

test('templates.get returns one full template, and not_found for a missing one', function()
  local a = agent('alice')
  local t = a:call('templates.get', {template = 'a-big-1'}).template
  expect(t.name).to_be('a-big-1')
  expect(t.saved_by).to_be('user')
  expect(t.tabs[1].title).to_be(string.rep('<', 6000))
  expect(t.v).to_be(nil)
  expect_error(function() a:call('templates.get', {template = 'no-such-template'}) end, 'not_found')
end)

-- The largest test write is a little under 64 KiB (10 700 "<" is refused as request_too_large).
-- A reply just under GET_BUDGET arrives at the hub; a template near the write limit gives too_large.
-- The Lua test client takes replies of at most 48 KiB (hub testmode.go, testReplyLimit). So the hub
-- refuses the larger reply to the test client, and its error gives the size that it received from
-- the plugin: the reply arrived (a plugin reply over 64 KiB never arrives: a timeout).
test('templates.get: a reply just under 60 KiB arrives; a larger one gives too_large', function()
  local a = agent('alice')
  put('a-just', 10150)
  local err = expect_error(function() a:call('templates.get', {template = 'a-just'}) end, 'too_large')
  local got = tonumber(tostring(err.message):match('the reply is (%d+) bytes, the limit for a Lua test client'))
  expect(got ~= nil and got > 60000 and got <= 60 * 1024).to_be(true)
  put('a-huge', 10500)
  err = expect_error(function() a:call('templates.get', {template = 'a-huge'}) end, 'too_large')
  expect(tostring(err.message)).to_match('is too large to read')
  expect(size(err) < 1024).to_be(true)
end)

test('templates.list pages every template once, in byte order (limit and default)', function()
  local a = agent('alice')
  for i = 1, 130 do put(string.format('p-%03d', i)) end
  local names, list = pages(a, nil, 'p-')
  local want = {}
  for i = 1, 130 do want[i] = string.format('p-%03d', i) end
  expect(names).to_equal(want)
  expect(#list[1].templates).to_be(50)
  names = pages(a, 7, 'p-')
  expect(names).to_equal(want)
end)

-- Names of 4 characters and 66 "<" (about 440 bytes per summary): 100 summaries are over 40 KB.
-- The row that does not fit is not processed: next_after is the row before it, and the next page starts with it.
test('templates.list stops a page at the byte budget, and the next page starts with the row that did not fit', function()
  local a = agent('alice')
  local want = {}
  for i = 1, 100 do
    want[i] = 'q' .. string.format('%03d', i) .. string.rep('<', 66)
    put(want[i])
  end
  local page = a:call('templates.list', {after = 'q', limit = 100})
  local n = #page.templates
  expect(n < 100).to_be(true)
  expect(size(page) <= BUDGET).to_be(true)
  expect(page.next_after).to_be(want[n])
  local second = a:call('templates.list', {after = page.next_after, limit = 100})
  expect(second.templates[1].name).to_be(want[n + 1])
  local names = pages(a, 100, 'q')
  expect(names).to_equal(want)
end)

test('templates.list accepts a removed name as cursor, and gives an empty page after the last name', function()
  local a = agent('alice')
  write({{key = 'template/' .. W.hex('p-050'), delete = true}})
  local page = a:call('templates.list', {after = 'p-049', limit = 2})
  expect(page.templates[1].name).to_be('p-051')
  page = a:call('templates.list', {after = 'p-050', limit = 1})
  expect(page.templates[1].name).to_be('p-051')
  page = a:call('templates.list', {after = string.rep('~', 10)})
  expect(#page.templates).to_be(0)
  expect(page.next_after).to_be(nil)
end)

test('templates.list and templates.get refuse bad arguments', function()
  local a = agent('alice')
  refused(a, 'templates.list', {limit = 0})
  refused(a, 'templates.list', {limit = 101})
  refused(a, 'templates.list', {limit = 1.5})
  refused(a, 'templates.list', {limit = 'ten'})
  refused(a, 'templates.list', {after = 12})
  -- An after of 1366 "<" is 8198 bytes encoded: over 8192.
  refused(a, 'templates.list', {after = string.rep('<', 1366)})
  refused(a, 'templates.list', {after = string.rep('a', 8191)})
  refused(a, 'templates.list', {other = 1})
  refused(a, 'templates.get', {})
  refused(a, 'templates.get', {template = ''})
  refused(a, 'templates.get', {template = 'x', other = 1})
  -- The largest after is accepted.
  expect(#a:call('templates.list', {after = string.rep('a', 8190), limit = 1}).templates).to_be(1)
end)

-- A key name whose value.name differs (another writer): the key's name is the identity.
test('a record whose value.name differs from its key is listed and read by its key name', function()
  local a = agent('alice')
  write({{key = 'template/' .. W.hex('m-key'), value = tpl('m-other')}})
  local page = a:call('templates.list', {after = 'm', limit = 1})
  expect(page.templates[1].name).to_be('m-key')
  expect(a:call('templates.get', {template = 'm-key'}).template.name).to_be('m-key')
  expect_error(function() a:call('templates.get', {template = 'm-other'}) end, 'not_found')
end)

-- A foreign summary over 40 KB with a short name (a saved_by of 7000 "<"): the page refuses it,
-- names its cursor, and the next page skips it.
test('a summary over the budget gives too_large with its cursor, and the next page skips it', function()
  local a = agent('alice')
  put('s-big', 1, string.rep('<', 7000))
  put('s-next')
  local err = expect_error(function() a:call('templates.list', {after = 's', limit = 5}) end, 'too_large')
  expect(tostring(err.message)).to_match('set after to its name: s%-big$')
  expect(size(err) <= 9 * 1024).to_be(true)
  expect(a:call('templates.list', {after = 's-big', limit = 1}).templates[1].name).to_be('s-next')
end)

-- A blocking key: a valid row, then a key that is not cursorable, then a valid row. Page 1 ends
-- before it with next_after = the first row; page 2 starts at it and fails without a cursor.
local function blocked(a, first, blocking_key, blocking_value, last)
  put(first)
  write({{key = blocking_key, value = blocking_value}})
  put(last)
  local page = a:call('templates.list', {after = first:sub(1, 1), limit = 5})
  expect(#page.templates).to_be(1)
  expect(page.templates[1].name).to_be(first)
  expect(page.next_after).to_be(first)
  local err = expect_error(function() a:call('templates.list', {after = page.next_after, limit = 5}) end, 'too_large')
  expect(tostring(err.message)).to_match('No cursor skips it')
  expect(#tostring(err.message) <= 512).to_be(true)
  write({{key = blocking_key, delete = true}})
end
test('a foreign name between 8 KiB and 40 KiB encoded blocks the list without an invalid cursor', function()
  -- 1400 "<" is 8400 bytes encoded: not a cursor, but its summary fits 40 KB.
  local name = 'u-2' .. string.rep('<', 1400)
  blocked(agent('alice'), 'u-1', 'template/' .. W.hex(name), tpl(name), 'u-3')
end)
test('a record that is not a template under a long name blocks the list the same way', function()
  blocked(agent('alice'), 'v-1', 'template/' .. W.hex('v-2' .. string.rep('<', 1400)), 7, 'v-3')
end)
test('a key that is not hex blocks the list the same way (odd length; a non-hex character)', function()
  blocked(agent('alice'), 'w-1', 'template/' .. W.hex('w-2') .. '0', tpl('w-2'), 'w-3')
  blocked(agent('alice'), 'x-1', 'template/' .. W.hex('x-2') .. 'zz', tpl('x-2'), 'x-3')
end)
test('a record that is not a template is passed over, and its name can be the cursor', function()
  local a = agent('alice')
  put('y-1')
  write({{key = 'template/' .. W.hex('y-2'), value = 7}})
  put('y-3')
  local page = a:call('templates.list', {after = 'y', limit = 1})
  expect(page.templates[1].name).to_be('y-1')
  page = a:call('templates.list', {after = 'y-1', limit = 1})
  expect(page.templates[1].name).to_be('y-3')
end)

-- A name with control characters: listed; as next_after it is accepted again.
test('a name with control characters round-trips as a cursor', function()
  local a = agent('alice')
  local name = 'yz\1\2\n\t'
  put(name)
  put('yz~')
  local page = a:call('templates.list', {after = 'yz', limit = 1})
  expect(page.templates[1].name).to_be(name)
  expect(page.next_after).to_be(name)
  expect(a:call('templates.list', {after = page.next_after, limit = 1}).templates[1].name).to_be('yz~')
end)

-- 30 templates of about 36 KB each: a scan page of 50 records is over the hub reply guard
-- (1 047 552 bytes), so the scan halves; every name comes once, in byte order.
test('templates.list returns every name after the scan halves', function()
  local a = agent('alice')
  local want = {}
  for i = 1, 30 do
    want[i] = string.format('z-%02d', i)
    put(want[i], 6000)
  end
  expect((pages(a, 50, 'z'))).to_equal(want)
  expect((pages(a, 7, 'z'))).to_equal(want)
end)

-- The empty name (the key template/ alone): the first row of the store; after = '' skips it.
test('an empty name is listed first and round-trips as a cursor', function()
  local a = agent('alice')
  write({{key = 'template/', value = tpl('')}})
  local page = a:call('templates.list', {limit = 1})
  expect(page.templates[1].name).to_be('')
  expect(page.next_after).to_be('')
  expect(a:call('templates.list', {after = '', limit = 1}).templates[1].name).to_be('a-big-1')
end)

-- Names that JSON does not keep: the encoder replaces an invalid UTF-8 byte with U+FFFD, so such a
-- name as a cursor would sort before its key, and the list would repeat (the reviewer's probe:
-- template/ff and template/ffff). Such a key blocks the list. Valid multibyte names are cursors.
-- This test runs last: the keys template/ff... sort after every other name.
test('a name that is not valid UTF-8 blocks the list; a valid multibyte name round-trips', function()
  local a = agent('alice')
  local e1, e2, e3 = '\195\169-1', '\195\169-2\255', '\195\169-3' -- "é-1", "é-2" and the byte ff, "é-3"
  put(e1)
  write({{key = 'template/' .. W.hex(e2), value = tpl('foreign')}})
  put(e3)
  local page = a:call('templates.list', {after = '\195\169', limit = 5})
  expect(#page.templates).to_be(1)
  expect(page.templates[1].name).to_be(e1)
  expect(page.next_after).to_be(e1)
  local err = expect_error(function() a:call('templates.list', {after = e1, limit = 5}) end, 'too_large')
  expect(tostring(err.message)).to_match('No cursor skips it')
  expect(#tostring(err.message) <= 512).to_be(true)
  write({{key = 'template/' .. W.hex(e2), delete = true}})
  -- Valid multibyte names: each next_after is accepted again and moves on.
  page = a:call('templates.list', {after = '\195\169', limit = 1})
  expect(page.next_after).to_be(e1)
  expect(a:call('templates.list', {after = page.next_after, limit = 1}).templates[1].name).to_be(e3)
  -- The probe: template/ff and template/ffff after the last valid name.
  write({{key = 'template/ff', value = {name = 'foreign', tabs = {}, saved_by = 'user'}},
    {key = 'template/ffff', value = {name = 'foreign', tabs = {}, saved_by = 'user'}}})
  page = a:call('templates.list', {after = '\195\169', limit = 5})
  expect(#page.templates).to_be(2)
  expect(page.next_after).to_be(e3)
  expect_error(function() a:call('templates.list', {after = e3, limit = 1}) end, 'too_large')
  write({{key = 'template/ff', delete = true}, {key = 'template/ffff', delete = true}})
end)
