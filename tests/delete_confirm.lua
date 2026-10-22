-- The panel's template rows (tests/templates-run.md, "Panel delete"). A row opens the template menu
-- (/forms/template/<hex>): Start session… opens the Start form with that template
-- (/forms/start/<hex>), and Delete… opens the confirmation (/forms/delete/<hex>/<rev>). A
-- template's identity is the hex of its storage key. The confirmation deletes only the revision of
-- the choice. The renderer's Cancel quits its process (hub view/menu.go, cancelForm), so a test
-- closes the form pane (block.close) instead: that proves the hub's return to the panel, not a
-- keypress in the renderer.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')
local BUDGET = 48 * 1024
local function size(v) return #rex.json.encode(v) end
local function layout(title) return {{title = title, layout = {launch = {shell = true}, dir = '.'}}} end
local function put(key_name, value) W.put_template(W.hex(key_name), value) end
local function tpl(name, title) return {v = 1, name = name, saved_by = 'user', tabs = layout(title or 'one')} end
local function close_form(s)
  for _, b in ipairs(W.blocks(s)) do
    if tostring(b.label):sub(1, 13) == 'lazyrex-form:' then rex.call('block.close', {session_id = s, block_id = b.block_id}); return b.label end
  end
end
-- open_menu opens the template menu of hx from the panel in session s.
local function open_menu(s, hx, key)
  local p = W.panel(s)
  p:render()
  expect(p:action('templates', 'open', {item_id = hx}, key).status).to_be('succeeded')
  return user:view('/forms/template/' .. hx, nil, s)
end
-- open_confirm opens the confirmation of hx (from its menu) and returns it with the rev of the choice.
local function open_confirm(s, hx, key)
  local menu = open_menu(s, hx, key .. '-open')
  menu:render()
  local rev = W.template(hx).rev
  expect(menu:action('template_menu', 'delete', {item_id = 'delete'}, key .. '-menu').status).to_be('succeeded')
  local confirm = user:view('/forms/delete/' .. hx .. '/' .. rev, nil, s)
  return confirm, rev
end
local function submit(confirm, key) return confirm:action('confirm', 'submit', {values = {}}, key) end

test('the panel row does not delete: a delete action of the row is refused; the row opens the menu', function()
  local s = W.workspace()
  put('pd-old', tpl('pd-old'))
  local hx = W.hex('pd-old')
  local p = W.panel(s)
  local tree0 = p:render()
  -- One action (one Enter on the row) must not delete the template.
  local old = p:action('templates', 'delete', {item_id = 'pd-old'}, 'pd-old-delete')
  expect(W.template(hx).value).not_to_be(nil)
  expect(old.status).to_be('failed')
  local row = W.find(node(tree0, 'templates').items, 'id', hx)
  expect(row.action.name).to_be('open')
  expect(row.action.user_only).to_be('navigation')
  local menu = open_menu(s, hx, 'pd-old-open')
  local tree = menu:render()
  expect(tree.menu).to_be(true)
  expect(node(tree, 'summary').text).to_be('1 tab · saved by user')
  expect(#node(tree, 'template_menu').items).to_be(2)
  expect(node(tree, 'cancel').action.name).to_be('$cancel')
  close_form(s)
end)

test('Cancel in the confirmation keeps the template; the panel comes back', function()
  local s = W.workspace()
  put('pd-cancel', tpl('pd-cancel'))
  local hx = W.hex('pd-cancel')
  local confirm, rev = open_confirm(s, hx, 'pd-cancel')
  local tree = confirm:render()
  expect(node(tree, 'question').text).to_be('Delete the template pd-cancel (1 tab)? This cannot be undone.')
  expect(node(tree, 'confirm').submit_action.tool).to_be('templates.delete')
  expect(node(tree, 'cancel').action.name).to_be('$cancel')
  close_form(s)
  expect(user:view('/panels/templates', nil, s):render().title).to_be('Templates')
  expect(W.template(hx).rev).to_be(rev)
end)

test('Delete in the confirmation deletes; the form closes; the same operation key replays', function()
  local s = W.workspace()
  put('pd-yes', tpl('pd-yes'))
  local hx = W.hex('pd-yes')
  local confirm = open_confirm(s, hx, 'pd-yes')
  local op = submit(confirm, 'pd-yes-submit')
  expect(op.status).to_be('succeeded')
  expect(op.result).to_equal({close_form = true})
  expect(W.template(hx)).to_be(nil)
  expect(user:view('/panels/templates', nil, s):render().title).to_be('Templates')
  expect(operation('pd-yes-submit').result).to_equal({close_form = true})
end)

test('a template replaced before the submit is kept: conflict; the confirmation then has no submit', function()
  local s = W.workspace()
  put('pd-swap', tpl('pd-swap', 'old'))
  local hx = W.hex('pd-swap')
  local confirm = open_confirm(s, hx, 'pd-swap')
  confirm:render()
  -- Deleted and saved again under the same name (a direct write: no render of the open views).
  W.delete_template(hx)
  put('pd-swap', tpl('pd-swap', 'new'))
  local op = submit(confirm, 'pd-swap-submit')
  expect(op.status).to_be('failed')
  expect(op.error.code).to_be('conflict')
  expect(W.template(hx).value.tabs[1].title).to_be('new')
  local tree = confirm:render()
  expect(node(tree, 'confirm')).to_be(nil)
  expect(node(tree, 'changed').text).to_be('The template changed or was deleted after you chose Delete.')
  close_form(s)
end)

-- The revision guard of the confirmation route (templates.lua, delete_ui): another writer replaces
-- the template after the choice, before the submit.
test('a template replaced after the Delete choice is kept: conflict', function()
  local s = W.workspace()
  put('pd-race', tpl('pd-race', 'old'))
  local hx = W.hex('pd-race')
  local confirm = open_confirm(s, hx, 'pd-race')
  confirm:render()
  put('pd-race', tpl('pd-race', 'new'))
  local op = submit(confirm, 'pd-race-submit')
  expect(op.status).to_be('failed')
  expect(op.error.code).to_be('conflict')
  expect(W.template(hx).value.tabs[1].title).to_be('new')
  close_form(s)
end)

-- A lost commit reply: the delete and its operation committed, and the plugin got a transient error.
-- The hub runs the operation again; the saved result answers, and nothing is deleted twice.
test('a lost commit reply: the operation runs again and answers from the saved result', function()
  local s = W.workspace()
  put('pd-lost', tpl('pd-lost', 'old'))
  local hx = W.hex('pd-lost')
  local confirm = open_confirm(s, hx, 'pd-lost')
  confirm:render()
  local inj = inject({match = {sql_commit_writes = 'templates'}, fail = 'reply lost by the test', fail_code = 'unavailable', after = true})
  local op = submit(confirm, 'pd-lost-submit')
  expect(injection(inj).consumed).to_be(1)
  expect(op.status).to_be('succeeded')
  expect(op.result).to_equal({close_form = true})
  expect(W.template(hx)).to_be(nil)
end)

test('the same operation key on the route of another template is operation_conflict', function()
  local s = W.workspace()
  put('pd-k1', tpl('pd-k1'))
  put('pd-k2', tpl('pd-k2'))
  expect(submit(open_confirm(s, W.hex('pd-k1'), 'pd-k1'), 'pd-k-submit').status).to_be('succeeded')
  local second = open_confirm(s, W.hex('pd-k2'), 'pd-k2')
  expect_error(function() second:action('confirm', 'submit', {values = {}}, 'pd-k-submit') end, 'operation_conflict')
  expect(W.template(W.hex('pd-k2')).value).not_to_be(nil)
  close_form(s)
end)

-- Start session… selects the template of the key, also when value.name names another template.
test('Start session… starts the template of the row\'s key, not of its value.name', function()
  local s, root = W.workspace()
  put('pd-a', {v = 1, name = 'pd-b', tabs = layout('a-tab')})
  put('pd-b', {v = 1, name = 'pd-b', tabs = layout('b-tab')})
  local hx = W.hex('pd-a')
  local menu = open_menu(s, hx, 'pd-a-open')
  menu:render()
  expect(menu:action('template_menu', 'start', {item_id = 'start'}, 'pd-a-start').status).to_be('succeeded')
  local form = user:view('/forms/start/' .. hx, nil, s)
  local tree = form:render()
  local values = W.form_input(tree, 'start_session')
  expect(values.template).to_be('pd-a')
  expect(node(tree, 'start_session').fields[1].options[1].value).to_be('pd-a')
  values.root, values.session_id = root, '@new'
  local op = form:action('start_session', 'submit', {values = values}, 'pd-a-submit')
  expect(op.status).to_be('succeeded')
  expect(W.run(op.result.run_id).value.request.template.tabs[1].title).to_be('a-tab')
end)

-- A key whose name is not valid UTF-8 cannot be an option (its JSON round trip changes it). The
-- Start form says so and has no submit; Delete names the record by its hex and deletes it.
test('a foreign key that is not UTF-8: no Start submit; Delete deletes that record', function()
  local s = W.workspace()
  W.put_template('ff', {v = 1, name = 'foreign', tabs = layout('f')})
  local p = W.panel(s)
  expect(W.find(node(p:render(), 'templates').items, 'id', 'ff').label).to_be('foreign')
  local menu = open_menu(s, 'ff', 'pd-ff-first')
  menu:render()
  menu:action('template_menu', 'start', {item_id = 'start'}, 'pd-ff-start')
  local tree = user:view('/forms/start/ff', nil, s):render()
  expect(node(tree, 'start_session')).to_be(nil)
  expect(node(tree, 'no_template').text).to_be('The name of this template cannot be used in a form. Use templates.start.')
  close_form(s)
  local confirm = open_confirm(s, 'ff', 'pd-ff')
  expect(submit(confirm, 'pd-ff-submit').status).to_be('succeeded')
  expect(W.template('ff')).to_be(nil)
end)

-- The selected template stays selected when the other options do not all fit.
test('a selected template late in a large list stays selected; the others are cut', function()
  local s = W.workspace()
  for i = 1, 100 do
    local name = string.format('pd-big-%03d-', i) .. string.rep('x', 390)
    W.put_template(W.hex(name), tpl(name))
  end
  local last = 'pd-big-100-' .. string.rep('x', 390)
  local hx = W.hex(last)
  local menu = open_menu(s, hx, 'pd-big-open')
  menu:render()
  menu:action('template_menu', 'start', {item_id = 'start'}, 'pd-big-start')
  local tree = user:view('/forms/start/' .. hx, nil, s):render()
  expect(size(tree) <= BUDGET).to_be(true)
  local field = node(tree, 'start_session').fields[1]
  expect(field.value).to_be(last)
  expect(field.options[1].value).to_be(last)
  expect(node(tree, 'more_options').text).to_match('more templates')
  close_form(s)
  for i = 1, 100 do W.delete_template(W.hex(string.format('pd-big-%03d-', i) .. string.rep('x', 390))) end
end)

test('a template removed before its Start form or its menu opens: the form says so, with no submit', function()
  local s = W.workspace()
  put('pd-gone', tpl('pd-gone'))
  local hx = W.hex('pd-gone')
  local menu = open_menu(s, hx, 'pd-gone-open')
  menu:render()
  W.delete_template(hx)
  local missing = menu:render()
  expect(node(missing, 'missing').text).to_be('This template no longer exists.')
  expect(node(missing, 'template_menu')).to_be(nil)
  -- The menu's tree before the render still had Start session…: its form says the template is gone.
  put('pd-gone', tpl('pd-gone'))
  menu = open_menu(s, hx, 'pd-gone-open-2')
  menu:render()
  W.delete_template(hx)
  menu:action('template_menu', 'start', {item_id = 'start'}, 'pd-gone-start')
  local tree = user:view('/forms/start/' .. hx, nil, s):render()
  expect(node(tree, 'start_session')).to_be(nil)
  expect(node(tree, 'no_template').text).to_be('This template no longer exists.')
  close_form(s)
end)

-- A foreign record with a long name and a large saved_by: the texts are bounded, the views fit.
test('a long foreign name and a large saved_by: bounded texts within the view budget', function()
  local s = W.workspace()
  local name = string.rep('é', 150) -- 300 bytes: a route of about 640 bytes
  put(name, {v = 1, name = name, saved_by = string.rep('s', 50000), tabs = layout('t')})
  local hx = W.hex(name)
  local p = W.panel(s):render()
  expect(size(p) <= BUDGET).to_be(true)
  expect(#W.find(node(p, 'templates').items, 'id', hx).label <= 200).to_be(true)
  local menu = open_menu(s, hx, 'pd-long-first')
  local tree = menu:render()
  expect(size(tree) <= BUDGET).to_be(true)
  expect(#tree.title <= 200).to_be(true)
  expect(#node(tree, 'summary').text <= 220).to_be(true)
  close_form(s)
  local confirm = open_confirm(s, hx, 'pd-long')
  tree = confirm:render()
  expect(size(tree) <= BUDGET).to_be(true)
  expect(submit(confirm, 'pd-long-submit').status).to_be('succeeded')
end)

test('a row ID that is not the lowercase hex of a name is invalid_input', function()
  local s = W.workspace()
  local p = W.panel(s)
  p:render()
  for i, id in ipairs({'ABCD', 'abc', 'zz', '', '6162/63'}) do
    local op = p:action('templates', 'open', {item_id = id}, 'pd-bad-' .. i)
    expect(op.status).to_be('failed')
    expect(op.error.code).to_be('invalid_input')
  end
end)
