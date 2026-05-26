# CamlFlow Examples

This directory is the quickest way to learn CamlFlow by running real workflows.
Start with pure examples, then add skills, providers, JSON-RPC hosts, the generic
orchestrator SDK, and the Pi SDK harness.

Run commands from the repository root unless a section says otherwise. If your
active opam switch is not OCaml 5.4, replace `opam exec --` with
`opam exec --switch 5.4.0 --`.

## Learning Path

1. [`first-workflow`](./first-workflow): copyable tutorial project with input
   JSON and `camlflow.json`.
2. [`basic`](./basic): smallest `Agent.bind` workflow and `let*`.
3. [`recursion`](./recursion): pure recursion without effects.
4. [`variants-match`](./variants-match): variants and `match`.
5. [`qualified-imports`](./qualified-imports): module loading and qualified
   references.
6. [`local-skill`](./local-skill): `Skill.bind` plus local `SKILL.md`.
7. [`project-config`](./project-config): nearest `camlflow.json` defaults.
8. [`problem-coach`](./problem-coach): practical structured-output workflow.
9. [`repo-triage`](./repo-triage): repository-grounded workflow suited for a
   Pi-style coding agent host.
10. [`orchestrator-session`](./orchestrator-session): `.cml` workflow intended
    to run inside a host-owned sandbox/session/task lifecycle.

## Small Syntax Examples

Run these first:

```sh
opam exec -- dune exec camlflow -- run examples/first-workflow/main.cml \
  --input examples/first-workflow/input.json
opam exec -- dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
opam exec -- dune exec camlflow -- run examples/recursion/main.cml --input-json '4'
opam exec -- dune exec camlflow -- run examples/variants-match/main.cml
opam exec -- dune exec camlflow -- check examples/qualified-imports/main.cml
```

These cover:

- source file loading
- simple JSON input
- pure helpers
- variants
- pattern matching
- module references

## Skills

[`local-skill`](./local-skill) shows the minimum local skill layout:

```text
skills/
  caveman/
    SKILL.md
```

Run it with:

```sh
opam exec -- dune exec camlflow -- run examples/local-skill/main.cml \
  --skills examples/local-skill/skills \
  --input-json '"hello"'
```

## Project Defaults

[`project-config`](./project-config) shows `camlflow.json`.

```sh
(cd examples/project-config && opam exec -- dune exec camlflow -- check)
(cd examples/project-config && opam exec -- dune exec camlflow -- run --input input.json)
```

`check`, `compile`, and `run` can omit the file argument when the nearest
`camlflow.json` supplies `program`.

## Structured Workflow Examples

Use these when you want examples closer to real host use:

- [`problem-coach`](./problem-coach): algorithm-answer pack with typed record
  output.
- [`interview-pipeline`](./interview-pipeline): larger pipeline with records,
  variants, options, lists, local skills, bound effects, and inline agents.
- [`dev-workflow`](./dev-workflow): typed approval state machine for software
  workflow planning and review.
- [`repo-triage`](./repo-triage): repository investigation and triage report,
  designed for a tool-using coding agent host.
- [`orchestrator-session`](./orchestrator-session): issue triage workflow shaped
  for a generic sandbox orchestrator session.

Run one deterministic structured workflow:

```sh
opam exec -- dune exec camlflow -- run examples/problem-coach/main.cml \
  --skills examples/problem-coach/skills \
  --input examples/problem-coach/input.json
```

Deterministic runs validate parsing, typing, module resolution, JSON decoding,
effect wiring, and final output validation. They do not evaluate model quality.

## Provider-Backed Examples

[`codex`](./codex) exercises a bound agent, local prompt skill, and inline agent
through the direct CLI provider path.

```sh
opam exec -- dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only \
  --trace-provider
```

Provider-backed runs are useful for terminal validation. Pi integrations should
prefer `packages/camlflow-pi-sdk` instead of adding slash-command parsing here.

## JSON-RPC Host Examples

These examples show CamlFlow as a JSON-RPC server and a host process satisfying
`camlflow/executeEffect` requests:

- [`json-rpc-host`](./json-rpc-host): minimal dependency-free host.
- [`json-rpc-problem-coach`](./json-rpc-problem-coach): structured host for the
  `problem-coach` workflow.

Run:

```sh
opam exec -- node examples/json-rpc-host/host.js
opam exec -- node examples/json-rpc-problem-coach/host.js
```

Use one `camlflow serve --stdio` process per active run. The bridge is
single-active-run by design.

## Pi SDK Harness Examples

The Pi SDK examples live under
[`packages/camlflow-pi-sdk/examples`](../packages/camlflow-pi-sdk/examples).
They are compile-checked TypeScript sketches for:

- native Pi command/palette style workflow runs
- cancellation and streamed output
- Flue-style `agent.session(...).prompt/skill/task/shell` orchestration

Run the package checks:

```sh
(cd packages/camlflow-pi-sdk && npm install && opam exec -- npm test)
```

The best `.cml` workflow to pair with a Pi-style coding agent is
[`repo-triage`](./repo-triage), because it asks an agent to inspect the current
repository and return grounded file-level findings.

## JSON Input Cheat Sheet

CamlFlow JSON uses explicit typed encodings:

- `string`, `int`, `float`, `bool` map to JSON primitives.
- records map to JSON objects.
- lists map to JSON arrays.
- nullary variants use `{ "tag": "Constructor" }`.
- variants with payloads use `{ "tag": "Constructor", "value": ... }`.
- options use the same variant encoding: `{ "tag": "None" }` or
  `{ "tag": "Some", "value": ... }`.

See [`problem-coach/input.json`](./problem-coach/input.json) and
[`dev-workflow/input-approved.json`](./dev-workflow/input-approved.json) for
concrete structured inputs.

## More Docs

- [Documentation map](../docs/README.md)
- [First workflow tutorial](../docs/first-workflow.md)
- [Language reference](../docs/language-reference.md)
- [Glossary](../docs/glossary.md)
- [Run modes](../docs/run-modes.md)
- [Writing and running CamlFlow workflows](../docs/writing-and-running-camlflow.md)
- [Workflow cookbook](../docs/workflow-cookbook.md)
- [Install and run guide](../docs/how-to-run-and-install.md)
- [CLI reference](../docs/cli-reference.md)
- [Project config reference](../docs/project-config.md)
- [JSON encoding reference](../docs/json-encoding.md)
- [Editor support](../docs/editor-support.md)
- [Pi SDK harness guide](../docs/pi-sdk-harness.md)
- [Troubleshooting](../docs/troubleshooting.md)
- [Provider-backed execution](../docs/provider-execution.md)
- [JSON-RPC protocol](../docs/json-rpc.md)
- [Pi SDK README](../packages/camlflow-pi-sdk/README.md)
