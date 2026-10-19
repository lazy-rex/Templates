// Lab: session templates end to end (plugins/templates.lua + templates_run.lua + hub.spawn_window),
// with the real hub and the real renderer. Lab only.
// Setup: spikes/lab/server.sh /tmp/rexlab-templates-<name>; the hub runs on that server with a
// config whose plugins are lazyrex and templates, and whose profiles file defines "server"
// (arg port, default 3000) and "watcher". Set TEMPLATES_LAB to the lab directory; the hub state
// is $TEMPLATES_LAB/hubstate.
// Checks:
//   1. Save: a session of two tabs in repo A. The form leaves out LazyRex's own panes (the form
//      itself), guesses Shell for idle shells, and asks for a pane whose foreground is another
//      program. A submit with "Choose…" left is refused; "Leave out" removes that pane and its split.
//      The stored template has relative dirs and the exact remaining layout.
//   2. Start: from a pane in repo B, the form defaults the root to repo B. The run opens both tabs
//      in a new session with the saved ratios and directories under repo B.
//   2 also checks the app switch: a fake app (a client with hello kind "app" that declares
//      session.select) shows the source session. The start form waits for the first tab, then
//      the hub asks that app once to select the new session and its first tab.
//   3. The Templates panel lists the template and the run as open.
//   5 also checks that a start into the current session never asks the app to switch.
//   6. With two apps on the source session, the hub refuses (ambiguous_app). The start still
//      opens, the app is not asked, and the panel says how to switch by hand.
import {connectControl} from '../../LazyRex/lib/rex-client.mjs';
import fs from 'node:fs';
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';

const LAB = process.env.TEMPLATES_LAB || '/tmp/rexlab-templates-claude';
if (!/^\/tmp\/rexlab-templates-/.test(LAB)) throw new Error('refuse a non-lab directory');
const SOCK = `unix://${LAB}/rex.sock`, DB = `${LAB}/hubstate/hub.db`, EV = `${LAB}/hubstate/events.jsonl`;
const c = await connectControl(`${LAB}/rex.sock`);
const sleep = ms => new Promise(r => setTimeout(r, ms));
let lastScreen = '';
const waitFor = async (what, f, ms = 15000) => { for (let t = 0; t < ms; t += 150) { const v = await f(); if (v) return v; await sleep(150); } assert.fail(`timed out: ${what}\nlast screen: ${lastScreen}`); };
const findHub = async () => (await c.call('client.list')).clients.filter(x => x.info?.label === 'lazyrex-hub' && x.connection_state === 'connected').at(-1)?.client_id;
let hubId = await findHub();
await c.call('client.set_label', {label: 'templates-lab'});
const me = (await c.call('client.list')).clients.find(x => x.info?.label === 'templates-lab' && x.connection_state === 'connected').client_id;
const hub = async (action, args = {}) => (await c.call('client.perform', {client_id: hubId, action, args, timeout_ms: 10000})).result;
const rex = (...a) => execFileSync('env', ['-u', 'REX_SESSION', '-u', 'REX_BLOCK', 'rex', '-S', SOCK, '--autostart=false', ...a], {encoding: 'utf8'});
const sql = q => execFileSync('sqlite3', ['-readonly', DB, q], {encoding: 'utf8'}).trim();
const startAt = new Date().toISOString();
const events = name => fs.readFileSync(EV, 'utf8').split('\n').filter(l => l.includes(`"event":"${name}"`)).map(l => JSON.parse(l)).filter(e => e.at >= startAt);
const screen = (s, b) => { try { lastScreen = rex('capture', '-s', s, '-b', b); return lastScreen.replace(/\s+/g, ''); } catch { return ''; } };
const shows = (s, b, text) => screen(s, b).includes(text.replace(/\s+/g, ''));
// Keys after a focus change can be lost (roadmap, known defects): wait between keys.
const press = async (s, b, ...keys) => { for (const k of keys) { rex('send-key', '-s', s, '-b', b, k); await sleep(250); } };
const pick = async (s, b, label) => {
  await press(s, b, 'enter');
  await waitFor('select opens', () => shows(s, b, '✓'));
  rex('send', '-s', s, '-b', b, label); await sleep(250);
  await press(s, b, 'enter');
  await waitFor(`${label} chosen in the closed field`, () => shows(s, b, `${label} ▾`) && !shows(s, b, '✓'));
};
const real = p => fs.realpathSync(p);

// Two repositories with the same layout.
const repo = name => {
  const dir = `${LAB}/${name}`;
  fs.rmSync(dir, {recursive: true, force: true});
  fs.mkdirSync(`${dir}/api`, {recursive: true});
  fs.mkdirSync(`${dir}/web`, {recursive: true});
  execFileSync('git', ['init', '-q', dir]);
  return real(dir);
};
const A = repo('repo-a'), B = repo('repo-b');
// Each run starts with no saved templates (lab hub database only), so the start form's default
// template is this run's.
execFileSync('sqlite3', [DB, `DELETE FROM records WHERE ns = 'templates' AND key LIKE 'template/%'`]);
const sh = (label, cwd) => ({block: {flavor: 'com.superlogical.terminal.shell', label, options: {command: ['/bin/sh'], login: false, cwd}}});
// A program run directly: the pane's child is not a shell.
const direct = (label, cwd) => ({block: {flavor: 'com.superlogical.terminal.shell', label, options: {command: ['/bin/sleep', '600'], login: false, cwd}}});
const ish = (label, cwd) => ({block: {flavor: 'com.superlogical.terminal.shell', label, options: {command: ['/bin/sh', '-i'], login: false, cwd}}});
const H = (r, b, a) => ({split: {direction: 'horizontal', ratio: r, before: b, after: a}});
const V = (r, b, a) => ({split: {direction: 'vertical', ratio: r, before: b, after: a}});

const label = `proj-${Date.now() % 100000}`;
const S = (await c.call('session.create', {label, initial_windows: [
  {window_label: 'code', layout: H(0.4, sh('api', `${A}/api`), V(0.7, sh('web', `${A}/web`), ish('busy', A)))},
  {window_label: 'logs', layout: V(0.5, sh('log', `${A}/web`), direct('tail', A))}]})).session_id;
await c.call('session.attach', {session_id: S, event_scope: 'session'});
const created = [S];
const view = async s => (await c.call('session.view', {session_id: s}));
const blockByLabel = async (s, l) => (await c.call('session.list_blocks', {session_id: s})).blocks.find(b => b.label === l);
const formIn = async (s, viewId) => (await c.call('session.list_blocks', {session_id: s})).blocks.find(b => b.label === `lazyrex-form:${viewId}`);
const palette = async (command, s, block) => {
  const before = events('form_opened').length;
  await hub('hub.palette.run', {command, ctx: {client_id: me, session_id: s, block_id: block}});
  const opened = await waitFor('form_opened', () => events('form_opened')[before]);
  const pane = await waitFor('form pane', () => formIn(s, opened.view_id));
  return {opened, pane};
};
const store = key => { const v = sql(`SELECT value FROM records WHERE ns = 'templates' AND key = '${key}'`); return v ? JSON.parse(v) : null; };
const hex = s => Buffer.from(s).toString('hex');

try {
  // An interactive shell runs a program in the foreground (job control).
  await sleep(800);
  const busyPane = await blockByLabel(S, 'busy');
  rex('send', '-s', S, '-b', busyPane.block_id, 'sleep 600');
  rex('send-key', '-s', S, '-b', busyPane.block_id, 'enter');
  await waitFor('sleep in the foreground', async () => (await c.call('com.superlogical.terminal.process', {session_id: S, block_id: busyPane.block_id, args: {}})).foreground?.name === 'sleep');
  const api = await blockByLabel(S, 'api');

  // 1. Save.
  const save = await palette('templates.save_template', S, api.block_id);
  const f = save.pane.block_id;
  await waitFor('save form renders', () => shows(S, f, 'code · ' + A + ' · running sleep'));
  assert(shows(S, f, A), 'the root defaults to the git root of the panes');
  assert(!shows(S, f, 'lazyrex-form'), 'the form pane is not listed');
  // Controls: name, root, five panes (depth-first: api, web, busy, log, tail), submit, cancel.
  await press(S, f, 'ctrl+n', 'tab', 'tab', 'tab', 'tab', 'tab', 'tab', 'tab', 'enter');
  await waitFor('refused while a pane is undecided', () => shows(S, f, 'Choose a launch or Leave out for each pane'));
  // The focus on the submit button scrolls the last panes into view.
  assert(shows(S, f, 'logs · ' + A + ' · running sleep'), 'a pane that runs a program directly is undecided');
  // Pick Leave out for busy, then Server for tail.
  await press(S, f, 'shift+tab', 'shift+tab', 'shift+tab');
  await pick(S, f, 'Leave out');
  await press(S, f, 'tab', 'tab');
  await pick(S, f, 'Server');
  await press(S, f, 'tab', 'enter');
  const tpl = await waitFor('template stored', () => store(`template/${hex(label)}`));
  await waitFor('save form closed', async () => !(await formIn(S, save.opened.view_id)));
  assert.deepEqual(tpl, {v: 1, name: label, tabs: [
    {title: 'code', layout: {direction: 'horizontal', ratio: 0.4, before: {launch: {shell: true}, dir: 'api'}, after: {launch: {shell: true}, dir: 'web'}}},
    {title: 'logs', layout: {direction: 'vertical', ratio: 0.5, before: {launch: {shell: true}, dir: 'web'}, after: {launch: {profile: 'server'}, dir: '.'}}}]},
    'stored template: ' + JSON.stringify(tpl));
  console.log('ok 1 save: relative dirs, layout without the left-out pane');

  // 2. Start from a pane in repo B.
  const O = (await c.call('session.create', {label: `other-${Date.now() % 100000}`, initial_windows: [{window_label: 'b', layout: sh('b', `${B}/web`)}]})).session_id;
  created.push(O);
  await c.call('session.attach', {session_id: O, event_scope: 'session'});
  await sleep(500);
  const bb = await blockByLabel(O, 'b');
  // The fake app records every session.select that it gets.
  const selects = [];
  const fakeApp = async name => {
    const a = await connectControl(`${LAB}/rex.sock`, {client: {kind: 'app', name, label: name}});
    await a.call('client.keymap', {actions: [{name: 'session.select', kind: 'client', title: 'Go to Session'}]});
    a.events.on('event', async frame => {
      if (frame.payload?.type !== 'client_perform_requested') return;
      const ev = frame.payload.payload;
      selects.push({app: name, action: ev.action, args: ev.args});
      await a.call('client.reply', {call_id: ev.call_id, result: {}});
    });
    await a.call('session.attach', {session_id: O, event_scope: 'session'});
    const row = await waitFor('app client listed', async () => (await c.call('client.list')).clients.find(x => x.info?.label === name && x.connection_state === 'connected'));
    assert.equal(row.info.kind, 'app');
    assert(row.session_ids.includes(O), 'the app shows the source session: ' + JSON.stringify(row));
    return a;
  };
  const app1 = await fakeApp('templates-lab-app');
  const before = new Set((await c.call('session.list')).sessions.map(s => s.session_id));
  const start = await palette('templates.start_session', O, bb.block_id);
  const g = start.pane.block_id;
  await waitFor('start form renders', () => shows(O, g, label));
  assert(shows(O, g, B), 'the root defaults to the git root of the source pane');
  // Controls: template, root, session, session name, submit, cancel.
  await press(O, g, 'ctrl+n', 'tab', 'tab', 'tab', 'tab', 'enter');
  const N = await waitFor('new session', async () => (await c.call('session.list')).sessions.find(s => !before.has(s.session_id) && s.label === label)?.session_id);
  created.push(N);
  await c.call('session.attach', {session_id: N, event_scope: 'session'});
  const nv = await waitFor('both tabs open', async () => { const v = await view(N); return v.windows?.length === 2 && v; });
  assert.deepEqual(nv.windows.map(w => w.label), ['code', 'logs']);
  const code = nv.windows[0].layers[0].layout;
  assert(code.split && code.split.direction === 'horizontal' && code.split.ratio === 0.4 && code.split.before.block_id && code.split.after.block_id, 'code layout: ' + JSON.stringify(code));
  const cwd = async b => (await c.call('com.superlogical.terminal.process', {session_id: N, block_id: b, args: {}})).child?.cwd;
  const logs = nv.windows[1].layers[0].layout;
  assert(logs.split && logs.split.direction === 'vertical' && logs.split.ratio === 0.5, 'logs layout: ' + JSON.stringify(logs));
  await waitFor('pane directories under repo B', async () =>
    await cwd(code.split.before.block_id) === `${B}/api` && await cwd(code.split.after.block_id) === `${B}/web` &&
    await cwd(logs.split.before.block_id) === `${B}/web` && await cwd(logs.split.after.block_id) === B);
  // The server pane runs the profile with its default arg.
  await waitFor('server prints its default port', () => shows(N, logs.split.after.block_id, 'server 3000'));
  const spec = await hub('hub.workers');
  assert(spec.workers.some(w => w.profile === 'shell') && spec.workers.some(w => w.profile === 'server'), 'workers: ' + JSON.stringify(spec.workers.map(w => w.profile)));
  await waitFor('the app is asked to switch', () => selects.length === 1);
  assert.deepEqual(selects[0], {app: 'templates-lab-app', action: 'session.select', args: {session_id: N, window_id: nv.windows[0].window_id}});
  assert.equal(events('app_select_session').length, 1);
  console.log('ok 2 start: a new session with the saved layout in repo B; the app switches to its first tab');

  // 3. The panel shows the template and the run.
  // The panel replaces the form after the switch: the old form pane can still be listed while it closes.
  const panel = await waitFor('templates panel lists the template', async () => (await c.call('session.list_blocks', {session_id: O})).blocks.find(b => /^lazyrex-form:/.test(b.label) && shows(O, b.block_id, label)));
  // The run record (the panel shows it below the lab pane's height).
  const runs = sql(`SELECT value FROM records WHERE ns = 'templates' AND key LIKE 'run/%'`).split('\n').filter(Boolean).map(JSON.parse);
  const mine = runs.filter(r => r.request.template.name === label);
  assert.equal(mine.length, 1, 'one run for this start');
  assert.equal(mine[0].status, 'open');
  assert.equal(mine[0].root, B);
  assert.equal(mine[0].results.length, 2);
  console.log('ok 3 panel: template and open run');

  // 5. Start into the current session: the first new tab gets the focus, because the user is still
  // on the source tab (placement.focus).
  {
    const winsBefore = (await view(O)).windows.length;
    const st = await palette('templates.start_session', O, bb.block_id);
    const g5 = st.pane.block_id;
    await waitFor('start form renders', () => shows(O, g5, B));
    const oLabel = (await c.call('session.list')).sessions.find(s => s.session_id === O).label;
    // Open the Session list and pick this session.
    await press(O, g5, 'ctrl+n', 'tab', 'tab');
    await pick(O, g5, oLabel);
    await press(O, g5, 'tab', 'tab', 'enter');
    const v5 = await waitFor('two new tabs in this session', async () => { const v = await view(O); return v.windows.length === winsBefore + 2 && v; });
    const code5 = v5.windows.find(w => w.label === 'code');
    assert.equal(v5.active_window_id, code5.window_id, 'the first new tab is active');
    assert.equal(code5.focused_block_id, code5.layers[0].layout.split.before.block_id, 'its first pane has focus');
    await sleep(1000);
    assert.equal(selects.length, 1, 'no switch for the current session');
    console.log('ok 5 start into this session: the first new tab gets the focus; no app switch');
  }

  // 6. Two apps show the source session: the hub cannot know where the user is.
  {
    const app2 = await fakeApp('templates-lab-app-2');
    const before6 = new Set((await c.call('session.list')).sessions.map(s => s.session_id));
    const st = await palette('templates.start_session', O, bb.block_id);
    const g6 = st.pane.block_id;
    await waitFor('start form renders', () => shows(O, g6, B));
    await press(O, g6, 'ctrl+n', 'tab', 'tab', 'tab', 'tab', 'enter');
    const N6 = await waitFor('new session', async () => (await c.call('session.list')).sessions.find(s => !before6.has(s.session_id) && s.label === label)?.session_id);
    created.push(N6);
    const p6 = await waitFor('the panel replaces the form', async () => (await c.call('session.list_blocks', {session_id: O})).blocks.find(b => /^lazyrex-form:/.test(b.label) && shows(O, b.block_id, 'did not switch')));
    assert(shows(O, p6.block_id, 'more than one Rex app shows the session of the form'), 'the hint names the reason');
    assert(shows(O, p6.block_id, 'Go to Session'), 'the hint says how to switch');
    assert.equal(selects.length, 1, 'no app was asked');
    app2.close();
    console.log('ok 6 two apps: the start opens, no switch, the panel says how to switch by hand');
  }

  // 4. (TEMPLATES_RESTART=1) The hub stops right after a start is admitted and starts again. The
  // run stays pending (as decided), no tab is created twice, and Dismiss ends the run. Kills only the lab hub whose
  // command is $LAB/hub, and starts it again the same way.
  if (process.env.TEMPLATES_RESTART === '1') {
    const hubPid = () => { const l = fs.readFileSync(EV, 'utf8').split('\n').filter(x => x.includes('"event":"hub_started"')).at(-1); return JSON.parse(l).pid; };
    const pid = hubPid();
    assert.match(execFileSync('ps', ['-o', 'command=', '-p', String(pid)], {encoding: 'utf8'}), new RegExp(`^${LAB.replace(/\//g, '\\/')}/hub |^\\./hub `), 'the lab hub');
    const before2 = new Set((await c.call('session.list')).sessions.map(s => s.session_id));
    const runsBefore = sql(`SELECT COUNT(*) FROM records WHERE ns = 'templates' AND key LIKE 'run/%'`);
    const st = await palette('templates.start_session', O, bb.block_id);
    await waitFor('start form renders', () => shows(O, st.pane.block_id, B));
    await press(O, st.pane.block_id, 'ctrl+n', 'tab', 'tab', 'tab', 'tab', 'enter');
    await waitFor('run admitted', () => sql(`SELECT COUNT(*) FROM records WHERE ns = 'templates' AND key LIKE 'run/%'`) !== runsBefore, 10000);
    process.kill(pid, 'SIGKILL');
    console.log('   hub', pid, 'killed after admission');
    const {spawn} = await import('node:child_process');
    const out = fs.openSync(`${LAB}/hubstate/hub.log`, 'a');
    const env = {...process.env, REX_SERVER: SOCK}; delete env.REX_SESSION; delete env.REX_BLOCK;
    spawn(`${LAB}/hub`, ['-config', `${LAB}/hub.json`], {cwd: LAB, env, detached: true, stdio: ['ignore', out, out]}).unref();
    await waitFor('hub restarted', () => hubPid() !== pid, 15000);
    hubId = await waitFor('the new hub client', async () => { const id = await findHub(); return id !== hubId && id; });
    // Decided (2026-10-17): the hub never adopts accessory panes by label, so the run stays pending
    // with its candidate panes, and the user can dismiss it. Dismiss closes no pane.
    const latest = () => sql(`SELECT value FROM records WHERE ns = 'templates' AND key LIKE 'run/%'`).split('\n').filter(Boolean).map(JSON.parse).sort((a, b) => Number(b.id) - Number(a.id))[0];
    // The kill can land before, during or after the create. After Rex answered: the run finishes
    // from its records. Before: the run stays pending (decided), with no pane or with its candidate
    // panes, and Dismiss ends it.
    const ended = await waitFor('the run opens or waits with candidates', () => {
      const r = latest(); return (r.status === 'open' || (r.status === 'pending' && /outcome unknown/.test(r.error || ''))) && r;
    }, 30000);
    console.log('   run after restart:', ended.status, ended.error || '');
    const news = (await c.call('session.list')).sessions.filter(s => !before2.has(s.session_id) && s.label === label);
    assert.equal(news.length, 1, 'one new session');
    created.push(news[0].session_id);
    await c.call('session.attach', {session_id: news[0].session_id, event_scope: 'session'});
    const spawned = async () => (await c.call('session.list_blocks', {session_id: news[0].session_id})).blocks.filter(b => /^lazyrex-spawn:/.test(b.label)).length;
    if (ended.status === 'open') {
      assert.deepEqual((await view(news[0].session_id)).windows.map(w => w.label), ['code', 'logs'], 'two tabs, no duplicate');
      assert.equal(await spawned(), 4, 'four panes, no duplicate');
    } else {
      // The kill landed before the create (no pane) or during it (the first tab's panes, once).
      const panes = await spawned();
      assert(panes === 0 || panes === 2, `${panes} panes: the first tab exists at most once; the second tab waits`);
      // Dismiss in the panel. Controls: Start, Save, the template, then the starts, newest first.
      const p2 = await palette('templates.templates', O, bb.block_id);
      await waitFor('panel renders', () => shows(O, p2.pane.block_id, label));
      // The focus on the stuck start scrolls it into view.
      await press(O, p2.pane.block_id, 'tab', 'tab', 'tab');
      // The focus marker (▏) is on the stuck start.
      await waitFor('the stuck start is focused', () => screen(O, p2.pane.block_id).includes(`▏${label}in${B}·Dismiss`));
      await press(O, p2.pane.block_id, 'enter');
      await waitFor('dismissed', () => latest().status === 'dismissed');
      assert(store(`template/${hex(label)}`), 'the template stays');
      assert.equal(await spawned(), panes, 'dismiss closes no pane');
    }
    console.log(`ok 4 restart: ${ended.status === 'open' ? 'the run finished once' : 'the run waits with its panes; Dismiss ends it and closes nothing'}`);
  }
} finally {
  for (const s of created) {
    try { await c.call('session.attach', {session_id: s, event_scope: 'session'}); await c.call('session.destroy', {session_id: s}); } catch {}
  }
  fs.rmSync(`${LAB}/repo-a`, {recursive: true, force: true});
  fs.rmSync(`${LAB}/repo-b`, {recursive: true, force: true});
}
process.exit(0);
