# Templates: port to the Plugin SDK

Status: **proposed** (2026-10-22). Source: hub branch `hub/sql-contract` at a2a0ece,
`docs/plugin-sdk.md` and `docs/sql.md` (both labeled draft 2). The SDK does not exist yet. Templates
`main` at the time of writing: 47ee2db.

Size before: `templates.lua` 1613 lines, `templates_run.lua` 754 lines (2367); tests 4357 lines.

## 1. What the SDK replaces (deleted from Templates)

| Today | After |
|---|---|
| `hub()` and its error mapping, `client.keymap`, `hub.register`, the `client_perform_requested` dispatch, `client.reply`, the actions list, the exports list | `app.action`, `app.panel`, SDK dispatch |
| `agent_caller`, `hub.identify`, `hub.forward` handling | `ctx.agent` |
| `op_keys`, `prior_op`, `hub.store.op` replay for save, delete, replace, retry, dismiss | the `ops` table with `{store = false}` (permanent replay; coordinator decision, 2026-10-22) |
| `if_rev` reads and `conflict` retries around each `hub.store.batch` | one transaction per handler |
| `scan_all`, `smaller`, the scan paging and `reply_too_large` halving (Store scans) | SQL queries with `ORDER BY` and `LIMIT` |
| `hub.ui.invalidate` after engine writes | table dependencies (section 10 of sql.md) |
| the Save form's re-render on every store commit (item 5) | tracked table dependencies: the Save form render reads no store record today (`save_tree`: capture, `hub.profiles`, `hub.session.list`), so its render must read no table, and a commit must not render it; its submit reads `templates` and `ops`, which is not a render. To measure with `renders()` after the port. |

## 2. What stays

- Capture (Rex calls, `hub.spawn.spec`, `hub.profiles`, the directory checks) and the launch rules.
- The start engine's phases and their durable records. No SQL transaction is held across a pane
  creation (`hub.spawn_window`) or an app switch (`hub.app.select_session`): each phase commits,
  then the external call runs, then the next phase records its result.
- Grants for agent starts (`hub.grant.create` on behalf of the caller, `hub.grant.get`, revoke).
- The view budget checks (48 KiB), the reply bounds of `templates.list`, `templates.runs` and
  `templates.get`, and the save size check (MAX_RUN).
- Behavior that the tests pin: admitted runs and their frozen requests, caller identity, the replay
  of old operations, replacement revisions, switch decisions, retention markers (30 days), and the
  request and reply byte limits.

## 3. Data: hub.store to SQL

This section is the plan. The schema that Templates uses is in `templates_sql.lua` (`SCHEMA`,
migration 1; `SCHEMA_2`, migration 2). "Stage 2" below gives the changes from this plan.

Schema (planned):

```sql
CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);          -- rev counter, run counter, import state
CREATE TABLE templates (hex TEXT PRIMARY KEY, rev INTEGER NOT NULL, value TEXT NOT NULL);   -- JSON
CREATE TABLE runs (id TEXT PRIMARY KEY, rev INTEGER NOT NULL, value TEXT NOT NULL);   -- id: exact decimal text
CREATE TABLE run_keys (key TEXT PRIMARY KEY, rev INTEGER NOT NULL, value TEXT NOT NULL);    -- admission and retention markers
CREATE TABLE start_forms (key TEXT PRIMARY KEY, rev INTEGER NOT NULL, value TEXT NOT NULL); -- frozen Start form requests
CREATE TABLE switches (key TEXT PRIMARY KEY, rev INTEGER NOT NULL, value TEXT NOT NULL);    -- switch decisions
CREATE TABLE ops (key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL);  -- permanent replay
```

- A template keeps the hex of its old storage key as its identity (Panel delete). A record that
  Templates did not write keeps its key and value unchanged (a JSON text, or a blob if it is not
  valid UTF-8).
- Run IDs: `MAX_RUN_ID` allows 32 decimal digits, more than an SQLite INTEGER holds, so an ID is
  exact text. Where numeric order is needed (newest first, retention), the order is by length, then
  by the digits: `ORDER BY length(id), id`.
- Revisions: `rev` comes from one plugin counter in `meta`, which starts above the highest imported
  revision. So a route or an agent `replace` that holds an old revision never matches a newer record.
  Every table whose revision is held outside one transaction keeps `rev`, and the import keeps the
  store revision of each record:
  - `templates.rev`: the delete route (`/forms/delete/<hex>/<rev>`), `templates.get` and `replace`.
  - `start_forms.rev`: a retention marker keeps `form_rev`, the revision of the frozen form record,
    and compares it later (`switch_settled`, the cleanup, `start_core`).
  - `runs.rev`, `run_keys.rev`, `switches.rev`: today they guard read-then-write steps (`if_rev`).
    In a handler transaction the guard is the transaction; the engine steps that span an external
    call (a pane creation, an app switch) still compare the revision that the earlier phase read.
- One-time import, at startup before the plugin serves: a bounded loop over `hub.store.scan` of each
  record prefix (`template/`, `run/`, `run-counter`, `run-key/`, `start-form/`, `switch/`), in steps
  that each commit. `meta.import` records the last key of each prefix, so a crash continues the
  import.
- Operation records: `hub.store.ops_scan` (LazyRex hub/sql-r2 f6f1a03) lists the plugin's saved
  operations. The import copies each operation of a kind that is in SQL into `ops` (key,
  fingerprint and result unchanged). A kind that is still in the store reads `hub.store.op` until
  its slice. No legacy fallback stays after a kind's import.
- Rollback: after the SQL tables take new writes, the old store records are stale. Keeping them
  does not make a rollback safe. A rollback needs a coordinated backup of the hub and plugin files
  (sql.md, "Backup"), or a reverse migration.

## 4. Decisions needed

1. **Replay window: decided** (coordinator, 2026-10-22). Templates keeps its own `ops` table with
   `{store = false}`: a saved operation replays without a time limit, as today. Starts keep their
   own records (run keys and retention markers, 30 days).
2. **Store data after the import:** keep it until one release later (it is not a rollback path:
   section 3), or delete it in the import.

## 5. Order of work

1. This plan (review).
2. Port on the fake `hub.sql` as soon as the SDK's first Lua commit runs; use the raw escape
   (`app.hub`) for each gap in section 6, and shrink it later.
3. Import and its tests: a lab seeded with today's records (every prefix, a foreign record, an
   invalid UTF-8 key, a run near MAX_RUN) imports once, and a restart in the middle continues.
4. Each existing test file stays green. Tests that seed with `write()` or read with `store()` move to
   the SQL test helpers.
5. Report the line count before and after.

## Stage 1

The coordinator split the port into two stages (2026-10-22). Stage 1 moves the registration, the
dispatch, the views and the hub calls to the SDK. The data stays in hub.store, with the Templates
operation replay (`hub.store.op`). Stage 2 moves the data to SQL (sections 3 and 5).

- `lazyrex.json` has `"sdk": "0"`: the hub starts the plugin through the SDK launcher
  (LazyRex 0ae7451 or later).
- Each action and view has `{tx = false, store = false}`. With these options the SDK makes no
  `hub.sql` call and saves no reply. `tests/sdk.lua` checks the complete call record of the plugin.
- An adapter (`boundary`) keeps the error codes of the Templates handlers: a structured error passes
  unchanged, and any other error is `internal`. An error of the SDK itself keeps the SDK code.
- Changes that the SDK brings (reviewed 2026-10-22):
  - An agent can call an export directly. The SDK identifies the agent from the requester PID
    that Rex gives (`hub.identify`). A direct call and a forwarded call of one agent share its
    keys. An unknown peer is refused.
  - The SDK adds a `key` argument to each export. The read-only exports accept and ignore it.
  - The SDK checks the schema of an export first. Some `invalid_input` messages have new text.
    The codes and the limits stay the same.
- Line count: 2384 before (main 8a4cfc9), 2369 after.

Tested: SDK origin/sdk/lua 62dde56 at `sdk/lua` of a LazyRex checkout at 0ae7451 (the launcher;
no `hub.sql`), with `lazyrex-hub test -lazyrex <that checkout>`.

## Stage 2

The coordinator decided the storage design (2026-10-22): domain tables, in bounded slices. A run
keeps its payload as one JSON column first. No generic key-value table, also not for a while. Short
transactions replace the local conflict loops. A revision guard stays only where an external
effect or a held revision needs it, and each guard that stays is listed here with its reason.

### Slice 1: templates, and the save and delete operations

- Tables: `meta`, `templates` and `ops` (`templates_sql.lua`). The engine records (runs, run keys,
  start forms, switches) and the other operation kinds stay in hub.store until their slices.
- Save, the two deletes, list, get, the panel, the forms and the start read and write SQL only.
  `tests/sdk.lua` checks the complete call record: no hub.store call names a template record or a
  save or delete operation.
- Each write is one short transaction: the replay, the read and the write together. So the
  conflicts "saved meanwhile" and "changed; try again" cannot happen any more.
- Revision guards that stay:
  - `templates.save` with `replace`: the agent holds the revision that `templates.get` gave.
  - The Delete confirmation (`/forms/delete/<hex>/<rev>`): the user confirmed that revision.
- Revisions: one counter in `meta`. Its floor is the revision of a store write (`sql-import`) at the
  import, so it is above every revision that the store gave. An imported row keeps its store
  revision, so a held revision of an old record still names it.
- Request size: a hub.sql request carries a JSON value as a string parameter, so the value is
  JSON-encoded twice (observed on Rex 0.0.1792158932-g88fd41: a 60 023-byte record of "&" gave a
  70 271-byte request; the limit is 64 KiB). The row writer measures the complete frame (client ID,
  action, SQL text, every parameter, a 32-digit token) and writes a long value in chunks in the
  same transaction: an INSERT with the first chunk, then `value = value || ?`. A chunk is cut on a
  UTF-8 boundary. The chunk budget (60 KiB) is internal; the record limits do not change.
  - The largest row: a store record is at most one 64 KiB control message as JSON, and a '"' or a
    "\" grows the most as a parameter (2 bytes to 4). So with ordinary metadata (a key of a few
    hundred bytes) the largest row needs 3 chunks, in one transaction within the hub's 10 s
    (tested: 31 000 '"', 2 appends). Metadata that leaves little room gives more, smaller chunks.
  - A row whose key and other parameters alone are over the budget is refused (`too_large`). The
    import stops before that row: its cursor does not pass it, and `import` is not set, so the
    plugin does not serve. The hub starts the plugin again, and the import tries again (tested
    with a 63 000-character key). A key that leaves little room gives many small chunks.
- Import: at the start, after the registration and before the plugin serves (the SDK runs the start
  code in its registration callback, and Rex Lua runs one handler at a time). Each record commits
  with its cursor in one short transaction. An error stops the start, and the hub starts the plugin
  again; the import continues at the cursor. A record that is written again is the same row. The
  store records stay in the store; they are not a rollback path (section 3).
- A call during the import waits until the import ends. Tested with 200 records: the test checks
  that the import has not ended, sends the call, and reads the complete call record (no call
  dropped): the agent's dispatch (`hub.identify`) comes after the import's last write. The hub
  gives a forwarded call 10 s, so a call can time out during a long import (tested with 6000
  records; that test does not check the order). Rex can still deliver it after the import
  (observed in one lab run, not in another). Either way, a retry with the same key answers as one
  save.
- Reads: a read of many rows uses `app.db.each`. Since SDK cf811b5, `app.db.query` gives
  `too_large` for a result that does not fit in one reply. `templates()` reads every row.
  `templates.list` reads at most LIST_MAX + 1 summaries in each query (`tests/list.lua`, "summaries
  over one SQL reply"; `tests/scan.lua` for `templates()`).
- Tests: `tests/import.lua` (every record shape with its exact JSON text and rev, string values,
  the operations, the revision floor, a failed append between two chunks, a failed commit, a lost
  commit reply, the largest row, a key over the budget, a call during the import),
  `tests/delete_confirm.lua` and `tests/replace.lua` (the guards, a lost commit reply and its
  replay). The test helpers `W.twrite` and `W.trow` write and read template rows as another writer
  would.
- Tested: LazyRex hub/sql-lab f413b36 (the launcher, hub.sql, the store fence and
  `hub.admin.sql_return`) with SDK origin/sdk/lua eb9654d at `sdk/lua`; Rex 0.0.1792158932-g88fd41.
  All 24 files pass (Templates 8dc229b). SDK eb9654d: a render reads without a transaction, and a
  write in a render fails. No Templates render writes (the reviewer checked the render paths; the suite
  passes with this refusal).

### Slice 2: the start records, and the dismiss and retry operations

- Tables (migration 2, `SCHEMA_2`): `runs`, `run_keys`, `start_forms`, `switches`; the run counter
  is `meta` `run-counter`. The operations of dismiss and retry go to `ops`. After the import,
  Templates makes no hub.store call (`tests/sdk.lua` checks the complete call record).
- Release 4 keeps the private `ops` and `start_forms` tables, and the plugin keeps its raw views
  (coordinator decision, 2026-10-22). The removal of these tables is decided at slice 4.
- Store records and their rows:

  | hub.store record | SQL row |
  | --- | --- |
  | `run/<id>` `{rev, value}` | `runs (id, ver, status, value)`: `value` is the record value as JSON text, `status` a copy of `value.status`, `ver` a write count that starts at 1. |
  | `run-counter` (decimal text) | `meta` `run-counter` |
  | `run-key/<key>` `{id}` | `run_keys (key, run_id)`, `expired_at` and `form_rev` NULL: the key names its live run. |
  | `run-key/<key>` `{id, expired_at, form_rev?}` | `run_keys` with `expired_at`; `form_rev` NULL in a legacy marker. |
  | `start-form/<hex key>` `{fingerprint, request, at?}` | `start_forms (key, rev, fingerprint, request, at)`: the key is the operation key (not hex), `rev` is the store rev, `at` NULL in a legacy form. |
  | `switch/<hex key>` `{state, code?, message?}` | `switches (start_key, state, code, message)` |
  | dismiss and retry operations (`hub.store.ops_scan`) | `ops`, key, fingerprint and result unchanged |

- Import: the steps run in this order, each with its own cursor and done flag in `meta`, so a step
  that a slice 1 import completed does not run again: `template/`, the save and delete
  operations, `import/floor-2` (the revision floor again, above every store rev), the counter,
  `run/`, `run-key/`, `start-form/`, `switch/`, the dismiss and retry operations. A record of a
  shape that Templates did not write refuses the import: the start fails with its key and the
  reason, nothing of that record commits, and the hub starts the plugin again.
- Transactions: admission writes the start form, the run key, the counter and the run in one
  transaction. It reads the run key and the start form again in that transaction: another
  writer that changed them after the first read gives `conflict`. Dismiss, authorize and retry
  read the run and write it with their operation in one transaction. Retire and expire use one
  transaction each.
- Revision guards that stay:
  - `runs.ver`: a step that calls the hub between its read and its write (a pane creation, a
    session check, a grant) writes over the ver that its read gave. Another write wins: the step
    gets `conflict`, and the next wake continues.
  - `start_forms.rev`: a marker's `form_rev` names the form of a retired run.
- Behavior changes:
  - A refused admission (for example "too large to start") leaves no start form. Before, the
    form stayed.
  - The test writer (`W.sql_write`) retries `busy` for up to 5 s: a test write fails at once
    while the plugin holds a transaction.
- Reads: the engine pages its runs (`run_summaries`, SCAN_LIMIT) and the expired markers with
  `app.db.each`. The panel and the run page use SQL queries and counts; the full store scans are
  deleted. A render makes no write.
- Size: a run row is written in chunks (`write_text`); its record bound stays `MAX_RUN`.
  Admission is the largest transaction: at most 15 `hub.sql` calls (`tests/templates-run.md`,
  "Size bounds").
- Rollback: the store records stay as they were before the import. They are a snapshot from
  before the cutover: a run, key, form or operation that SQL got after the import is not in them.
  So `hub.admin.sql_return` to a store version is not lossless: it loses those writes. A safe
  rollback needs the coordinated backup of section 3.
- Tests: `tests/sql_runs.lua` (a lost and a refused admission commit, a lost dismiss reply, a run
  over the frame limit as a parameter, a failed append in a chunked run update, status =
  value.status); `tests/import.lua` (every slice 2 shape after a completed slice 1 import, an
  unsupported record); `tests/switch.lua` (a lost final switch reply); engine cases (the
  admission re-checks: a run key or start form that changes while prepare calls the hub).
  Limit: the admission re-checks are tested only in engine cases. Rex Lua runs one handler at a
  time, so the lab cannot interleave two handlers there, and the test hub has no SQL delay fault.
- Tested: LazyRex hub/sql-lab f413b36 with SDK eb9654d at `sdk/lua`; Rex 0.0.1792158932-g88fd41.
  All 25 files pass (Templates a52ab11).

### Slice 4: options for the table decision (decided: option A)

Release 4 keeps the private tables `ops` and `start_forms` and the raw views (coordinator
decision, 2026-10-22). Slice 4 decides whether they stay. This section compares the options. The
facts come from Templates 59b40b5 and the SDK at 040ee9b (`lazyrex.lua`, `docs/plugin-sdk.md`,
`docs/sql.md` sections 8 and 10). Nothing here is tested unless it says so.

What each table does today:

- `ops`: the saved replies of save, delete (agent and Delete confirmation), dismiss and retry,
  under the caller's key (`<kind>/<part(key)>`, or `<kind>/agent/<part(id)><part(key)>` for each
  ID of an agent). The kind (`save`, `delete`, ...) is part of the key, so one key can name one
  operation of each kind. Templates checks every ID of an agent, and refuses with `conflict` when
  two IDs saved the same key. The fingerprints are semantic:
  - UI save: `save-v2/` + the source session ID + the submitted values in key order
    (`values_fingerprint`).
  - Agent save: `save-agent-v1/` + the canonical arguments (`canon`).
  - Delete confirmation: `delete-ui-v1/` + hex + rev. Dismiss and retry: the kind + the run ID.

  A reply replays without a time limit. Dismiss and retry write their reply in the same
  transaction as the run. No `ops` row expires: there is no size limit and no eviction.
- `run_keys`: the replay of a start. A row names the live run of a start key. When the run is
  retired, the row stays as a marker for 30 days (`MARKER_TTL`); a replay in that time gives
  `expired`. Then the cleanup deletes the marker (`templates_run.lua`, `expire`).
- `start_forms`: the frozen request of a start (fingerprint, request, `at`), under the start's
  key. It is not a reply store. A start answers `{status = 'running'}` while it waits, and the
  hub calls again. Each call reads the frozen request. A UI poll of the Start form after a hub
  restart gives the same run. A UI poll after the run was retired finishes with the retired
  run's ID, with no new start and no switch. An agent replay of the same key works differently:
  in the marker window it gives `expired`, and with changed arguments it gives
  `operation_conflict`. A marker's `form_rev` names the form, and the switch
  wait uses `at` (Retention). A form stays until the cleanup deletes its marker: the cleanup
  deletes the form in the same transaction, only if the form's rev is the marker's `form_rev`. A
  form under a legacy marker (`form_rev` NULL) is not deleted. Starts do not use `ops`.

Option A: keep both tables and the raw views (the release 4 state).

- Deletes nothing. Changes nothing for users or agents.
- Costs: about 40 lines of replay code (`op_keys`, `prior_op`, `saved_op`, the `put_op` calls)
  and the `ops` rows, which have no size limit or eviction.
- Render dependencies: on hub 9db858f, the raw views render again after every SQL commit
  (`main.go:456`). The SDK renders a raw view with read tracking too (`lazyrex.lua:842`:
  `render = a.render`, as for a panel at line 839). So when the hub side of `sql.md` section 10
  is on main (hub 4.1 or 4.2), option A gets the same render dependencies as option C. Untested:
  the raw views also make hub and Rex calls in a render (Save captures the session); section 10
  tracks SQL reads only.

Option B: SDK saved replies (`store = true`) in place of `ops`; `start_forms` stays.

- Deletes the replay code above and the `ops` table. The existing `ops` rows need an explicit
  plan: a migration into the SDK store (an SDK or hub change), or a written policy that drops
  them (old keys then run again once). They do not expire by themselves.
- Changes the guarantee: a retry replays within 7 days and within the last 10 000 keys
  (`sql.md` section 8). After that, the handler runs again. For save, a late retry saves again
  (without `replace`, it gets the name conflict; with it, the rev guard). For delete, it deletes
  again or gets `not_found`. For dismiss and retry, the run state decides. Decision 1 (the replay
  window) chose no time limit; option B reopens it, and needs a new fact or a new user decision.
- Changes the key scope: the SDK key is `a/<part(agent)><part(key)>` or `u/<part(key)>`
  (`lazyrex.lua`, `op_key`). It has no action kind. A key that an agent used for a save and then
  for a delete gives `operation_conflict` (another fingerprint) in place of two operations.
- Blocker: dismiss and retry run with `tx = false` and open their own transactions. With
  `tx = false`, the SDK commits the handler's transactions first, and then saves the reply in a
  new transaction. A lost reply between the two commits runs the handler again: dismiss gives the
  same result, and retry can wake the run twice. Option B cannot cover dismiss and retry until
  the SDK saves the reply in the handler's last commit.
- Questions to check before this option:
  1. Legacy agent IDs: the SDK finds a reply under one of `ctx.aliases` and saves under the
     current ID. Templates refuses two IDs with the same key (`conflict`); the SDK takes the first
     that it finds. Is that difference acceptable?
  2. Fingerprints: for an action, the SDK calls `opts.fingerprint(args)` before the replay check,
     outside the handler's transaction and without `ctx` (`lazyrex.lua:812`). The agent save
     fingerprint uses only the arguments, so it fits. For a view, the SDK computes a fixed
     fingerprint (view ID, context, route, node, input) and has no `fingerprint` option
     (`lazyrex.lua:849`). The UI save fingerprint uses the source session ID and the values, not
     the view ID. Is a conflict on a resubmit from another view acceptable, or does the SDK need a
     view fingerprint option?
  3. The rows: see the `ops` migration above.

Option C: `app.form` and `app.panel` in place of the raw views.

- Gains, independent of render dependencies (option A gets those too, above):
  - The SDK checks the field values (required, select options, unknown fields), so Templates
    can delete its own checks.
  - The SDK renders the standard form (Cancel, the status "Waiting for input").
  - Less view code in Templates: the route parsing, the node building and the action dispatch.
    Proposed, not measured: the size of this gain depends on how much of the Start and Save
    forms needs the advanced surface (`instead`, `after`, `check = false`).
- Costs and blockers:
  - The routes carry values in the path (`/forms/start/<hex>`, `/forms/template/<hex>`,
    `/forms/delete/<hex>/<rev>`). `app.form` matches a route with a query
    (`app.route('/forms/delete', {hex, rev})`), so every route changes. A route change is
    visible to the user: a saved view operation of an old route does not match the new one. The
    coordinator asked to keep the old routes as redirects or aliases. Untested: whether the SDK
    can serve an old path route (a raw `app.view` prefix route that answers `{navigate = ...}`
    is one candidate).
  - Replay: the hub keeps the view operations (`view_ops`), and the SDK fingerprint of a view is
    fixed (above). The Delete confirmation today replays from `ops` with its own fingerprint
    (`delete-ui-v1/`). A move to `app.form` must keep one replay per operation key; the plan for
    each view must say which store replays it.
  - The Start form switches the app once (`hub.app.select_session` with `view_id`), shows
    "Starting…" while the run waits, and reads `start_forms` on each call. That needs `instead`,
    `{status = 'running'}` and `ctx.view_id`, which the advanced surface has. It is the largest
    view, and it carries the most tests (switch.lua, starting.lua, retention.lua).
  - The Save form captures the source session at each render (hub and Rex calls). The SDK
    refuses only writes in a render; whether `fields` may make these calls is untested.
  - The panel has paged lists with a byte budget (views.lua, views_huge.lua). `app.ui.list`
    must keep the same budget rules.
- `start_forms` stays in option C: a `running` reply is never saved, so the frozen request needs
  a table of its own either way.

Decision (coordinator, 2026-10-22; vault decision "LazyRex Templates slice 4 keeps raw views and
defers app.form, replacing the view-by-view port"): option A with the hub read tracking.

- Keep the raw views and the tables `ops` and `start_forms`. The render dependencies come from the
  hub read tracking (hub 4.1). Verify them in a lab when hub 4.1 is on main.
- Option C is not planned. A later proposal can take one view, only if its own gains (above)
  clearly pay for the route change.
- Option B stays deferred: it reopens decision 1, and the `tx = false` reply gap blocks it for
  dismiss and retry.
- The comparison above was the input to this decision. Render dependencies do not separate A
  from C: both get them from the hub read tracking.

## 6. SDK gaps (sent 2026-10-22)

The coordinator reports that the SDK v0 surface covers forms and routes (`app.view`), structured
errors, `app.on`/`after`/`every` with transactions, `app.db.transaction`, `app.refresh`,
`ctx.requester_pid` and the raw `app.hub` (for the import). Sent to the SDK author as still open:
long view actions (`running`, `view_id`, `operation_key`) and test seeding of SQL rows. The full
list as sent:


- **Forms.** Templates has forms, not only a panel: routes with parameters (`/forms/start/<hex>`,
  `/forms/template/<hex>`, `/forms/delete/<hex>/<rev>`), fields (text, select), a submit with an
  operation key, results with effects (`close_form`, `panel`, `form`), and a cancel node.
- **A long action.** The Start form answers `{status = 'running'}` and the hub calls it again until
  it ends. The handler needs `view_id`, and it calls `hub.app.select_session`.
- **Structured errors.** Templates replies codes (`conflict`, `invalid_input`, `operation_conflict`,
  `expired`, `too_large`, `not_found`, `refused`). The page has only `error('text')`.
- **Transactions outside handlers.** The engine runs from timers (`rex.after`) and from
  `hub.changed {what = workers}`. It needs an atomic multi-statement write there (for example the
  admission: the run, the counter and the key marker together).
- **Hub events.** `hub.changed` (workers) wakes the engine.
- **Agent identity for grants.** `hub.grant.create {on_behalf}` needs the caller's pid, not only
  `ctx.agent`.
- **Explicit invalidate.** The Start form's waiting state is in memory; it needs
  `hub.ui.invalidate {routes}`.
- **Test helpers.** Seed and read SQL rows from a test, as `write()` and `store()` do today.
