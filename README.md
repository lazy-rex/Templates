# Templates

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Session templates: a named group of tabs and panes that starts together, in a new session or an existing one.

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

`tests/templates-lab.mjs` is a Node test that has no Lua replacement yet. It uses `../LazyRex`
(the client library in `lib/` and the lab harness in `lab/`). Start an isolated lab server first,
and never point it at your own Rex server:

```sh
../LazyRex/lab/server.sh /tmp/rexlab
REX_SERVER=unix:///tmp/rexlab/rex.sock node tests/templates-lab.mjs
```
