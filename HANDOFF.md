# Handoff: Templates (2026-10-19)

## State

- `origin/main` is `ab6bcb5`. The reviewer gave final approval with LazyRex `c9b3e0d`. The coordinator pushed it.
- The live hub runs a release clone of Templates at `ab6bcb5`. A push to `main` does not deploy. A release needs the user's approval, through the coordinator.
- Branch `harness` is `main` plus this file. It has no other unpushed commits.
- The local branch `main` in the first checkout is old (`bc2ce65`). Update it with `git pull` before you use it.
- LazyRex branch `templates` has no work of its own. Its harness changes are on LazyRex `main`: `hub:restart`, fake apps, inject `updates`, `skip` and `cancel_injection`, the window hold, and the restart fix.

## Done

- The Node tests are ported to `tests/*.lua` and removed. The coverage maps are in the messages of commits `eb753bb` and `ab6bcb5`.
- Agent parity: every action has `tool=` or `user_only`. The parity sweep passes.
- An agent may delete, dismiss and retry any template or run (`6050916`, the user's decision of 2026-10-19).
- The engine contract, grants and size bounds are in `tests/templates-run.md`.

## Decisions to keep

- `find_grant` accepts a grant only with these properties: the plugin key `run/<id>`, active, and exactly equal entries. It does not compare the grant's agent with `request.by`.
- Size bounds:
  - Admission refuses a run record over 62 KiB.
  - Stored errors are cut to 512 bytes.
  - Input IDs are checked before the first write.
- Agent IDs: the identity and each legacy ID are at most 128 bytes, with no control characters. If one ID is outside the bound, the plugin refuses the agent. It does not drop the ID.
- The coordinator records these decisions in LazyRex `docs/decisions.md`.
- A view operation key is bound to its view. A new form with an old key is refused (`operation_conflict`). Do not add a way to submit through a closed view.

## Open items

- No open review conditions.
- Known bugs: none in Templates.
- Two harness defects are fixed on LazyRex `main`:
  - the test view did not attach again after a hub restart;
  - the side-panel askRelease race.
  Before those fixes, `switch.lua` failed sometimes under high load. On `c9b3e0d` it passed 12/12 in 5 runs out of 5.

## How to test

```sh
lazyrex-hub test -lazyrex <LazyRex checkout at main>
```

Build the hub with `go build -o <scratch dir>/lazyrex-hub ./cmd/hub` in LazyRex `hub/`. Do not build into a repository. Never test on the user's real Rex server.

## Next step

None is planned. Start new work from `origin/main`.
