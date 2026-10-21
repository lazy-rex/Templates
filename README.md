# Templates

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Session templates: a named group of tabs and panes that starts together, in a new session or an existing one.

## Limits

A plugin reply over 64 KiB never arrives (LazyRex `docs/rex-protocol.md`, "Rex Lua runtime"), so
each view and agent output has a size limit:

- The panel and the Start form are at most 48 KiB each. The panel keeps the unfinished starts
  first, then the templates, then the 10 newest other starts. The Start form keeps the template
  options first, then the root default, then the sessions. A line counts what does not fit and
  names the agent tool that shows it (`templates.runs`, `templates.list` or `templates.start`).
- `templates.runs` gives pages of at most 40 KB.

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
