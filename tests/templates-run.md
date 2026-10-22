# Template start engine

Status: the controlled engine tests (`tests/engine.lua`) and the real-hub tests in `tests/*.lua`
pass under `lazyrex-hub test`. The Rex layout contract under `hub.spawn_window` is in
`tests/start.lua`.

## Contract

Load `templates_run.lua` (beside `templates.lua`) with `dofile` and an absolute path. The
module does no work at load time. Construct it with:

```lua
local engine = module.new({hub = hub, start_tab = start_tab,
  resolve_root = resolve_root, resolve_dir = resolve_dir, changed = changed,
  find_grant = find_grant, revoke = revoke, log = log})
```

- `hub(action, args)` returns the result object or raises an error.
- `resolve_root(path)` returns an existing canonical absolute directory.
- `resolve_dir(root, rel)` returns an existing canonical directory within root.
- `start_tab(request)` starts or reads the same whole-tab operation. It must be
  idempotent by key and reject changed content for that key. It must return a
  current result for a closed tab, without recreating it.
- `changed(run)` is optional. It receives a copy after a committed state change.
- `find_grant(run)` is optional. It returns the grant ID of an agent's run, or nil. It never
  creates a grant ("Agent starts and grants").
- `revoke(grant_id)` is optional. It revokes a grant. An error leaves the revoke owed.
- `log(line)` is optional. It receives the full text of an error that the run stores bounded.

The input to `admit` is `{key, template, root, session_id | new_session_name,
placement?, by?}`. `by` is the agent ID of an agent's start; a user's start has no `by`. The only placement option is `focus={source_window_id}`. It is
copied into every tab request unchanged. Without it the engine requests no focus.
The hub owns the check against the source window and never focuses on late
adoption or replay. The engine must not perform focus as a separate effect.
Template v1 is `{v=1, name, tabs={{title, layout}, ...}}`. A leaf is
`{launch={profile, args?} | {shell=true}, dir, label?}`. A split is
`{direction='horizontal'|'vertical', ratio, before, after}`. These nodes have no
`block` or `split` wrapper. `ratio` is the before share. A directory is `.` or a
relative path without empty, `.` or `..` segments.

The adapter receives `{key, session, title, layout, placement?}`. Each layout leaf contains
`{profile, args?, cwd, label?}` or `{shell=true, cwd, label?}`. Splits keep the
same shape and ratio. The adapter translates this shape to the hub action.
The engine never creates Rex panes directly.

The adapter returns `{status, window_id?, block_ids?, error?}`. Status is `open`,
`pending`, `unknown`, `failed`, or `closed`. `open` requires a window ID.
Only `open` advances to the next tab. The engine preserves earlier results on
failure. It never rolls back or creates a replacement for a closed result.

`admit` returns the durable run. Repeating an identical admission returns that
run, even when its directories no longer exist. Changed content fails with
`operation_conflict`. Admission freezes the request, canonical directories and
tab layouts before any resource creation. The session-bound tab request commits
before dispatch. All retries use the recorded request and key.

`get(id)` returns the durable run. Status is `authorizing`, `queued`, `starting`, `pending`,
`unknown`, `blocked`, `open`, `failed`, `closed`, or `dismissed`. `results` contains each tab's
latest result. `next_tab` is the first incomplete tab. `blocked` means a call
failed or returned an invalid result; it does not prove that no resource exists.

`dismiss(id, op?)` accepts only pending, unknown, blocked or authorizing runs and sets
`dismissed` (`dismissed_from` keeps the earlier status). The read of the run, the write and `op`,
the plugin's operation record, are in one transaction with no hub call between them, so no
revision check is needed. Repeating it returns the same result. It preserves all
requests and results and closes no pane. A request already sent to Rex can still
finish. A dismissed run never schedules more work, including after a restart or
same-key admission. Dismiss is not cancellation of a Rex operation.

`resume()` requests a paged scan after plugin registration. `wake()` requests the
same scan on worker changes, reconnect, or explicit retry. Repeated wakes coalesce
while a scan runs. `tick()` advances
one scan page or one run phase and returns `(more, error)`. Schedule ticks outside
the action handler. Use worker events to call `wake`. No coroutine crosses a
callback. An unknown or pending tab waits for a wake and can only be queried with
its same key. Blocked runs retry after a wake or identical `admit`. Failed and
closed runs do not resume. A write failure returns the error and stops scheduling
that run until a wake; its last committed state remains available. A scan error
also stops scheduling the scan. The plugin may use a delayed reconnect retry; it
must not immediately tick again on errors.

The start records are SQL rows (`templates_sql.lua`): `runs`, `run_keys`, `start_forms`,
`switches`, and the run counter in `meta`. Admission reads the run key and the start form again,
then writes the start form, the run key, the counter and the run in one transaction. A refused
commit leaves none of them. A step that calls the hub between its read and its write (a pane
creation, a session check) writes over the run's `ver`, the write count that its read gave. The
counter produces compact decimal IDs without relying on floating-point integer precision. Spawn keys use
`templates/<id>/tab/<n>` because user-context hub keys are shared across plugins.

`retry(id, op)` queues a blocked, pending or unknown run again. The queued state and `op` (with
`result = {run_id, woken}`) commit in one transaction, so a lost reply loses no retry. Another status
gives `woken = false`: it keeps the run unchanged and records the operation result. `wake_one(id)` schedules one queued or starting run
(a replayed retry). Dismiss and retry come from the user or any agent (decision "Agents may act on
anything", 2026-10-19); the run keeps its `by` and its grant.

## Agent starts and grants

An agent's start (`by` set) dispatches nothing before it has a grant. A grant is a durable
authority that the hub stores (LazyRex `hub.grant.*`): it lets the plugin send the run's exact
`hub.spawn_window` requests later, as the agent, outside the agent's call.

1. `admit` gives the run status `authorizing`.
2. In the same agent call, the plugin calls `hub.grant.create` with `on_behalf` (the agent's
   requester PID), the key `run/<id>`, and one entry per tab: `{action = 'hub.spawn_window', key,
   request = {session, title, layout}}`. A new session is the reference `{ensure_key}`.
3. `authorize(id, grant_id)` records the grant and queues the run. A run that has another grant
   gives `conflict`. A finished or already authorized run keeps its state.

The dispatch guard is the grant, not the status: `advance` dispatches an agent's run only with
`grant_id` set. Without it, the run waits with the error "The start is not authorized yet; retry
the start with the same key". A wake, resume, retry or same-key admission without a grant
dispatches nothing and creates no session.

Recovery (`find_grant`). A crash between the grant and `authorize` leaves a grant that the run did
not record. The plugin's `find_grant` accepts a grant only when all of these are true:

- It is the grant with the key `run/<id>`. The hub scopes grant keys to the plugin. Only the
  plugin's start path creates this key, in the initial call or a replay with this run's
  operation key. The operation key lookup covers only the identity set (the identity and its
  legacy IDs) of the run's agent.
- It is active.
- Its entries equal the run's requests exactly (canonical encoding).

`find_grant` does not compare the grant's agent with `request.by`. After an identity migration,
`request.by` can keep a legacy ID while the grant belongs to the current identity of the same
agent (coordinator decision, 2026-10-19). `tests/restart.lua` "constructed boundary" covers this
case. A finished agent run without a recorded grant is checked once per engine: a grant that it
finds is recorded and then revoked. Nothing dispatches.

Revoke. When an agent's run is finished (open, failed, closed or dismissed) and has a grant, the
engine revokes the grant after the final state commits, and records `grant_revoked`. A failed
revoke stays owed until a later wake.

## Retention

Decision "Templates retention keeps 200 finished starts and frees their keys after 30 days"
(2026-10-20). Code: `templates_run.lua`, "Retention". Tests: `engine.lua` (the retention cases, with
a controlled clock and timers) and `retention.lua` (through the plugin).

- **Eligible.** A run is eligible when it is finished, owes no revoke, and is a user run or an agent
  run with a recorded grant. Unfinished runs, runs that owe a revoke, and agent runs without a
  recorded grant are kept and not counted.
- **Retired.** A run is retired when at least 200 newer eligible runs exist. The engine keeps the
  eligible run IDs in memory. The first full scan after a plugin start builds the list. After that,
  a run joins when its final state commits with nothing owed, or when its revoke succeeds. So the
  201st eligible run retires the oldest one without a separate wake.
- **Transaction.** One transaction reads the run, its run key, its start form and its switch row.
  It retires the run only if the run is still eligible and the run key names it. Then it deletes
  the run, replaces the run key with the marker `{run_id, expired_at, form_rev}`, and deletes the
  switch row if it exists. The start form is not changed. `form_rev` is its rev at that read.
  Templates writes the start form only when it is absent, or after its marker expired, so it
  cannot change while the run key names the live run. A form rev is unique: `meta` `rev` gives each new
  revision once (`next_rev` in `templates_sql.lua`).
  `tests/engine.lua` retires a run with the largest operation key.
- **Switch wait.** A user start into a new session has a Start form that switches the app once
  (`switch_app`). The form stays open until that decision. Its run is retired only when the switch
  row has a final state (`done`, `refused` or `unknown`), or when the start form is at
  least `switch_wait` + 60 s old (the form was closed, or the decision was lost). A missing or
  `attempted` switch row waits for that bound. Agent starts and starts into an
  existing session never switch. A step that must wait is tried again 60 s later, by its timer
  (`switch_settled` in `templates_run.lua`; the plugin gives it as the engine option `retirable`).
  So retirement is eventual: after the bound, and then at the next try.
- **Replay.** An agent replay of a retired key within 30 days: `expired` (same arguments) or
  `operation_conflict` (other arguments).
  A Start form operation that runs again after its run was retired (a late poll, or the operation
  again after a hub restart) gets the retired run's ID: no new run, no new session, no switch. Its
  fingerprint must match, and the marker's `form_rev` must be the rev of its start form.
  The 60 s bound is a policy delay, not proof that every poll ended: this replay rule makes a late
  poll safe. Only the user path has it; an agent replay gets `expired`.
- **Expiry.** A marker expires 30 days after `expired_at` (`now - expired_at >= 30 * 86400`). The
  check is on each use, before the fingerprint check: in the agent's alias lookup, in `start_core`
  and in `engine.admit`. A start form counts as absent only when its marker has expired
  and `form_rev` equals its rev. Then the new start replaces the form and the run key in the
  admission transaction, which reads both again.
- **Cleanup.** After the first full scan and then every 24 hours, the engine reads a page of
  expired markers (`expired_markers`) and queues each one. Each step reads both rows again in one
  transaction and deletes the marker only if it is the one the page gave (`run_id`, `expired_at`,
  `form_rev`) and has expired. It deletes the start form only if that form has rev `form_rev`. A
  reused key keeps its new rows.
- **Maintenance.** A tick does its run work first, then at most one maintenance step (a
  retirement, a cleanup page or a cleanup step). A tick that read a page of runs does none:
  one page read per tick. A failed step waits 60 s. One timer wakes the pump for the earliest
  step that is not due yet. Each tick sets it again, also a tick that read a scan page: a timer
  for an earlier step can supersede it. A newer timer for an earlier time supersedes an older
  callback (a generation number: `rex.after` has no cancel).
- **UI boundary.** The hub saves a completed view operation and answers a resubmit without a
  call to Templates. A new Start form with the same key is refused by the hub
  (`operation_conflict`). A read hook proves that Templates does not read the record.

## Panel delete

A template row in the Templates panel opens the template menu. One Enter does not delete a
template. Code: `templates.lua`, `menu_view`, `delete_view`, `delete_ui`. Tests:
`tests/delete_confirm.lua`.

- **Identity.** A template is named by the hex of its name: the key of its SQL row
  (`templates.hex`; the old store key was `template/<hex>`), not `value.name`. A record that
  Templates did not write can have another name inside. The panel row ID, the routes and every read
  use that hex.
- **Routes.** The hub opens any form route that starts with `/forms/` (checked in the source of hub
  6c48bf7, and observed with a lab probe on Rex 0.0.1792158932-g88fd41: the route reached render
  and action unchanged). Each route is an exact pattern. Anything else is `invalid_input`, at
  render and at action:
  - `/forms/template/<hex>`: the menu, with Start session… and Delete… (navigation only);
  - `/forms/start/<hex>`: the Start form with that template selected;
  - `/forms/delete/<hex>/<rev>`: the confirmation of the revision of the Delete… choice.

  The hex is the lowercase hex of a name (it round-trips). The rev is 1 to 20 digits, kept as an
  exact string. A route over 1024 bytes is not used: such a row (a name over about 500 bytes) has
  no action and names `templates.get` and `templates.delete`. The agent tools have no such limit.
- **Missing.** A valid route whose record is gone shows "This template no longer exists." (the
  menu and the Start form) or "The template changed or was deleted after you chose Delete." (the
  confirmation), with no submit.
- **Start.** The selected option is reserved before the other options, and it is the default
  value. An option's value is the name of the key. A key whose name is not JSON-safe (for example
  not valid UTF-8) cannot be an option: that Start form says so and has no submit. The form never
  selects another template instead.
- **Delete.** The key and the rev come from the route only. The replay of a saved operation answers
  first. Then one short transaction deletes the row only if its rev is the route's rev, and saves
  the operation. This revision guard stays in SQL because the user confirmed that revision: a
  template replaced after the choice is kept (`conflict`). The fingerprint is
  `delete-ui-v1/` + part(hex) + part(rev), so the same operation key on another route is
  `operation_conflict`. The result is `{close_form = true}`: the hub returns to the panel.
- **Texts.** A displayed name, `saved_by` and title are at most 200 bytes (cut on a UTF-8 boundary,
  with "…"). Each form is checked against the view budget (48 KiB).
- **Cancel.** The renderer's Cancel quits its process (hub `view/menu.go`, `cancelForm`). The tests
  close the form pane (`block.close`) instead. That proves the hub's return to the panel, not a
  keypress in the renderer (untested).
- The agent tool `templates.delete` does not change: it deletes by name, with no confirmation.

## Replace

A save keeps an existing template with the same name (`conflict`), unless the caller chooses to
replace it. Code: `templates.lua`, `save_core`. Tests: `tests/replace.lua`.

- **Agent.** `templates.get` gives `{template, rev}`, both from one record response. `rev` is a
  decimal string. `templates.save` with `replace = rev` replaces exactly that revision: one short
  transaction replaces the row only if its rev is `rev`. This revision guard stays because the agent
  holds the revision that it read. A template that changed or was deleted since gives `conflict`,
  and a name with no record gives `conflict`. `replace` is a canonical nonzero revision (no `0`, no
  leading zero, at most 20 digits), else `invalid_input`.
- **Form.** The field "If a template has this name" is "Keep it (do not save)" (`keep`, the
  default) or "Replace it" (`replace`). It authorizes the replacement of the record as it is at the
  submit, not as it was when the form opened. After the capture and the size check, one short
  transaction reads the template and writes it. So Replace it replaces the template as it is at the
  commit, also one that another writer changed or deleted after the form opened, and Keep it gives
  `conflict` when a template with the name exists at the commit. No change can come between the
  read and the write, so the form has no revision guard. A missing field means `keep`; another value
  is `invalid_input`.
- **Unchanged.** The operation and the template commit in one transaction. A replay answers before the
  capture and every check. An omitted `replace` is not in the agent or the form fingerprint. The
  save size check runs before the write: a refused replacement leaves the old template and its rev. `saved_by` is the new saver.
- **Other features.** A delete confirmation of the old revision gets `conflict` and then shows no
  submit ("Panel delete"). A start that is running keeps its frozen template.

## Save form renders

The hub renders every open view of the plugin again after each SQL commit that writes a table,
each `hub.ui.invalidate` and each worker change (hub `docs/hub.md`, "Snapshots
and invalidation"; for SQL commits: the source of LazyRex f413b36, `sqlsvc.go` calls `kickViews`
after a commit with table marks). A
start makes many of these, so an open Save form renders many times. Each render captures the
source session again: per pane `hub.spawn.spec`, `terminal.process` and `terminal.pwd`, then
`realpath` and `test -d`, and `git rev-parse` for the common root.

- **Request-local dedup.** During one Save form render (`with_dir_memo`), `real_dir` and `git_root`
  check each path once. A failure is not kept. The maps are cleared on every exit, also on an
  error, so each render, `templates.capture` and the submit check again. The scope relies on the
  plugin running its handlers one at a time (LazyRex `docs/rex-protocol.md`, "Rex Lua runtime");
  it is not safe under concurrent handlers. Tests: `tests/save_dedup.lua`.
- **Measured** (lab, Rex 1203 `0.0.1792158932-g88fd41`, hub 6c48bf7): a session of 6 idle shells
  in 3 tabs, in 3 directories of one git repository. One Save render launches 9 processes (30
  without the dedup). This count belongs to that fixture: a git root outside the captured directories
  adds work.
- No cache survives a render: the form never shows an older capture than its last render.
## Start form wait

A start from the Start form into a new session keeps its operation running (`{status = 'running'}`)
until the switch is decided: the first tab opened, the start stopped, or the switch wait
(`switch_wait`) passed. Meanwhile the form shows "Starting…" (`starting[view_id]`, memory only).
The hub calls the action again about every 0.5 s while the result is `running`, whether the form
is open or not (hub `viewsvc.go`, `runOps`).

- A result clears the state. A success opens the panel in the form's place.
- A definite error clears the state and asks for a render, because the hub ends the operation
  (hub `viewsvc.go`, `definiteFailure`). A transient error (`disconnected`, `client_unavailable`,
  `timeout`, `deadline_exceeded`, `unavailable`, `outcome_unknown`) keeps it: the hub runs the
  operation again. Tests: `tests/starting.lua`.
- After a plugin restart, the next call sets the state again; until then the form can render
  without "Starting…" (untested).

## Titles

A save keeps a pane's launch title as the leaf `label` only when the caller of the spawn asked for
that title. The hub records the request: `hub.spawn.spec` gives `requested_title` and
`title_source = 'request'` (LazyRex 03ef95f or later). A resolved title is not saved:

- A spawn without a title gets the profile's name. A save of that pane gives no label, so the next
  start uses the profile's name at that time (a profile renamed after the spawn included).
- An agent spawn without a title gets a generated name ("Bot 1"). The hub counts these names for
  each profile. A save gives no label, so the next start gets a new name, not a copy of the old one.

The label is kept only when the saved launch is the launch that the pane ran:

- `profile:<id>` with the profile of the spawn, or
- `shell` for a pane that LazyRex spawned as a shell (an idle shell, or a busy shell with an
  explicit Shell choice).

Another launch, or Leave out, drops the label. `templates.capture` shows `requested_title` for each
pane that has one. The Save form shows the pane's title in its label: `<tab> · <title>`, and for a
busy shell `<tab> · <title> · running <program>`.

Out of scope: a pane renamed after its spawn keeps its requested title in the save, not the new
name (source review, untested). A plain Rex pane (not spawned by LazyRex) has no spawn spec and
gets no label. A hub before 03ef95f gives no `title_source`; the pane then gets no label (source
review only, untested).

`templates.capture` has no reply byte limit (a gap from before this change). A title is at most 60
characters, so `requested_title` adds at most about 400 bytes of JSON to a pane (6 bytes for each
escaped character).

Tests: `tests/titles.lua` (observed on Rex 0.0.1792158932-g88fd41 with LazyRex 03ef95f).

## Storage

Templates keeps every record in its SQL database (`templates_sql.lua`; LazyRex `docs/sql.md`) and
makes no `hub.store` call (`tests/sdk.lua` checks the complete call record). The tables:

- `meta`: the revision counter (`rev`) and the run counter (`run-counter`).
- `templates (hex, rev, value)`: `hex` is the hex of the name, `value` the template as JSON.
- `ops (key, fingerprint, result)`: the saved replies of save, delete, dismiss and retry.
- `runs`, `run_keys`, `start_forms`, `switches`: the start records ("Contract", "Retention").

Revisions. `next_rev` gives each new revision of `meta` `rev` once; the first write on a new
database gets 1 (`tests/fresh.lua`). A revision guard stays only where a revision is held outside
one transaction (decision "lazyrex Templates SQL transactions replace local conflict retries while
justified revision guards remain"):

- `templates.rev`: `templates.save` with `replace` (the agent holds the rev that `templates.get`
  gave), and the Delete confirmation route (`/forms/delete/<hex>/<rev>`).
- `runs.ver`: an engine step that calls the hub between its read and its write.
- `start_forms.rev`: a retention marker's `form_rev` names the form of its retired run.

Operation replay. A write handler commits its change and its saved reply (an `ops` row) in one
short transaction: a lost reply replays, and a refused commit leaves neither. Save checks the
replay first, captures the session outside the transaction, and then checks the replay again in
the transaction that reads and writes the template (with `replace`, also the held rev). Dismiss
and retry check the replay first; then one transaction reads the run and writes it with the reply
(a reply that another call saved meanwhile replays: `op_exists`). The `ops` key is
`<kind>/<part(key)>`, or `<kind>/agent/<part(id)><part(key)>` for each ID of an agent, so one key
can name one operation of each kind. The fingerprints:

- UI save: `save-v2/` + the source session ID + the submitted values in key order.
- Agent save: `save-agent-v1/` + the canonical arguments (`canon`).
- Delete confirmation: `delete-ui-v1/` + hex + rev. Dismiss and retry: the kind + the run ID.

An omitted `replace` is not in the text of a save fingerprint (agent or form). The other optional
agent arguments are in it with their defaults: `session_id` as false, `panes` as an empty object.

A saved reply replays without a time limit, and no `ops` row expires (decision "lazyrex release 4
keeps private operation tables until SDK replay covers their guarantees"). Starts do not use `ops`:
a start replays from its run key and its start form, because a `running` reply is never saved
(decision "lazyrex Templates keeps start_forms because running replies never save the frozen start
request").

Reads. A read of many rows uses `app.db.each`: `app.db.query` gives `too_large` for a result over
one reply. `templates.list` reads at most LIST_MAX + 1 summaries in each query; the engine reads
its runs and the expired markers in pages of SCAN_LIMIT (`tests/list.lua`, `tests/scan.lua`). A
render makes no write.

## Size bounds

One control message is at most 64 KiB (LazyRex `docs/rex-protocol.md`, "Rex Lua runtime"). A run
is an SQL row. Its value is a JSON parameter, which is encoded once more, so the row writer
(`write_text` in `templates_sql.lua`) writes a long value in chunks of at most `FRAME_MAX` (60 KiB)
per statement, in one transaction. The bound of the record stays `MAX_RUN` (61 KiB as encoded
JSON), and the record grows after admission. Every field that a later write adds has a bound:

| Field | Bound | Longer value |
| --- | --- | --- |
| An error text (`run.error`, a tab result's `error`) | 512 bytes and 1 026 bytes of JSON, control characters replaced with spaces | Cut on a UTF-8 boundary with "…" (within both bounds). The full text goes to the plugin log. |
| A session ID in a start request | 1 to 128 characters of `[A-Za-z0-9.:_-]` | `invalid_input`; nothing is written. |
| A session, window or block ID from the hub | 1 to 128 characters of `[A-Za-z0-9.:_-]` | The result is invalid: the run blocks with a fixed error. |
| A grant ID | 1 to 128 characters of `[A-Za-z0-9.:_-]` | `engine.authorize` refuses it with `invalid_input`. Recovery (`find_grant`) does not record it: the run stays authorizing and dispatches nothing. A finished run records no grant. |
| The block IDs of a tab result | The number of leaves of the tab | The result is invalid. |
| An operation key (agent `key`, UI operation key) | 200 bytes, no control characters | `invalid_input`; nothing is written. |
| An agent ID (the identity and each legacy ID) | 128 bytes, no control characters | `refused`. The plugin refuses the agent if any one of its IDs is outside the bound. It does not drop an ID. |
| A run ID in a dismiss or retry | 32 digits | `not_found`. |
| The run counter at admission | 32 digits | `unavailable` ("The run counter is full"); nothing is written. |

Sizes are encoded JSON as `rex.json.encode` writes them, the encoder that writes the record. It
encodes `<`, `>` and `&` as 6 bytes, as the hub does, and a malformed byte as U+FFFD (3 bytes)
(observed on Rex 0.0.1792158932-g88fd41). A count of the raw bytes is not a bound.

Admission builds the record at its final size with these bounds (every tab request and result,
the IDs and an error at their maximum) and measures it with `rex.json.encode`. It refuses a run
over 61 KiB with `invalid_input` ("too large to start") and writes nothing then.
`tests/engine.lua` measures the largest admitted run at its final size with a 32-digit run ID.
The row writer measures each statement as its complete frame (client ID, action, SQL text, every
parameter, the transaction token), so the frame limit does not depend on the record bound. As a
parameter, a value of at most `MAX_RUN` is at most twice that size, so at most 3 chunks.
`tests/sql_runs.lua` opens a run that is over the frame limit as a parameter.

Admission is the largest transaction: at most 15 `hub.sql` calls (3 reads; the start form, the
run key, the counter and the run, with their chunks) and no other hub call. The hub ends a
transaction 5 s after its last call or 10 s after its start (LazyRex `docs/sql.md`). The count
bounds the calls, not their time: on a slow host the commit can fail with `tx_expired`, and then
nothing is committed (`tests/sql_runs.lua` refuses the commit to check that state).

The bound applies to admissions of new runs. A replay checks no size: the same-key admission of
a run larger than 61 KiB returns it, and another request with its key conflicts.

Measured on a lab hub (tests/limits.lua): a run record is about 3 times its template. A template
of 18 KB in one tab opens on both paths; one of 20 KB in one tab of two panes is refused on both
paths. The user path and the agent path always have the same outcome.

### Save size

A run record holds its template about three times, so a template that its save accepts could be
too large to start. Save (`save_core`, both paths) measures four reference starts of the new
template at the save's resolved root R with `engine.measure`. Each reference is a valid request,
built as `op_keys` builds the key:

- a user start into a new session and into an existing session: the key `start/` + part(MAX_KEY
  of `<`), and `placement.focus.source_window_id` of MAX_ID bytes;
- an agent start into a new session and into an existing session: the key `start/agent/` +
  part(MAX_ID of `<`) + part(MAX_KEY of `<`), and `by` of MAX_ID of `<`;
- a new session named as the template; an existing session ID of MAX_ID bytes; the template
  without `saved_by` (as `start_core`); the raw and the resolved root both R.

`engine.measure` runs admission's validation and compile, and builds the same final record with a
run ID of 32 digits. It reads no record and writes nothing. Admission measures with the actual run
ID, as before. Save refuses the template with `invalid_input` when the largest reference is over
MAX_RUN. The check comes after the replay of a saved save operation and before the only write, so
a refused save writes no template and no operation.

The guarantee covers the size check only, for valid start inputs and the same template content.
Let J(s) be the length of `rex.json.encode(s)`, cwd_i the resolved directory of leaf i at the save,
and N the template name. Save accepts the template. Then a start passes admission's size check
when all of these hold:

- (a) J(raw root) <= J(R) and J(resolved root) <= J(R);
- (b) for each leaf i, J(resolved directory of leaf i at the start) <= J(cwd_i);
- (c) for a new session, J(new_session_name) <= J(N);
- (d) with a placement, J(source_window_id) <= MAX_ID + 2.

The key, the agent ID, `by` and the run ID are always within the reference bounds. Each variable
value is a whole JSON string in the final record, and the object keys are fixed, so the size is a
fixed part plus the sum of J of the variable strings. (b) is a separate condition: a shorter root
does not imply it, because a relative symlink can resolve to another suffix at another root.

A start that breaks a condition can still get "too large to start" at admission. That refusal
makes no run, no session, no run-counter change and no start form: admission writes the start
form in its own transaction. A retry with the same key compiles its request again, so it gets the
same refusal unless the resolved directories changed in the meantime.
Records that exist already, or a template written by another writer, are not checked at save;
admission still applies. Tests: `tests/save_size.lua` and the measure cases in `tests/engine.lua`.

## Render inputs

On the released hub (v0.4.1), each SQL commit of the plugin renders every open view again. Hub
main d912148 (not released; planned for hub 4.2) tracks reads by default: it renders a view again
after a write to a table that its render read, after its own action, and after `app.refresh()`.
There the SDK makes a render broad (each SQL commit renders it again) when the render calls Rex,
reads files or runs a subprocess, makes a hub call other than an SQL query, or has a failed hub
call. A Lua value that a render shows needs `app.refresh()` when it changes (LazyRex
`docs/plugin-sdk.md` on hub main). This list gives the inputs of each view outside SQL (read in
source):

- Panel (`/panels/templates`): templates, runs, run counts and switches from SQL. Outside SQL:
  `HOME` only (`short`), which does not change while the plugin runs.
- Template menu (`/forms/template/<hex>`) and Delete confirmation (`/forms/delete/<hex>/<rev>`):
  the template row from SQL only.
- Start form (`/forms/start`, `start_view`):
  - Always: the Lua table `starting[view_id]` (the "Starting…" state). Each change of `starting`
    calls `hub.ui.invalidate` (set in `start_poll`; cleared after a definite error in
    `start_session`), or closes the form (cleared before the `done` result).
  - The early paths return before any other input: a named template that is missing or has an
    unusable name, an empty template list, the fixed tree over the budget (`too_large_view`), a
    selected template option that does not fit, and no usable template option. They read SQL and
    `starting` only.
  - The normal path also reads the source pane (`source_dir`: Rex `terminal.process` and
    `terminal.pwd` through `pane_dir`, the file system through `realpath` and `test -d`, and the
    git root through a `git` subprocess) and calls `hub.session.list`.
- Save form (`/forms/save`, `save_tree`): reads no table.
  - `capture`: Rex `session.attach`, `session.view`, `session.list_blocks` and
    `terminal.process`; `hub.spawn.spec` for each kept pane; `pane_dir` (Rex `terminal.pwd`, the
    file system); `is_shell` (`SHELL`).
  - With panes, `save_fields`: `hub.profiles` (caught with `pcall`), `common_root` (git and the
    file system) and `short` (`HOME`); and `session_label` (`hub.session.list`).

## Verification

`lazyrex-hub test` runs the controlled tests in `tests/engine.lua` (the cases are in
`tests/support/engine_cases.lua`), and the real-hub tests in the other `tests/*.lua` files.

The controlled tests cover admission without a side effect, copied inputs,
same-key replay after directory removal, changed-key content, lost admission and
progress replies, no dispatch before commit, plugin restart after a lost spawn
reply, pending ordering, partial failure and closure, session uncertainty, and
directory validation, and waiting for a wake after an unknown result or store
failure, frozen focus intent across restart and retry, and durable dismissal
without resource changes or resumed work. The adapter and store
are controlled fixtures. These tests
do not establish real hub restart behavior or the user interface.
