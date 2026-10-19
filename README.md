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
(the client library in `lib/` and the lab server script in `lab/`). It reads the lab directory from
`TEMPLATES_LAB`, not from `REX_SERVER`. The directory must match `/tmp/rexlab-templates-*`; the
default is `/tmp/rexlab-templates-claude`. Use a directory name that no other lab uses, because the
test changes the hub records in that lab. Never point it at your own Rex server.

The lab server alone is not enough. Before the test, prepare the lab:

1. Start an isolated lab server: `../LazyRex/lab/server.sh /tmp/rexlab-templates-<name>`.
2. Put a hub binary at `$TEMPLATES_LAB/hub` and its config at `$TEMPLATES_LAB/hub.json`.
3. In the config, set `state` to `$TEMPLATES_LAB/hubstate`, and `view` to a renderer
   (`lazyrex-view`).
4. In the config, list the plugins `lazyrex` and `templates`.
5. Set `profiles` to a file that defines `server` (arg `port`, default `3000`) and `watcher`,
   for example `tests/profiles.json`.
6. Start the hub from `$TEMPLATES_LAB` on the lab server, with `REX_SERVER` set to the lab socket.
   The test needs `sqlite3` to read `$TEMPLATES_LAB/hubstate/hub.db`.

Then run:

```sh
TEMPLATES_LAB=/tmp/rexlab-templates-<name> node tests/templates-lab.mjs
```

With `TEMPLATES_RESTART=1`, the test also kills the lab hub after a start is admitted (only a hub
whose command is `$TEMPLATES_LAB/hub`) and starts it again with `-config $TEMPLATES_LAB/hub.json`.
