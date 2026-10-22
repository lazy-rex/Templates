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

Schema (version 1):

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
- Tests: `tests/import.lua` (every record shape with its exact JSON text and rev, string values,
  the operations, the revision floor, a failed append between two chunks, a failed commit, a lost
  commit reply, the largest row, a key over the budget, a call during the import),
  `tests/delete_confirm.lua` and `tests/replace.lua` (the guards, a lost commit reply and its
  replay). The test helpers `W.twrite` and `W.trow` write and read template rows as another writer
  would.
- Tested: LazyRex hub/sql-lab f413b36 (the launcher, hub.sql, the store fence and
  `hub.admin.sql_return`) with SDK origin/sdk/lua 42cebcc at `sdk/lua`; Rex 0.0.1792158932-g88fd41.

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
