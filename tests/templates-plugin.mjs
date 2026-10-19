// Controlled hub test for plugins/templates.lua (Codex's review of 108504e). The real plugin runs
// in `rex do` on a lab server; this script answers its hub calls with an in-memory store. Capture
// reads a real lab session.
// Run: REX_SERVER=unix:///tmp/rexlab-templates-<name>/rex.sock node spikes/03-ui-framework/tests/templates-plugin.mjs
// Checks:
//   A. A save replays its result after a lost reply, even when the source session changed and the
//      root is gone. Changed content with the same key is refused.
//   B. A start replays the same run after its template was deleted.
//   C. A delete replays its result and never deletes a newer template with the same name.
//   D. With more than 50 runs, the newest stuck run is listed with Dismiss.
//   E. A pane whose spawn profile no longer exists keeps every option (Leave out, Shell, profiles).
//   F. A start into a new session switches the app once, from the open form: success, replay,
//      existing session, refusal, a lost answer after the attempt, and the wait timeout.
import {connectControl} from '../../LazyRex/lib/rex-client.mjs';
import {labSocket, until} from '../../LazyRex/lab/lab.mjs';
import {spawn, execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import fs from 'node:fs';
import assert from 'node:assert/strict';

const socket = await labSocket();
const control = await connectControl(socket), hub = await connectControl(socket);
const records = new Map(), operations = new Map();
let revision = 0n, child, pluginId, specs = {}, windows = 0, selects = [], selectError = '', ensureDelay = 0;
const copy = v => structuredClone(v);
const record = key => copy(records.get(key) ?? {rev: '0'});
function batch(args) {
  const ops = Array.isArray(args.ops) ? args.ops : [];
  const saved = args.op && operations.get(args.op.key);
  if (saved) return saved.fingerprint === args.op.fingerprint ? {op_exists: copy(saved)} : {conflict: {kind: 'operation'}};
  for (const op of ops) if (op.if_rev !== undefined && op.if_rev !== record(op.key).rev) return {conflict: {kind: 'revision', key: op.key}};
  const revs = {};
  for (const op of ops) {
    if (op.delete) records.delete(op.key); else records.set(op.key, {value: copy(op.value), rev: String(++revision)});
    revs[op.key] = record(op.key).rev;
  }
  if (args.op) operations.set(args.op.key, copy(args.op));
  return {revs};
}
const hubId = await (async () => {
  const names = ['register', 'profiles', 'spawn.spec', 'spawn_window', 'app.select_session', 'session.list', 'session.ensure', 'store.get', 'store.scan', 'store.batch', 'store.op', 'ui.invalidate'];
  await hub.call('client.keymap', {actions: names.map(n => ({name: `hub.${n}`, kind: 'client', title: n}))});
  const label = `templates-mock-${process.pid}`;
  await hub.call('client.set_label', {label});
  return (await control.call('client.list')).clients.find(c => c.info?.label === label).client_id;
})();
hub.events.on('event', async frame => {
  if (frame.payload?.type !== 'client_perform_requested') return;
  const ev = frame.payload.payload;
  try {
    let result;
    const a = ev.args;
    switch (ev.action) {
      case 'hub.register': pluginId = ev.requester.client_id; result = {namespace: 'templates', generation: '1'}; break;
      case 'hub.profiles': result = {profiles: [{id: 'shell', name: 'Shell'}, {id: 'server', name: 'Server'}]}; break;
      case 'hub.spawn.spec': result = specs[a.block_id] ?? {found: false}; break;
      case 'hub.spawn_window': windows++; result = {status: 'open', window_id: `window:mock-${windows}`, leaves: []}; break;
      case 'hub.session.list': result = {sessions: []}; break;
      case 'hub.session.ensure':
        if (ensureDelay) await new Promise(r => setTimeout(r, ensureDelay));
        result = {session_id: 'session:mock-' + a.key}; break;
      case 'hub.app.select_session':
        selects.push(a);
        if (selectError) throw Object.assign(new Error(selectError + ': refused by the mock'), {code: selectError});
        result = {status: 'selected'}; break;
      case 'hub.store.get': result = {records: Object.fromEntries(a.keys.map(k => [k, record(k)]))}; break;
      case 'hub.store.op': { const s = operations.get(a.key); result = s ? {found: true, ...copy(s)} : {found: false}; break; }
      case 'hub.store.batch': result = batch(a); break;
      case 'hub.store.scan': {
        const all = [...records.entries()].filter(([k]) => (!a.after || k > a.after) && (!a.prefix || k.startsWith(a.prefix))).sort(([x], [y]) => x < y ? -1 : x > y ? 1 : 0);
        const page = all.slice(0, a.limit || 50);
        result = {records: Object.fromEntries(page.map(([k, r]) => [k, copy(r)])), ...(all.length > page.length ? {next: page.at(-1)[0]} : {})};
        break;
      }
      case 'hub.ui.invalidate': result = {status: 'accepted'}; break;
      default: throw new Error('unknown hub action ' + ev.action);
    }
    await hub.call('client.reply', {call_id: ev.call_id, result});
  } catch (error) {
    await hub.call('client.reply', {call_id: ev.call_id, error: {code: error.code ?? 'internal', message: error.message}});
  }
});
const call = async (action, args) => {
  const r = await hub.call('client.perform', {client_id: pluginId, action, args, timeout_ms: 15000});
  return r.result;
};
const fails = async (p, re) => { try { await p; } catch (e) { assert.match(String(e.message ?? e), re); return; } assert.fail('expected an error ' + re); };

const root = fs.mkdtempSync('/tmp/rexlab-templates-plugin-');
fs.mkdirSync(`${root}/api`);
const realRoot = fs.realpathSync(root);
const sh = (label, cwd) => ({block: {flavor: 'com.superlogical.terminal.shell', label, options: {command: ['/bin/sh'], login: false, cwd}}});
const S = (await control.call('session.create', {label: 'templates-plugin', initial_windows: [{window_label: 'code',
  layout: {split: {direction: 'horizontal', ratio: 0.5, before: sh('a', `${realRoot}/api`), after: sh('b', realRoot)}}}]})).session_id;
await control.call('session.attach', {session_id: S, event_scope: 'session'});
try {
  child = spawn(process.env.REX_BIN || 'rex', ['-S', `unix://${socket}`, '--autostart=false', 'do',
    process.env.TEMPLATES_PLUGIN || fileURLToPath(new URL('../../Templates/templates.lua', import.meta.url)), '--all', `hub_client_id=${hubId}`, 'instance_id=templates-test', 'switch_wait=2'],
    {env: {...process.env, REX_SERVER: `unix://${socket}`, REX_SESSION: '', REX_BLOCK: '', REX_CLIENT: ''}});
  child.stdout.pipe(process.stdout); child.stderr.pipe(process.stderr);
  await until(async () => pluginId && (await control.call('client.list')).clients.some(c => c.info?.label === 'lazyrex-plugin:templates' && c.connection_state === 'connected'), 'plugin ready');
  await new Promise(r => setTimeout(r, 800)); // idle shells
  const blocks = (await control.call('session.list_blocks', {session_id: S})).blocks;
  const A = blocks.find(b => b.label === 'a').block_id, B = blocks.find(b => b.label === 'b').block_id;
  const ctx = {session_id: S, window_id: 'window:x', source_block_id: A};
  const act = (route, node_id, action, values, key, item_id) => call('view.action', {route, node_id, action, view_id: 'view-test', user: 'user', operation_key: key, context: ctx,
    input: item_id ? {item_id} : {values}});

  // A. Save, then a lost reply: the source changes and the root disappears; the retry still answers.
  const values = {name: 'web', root: realRoot, [`pane_${A}`]: 'shell', [`pane_${B}`]: 'profile:server'};
  assert.deepEqual(await act('/forms/save', 'save_template', 'submit', values, 'save-1'), {close_form: true});
  const tpl = records.get('template/' + Buffer.from('web').toString('hex')).value;
  assert.deepEqual(tpl.tabs[0].layout, {direction: 'horizontal', ratio: 0.5, before: {launch: {shell: true}, dir: 'api'}, after: {launch: {profile: 'server'}, dir: '.'}});
  await control.call('block.close', {session_id: S, block_id: B});
  fs.rmSync(`${root}/api`, {recursive: true});
  assert.deepEqual(await act('/forms/save', 'save_template', 'submit', values, 'save-1'), {close_form: true}, 'replay');
  await fails(act('/forms/save', 'save_template', 'submit', {...values, name: 'other'}, 'save-1'), /different content/);
  console.log('ok A save replays after the source and root changed');

  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const switchRecord = key => records.get('switch/' + Buffer.from(`start/${key.length}:${key}`).toString('hex'))?.value;
  const finish = async (values, key) => {
    let running = 0;
    for (let i = 0; i < 60; i++) {
      const r = await act('/forms/start', 'start_session', 'submit', values, key);
      if (r.status !== 'running') return {r, running};
      running++;
      await sleep(250);
    }
    assert.fail('the start still waits');
  };
  // B. Start, delete the template, then a retry of the start returns the same run.
  const startValues = {template: 'web', root: realRoot, session_id: '@new', session_name: ''};
  fs.mkdirSync(`${root}/api`);
  const {r: first} = await finish(startValues, 'start-1');
  assert(first.run_id && first.panel, JSON.stringify(first));
  assert.deepEqual(await act('/panels/templates', 'templates', 'delete', null, 'delete-1', 'web'), {});
  assert(!records.has('template/' + Buffer.from('web').toString('hex')), 'deleted');
  const {r: again} = await finish(startValues, 'start-1');
  assert.equal(again.run_id, first.run_id, 'the same run');
  console.log('ok B start replays after its template was deleted');

  // C. A newer template with the same name survives a retried delete.
  await act('/forms/save', 'save_template', 'submit', {name: 'web', root: realRoot, [`pane_${A}`]: 'shell'}, 'save-2');
  assert.deepEqual(await act('/panels/templates', 'templates', 'delete', null, 'delete-1', 'web'), {}, 'replayed result');
  assert(records.has('template/' + Buffer.from('web').toString('hex')), 'the newer template stays');
  console.log('ok C delete replays and keeps a newer template');

  // F. The app switch. The mock records hub.app.select_session; the hub's own checks have unit tests.
  selects.length = 0; // B also switched
  const notice = async () => (await call('view.render', {route: '/panels/templates', user: 'user', context: {...ctx, panel: true}})).tree.nodes.find(n => n.id === 'switch')?.text;
  const fresh = name => ({template: 'web', root: realRoot, session_id: '@new', session_name: name});
  {
    const {r} = await finish(fresh('f1'), 'start-f1');
    assert(r.panel && r.run_id, JSON.stringify(r));
    assert.equal(selects.length, 1, 'one switch');
    const run = records.get('run/' + r.run_id).value;
    assert.deepEqual(selects[0], {view_id: 'view-test', session_id: run.session_id, window_id: run.results[0].window_id});
    assert.equal(switchRecord('start-f1').state, 'done');
    assert.equal(await notice(), undefined, 'no hint after a switch');
    const again = await finish(fresh('f1'), 'start-f1');
    assert.equal(again.running, 0, 'a replay does not wait');
    assert.equal(again.r.run_id, r.run_id);
    assert.equal(selects.length, 1, 'a replay never switches again');
    console.log('ok F1 a new-session start switches once; its replay does not');
  }
  {
    const r = await act('/forms/start', 'start_session', 'submit', {template: 'web', root: realRoot, session_id: S, session_name: ''}, 'start-f2');
    assert(r.panel, 'an existing-session start returns at once: ' + JSON.stringify(r));
    await sleep(500);
    assert.equal(selects.length, 1, 'no switch for an existing session');
    console.log('ok F2 an existing-session start never switches');
  }
  {
    selectError = 'not_focused';
    const {r} = await finish(fresh('f3'), 'start-f3');
    assert(r.panel);
    assert.equal(selects.length, 2);
    assert.deepEqual([switchRecord('start-f3').state, switchRecord('start-f3').code], ['refused', 'not_focused'], JSON.stringify(switchRecord('start-f3')));
    assert.match(await notice(), /f3.*did not switch.*left the form.*Go to Session/);
    await finish(fresh('f3'), 'start-f3');
    assert.equal(selects.length, 2, 'a refused switch is not asked again');
    selectError = '';
    console.log('ok F3 a refused switch returns with the hint');
  }
  {
    // A crash after the attempt marker: the retry never asks again.
    records.set('switch/' + Buffer.from('start/8:start-f4').toString('hex'), {rev: String(++revision), value: {state: 'attempted'}});
    const {r} = await finish(fresh('f4'), 'start-f4');
    assert(r.panel);
    assert.equal(selects.length, 2, 'no switch after an attempt');
    assert.equal(switchRecord('start-f4').state, 'unknown');
    assert.match(await notice(), /may not have switched.*If it did not, use Go to Session/);
    console.log('ok F4 an earlier attempt reads as unknown and never switches again');
  }
  {
    ensureDelay = 3500;
    const {r, running} = await finish(fresh('f5'), 'start-f5');
    ensureDelay = 0;
    assert(r.panel && running > 0, 'the form waited ' + running);
    assert.equal(switchRecord('start-f5').code, 'timeout');
    assert.equal(selects.length, 2, 'no switch after the timeout');
    await until(async () => records.get('run/' + r.run_id).value.status === 'open', 'the late start opens');
    await sleep(300);
    assert.equal(selects.length, 2, 'a late first tab never switches');
    assert.match(await notice(), /wait for the automatic switch .* expired, so the app did not switch\. When the session is available, use Go to Session/);
    console.log('ok F5 the wait times out, the late tab does not switch');
  }
  // F7/F8. A recovered start whose wait expired never switches, even with its first tab open now:
  // a legacy start-form record without at, and one older than the wait (Codex's review).
  for (const [name, edit] of [['f7', v => { delete v.at; }], ['f8', v => { v.at -= 60; }]]) {
    ensureDelay = 1000;
    const key = `start-${name}`;
    const r = await act('/forms/start', 'start_session', 'submit', fresh(name), key);
    assert.equal(r.status, 'running', name + ' waits first');
    const formKey = 'start-form/' + Buffer.from(`start/${key.length}:${key}`).toString('hex');
    edit(records.get(formKey).value);
    ensureDelay = 0;
    await until(async () => records.get('run/' + r.run_id).value.status === 'open', name + ' first tab open');
    const {r: done} = await finish(fresh(name), key);
    assert(done.panel);
    assert.equal(switchRecord(key).code, 'timeout', name);
    assert.equal(selects.length, 2, name + ' never switches late');
  }
  console.log('ok F7 F8 a legacy or expired start with an open first tab does not switch');
  {
    // While a start waits, its form says so and cannot submit again.
    ensureDelay = 1500;
    const r = await act('/forms/start', 'start_session', 'submit', fresh('f6'), 'start-f6');
    assert.equal(r.status, 'running');
    const form = (await call('view.render', {route: '/forms/start', view_id: 'view-test', user: 'user', context: ctx})).tree;
    assert.match(form.nodes[0].text, /^Starting/);
    assert.equal(form.status.state, 'working');
    ensureDelay = 0;
    await finish(fresh('f6'), 'start-f6');
    const after = (await call('view.render', {route: '/forms/start', view_id: 'view-test', user: 'user', context: ctx})).tree;
    assert.notEqual(after.nodes[0].id, 'starting');
    console.log('ok F6 the waiting form shows Starting…');
  }

  // D. 55 runs: the oldest is stuck, with 54 newer finished runs. It stays listed with Dismiss.
  for (let i = 100; i < 155; i++) {
    records.set(`run/${i}`, {rev: String(++revision), value: {id: String(i), status: i === 100 ? 'pending' : 'open', next_tab: 2,
      tabs: [{key: 'x', title: 'x', layout: {}}], root: realRoot, request: {key: `k${i}`, template: {name: `t${i}`}}, results: []}});
  }
  const panel = (await call('view.render', {route: '/panels/templates', user: 'user', context: {...ctx, panel: true}})).tree;
  const stuckList = panel.nodes.find(n => n.id === 'stuck');
  assert.deepEqual(stuckList?.items.map(i => [i.id, i.action?.name]), [['100', 'dismiss']], 'stuck: ' + JSON.stringify(stuckList));
  const recent = panel.nodes.find(n => n.id === 'runs');
  assert.equal(recent.items.length, 10);
  assert.equal(recent.items[0].id, '154', 'newest first');
  assert(recent.items.every(i => !i.action), 'finished starts have no action');
  // Dismiss ends the run in the engine.
  records.get('run/100').value.next_tab = 1;
  assert.deepEqual(await act('/panels/templates', 'stuck', 'dismiss', null, 'dismiss-1', '100'), {});
  assert.equal(records.get('run/100').value.status, 'dismissed');
  console.log('ok D an old stuck run stays listed with Dismiss behind 54 newer runs, and dismisses');

  // E. A spawned pane with a removed profile keeps every option.
  specs[A] = {found: true, profile: 'gone', args: {}, cwd: realRoot, title: 'Gone'};
  const form = (await call('view.render', {route: '/forms/save', user: 'user', context: ctx})).tree;
  const field = form.nodes[0].fields.find(f => f.id === `pane_${A}`);
  assert.deepEqual(field.options.map(o => o.value), ['@choose', '@skip', 'shell', 'profile:server', 'profile:gone']);
  assert.equal(field.value, 'profile:gone');
  console.log('ok E a removed profile keeps every option');
} finally {
  if (child && child.exitCode === null) child.kill();
  await control.call('session.destroy', {session_id: S}).catch(() => {});
  fs.rmSync(root, {recursive: true, force: true});
}
process.exit(0);
