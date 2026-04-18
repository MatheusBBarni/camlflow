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

This validates parsing, typing, module resolution, JSON encoding, and effect wiring, but the result will use deterministic placeholder effect behavior unless you run through a real host.

```sh
dune exec camlflow -- run examples/repo-triage/main.cml \
  --skills examples/repo-triage/skills \
  --input examples/repo-triage/input.json
```

## `pi-mono` host run

From the `camlflow` repo root:

```sh
./scripts/run-pi-mono-repo-triage.sh
```

That launches `pi-mono` with a prefilled `/camlflow-run ...` command aimed at this workflow.

## Why this example matters

This is the best current example for exposing the strengths and rough edges of the `pi-mono` integration because it should reveal:

- whether the worker prompt is strong enough to induce good tool use
- whether the current working directory is what the agent expects
- whether streamed output chunks are useful or noisy
- whether final JSON extraction is robust for larger structured outputs
- whether the final transcript gives the user a clear and actionable artifact
