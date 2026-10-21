# Templates

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Session templates: a named group of tabs and panes that starts together, in a new session or an existing one.

## Quick start

### What a template is

A template is a named copy of the tabs of a Rex session. Each tab keeps its title and its
layout of panes. Each pane keeps:

- its launch: a LazyRex profile (with the args it ran with), or a shell;
- its directory, relative to the template's root.

When you start a template, you choose a root directory. Each pane starts in the same relative
directory under that root. So one template can start a project in any checkout of it.

### Save a session

1. Open the Rex palette in the session that you want to save, and run **Save as Template…**.
2. Enter a template name. The default is the session's name.
3. Check the root. The default is the git root of the panes, or else their deepest common
   directory. Every pane that you keep must be under the root.
4. For each pane, choose its launch: the profile it ran, **Shell**, or **Leave out**. A pane that
   LazyRex started from a profile has that profile already. A pane with an idle shell has
   **Shell**. A pane that runs another program needs your choice.
5. Choose **Save template**.

Floating panes and LazyRex's own panes (its forms and panels) are not saved.

### Start a template

1. Run **Start Session…** from the palette.
2. Choose the template and the root directory.
3. For **Session**, choose **New session…** (with an optional name; the default is the template's
   name), or an open session to add the tabs to.
4. Choose **Start session**. The tabs open one after another. In a new session, the app goes to that session when
   its first tab opens.

You can also open **Templates…** from the palette, choose a template, and choose
**Start session…**.

### Replace a template

Save again with the same name, and set **If a template has this name** to **Replace it**. The
default, **Keep it**, refuses the save, so you cannot overwrite a template by accident.

### Delete a template

Open **Templates…**, choose the template, and choose **Delete…**. A confirmation shows the
template. If the template changed after you chose Delete, nothing is deleted.

### Follow a start

**Templates…** also lists the recent starts. A start that stopped (for example, a tab that could
not open) shows **Retry** and **Dismiss**.

### What agents can do

An agent that is connected to LazyRex uses these actions (MCP tools):

| Action | What it does |
| --- | --- |
| `templates.list` | Lists the templates, one page at a time. |
| `templates.get` | Gives one template with its tabs, and its `rev`. |
| `templates.capture` | Shows what a save would keep from a session: each pane's directory and launch guess. |
| `templates.save` | Saves a session as a template. To replace a template, pass `replace` with the `rev` from `templates.get`. |
| `templates.start` | Starts a template in a root, in a new session or an open one. The agent owns the panes that it starts. |
| `templates.runs` | Lists the starts and their status. |
| `templates.retry`, `templates.dismiss` | Try a stopped start again, or close it. |
| `templates.delete` | Deletes a template by name, with no confirmation. |

Each action that changes something takes a `key`. A retry with the same key and the same
arguments returns the first result and does not act twice.

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
- A save keeps a template with the same name. To replace it, choose "Replace it" in the Save
  form, or pass `replace` (the `rev` from `templates.get`) to `templates.save`. Details:
  `tests/templates-run.md`, "Replace".
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
