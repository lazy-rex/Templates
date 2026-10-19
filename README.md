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
2. Put a hub binary at `$TEMPLATES_LAB/hub` and its config at `$TEMPLATES_LAB/hub.json`
   (see LazyRex `hub.example.json`).
3. In the config, set these fields. The hub refuses a config without `server`, `state` and
   `agents`:
   - `server`: the lab socket, `unix:///tmp/rexlab-templates-<name>/rex.sock`. The hub reads the
     server only from its config, not from `REX_SERVER`.
   - `state`: `$TEMPLATES_LAB/hubstate`.
   - `agents`: at least one agent, for example `[{"id": "user", "name": "User"}]`.
   - `view`: the renderer (`lazyrex-view`).
   - `plugins`: `lazyrex`, and `templates` with `"events": "all"`.
   - `profiles`: a profiles file (step 4).
4. Write a profiles file that defines `server` and `watcher`. The `server` profile has the arg
   `port` (default `3000`) and must print `server <port>`, because the test waits for
   `server 3000`. `tests/profiles.json` prints `serving on <port>` for the Lua tests, so it does
   not match. For example:

   ```json
   {"profiles": [
    {"id": "server", "name": "Server", "kind": "accessory", "command": ["/bin/sh", "-c", "echo server $1; exec sleep 100000", "server", "${port}"],
     "args": [{"name": "port", "default": "3000"}]},
    {"id": "watcher", "name": "Watcher", "kind": "accessory", "command": ["/bin/sleep", "100000"]}
   ]}
   ```
5. Start the hub from `$TEMPLATES_LAB`: `./hub -config hub.json`. Set `REX_SERVER` to the lab
   socket in its environment, and unset `REX_SESSION` and `REX_BLOCK`. The test starts the hub
   the same way when it restarts it.
   The test needs `sqlite3` to read `$TEMPLATES_LAB/hubstate/hub.db`.

Then run:

```sh
TEMPLATES_LAB=/tmp/rexlab-templates-<name> node tests/templates-lab.mjs
```

With `TEMPLATES_RESTART=1`, the test also kills the lab hub after a start is admitted (only a hub
whose command is `$TEMPLATES_LAB/hub`) and starts it again with `-config $TEMPLATES_LAB/hub.json`.
