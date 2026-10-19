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
