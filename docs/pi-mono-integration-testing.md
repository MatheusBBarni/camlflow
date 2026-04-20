# `pi-mono` Integration Testing Guide

This document explains how to validate the CamlFlow ↔ `pi-mono` integration from the `camlflow` repo, and how to use the helper scripts in `scripts/`.

Related docs:

- `docs/pi-mono-host-integration-plan.md`
- `docs/pi-mono-implementation-checklist.md`
- `docs/json-rpc.md`

---

## What this integration is supposed to prove

The current `pi-mono` integration should support:

- running pure CamlFlow workflows end to end from `/camlflow-run`
- running effectful CamlFlow workflows through ephemeral `pi` worker sessions
- surfacing CamlFlow progress/errors in the visible `pi` UI
- giving a clear UX when no `pi` model is selected for effect execution

The primary development repo for the integration is:

- `~/projects/pi-mono`

The helper scripts live here:

- `~/projects/camlflow/scripts/`

---

## Prerequisites

Before testing, make sure:

1. `pi-mono` exists locally.
   - default expected path: `~/projects/pi-mono`
   - or set `PI_MONO_REPO=/path/to/pi-mono`

2. The integration branch is checked out in `pi-mono`.
   - expected branch: `feat/pi-mono-integration-path`

3. `pi-mono` dependencies are installed.
   - from `~/projects/pi-mono`: `npm install`

4. `pi-mono` has been built at least once.
   - the helper scripts require these build artifacts to exist:
     - `packages/ai/dist/index.js`
     - `packages/agent/dist/index.js`
     - `packages/tui/dist/index.js`
   - if they are missing, the scripts will stop with a clear error

5. For effectful workflow success tests, `pi` has a configured model/auth.
   - if no model is selected, pure workflows should still run
   - effectful workflows should warn and then fail cleanly

---

## Testing approach

Use a layered approach:

1. **Fast regression tests** in `pi-mono`
2. **Pure workflow smoke test** through `/camlflow-run`
3. **Effectful no-model UX test**
4. **Effectful real-model test**
5. **Optional cancellation test**

This gives faster feedback than relying only on a full manual session.

---

## Recommended showcase workflows

Use these workflows to exercise different parts of the integration:

- `examples/recursion/main.cml`
  - pure baseline
  - fastest end-to-end sanity check
- `examples/basic/main.cml`
  - smallest effectful workflow
  - best for no-model UX validation
- `examples/problem-coach/main.cml`
  - best current user-facing showcase
  - structured answer pack with local skill, bound skill, bound agent, and inline agent
- `examples/interview-pipeline/main.cml`
  - larger multi-step stress test
  - good for status/progress and larger structured outputs
- `examples/repo-triage/main.cml`
  - best current `pi-mono` power demo
  - designed to encourage tool-using worker sessions to inspect the repository and return an actionable engineering triage report

---

## 1. Fast regression tests in `pi-mono`

Run the focused CamlFlow integration test file:

```sh
cd ~/projects/pi-mono/packages/coding-agent
npx vitest --run test/camlflow-integration.test.ts
```

What this currently covers:

- `/camlflow-run` argument parsing
- invalid `--input-json` handling
- JSON extraction from raw output
- JSON extraction from fenced output
- no-model preflight notice
- no-model failure notice
- effect-executor JSON parsing
- effect-executor missing-model failure

Optional extra sanity check:

```sh
cd ~/projects/pi-mono/packages/coding-agent
npx vitest --run test/assistant-message.test.ts
```

### About `npm run check`

You should still run:

```sh
cd ~/projects/pi-mono
npm run check
```

But note that, at the moment, repo-wide `check` is still blocked by unrelated `packages/web-ui` type-resolution errors. That failure is currently known and not caused by the CamlFlow integration.

So during integration work, treat the focused CamlFlow tests plus the manual smoke tests below as the primary signal.

---

## 2. Pure workflow smoke test

Start `pi-mono` against the current `camlflow` repo:

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono.sh
```

Inside `pi`, run:

```text
/camlflow-run examples/recursion/main.cml --entry main --input-json 4
```

Expected result:

- the run completes successfully
- the summary shows the workflow path and entry
- `steps` is `0`
- `output` is `10`
- notes should mention the CamlFlow engine, typically something like `dune:/.../camlflow`

This is the simplest end-to-end proof that:

- the command is registered
- the sidecar starts
- the workflow runs
- the result is returned to `pi`

---

## 3. Effectful workflow test with **no model selected**

This validates the UX and failure path.

Start `pi-mono`:

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono.sh
```

Do **not** select a `pi` model.

Inside `pi`, run:

```text
/camlflow-run examples/basic/main.cml --entry main --input-json "Ada"
```

Expected behavior:

- before the run, `pi` warns that no model is selected
- the run reaches effect execution
- the run fails cleanly with an actionable message
- the visible warning should tell the user to use `/model` and rerun `/camlflow-run`

This is an important regression test because pure workflows should still work in this state, while effectful workflows should fail predictably.

---

## 4. Effectful workflow test with a real configured model

This validates the main end-to-end host behavior.

Start `pi-mono`:

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono.sh
```

Inside `pi`:

1. select a model with `/model`
2. make sure the model has valid auth
3. run:

```text
/camlflow-run examples/basic/main.cml --entry main --input-json "Ada"
```

Expected behavior:

- the run starts normally
- effect execution is delegated into an ephemeral `pi` worker session
- streamed worker text may appear as advisory output chunks
- the final workflow result completes successfully
- the visible transcript should show the CamlFlow summary message

What this proves:

- `camlflow/executeEffect` is reaching `pi`
- worker sessions are being created correctly
- final worker output is parsed back into JSON
- the sidecar/host path works end to end

---

## 5. Optional cancellation test

If you have a sufficiently long-running workflow or effect:

1. start `/camlflow-run`
2. trigger `pi`'s normal abort action

Expected behavior:

- the visible run stops
- the CamlFlow request is cancelled
- any active worker session is aborted too
- the sidecar does not remain stuck in the background

This is a useful manual check after changes in:

- `session.ts`
- `effect-executor.ts`
- cancellation wiring

---

## Helper scripts in `scripts/`

The scripts in `~/projects/camlflow/scripts/` are wrappers for launching your local `pi-mono` clone against the current `camlflow` checkout.

### `scripts/run-pi-mono.sh`

Basic launcher.

Usage:

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono.sh
```

What it does:

- resolves the current `camlflow` repo root
- finds the `pi-mono` repo at `~/projects/pi-mono` by default
- if the current shell switch is older than OCaml `5.4.0`, it re-runs
  `pi-test.sh` through `opam exec --switch 5.4.0 --` when that switch exists
- exports `CAMLFLOW_REPO` so `pi-mono` uses this CamlFlow checkout
- runs `~/projects/pi-mono/pi-test.sh`
- passes all CLI args through to `pi-test.sh`

Examples:

```sh
./scripts/run-pi-mono.sh --version
./scripts/run-pi-mono.sh --no-env
./scripts/run-pi-mono.sh --print "hello"
```

Useful env override:

```sh
PI_MONO_REPO=/some/other/pi-mono ./scripts/run-pi-mono.sh
CAMLFLOW_OPAM_SWITCH=5.4.0 ./scripts/run-pi-mono.sh
```

Failure modes:

- if `pi-mono` is missing, it errors immediately
- if `pi-test.sh` is missing, it errors immediately
- if required build artifacts are missing, it tells you to build `pi-mono` first
- if neither the shell nor the selected opam switch provides OCaml `5.4.0+`, it
  tells you to switch to a compatible toolchain before launch

### `scripts/run-pi-mono-basic.sh`

Convenience launcher for the smallest effectful example.

Usage:

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono-basic.sh
```

Default initial message:

```text
/camlflow-run examples/basic/main.cml --entry main --input-json '"Ada"'
```

### `scripts/run-pi-mono-recursion.sh`

Convenience launcher for the pure recursion smoke test.

Usage:

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono-recursion.sh
```

Default initial message:

```text
/camlflow-run examples/recursion/main.cml --entry main --input-json 4
```

### `scripts/run-pi-mono-problem-coach.sh`

Convenience launcher for the main structured user-facing showcase.

Usage:

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono-problem-coach.sh
```

Default initial message:

```text
/camlflow-run examples/problem-coach/main.cml --entry main --input-json '{ ... }' --skills-dir examples/problem-coach/skills
```

### `scripts/run-pi-mono-interview-pipeline.sh`

Convenience launcher for the larger structured stress test.

Usage:

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono-interview-pipeline.sh
```

Default initial message:

```text
/camlflow-run examples/interview-pipeline/main.cml --entry main --input-json '{ ... }' --skills-dir examples/interview-pipeline/skills
```

### `scripts/run-pi-mono-repo-triage.sh`

Convenience launcher for the repo-inspection power demo.

Usage:

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono-repo-triage.sh
```

Default initial message:

```text
/camlflow-run examples/repo-triage/main.cml --entry main --input-json '{ ... }' --skills-dir examples/repo-triage/skills
```

Why this script matters:

- it is the best current way to see whether `pi-mono` worker sessions use tools well
- it reveals whether the current working directory, streamed output, and final JSON extraction feel good in practice
- it tends to expose the next UX and prompt-quality improvements faster than the smaller demos

### Shared overrides for workflow launcher scripts

The workflow launcher scripts all follow the same pattern:

- build an initial `pi` message for `/camlflow-run`
- launch `pi-mono` through `run-pi-mono.sh`
- open `pi` with the command prefilled as the initial message

Common env overrides:

```sh
CAMLFLOW_WORKFLOW=examples/recursion/main.cml \
CAMLFLOW_ENTRY=main \
CAMLFLOW_INPUT_JSON=4 \
CAMLFLOW_SKILLS_DIR=examples/problem-coach/skills \
./scripts/run-pi-mono-problem-coach.sh
```

Notes:

- extra CLI flags are still forwarded to `run-pi-mono.sh`
- the script only prepares the initial message; it does not bypass normal `pi` startup

---

## Recommended manual test matrix

When changing the integration, run at least this matrix:

### Every time

- focused regression test:
  - `cd ~/projects/pi-mono/packages/coding-agent && npx vitest --run test/camlflow-integration.test.ts`
- pure smoke:
  - `/camlflow-run examples/recursion/main.cml --input-json 4`
- no-model effectful smoke:
  - `/camlflow-run examples/basic/main.cml --input-json "Ada"`

### Before calling the integration healthy

- configured-model effectful smoke
- one script launch through `scripts/run-pi-mono.sh`
- one script launch through `scripts/run-pi-mono-basic.sh`
- one structured demo launch through `scripts/run-pi-mono-problem-coach.sh`
- one repo power-demo launch through `scripts/run-pi-mono-repo-triage.sh`

### After lifecycle/cancellation changes

- repeat one run and abort it manually

---

## Troubleshooting

### Script says `pi-mono repo not found`

Set the repo path explicitly:

```sh
PI_MONO_REPO=/path/to/pi-mono ./scripts/run-pi-mono.sh
```

### Script says `pi-test.sh not found or not executable`

Your `pi-mono` clone is incomplete or not at the expected path.

### Script says `Missing pi-mono build artifact`

The wrapper expects `pi-mono` workspace builds to exist. Build `pi-mono` first, then rerun the script.

### Pure workflows work, effectful ones fail

That usually means no `pi` model is selected, or auth is not configured for the selected model.

### `npm run check` fails in `packages/web-ui`

This is currently a known unrelated issue in the `pi-mono` clone. Use the focused CamlFlow tests plus smoke tests to validate the integration until the repo-wide issue is fixed.
