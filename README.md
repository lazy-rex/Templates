# Templates

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Save the tabs of a Rex session as a
template, and start the same tabs and panes again later, in any checkout of your project. A start
goes into a new session or into an open one.

## Get it

LazyRex setup installs Templates with the other core plugins. To add it by hand, add an entry to
the `plugins` list of the hub config:

```json
{"source": "/path/to/Templates"}
```

The source is the plugin directory. Templates uses the LazyRex Plugin SDK (`"sdk": "0"` in
`lazyrex.json`). It needs LazyRex hub v0.5.0-rc.1 or later (the base migration step of the SDK).

## Palette commands

- **LazyRex: Save as Template…** saves the tabs of this session as a template.
- **LazyRex: Start Session…** starts a saved template in a directory.
- **LazyRex: Templates…** opens a panel with the saved templates and the recent starts.

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
   LazyRex started from a profile has that profile already. A pane whose idle shell Templates
   recognizes has **Shell**. Other panes need your choice: a pane that runs another program, and
   a pane whose shell runs under a login wrapper.
5. Choose **Save template**.

Floating panes and LazyRex's own panes (its forms and panels) are not saved.

### Start a template

1. Run **Start Session…** from the palette.
2. Choose the template and the root directory.
3. For **Session**, choose **New session…** (with an optional name; the default is the template's
   name), or an open session to add the tabs to.
4. Choose **Start session**. The tabs open one after another. For a new session, the app tries to
   switch to it when its first tab opens. If it cannot, **Templates…** says why: use Go to
   Session in the Rex app.

You can also open **Templates…** from the palette, choose a template, and choose
**Start session…**.

### Replace a template

Save again with the same name, and set **If a template has this name** to **Replace it**. The
default, **Keep it**, refuses the save, so you cannot overwrite a template by accident.

### Delete a template

Open **Templates…**, choose the template, and choose **Delete…**. A confirmation shows the
template. If the template changed after you chose Delete, nothing is deleted.

### Follow a start

**Templates…** also lists the recent starts. A start that cannot go on is unfinished:

- A blocked start shows **Retry** and **Dismiss**.
- A pending, unknown or authorizing start shows **Dismiss**.

A tab that fails ends the start with the status failed. A failed start has no actions. Dismiss
opens no more tabs. It does not close the panes that are open.

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
| `templates.retry` | Tries a blocked start again. |
| `templates.dismiss` | Ends a pending, unknown, blocked or authorizing start. It opens no more tabs. The panes and the session that are open stay. |
| `templates.delete` | Deletes a template by name, with no confirmation. |

Each action that changes something takes a `key`. A retry with the same key and the same
arguments returns the first result and does not act twice. One exception: Templates removes a
finished start when 200 newer eligible starts exist (see "Retention"). For 30 days after that, an
agent that sends the key again gets `expired`. After 30 days, the key starts a new start.

## Settings

Plugin args (hub config `plugins[].args`):

- `switch_wait` (default 15 seconds): how long a Start form start into a new session waits for
  its first tab before the app switch gives up.
- `switch_grace` (default 60 seconds): the extra time, after `switch_wait`, before Templates can
  remove a finished start whose switch is not decided.
- `retry_delay` (default 60 seconds): the wait before a failed maintenance step runs again.

## Limits

One Rex control message is at most 64 KiB (LazyRex
[Rex Lua runtime](https://github.com/lazy-rex/LazyRex/blob/main/docs/rex-protocol.md#rex-lua-runtime-rex-do)).
That limit applies to each request that the plugin sends. A reply to the hub can be larger: the
SDK sends a reply over `inline_max` (45056 bytes) in parts, up to `max_total` (786432 bytes)
(LazyRex [Reply parts](https://github.com/lazy-rex/LazyRex/blob/main/docs/hub.md#reply-parts)). Templates keeps its own size limits for
these views and agent outputs:

- A template name is at most 60 bytes.
- The panel and the Start form are at most 48 KiB each. The panel keeps the switch notice first,
  then the stuck starts
  (blocked, pending, unknown and authorizing: the starts with Retry or Dismiss), then the
  templates, then the 10 newest other starts (queued and starting starts are in this list). The
  Start form keeps the template options first, then the root default, then the sessions. A line
  counts what does not fit and names the agent tool that shows it (`templates.runs`,
  `templates.list` or `templates.start`).
- `templates.runs` and `templates.list` give pages of at most 40 KiB. `templates.list` gives a
  summary of each template; `templates.get` gives one template, at most 60 KiB.
- A template name is the cursor of `templates.list`. A record that is not from Templates, with a
  key that is not hex, a name that is not valid UTF-8, or a name over 8 KiB as JSON, stops the
  list: the page before it ends, and the next page gives `too_large`. Templates does not delete
  such a record.
- Save refuses a template that is too large to start at its root (`invalid_input`). A start
  at another root, with a longer encoded root, session name or folder, can still be refused at
  start. Details: `tests/templates-run.md`, "Save size".
- The Save as Template form has no size limit (not implemented).
- A save keeps a template with the same name. To replace it, choose "Replace it" in the Save
  form, or pass `replace` (the `rev` from `templates.get`) to `templates.save`. Details:
  `tests/templates-run.md`, "Replace".
- A template row in the panel opens a menu (Start session…, Delete…). Delete asks for a
  confirmation and deletes only the revision that you chose. A row with a name over about 500
  bytes has no action: use `templates.get` or `templates.delete`. Details: `tests/templates-run.md`,
  "Panel delete".

## Known issue: an open Save form slows starts (open)

While a Save as Template form is open, a start is slower. The hub renders the open form again
after changes, and each render reads the source session again. A Save render checks each
directory once (`tests/templates-run.md`, "Save form renders"). In one measurement, a start took
2.1 times as long.

## Retention

Templates keeps every unfinished start and every finished start that is not eligible. It removes
an eligible finished start when 200 newer eligible starts exist. Eligible: finished, no grant revoke owed, and a user start or an agent
start with a recorded grant. A start from the Start form into a new session is removed only after
its app switch is decided, or `switch_wait` + `switch_grace` (75 seconds with the defaults) after
the submit: removal is eventual. A replay
of a removed start's key within 30 days of the removal gives `expired`; after 30 days the key starts
a new start. A Start form that runs again after its start was removed gets that start's ID, with no
new start and no switch. Details: `tests/templates-run.md`, "Retention".

## Tests

The tests are Lua files in `tests/`. `lazyrex-hub test` runs them in its own lab Rex server
(LazyRex [docs/testing.md](https://github.com/lazy-rex/LazyRex/blob/main/docs/testing.md#run)).
Run them from the Templates directory, with `lazyrex-hub` on `PATH`:

```sh
lazyrex-hub test
```

`lazyrex-hub test` needs a LazyRex checkout: `-lazyrex <dir>`, `LAZYREX_DIR`, or `../LazyRex` beside
the plugin directory. The `test` field of `lazyrex.json` configures the tests.
