# Templates

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Session templates: a named group of tabs and panes that starts together, in a new session or an existing one.

## Limits

A plugin reply over 64 KiB never arrives (LazyRex `docs/rex-protocol.md`, "Rex Lua runtime"). These
views and agent outputs have a size limit:

- The panel and the Start form are at most 48 KiB each. The panel keeps the stuck starts first
  (blocked, pending, unknown and authorizing: the starts with Retry or Dismiss), then the
  templates, then the 10 newest other starts (queued and starting starts are in this list). The
  Start form keeps the template options first, then the root default, then the sessions. A line
  counts what does not fit and names the agent tool that shows it (`templates.runs`,
  `templates.list` or `templates.start`).
- `templates.runs` and `templates.list` give pages of at most 40 KB. `templates.list` gives a
  summary of each template; `templates.get` gives one template, at most 60 KiB.
- A template name is the cursor of `templates.list`. A record that is not from Templates, with a
  key that is not hex, a name that is not valid UTF-8, or a name over 8 KiB as JSON, stops the
  list: the page before it ends, and the next page gives `too_large`. Templates does not delete
  such a record.
- Save refuses a template that is too large to start at its root (`invalid_input`). A start
  at another root, with a longer encoded root, session name or folder, can still be refused at
  start. Details: `tests/templates-run.md`, "Save size".
- The Save as Template form view has no size limit yet.
- A template row in the panel opens a menu (Start session…, Delete…). Delete asks for a
  confirmation and deletes only the revision that you chose. A row with a name over about 500
  bytes has no action: use `templates.get` or `templates.delete`. Details: `tests/templates-run.md`,
  "Panel delete".

## Known issue: an open Save form slows starts (open)

The hub renders an open Save form again after each store change of the plugin and each worker
change, and a start makes many of these. Each render captures the source session again. A Save
render now checks each directory once (`tests/templates-run.md`, "Save form renders"). The
latency target (a start with the Save form open takes at most twice the time of a start without
it) is not met yet: 2.1 times in a lab run on a loaded host. The Save form will declare its render
dependencies when the hub supports them. A quiet performance run follows that change.

## Retention

Templates keeps every unfinished start and the newest 200 eligible finished starts. An older
finished start is removed. Eligible: finished, no grant revoke owed, and a user start or an agent
start with a recorded grant. A start from the Start form into a new session is removed only after
its app switch is decided, or `switch_wait` + 60 s after the submit: removal is eventual. A replay
of a removed start's key within 30 days of the removal gives `expired`; after 30 days the key starts
a new start. A Start form that runs again after its start was removed gets that start's ID, with no
new start and no switch. A resubmit of a completed Start form returns its saved result from the
hub. Details: `tests/templates-run.md`, "Retention".

## Install

Check this repository out next to LazyRex, and add the plugin to the hub config:

```json
{"name": "templates", "path": "/path/to/Templates/templates.lua"}
```

The plugin loads its other files from its own directory, so keep them together.

## Tests

The tests are Lua files in `tests/`. `lazyrex-hub test` runs them in its own lab Rex server
(LazyRex `docs/testing.md`):

```sh
lazyrex-hub test
```
