# Template start engine

Status: the module and controlled recovery tests pass on local Lua 5.5 and Rex
`0.0.1792158932-g88fd41`. The whole-tab Rex layout probe passes on the same Rex
build. The production `hub.spawn_window` adapter and combined UI test are pending.

## Contract

Load `plugins/templates_run.lua` with `dofile` and an absolute path. The module
does no work at load time. Construct it with:

```lua
local engine = module.new({hub = hub, start_tab = start_tab,
  resolve_root = resolve_root, resolve_dir = resolve_dir, changed = changed})
```

- `hub(action, args)` returns the result object or raises an error.
- `resolve_root(path)` returns an existing canonical absolute directory.
- `resolve_dir(root, rel)` returns an existing canonical directory within root.
- `start_tab(request)` starts or reads the same whole-tab operation. It must be
  idempotent by key and reject changed content for that key. It must return a
  current result for a closed tab, without recreating it.
- `changed(run)` is optional. It receives a copy after a committed state change.

The input to `admit` is `{key, template, root, session_id | new_session_name,
placement?}`. The only placement option is `focus={source_window_id}`. It is
copied into every tab request unchanged. Without it the engine requests no focus.
The hub owns the check against the source window and never focuses on late
adoption or replay. The engine must not perform focus as a separate effect.
Template v1 is `{v=1, name, tabs={{title, layout}, ...}}`. A leaf is
`{launch={profile, args?} | {shell=true}, dir, label?}`. A split is
`{direction='horizontal'|'vertical', ratio, before, after}`. These nodes have no
`block` or `split` wrapper. `ratio` is the before share. A directory is `.` or a
relative path without empty, `.` or `..` segments.

The adapter receives `{key, session, title, layout, placement?}`. Each layout leaf contains
`{profile, args?, cwd, label?}` or `{shell=true, cwd, label?}`. Splits keep the
same shape and ratio. The adapter translates this shape to the hub action.
The engine never creates Rex panes directly.

The adapter returns `{status, window_id?, block_ids?, error?}`. Status is `open`,
`pending`, `unknown`, `failed`, or `closed`. `open` requires a window ID.
Only `open` advances to the next tab. The engine preserves earlier results on
failure. It never rolls back or creates a replacement for a closed result.

`admit` returns the durable run. Repeating an identical admission returns that
run, even when its directories no longer exist. Changed content fails with
`operation_conflict`. Admission freezes the request, canonical directories and
tab layouts before any resource creation. The session-bound tab request commits
before dispatch. All retries use the recorded request and key.

`get(id)` returns the durable run. Status is `queued`, `starting`, `pending`,
`unknown`, `blocked`, `open`, `failed`, `closed`, or `dismissed`. `results` contains each tab's
latest result. `next_tab` is the first incomplete tab. `blocked` means a call
failed or returned an invalid result; it does not prove that no resource exists.

`dismiss(id)` accepts only pending, unknown or blocked runs and sets `dismissed`
with a revision check. Repeating it returns the same result. It preserves all
requests and results and closes no pane. A request already sent to Rex can still
finish. A dismissed run never schedules more work, including after a restart or
same-key admission. Dismiss is not cancellation of a Rex operation.

`resume()` requests a paged scan after plugin registration. `wake()` requests the
same scan on worker changes, reconnect, or explicit retry. Repeated wakes coalesce
while a scan runs. `tick()` advances
one scan page or one run phase and returns `(more, error)`. Schedule ticks outside
the action handler. Use worker events to call `wake`. No coroutine crosses a
callback. An unknown or pending tab waits for a wake and can only be queried with
its same key. Blocked runs retry after a wake or identical `admit`. Failed and
closed runs do not resume. A store failure returns the error and stops scheduling
that run until a wake; its last committed state remains available. A scan error
also stops scheduling the scan. The plugin may use a delayed reconnect retry; it
must not immediately tick again on errors.

Storage keys are `run/<id>`, `run-key/<request key>`, and `run-counter`. Admission
writes all three in one revision-checked batch. The counter produces compact
decimal IDs without relying on floating-point integer precision. Spawn keys use
`templates/<id>/tab/<n>` because user-context hub keys are shared across plugins.

## Verification

Run the controlled tests locally:

```sh
lua spikes/03-ui-framework/tests/templates-run.lua "$PWD/spikes/03-ui-framework/plugins/templates_run.lua"
```

Run the same suite in an isolated Rex server:

```sh
rex -S unix:///tmp/rexlab-templates-codex/rex.sock --autostart=false do \
  "$PWD/spikes/03-ui-framework/tests/templates-run.lua" --all \
  module="$PWD/spikes/03-ui-framework/plugins/templates_run.lua"
node spikes/03-ui-framework/tests/templates-layout-lab.mjs
```

The sixteen controlled tests cover admission without a side effect, copied inputs,
same-key replay after directory removal, changed-key content, lost admission and
progress replies, no dispatch before commit, plugin restart after a lost spawn
reply, pending ordering, partial failure and closure, session uncertainty, and
directory validation, and waiting for a wake after an unknown result or store
failure, frozen focus intent across restart and retry, and durable dismissal
without resource changes or resumed work. The adapter and store
are controlled fixtures. These tests
do not establish real hub restart behavior or the user interface.
