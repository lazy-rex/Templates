// Create-only layout contract. Run only against the Templates Codex lab.
import assert from 'node:assert/strict';
import {connectControl} from '../../LazyRex/lib/rex-client.mjs';
const c = await connectControl('/tmp/rexlab-templates-codex/rex.sock');
let session;
try {
  session = (await c.call('session.create', {label: 'templates-layout-contract'})).session_id;
  await c.call('session.attach', {session_id: session, event_scope: 'session'});
  const call = (method, args = {}) => c.call(method, {session_id: session, ...args});
  const dirs = {a: '/tmp', b: '/usr', c: '/', d: '/tmp'};
  const leaf = label => ({block: {flavor: 'com.superlogical.terminal.shell', label,
    options: {command: ['/bin/sleep', '600'], login: false, cwd: dirs[label] || '/tmp'}}});
  const split = (direction, ratio, before, after) => ({split: {direction, ratio, before, after}});
  const layout = split('horizontal', 0.3, split('vertical', 0.6, leaf('a'), leaf('b')),
    split('vertical', 0.4, leaf('c'), leaf('d')));
  const created = await call('session.new_window', {window_label: 'nested', layout, focus: false});
  assert.equal(created.block_ids.length, 4);
  const view = await call('session.view');
  const window = view.windows.find(w => w.window_id === created.window_id);
  const observed = window.layers.find(l => l.kind === 'tiled').layout;
  let index = 0;
  function compare(expected, actual) {
    if (expected.block) { assert.equal(actual.block_id, created.block_ids[index++]); return; }
    assert.equal(actual.split.direction, expected.split.direction);
    assert.equal(actual.split.ratio, expected.split.ratio);
    compare(expected.split.before, actual.split.before);
    compare(expected.split.after, actual.split.after);
  }
  compare(layout, observed);
  const blocks = (await call('session.list_blocks')).blocks;
  assert.deepEqual(created.block_ids.map(id => blocks.find(b => b.block_id === id).label), ['a', 'b', 'c', 'd']);
  const expectedCwds = ['/private/tmp', '/usr', '/', '/private/tmp'];
  for (let i = 0; i < created.block_ids.length; i++) {
    const process = await call('com.superlogical.terminal.process', {block_id: created.block_ids[i]});
    assert.equal(process.child.cwd, expectedCwds[i]);
  }
  const before = blocks.map(b => b.block_id).sort();
  await assert.rejects(call('session.new_window', {window_label: 'invalid', layout:
    split('horizontal', 0.5, leaf('must-not-remain'), {block: {flavor: 'invalid.templates.flavor'}})}));
  assert.deepEqual((await call('session.list_blocks')).blocks.map(b => b.block_id).sort(), before);
  assert.equal((await call('session.view')).windows.length, 1);
  console.log('PASS: nested layout, ratios, depth-first IDs, per-leaf cwd, invalid-flavor rejection leaves no blocks or window');
} finally {
  if (session) await c.call('session.destroy', {session_id: session});
  c.close();
}
