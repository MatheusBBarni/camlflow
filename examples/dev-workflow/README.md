# Dev workflow example

This example converts the `dev-workflow` skill into a CamlFlow harness.

It exercises:

- multi-file loading (`main.cml`, `types.cml`, `helpers.cml`)
- local prompt skills (`grill-me`, `caveman`)
- inline agents (`TheEngineer`, `CodeReviewer`)
- typed model-response validation on every effectful step
- approval gating through typed workflow output
- a realistic end-to-end software workflow instead of a toy string demo

Files:

- `main.cml`
- `types.cml`
- `helpers.cml`
- `input-approved.json`
- `input-pending.json`
- `input-rejected.json`
- `skills/grill-me/SKILL.md`
- `skills/caveman/SKILL.md`

## Deterministic local run

Approved path:

```sh
opam exec -- dune exec camlflow -- run examples/dev-workflow/main.cml \
  --skills examples/dev-workflow/skills \
  --input examples/dev-workflow/input-approved.json
```

Equivalent shortcut:

```sh
make run-dev-workflow
```

Pending-approval path:

```sh
opam exec -- dune exec camlflow -- run examples/dev-workflow/main.cml \
  --skills examples/dev-workflow/skills \
  --input examples/dev-workflow/input-pending.json
```

In deterministic mode, the local skill and inline agent fallbacks synthesize the
declared typed payloads, so the run still validates parsing, typing, JSON
encoding, approval branching, and final report assembly.

## Provider-backed run

```sh
opam exec -- dune exec camlflow -- run examples/dev-workflow/main.cml \
  --skills examples/dev-workflow/skills \
  --input examples/dev-workflow/input-approved.json \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only
```

## Why this example matters

This is a stronger real-use-case harness than the smaller demos because it turns
a daily software workflow into an explicit typed state machine:

- `NeedsClarification`
- `NeedsApproval`
- `Completed`

That makes it useful for testing both the language and the surrounding host
integration story.
