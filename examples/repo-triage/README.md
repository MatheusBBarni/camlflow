# repo-triage example

This example is designed specifically to show what a host like `pi-mono` can do when CamlFlow effect steps are executed inside a tool-using coding agent session.

It is meant to feel more like a real engineering task than the smaller string-only demos.

It exercises:

- multi-file loading (`main.cml`, `types.cml`, `helpers.cml`)
- structured JSON input and output
- local prompt skill (`caveman`)
- bound skill (`search-planner`)
- inline agent investigator with explicit tool-use guidance
- inline agent report packager
- repository-grounded triage output with files, findings, root causes, and patch steps

Files:

- `main.cml`
- `types.cml`
- `helpers.cml`
- `input.json`
- `skills/caveman/SKILL.md`

## Deterministic local run

This validates parsing, typing, module resolution, JSON encoding, and effect
wiring. It does not inspect the repository or call a model. Without a provider,
JSON-RPC host, or Pi worker, CamlFlow uses deterministic placeholder effect
behavior.

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/repo-triage/main.cml \
  --skills examples/repo-triage/skills \
  --input examples/repo-triage/input.json
```

Expected deterministic output is structurally valid but empty:

```text
steps: 4
{
  "title": "",
  "summary": "",
  "relevant_files": [],
  "findings": [],
  "root_causes": [],
  "patch_plan": [],
  "validation_steps": [],
  "follow_up_questions": []
}
```

That output means the workflow contract is valid and all four effect boundaries
were reached. It is not a meaningful triage report.

## Meaningful host or provider run

To get repository-grounded findings, run this workflow through a host that can
inspect files, such as the Pi SDK harness or the historical `pi-mono` prototype.
For a direct terminal smoke, use a configured provider:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/repo-triage/main.cml \
  --skills examples/repo-triage/skills \
  --input examples/repo-triage/input.json \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox workspace-write \
  --trace-provider
```

Provider runs require the provider CLI and credentials to be configured outside
CamlFlow. The best Pi path is `packages/camlflow-pi-sdk`, where host code can
call `agent.runWorkflow(...)` inside a selected sandbox.

## `pi-mono` host run

From the `camlflow` repo root:

```sh
./scripts/run-pi-mono-repo-triage.sh
```

That launches the historical `pi-mono` prototype with a prefilled
`/camlflow-run ...` command aimed at this workflow. New Pi integrations should
use `packages/camlflow-pi-sdk` and call the typed `runWorkflow(...)` API from a
native Pi UI surface instead.

## Why this example matters

This is the best current example for exposing the strengths and rough edges of the `pi-mono` integration because it should reveal:

- whether the worker prompt is strong enough to induce good tool use
- whether the current working directory is what the agent expects
- whether streamed output chunks are useful or noisy
- whether final JSON extraction is robust for larger structured outputs
- whether the final transcript gives the user a clear and actionable artifact
