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

## Size bounds

One control message is at most 64 KiB (LazyRex `docs/rex-protocol.md`, "Rex Lua runtime"). The
engine writes a run record whole in one `hub.store.batch`, and the record grows after admission.
Every field that a later write adds has a bound:

| Field | Bound | Longer value |
| --- | --- | --- |
| An error text (`run.error`, a tab result's `error`) | 512 bytes, control characters replaced with spaces | Cut on a UTF-8 boundary with "…". The full text goes to the plugin log. |
| A session ID in a start request | 1 to 128 characters of `[A-Za-z0-9.:_-]` | `invalid_input`; nothing is written. |
| A session, window or block ID from the hub | 1 to 128 characters of `[A-Za-z0-9.:_-]` | The result is invalid: the run blocks with a fixed error. |
| A grant ID | 1 to 128 characters of `[A-Za-z0-9.:_-]` | `engine.authorize` refuses it with `invalid_input`. Recovery (`find_grant`) does not record it: the run stays authorizing and dispatches nothing. A finished run records no grant. |
| The block IDs of a tab result | The number of leaves of the tab | The result is invalid. |
| An operation key (agent `key`, UI operation key) | 200 bytes, no control characters | `invalid_input`; nothing is written. |
| An agent ID (the identity and each legacy ID) | 128 bytes, no control characters | `refused`. The plugin refuses the agent if any one of its IDs is outside the bound. It does not drop an ID. |
| A run ID in a dismiss or retry | 32 digits | `not_found`. |
| The run counter at admission | 32 digits | `unavailable` ("The run counter is full"); nothing is written. |

Admission computes the record at its final size with these bounds (every tab request and result,
the IDs and an error at their maximum, counted as encoded JSON) and refuses a run over 62 KiB
with `invalid_input` ("too large to start"). It writes nothing then. The other 2 KiB is the envelope of the largest run
write, at most about 1200 bytes as encoded JSON: the `client.perform` frame, the record op
(`run/<id>`, `if_rev`), and the operation that dismiss or retry commits with the record.

Measured on a lab hub (tests/limits.lua): a run record is about 3 times its template. A template
of 18 KB in one tab opens on both paths; one of 20 KB in one tab of two panes is refused on both
paths. The user path and the agent path always have the same outcome.

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
