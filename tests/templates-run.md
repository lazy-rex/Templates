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
`dismissed` with a revision check (`dismissed_from` keeps the earlier status). `op`, the
plugin's operation record, commits in the same batch. Repeating it returns the same result. It preserves all
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
closed runs do not resume. A store failure returns the error and stops scheduling
that run until a wake; its last committed state remains available. A scan error
also stops scheduling the scan. The plugin may use a delayed reconnect retry; it
must not immediately tick again on errors.

Storage keys are `run/<id>`, `run-key/<request key>`, and `run-counter`. Admission
writes all three in one revision-checked batch. The counter produces compact
decimal IDs without relying on floating-point integer precision. Spawn keys use
`templates/<id>/tab/<n>` because user-context hub keys are shared across plugins.

`retry(id, op)` queues a blocked, pending or unknown run again. The queued state and `op` (with
`result = {run_id, woken}`) commit in one batch, so a lost reply loses no retry. Another status
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
- **Batch.** The engine reads `run/<id>`, `run-key/<key>`, `start-form/<hex key>` and
  `switch/<hex key>` fresh. It retires the run only if the run is still eligible and `run-key/<key>`
  names it. Then one batch, with `if_rev` on each record: delete `run/<id>`; write the marker
  `run-key/<key>` = `{id, expired_at, form_rev}`; delete the switch record if it exists. The batch
  is under 4 KiB with the largest keys (an engine case measures it). The `start-form` record is
  not changed. `form_rev` is its rev at the fresh read. Templates writes that record only when it
  is absent, or after its marker expired, so it cannot change while `run-key/<key>` names the live
  run. This holds for the writers of Templates, not for another writer of the store. Hub revisions
  never reset (`hub/cmd/hub/store.go`, `nextRev`).
- **Switch wait.** A user start into a new session has a Start form that switches the app once
  (`switch_app`). The form stays open until that decision. Its run is retired only when the switch
  record has a final state (`done`, `refused` or `unknown`), or when the `start-form` record is at
  least `switch_wait` + 60 s old (the form was closed, or the decision was lost). A missing or
  `attempted` switch record waits for that bound. A `start-form` record without a valid `at` is from
  before the switch: it never switches, so its run is retirable. Agent starts and starts into an
  existing session never switch. A step that must wait is tried again 60 s later, by its timer
  (`switch_settled` in `templates_run.lua`; the plugin gives it as the engine option `retirable`).
  So retirement is eventual: after the bound, and then at the next try.
- **Replay.** An agent replay of a retired key within 30 days: `expired` (same arguments) or
  `operation_conflict` (other arguments). A legacy run without a `start-form` record has a marker
  without `form_rev`: a replay writes a new record and gets `expired`.
  A Start form operation that runs again after its run was retired (a late poll, or the operation
  again after a hub restart) gets the retired run's ID: no new run, no new session, no switch. Its
  fingerprint must match, and the marker's `form_rev` must be the rev of its `start-form` record.
  The 60 s bound is a policy delay, not proof that every poll ended: this replay rule makes a late
  poll safe. Only the user path has it; an agent replay gets `expired`.
- **Expiry.** A marker expires 30 days after `expired_at` (`now - expired_at >= 30 * 86400`). The
  check is on each use, before the fingerprint check: in the agent's alias lookup, in `start_core`
  and in `engine.admit`. A `start-form` record counts as absent only when its marker has expired
  and `form_rev` equals its rev. Then the new start replaces both records (`if_rev`). A legacy
  marker never frees a later record: after 30 days that record decides the fingerprint.
- **Cleanup.** After the first full scan and then every 24 hours, the engine scans `run-key/` and
  queues each expired marker. Each step reads both records fresh and deletes the marker only if it
  is the one the scan saw (`id`, `expired_at`, `form_rev`) and has expired. It deletes the
  `start-form` record only if that record has rev `form_rev`. A reused key keeps its new records.
- **Maintenance.** A tick does its run work first, then at most one maintenance step (a
  retirement, a cleanup scan page or a cleanup batch). A tick that read a run-scan page does none:
  one store scan per tick. A failed step waits 60 s. One timer wakes the pump for the earliest
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

- **Identity.** A template is named by the hex of its storage key (`template/<hex>`), not by
  `value.name`: a record that Templates did not write can have another name inside. The panel row
  ID, the routes and every read use that hex.
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
  first. Then one batch deletes `template/<hex>` with `if_rev` = rev, with no read before it: a
  template replaced after the choice is kept (`conflict`). The fingerprint is
  `delete-ui-v1/` + part(hex) + part(rev), so the same operation key on another route is
  `operation_conflict`. The result is `{close_form = true}`: the hub returns to the panel.
- **Texts.** A displayed name, `saved_by` and title are at most 200 bytes (cut on a UTF-8 boundary,
  with "…"). Each form is checked against the view budget (48 KiB).
- **Cancel.** The renderer's Cancel quits its process (hub `view/menu.go`, `cancelForm`). The tests
  close the form pane (`block.close`) instead. That proves the hub's return to the panel, not a
  keypress in the renderer (untested).
- The agent tool `templates.delete` does not change: it deletes by name, with no confirmation.

## Save form renders

The hub renders every open view of the plugin again after each store commit, each
`hub.ui.invalidate` and each worker change (hub `docs/hub.md`, "Snapshots and invalidation"). A
start makes many of these, so an open Save form renders many times. Each render captures the
source session again: per pane `hub.spawn.spec`, `terminal.process` and `terminal.pwd`, then
`realpath` and `test -d`, and `git rev-parse` for the common root.

- **Request-local dedup.** During one Save form render (`with_dir_memo`), `real_dir` and `git_root`
  check each path once. A failure is not kept. The maps are cleared on every exit, also on an
  error, so each render, `templates.capture` and the submit check again. The scope relies on the
  plugin running its handlers one at a time (LazyRex `docs/rex-protocol.md`, "Rex Lua runtime");
  it is not safe under concurrent handlers. Tests: `tests/save_dedup.lua`.
- **Measured** (lab, Rex 1203 `0.0.1792158932-g88fd41`, hub 6c48bf7): a session of 6 idle shells
  in 3 tabs, in 3 directories of one git repository. One Save render launched 30 processes before
  and 9 after. This count belongs to that fixture: a git root outside the captured directories
  adds work. The start latency results are in the commit review, not here.
- No cache survives a render: the form never shows an older capture than its last render.
## Size bounds

One control message is at most 64 KiB (LazyRex `docs/rex-protocol.md`, "Rex Lua runtime"). The
engine writes a run record whole in one `hub.store.batch`, and the record grows after admission.
Every field that a later write adds has a bound:

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
over 61 KiB with `invalid_input` ("too large to start") and writes nothing then. The other 3 KiB
is the envelope of the largest run write, about 2.5 KB as encoded JSON: the `client.perform`
frame, the record op (`run/<id>`, `if_rev`), and the operation that dismiss or retry commits with
the record. Its key holds an agent ID and a key that can be all `<` (6 bytes each), so it is up
to 1 992 bytes. `tests/engine.lua` measures the largest admitted run in every write (admission, a
state change, dismiss, retry) with a 32-digit run ID and the worst agent ID and key.

The bound applies to new admissions. A run that an older version admitted, larger than 61 KiB,
is not changed: its same-key admission still returns it (no size check comes first), and another
request with its key still conflicts. A repair of such runs is not part of this bound.

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
makes no run, no session and no run-counter change. `start_core` writes the `start-form` record
before admission, so the frozen record stays. It keeps the request, not the refusal: a retry with
the same key compiles that request again, so it gets the same refusal unless the resolved
directories changed in the meantime. Another request with that key gets `operation_conflict`.
Records that exist already, or a template written by another writer, are not checked at save;
admission still applies. Tests: `tests/save_size.lua` and the measure cases in `tests/engine.lua`.

## Verification

`lazyrex-hub test` runs the controlled tests in `tests/engine.lua` (the cases are in
`tests/support/engine_cases.lua`), and the real-hub tests in the other `tests/*.lua` files.

The sixteen original controlled tests cover admission without a side effect, copied inputs,
same-key replay after directory removal, changed-key content, lost admission and
progress replies, no dispatch before commit, plugin restart after a lost spawn
reply, pending ordering, partial failure and closure, session uncertainty, and
directory validation, and waiting for a wake after an unknown result or store
failure, frozen focus intent across restart and retry, and durable dismissal
without resource changes or resumed work. The adapter and store
are controlled fixtures. These tests
do not establish real hub restart behavior or the user interface.
