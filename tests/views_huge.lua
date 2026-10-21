-- The panel and the Start form with records from another writer that do not fit the view budget
-- alone (48 KiB, VIEW_BUDGET in templates.lua). Tests in this file share one hub.

local W = load_fixture(H.args.file:match('^(.*)/') .. '/support/workspace.lua')
local BUDGET = 48 * 1024
local function size(tree) return #rex.json.encode({tree = tree}) end

-- The skeleton: the panel with no template and no start has the constant parts only. With both
-- omitted-count widgets at their largest text it is still far under the budget, so the fallback
-- view (too_large_view) is only a last check.
test('the constant parts of the panel and the Start form are small', function()
  local s = W.workspace()
  local panel = W.panel(s):render()
  expect(size(panel) < 1024).to_be(true)
  expect(node(panel, 'more_templates')).to_be(nil)
  expect(node(panel, 'more_runs')).to_be(nil)
  local form = W.open('start_session', '/forms/start', s):render()
  expect(node(form, 'empty').text).to_match('^No templates yet')
  expect(size(form) < 1024).to_be(true)
end)

-- A template whose option alone is over the budget: a name of 4200 "<" is 25 200 bytes encoded,
-- and the option has it twice (value and label).
local HUGE = 'h' .. string.rep('<', 4200)
test('no template option fits: the Start form has no submit and says to use templates.start', function()
  local s = W.workspace()
  write({{key = 'template/' .. W.hex(HUGE), value = {v = 1, name = HUGE, saved_by = 'user',
    tabs = {{title = 't', layout = {launch = {shell = true}, dir = '.'}}}}}})
  local tree = W.open('start_session', '/forms/start', s):render()
  expect(size(tree) <= BUDGET).to_be(true)
  expect(node(tree, 'start_session')).to_be(nil)
  expect(node(tree, 'no_template').text).to_be('The template list is too large for this form. Use templates.start.')
  expect(node(tree, 'cancel')).not_to_be(nil)
  -- The panel does not show the template row (over the budget with its label and ID) and counts it.
  local panel = W.panel(s):render()
  expect(size(panel) <= BUDGET).to_be(true)
  expect(#node(panel, 'templates').items).to_be(0)
  expect(node(panel, 'more_templates').text).to_be('1 more template: use templates.list')
  expect(node(panel, 'start').action.enabled).to_be(true)
end)

-- The newest start went to a new session and did not switch the app. Its template name (9000 "<",
-- 54 000 bytes encoded) makes the switch notice and its recent row too large: both are left out,
-- the start is counted, and the panel opens.
test('a switch notice over the budget is left out, and its start is counted', function()
  local s = W.workspace()
  local root = W.real(W.HOME)
  local name = string.rep('<', 9000)
  write({{key = 'run/7001', value = {id = '7001', status = 'open', next_tab = 2, root = root,
    tabs = {{key = 'templates/7001/tab/1', title = 'x', layout = {shell = true, cwd = root}}},
    request = {key = 'huge-notice', root = root, new_session_name = 'n', template = {v = 1, name = name, tabs = {}}},
    results = {}, session_key = 'templates/7001/session'}}})
  write({{key = 'switch/' .. W.hex('huge-notice'), value = {state = 'refused', code = 'no_app'}}})
  local panel = W.panel(s):render()
  expect(size(panel) <= BUDGET).to_be(true)
  expect(node(panel, 'switch')).to_be(nil)
  expect(node(panel, 'runs')).to_be(nil)
  expect(node(panel, 'more_runs').text).to_be('1 more finished start: use templates.runs')
end)

-- One stuck start whose rows alone are over the budget: counted, not shown; a smaller older stuck
-- start is still shown.
test('a stuck start over the budget is counted, and a smaller one is shown', function()
  local s = W.workspace()
  local root = W.real(W.HOME)
  for _, r in ipairs({{id = '7003', err = string.rep('<', 9000)}, {id = '7002', err = 'small'}}) do
    write({{key = 'run/' .. r.id, value = {id = r.id, status = 'pending', next_tab = 1, root = root,
      tabs = {{key = 'templates/' .. r.id .. '/tab/1', title = 'x', layout = {shell = true, cwd = root}}},
      request = {key = 'stuck' .. r.id, root = root, session_id = 'session:none', template = {v = 1, name = 's' .. r.id, tabs = {}}},
      results = {}, session_key = 'templates/' .. r.id .. '/session', error = r.err}}})
  end
  local panel = W.panel(s):render()
  expect(size(panel) <= BUDGET).to_be(true)
  local items = node(panel, 'stuck').items
  expect(#items).to_be(1)
  expect(items[1].id).to_be('dismiss:7002')
  expect(node(panel, 'more_runs').text).to_be('1 more unfinished start, 1 more finished: use templates.runs')
end)
