# `pi-mono` Manual Tests

Historical/manual-only note: these tests cover the original `/camlflow-run`
prototype and shell launchers. The supported CamlFlow-owned adapter is now
`packages/camlflow-pi-sdk`, which exposes a typed programmatic API and does not
parse slash-command text.

This document turns the existing `pi-mono` integration docs and launcher scripts
into an operator-ready manual test list.

It is intentionally more concrete than
`docs/pi-mono-integration-testing.md`: for each test, it tells you what to run,
what to type, and what the answer should look like.

Related docs:

- `docs/pi-mono-host-integration-plan.md`
- `docs/pi-mono-implementation-checklist.md`
- `docs/pi-mono-integration-testing.md`
- `packages/camlflow-ts-json-rpc-sdk/test/pi-mono-harness.js`

---

## Automation scaffold

There is now a TypeScript automation scaffold in
`packages/camlflow-ts-json-rpc-sdk/test/` for these checks.

Useful commands from `packages/camlflow-ts-json-rpc-sdk/`:

```sh
npm run doctor:pi-mono
npm run test:pi-mono:launchers
CAMLFLOW_PI_MONO_E2E=1 npm run test:pi-mono
```

Notes:

- `doctor:pi-mono` prints a JSON preflight report for the local `pi-mono`
  setup and, by default, checks whether the current `camlflow` checkout can run
  the CLI
- `test:pi-mono:launchers` is the cheap layer; it validates that the shell
  wrappers build the expected `/camlflow-run ...` commands without requiring a
  working `pi-mono` build
- `test:pi-mono` is the real host layer; it runs `pi` in `--print` mode and is
  opt-in on purpose
- model-backed host tests are further gated behind:
  - `CAMLFLOW_PI_MONO_MODEL_E2E=1`
  - `CAMLFLOW_PI_MONO_PROVIDER=<provider>`
  - `CAMLFLOW_PI_MONO_MODEL=<model>`
- the slower repo-triage test is additionally gated behind
  `CAMLFLOW_PI_MONO_DEEP_E2E=1`

This split is deliberate:

- cheap wrapper checks should be runnable in CI or during local shell-script
  edits
- real host tests should only run when the `pi-mono` checkout, build artifacts,
  and current `camlflow` repo are all ready

---

## What the docs say this integration is

Across the three `pi-mono` docs, the intended integration shape is consistent:

- `pi-mono` stays the host
- CamlFlow stays external and runs as a sidecar through `camlflow serve --stdio`
- `pi-mono` should expose one explicit command surface, currently `/camlflow-run`
- each CamlFlow effect should execute inside an ephemeral `pi` worker session
- progress, diagnostics, and streamed output should surface in the visible `pi`
  UI
- final effect success should come from parsed JSON, not from arbitrary worker
  prose

That means the most important manual checks are:

- pure workflow success
- effectful workflow failure when no model is selected
- effectful workflow success when a model is selected
- structured-output quality for larger workflows
- cancellation safety

---

## What the scripts actually do

The shell wrappers in `scripts/` are thin launchers, not separate runners.

### `scripts/run-pi-mono.sh`

This is the real entrypoint.

It:

- resolves the current `camlflow` repo root
- defaults `PI_MONO_REPO` to `~/projects/pi-mono`
- prefers the current shell OCaml, but falls back to `opam exec --switch 5.4.0
  --` when the shell switch is older than the repo requirement
- requires `pi-test.sh` to exist and be executable
- requires these build artifacts to exist before launch:
  - `packages/ai/dist/index.js`
  - `packages/agent/dist/index.js`
  - `packages/tui/dist/index.js`
- exports `CAMLFLOW_REPO`
- `exec`s `pi-test.sh`

So if this script fails, you are still in launcher/preflight territory. You are
not testing the CamlFlow host integration yet.

If you need to force a specific compatible switch, set
`CAMLFLOW_OPAM_SWITCH=<switch-name>` when launching.

### Convenience launchers

The other scripts only prefill an initial `pi` message:

- `scripts/run-pi-mono-recursion.sh`
- `scripts/run-pi-mono-basic.sh`
- `scripts/run-pi-mono-problem-coach.sh`
- `scripts/run-pi-mono-interview-pipeline.sh`
- `scripts/run-pi-mono-repo-triage.sh`

Each one:

- builds a `/camlflow-run ...` command string
- optionally appends `--skills-dir`
- calls `run-pi-mono.sh`
- passes the prefilled command as the initial message

This matters for testing:

- startup failures belong to `run-pi-mono.sh`
- workflow behavior belongs to `/camlflow-run`
- the convenience scripts should not change workflow semantics

---

## Current local blockers in this worktree

These blockers were observed while preparing this test pack:

- local `camlflow` CLI runs currently fail to build in this checkout because
  `lib/parsing/parsing_lower.ml` is using `constant.pconst_desc`, but the local
  compiler sees `Parsetree.constant` as a non-record type
- local `pi-mono` launcher runs currently stop before startup because
  `~/projects/pi-mono/packages/ai/dist/index.js` is missing

Because of that, the tests below are grounded in repository intent and current
script behavior, but were not fully executed end to end in this worktree.

---

## Test 0: launcher preflight fails clearly

Purpose:
confirm that script failures are actionable before you start debugging the host
integration itself.

Run:

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono.sh --version
```

Expected:

- if `~/projects/pi-mono` is missing, the script should fail immediately with
  `pi-mono repo not found: ...`
- if `pi-test.sh` is missing or not executable, the script should fail with
  `pi-test.sh not found or not executable: ...`
- if the `dist/` builds are missing, the script should fail with
  `Missing pi-mono build artifact: ...`
- the error should tell you what to do next instead of silently exiting

This test validates the launcher only. It does not validate `/camlflow-run`.

---

## Test 1: pure recursion smoke test

Purpose:
prove the command is registered, the sidecar starts, and a pure workflow returns
the final typed result.

Option A: type it manually inside `pi`

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono.sh
```

Then type:

```text
/camlflow-run examples/recursion/main.cml --entry main --input-json 4
```

Option B: use the convenience launcher

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono-recursion.sh
```

Expected result:

- the run succeeds
- the summary shows workflow path `examples/recursion/main.cml`
- the summary shows entry `main`
- `steps` is `0`
- `output` is `10`
- notes should mention the CamlFlow engine path, usually something like
  `dune:/.../camlflow`

Good answer shape:

```text
CamlFlow run complete
workflow: examples/recursion/main.cml
entry: main
steps: 0
output: 10
```

Fail if:

- the command is not recognized
- the run requires a model even though the workflow is pure
- the output is not `10`

---

## Test 2: invalid JSON input is rejected early

Purpose:
make sure bad `/camlflow-run` input fails before ambiguous host behavior.

Run:

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono.sh
```

Then type:

```text
/camlflow-run examples/basic/main.cml --entry main --input-json {bad-json
```

Expected:

- the command fails quickly
- the error is clearly about invalid JSON input
- the run should not appear to reach effect execution

Good answer shape:

```text
Invalid value for --input-json
```

The wording can differ, but the error should be obviously about JSON parsing,
not about model selection or worker-session failure.

---

## Test 3: effectful workflow fails cleanly with no model selected

Purpose:
validate the intended no-model UX.

Option A: type it manually inside `pi`

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono.sh
```

Do not select a model, then type:

```text
/camlflow-run examples/basic/main.cml --entry main --input-json "Ada"
```

Option B: use the convenience launcher

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono-basic.sh
```

Expected:

- `pi` warns before effect execution that no model is selected
- the workflow gets far enough to attempt effect execution
- the run fails cleanly
- the visible message tells the user to run `/model` and then rerun
  `/camlflow-run`

Good answer shape:

```text
No model selected for CamlFlow effect execution.
Use /model, then rerun /camlflow-run.
```

Fail if:

- the workflow hangs
- the failure looks like an internal stack trace with no user guidance
- the pure recursion test from Test 1 also fails in the same state

---

## Test 4: effectful workflow succeeds with a configured model

Purpose:
prove `camlflow/executeEffect` is reaching `pi` and returning parsed JSON.

Run:

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono.sh
```

Inside `pi`:

1. run `/model`
2. choose a working model with valid auth
3. run:

```text
/camlflow-run examples/basic/main.cml --entry main --input-json "Ada"
```

Expected:

- the run starts normally
- effect execution is delegated into a `pi` worker session
- streamed worker text may appear while the effect runs
- the final workflow result succeeds
- the final output is a greeting string for `Ada` ending with `!`

Why this output should look that way:

- `examples/basic/main.cml` binds `agent greeter : name:string -> string`
- `main` appends `!` to the returned greeting

Good answer shape:

```text
output: "Hello, Ada!"
```

The exact greeting text may vary, but it should:

- mention `Ada`
- be a string
- end with `!`

Fail if:

- the visible worker chatter becomes the final typed output
- the final output is not valid JSON/string output for the workflow
- the run works only after manual transcript cleanup

---

## Test 5: problem-coach structured answer

Purpose:
validate a realistic multi-effect workflow with skills and a user-facing output
pack.

Run:

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono-problem-coach.sh
```

The script should prefill something equivalent to:

```text
/camlflow-run examples/problem-coach/main.cml --entry main --input-json '{"problem_name":"two sum","language":{"tag":"Python"},"audience":{"tag":"Interview"},"must_cover":["hash map approach","time complexity","duplicate values edge case"]}' --skills-dir examples/problem-coach/skills
```

Expected:

- the run succeeds with a structured final result
- the result is shaped like `solution_pack`
- the answer is directly useful to a human, not just an internal debug dump

The final JSON should contain these top-level keys:

- `title`
- `answer`
- `code`
- `complexity`
- `edge_cases`
- `pitfalls`
- `next_steps`

Expected content checks:

- `title` references `two sum`
- `answer` explains the hash-map approach
- `code` is Python
- `complexity` mentions linear-time behavior or a similar correct complexity
- `edge_cases` includes duplicate values or equivalent wording
- `pitfalls` and `next_steps` are non-empty lists

Good answer shape:

```json
{
  "title": "Two Sum in Python",
  "answer": "Use a hash map from value to index while scanning once...",
  "code": "def two_sum(nums, target): ...",
  "complexity": "Time O(n), space O(n)",
  "edge_cases": ["duplicate values", "no solution shape if contract changes"],
  "pitfalls": ["overwriting an index too early"],
  "next_steps": ["practice explaining why the map works"]
}
```

Fail if:

- the final answer is mostly agent chatter instead of the packed result
- required fields are missing
- the result ignores the requested language or must-cover items

---

## Test 6: interview-pipeline stress test

Purpose:
validate a larger nested structured result with request normalization, multiple
effects, and reviewer output.

Run:

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono-interview-pipeline.sh
```

The script should prefill something equivalent to:

```text
/camlflow-run examples/interview-pipeline/main.cml --entry main --input-json '{"algorithm_name":"longest increasing subsequence","preferred_language":{"tag":"Python"},"target_difficulty":{"tag":"Hard"},"focus":[{"tag":"Pattern","value":"dynamic programming"},{"tag":"Constraint","value":"n up to 10^5"}]}' --skills-dir examples/interview-pipeline/skills
```

Expected:

- the run succeeds
- the final result is shaped like `report`
- the result contains both solution details and review details

The final JSON should contain these top-level keys:

- `request`
- `solution`
- `edge_cases`
- `review`
- `hints`

Expected content checks:

- `request.algorithm_name` stays `longest increasing subsequence`
- `solution.code` is Python
- `solution.time_complexity` discusses the chosen approach
- `review.approved` is a boolean
- `review.summary` is not empty
- `hints` should be present for `Hard`, likely something about invariants,
  pruning, or failure modes

Good answer shape:

```json
{
  "request": {
    "algorithm_name": "longest increasing subsequence",
    "difficulty_label": "hard"
  },
  "solution": {
    "approach": "patience sorting / DP tradeoff discussion",
    "code": "def lengthOfLIS(nums): ...",
    "time_complexity": "O(n log n)",
    "space_complexity": "O(n)"
  },
  "edge_cases": ["strictly decreasing array", "duplicates"],
  "review": {
    "approved": true,
    "summary": "Approach and complexity claims are coherent",
    "strengths": ["correct optimized approach"],
    "blockers": []
  },
  "hints": "Call out invariants, pruning, and failure modes explicitly."
}
```

Fail if:

- nested JSON is malformed
- `review` disappears into plain prose
- the answer ignores the `Hard` difficulty or the `n up to 10^5` constraint

---

## Test 7: repo-triage power demo

Purpose:
validate the most important `pi-mono` showcase: worker sessions using repo tools
to produce a grounded engineering artifact.

Run:

```sh
cd ~/projects/camlflow
./scripts/run-pi-mono-repo-triage.sh
```

The script should prefill something equivalent to:

```text
/camlflow-run examples/repo-triage/main.cml --entry main --input-json '{"task":"Triage how the pi-mono host integration is wired in this repo and identify the best files to inspect for improving no-model UX, effect streaming, and helper script ergonomics.","suspected_area":"pi-mono host integration docs, scripts, and TypeScript SDK wiring","file_hints":["docs/pi-mono-host-integration-plan.md","docs/pi-mono-implementation-checklist.md","docs/pi-mono-integration-testing.md","packages/camlflow-ts-json-rpc-sdk/src/client.ts","scripts"],"goals":["map the main integration path","identify the highest-value files for a follow-up patch","propose a small validation plan"],"constraints":["ground conclusions in repository evidence","prefer concrete file paths over generic advice","assume the caller wants to test through pi-mono"],"mode":{"tag":"DeepDive"}}' --skills-dir examples/repo-triage/skills
```

Expected:

- the run succeeds with a structured `triage_report`
- the content is grounded in the current repository
- relevant files include actual repo paths, not made-up ones
- findings mention evidence, patch steps, and validation steps

The final JSON should contain these top-level keys:

- `title`
- `summary`
- `relevant_files`
- `findings`
- `root_causes`
- `patch_plan`
- `validation_steps`
- `follow_up_questions`

Expected content checks:

- `relevant_files` should plausibly mention the `docs/pi-mono-*` files and
  `scripts/run-pi-mono*.sh`
- `findings` should sound like repo-grounded observations, not generic advice
- `patch_plan` should name concrete next edits
- `validation_steps` should mention a manual or script-based validation loop

Good answer shape:

```json
{
  "title": "pi-mono integration triage",
  "summary": "The integration path is documented clearly, but script ergonomics and no-model UX are the highest-value follow-up areas.",
  "relevant_files": [
    "docs/pi-mono-integration-testing.md",
    "docs/pi-mono-implementation-checklist.md",
    "scripts/run-pi-mono.sh"
  ],
  "findings": [
    "run-pi-mono.sh performs strict preflight checks before launch",
    "the convenience scripts only prefill /camlflow-run commands"
  ],
  "root_causes": [
    "no-model UX relies on host-side effect preflight",
    "script ergonomics are centralized in shell wrappers"
  ],
  "patch_plan": [
    "tighten no-model messaging",
    "add script-oriented manual tests"
  ],
  "validation_steps": [
    "run recursion, basic no-model, and repo-triage smoke tests"
  ],
  "follow_up_questions": [
    "Should convenience scripts validate JSON quoting more aggressively?"
  ]
}
```

Fail if:

- the answer talks about files that do not exist
- the report is generic and could have been written without reading the repo
- the worker uses tools, but the final report does not preserve concrete paths

---

## Test 8: convenience-script parity

Purpose:
prove that the convenience launchers are only sugar over `/camlflow-run`.

Run each of these:

```sh
./scripts/run-pi-mono-recursion.sh
./scripts/run-pi-mono-basic.sh
./scripts/run-pi-mono-problem-coach.sh
./scripts/run-pi-mono-interview-pipeline.sh
./scripts/run-pi-mono-repo-triage.sh
```

Expected:

- each script prints `Launching pi-mono with initial message:`
- the printed message matches the workflow and defaults in the script
- the workflow result is the same as if you had started `./scripts/run-pi-mono.sh`
  and pasted the same `/camlflow-run ...` command manually

Fail if:

- script launch behavior differs from manual command behavior
- the prefilled command is malformed
- `--skills-dir` is dropped for workflows that need it

---

## Test 9: environment override works

Purpose:
confirm the wrappers are configurable and do not hard-code only one workflow
shape.

Run:

```sh
cd ~/projects/camlflow
CAMLFLOW_WORKFLOW=examples/recursion/main.cml \
CAMLFLOW_ENTRY=main \
CAMLFLOW_INPUT_JSON=5 \
./scripts/run-pi-mono-recursion.sh
```

Expected:

- the printed initial message should include `--input-json 5`
- the workflow output should be `15`

Also test a repo override if needed:

```sh
PI_MONO_REPO=/some/other/pi-mono ./scripts/run-pi-mono.sh --version
```

Expected:

- the launcher should use the override path
- any failure message should reference the override path, not the default path

---

## Test 10: cancellation

Purpose:
confirm cancellation is surfaced as cancellation, not as a generic host error.

Best candidates:

- `./scripts/run-pi-mono-problem-coach.sh`
- `./scripts/run-pi-mono-interview-pipeline.sh`
- `./scripts/run-pi-mono-repo-triage.sh`

Procedure:

1. launch one of the longer workflows
2. wait until visible progress or worker output appears
3. trigger `pi`'s normal abort action

Expected:

- the visible run stops promptly
- the status clears or moves to a cancelled state
- the result is reported as cancelled
- the next run can start normally

Fail if:

- the visible session stays stuck in a running state
- the next `/camlflow-run` fails because prior state leaked
- cancellation is shown as a confusing generic exception

---

## Minimum recommended pass before calling the integration healthy

Run at least:

1. Test 0
2. Test 1
3. Test 3
4. Test 4
5. Test 5
6. Test 7
7. Test 10 after any lifecycle or cancellation change

If only one high-signal demo is needed after the smoke tests, use Test 7. It is
the best current proxy for whether `pi-mono` worker sessions are actually useful
in practice.
