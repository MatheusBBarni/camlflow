# CamlFlow Troubleshooting

This guide collects the common failure modes when writing, running, hosting, or
embedding CamlFlow workflows.

For the happy path, start with:

- [`how-to-run-and-install.md`](./how-to-run-and-install.md)
- [`first-workflow.md`](./first-workflow.md)
- [`language-reference.md`](./language-reference.md)
- [`writing-and-running-camlflow.md`](./writing-and-running-camlflow.md)
- [`run-modes.md`](./run-modes.md)
- [`glossary.md`](./glossary.md)
- [`cli-reference.md`](./cli-reference.md)
- [`json-encoding.md`](./json-encoding.md)
- [`pi-sdk-harness.md`](./pi-sdk-harness.md)

## Opam Switch Is Too Old

Symptom:

```text
CamlFlow requires OCaml >= 5.4
```

Fix:

```sh
opam switch create 5.4.0 ocaml-base-compiler.5.4.0
opam install . --deps-only --with-test --yes --switch 5.4.0
opam exec --switch 5.4.0 -- dune build
```

You can avoid changing your shell by adding `--switch 5.4.0` to `opam exec`
commands:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- --help
```

## Dune Cannot Locate `camlflow`

Symptom:

```text
Warning: As this is not the main instance of Dune it is unable to locate the
executable "camlflow" within this project.
Error: Program 'camlflow' not found!
```

This can happen when several `dune exec camlflow` commands run concurrently
from nested working directories.

Fix:

- rerun the command by itself, or
- install the CLI into the active switch:

```sh
opam exec --switch 5.4.0 -- dune install camlflow
eval "$(opam env --switch 5.4.0)"
camlflow --help
```

## Dune Language 3.22 Is Not Supported

Symptom:

```text
File "dune-project", line 1, characters 11-15:
1 | (lang dune 3.22)
               ^^^^
Error: Version 3.22 of the dune language is not supported.
```

Your shell is running an older `dune` binary than this repository requires. The
project needs Dune 3.22 or newer; older binaries such as Dune 3.14 stop before
they can run any CamlFlow command.

Fix by running through the opam switch that has the repo dependencies:

```sh
opam exec --switch 5.4.0 -- dune --version
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/repo-triage/main.cml \
  --skills examples/repo-triage/skills \
  --input examples/repo-triage/input.json
```

Or activate the switch in your shell:

```sh
eval "$(opam env --switch 5.4.0)"
dune --version
dune exec camlflow -- --help
```

## `check`, `compile`, Or `run` Used The Wrong File

`check`, `compile`, and `run` can omit a source path when the nearest
`camlflow.json` supplies `program`. If a command behaves differently from a
previous run, record the current working directory and rerun with an explicit
file path:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- check examples/basic/main.cml
```

Config precedence is:

1. explicit CLI flags
2. nearest `camlflow.json`
3. built-in defaults

For the full config field reference, see
[`project-config.md`](./project-config.md).

## Module Or Qualified Name Is Unbound

Likely causes:

- the `.cml` file is not in the project or include path
- the module path casing does not match CamlFlow's lowercase resolution
- the code is using OCaml stdlib modules such as `List.map`

CamlFlow only resolves loaded `.cml` modules. It is not full OCaml.

Useful checks:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- check examples/qualified-imports/main.cml \
  -I examples/qualified-imports
```

## JSON Input Does Not Decode

Symptoms:

```text
JSON value does not match declared type
missing JSON field ...
variant JSON requires a tag field
constructor payload missing value field
```

Fix the JSON shape to match the declared `.cml` type:

- records are JSON objects with every declared field
- lists and tuples are JSON arrays
- variants use `{ "tag": "Constructor" }`
- one-payload variants use `{ "tag": "Constructor", "value": ... }`
- multi-payload variants use `{ "tag": "Constructor", "values": [...] }`
- options use `{ "tag": "Some", "value": ... }` or `{ "tag": "None" }`
- `null` is only for `unit`

For larger inputs, prefer `--input file.json` over inline shell JSON.

## Deterministic Runs Return Empty Placeholder Values

Symptom:

```text
steps: 1
"!"
```

The default runtime is deterministic. Bound agents and skills return synthesized
placeholder JSON until a provider, JSON-RPC host, or Pi worker handles the
effect.

Use deterministic runs for parser/type/runtime validation. Use one of these for
real model execution:

- direct provider CLI: `--provider codex`, `--provider opencode`,
  `--provider claude-code`, or `--provider claude-cli`
- JSON-RPC host mode with `camlflow serve --stdio`
- Pi SDK host session or Flue-style harness

## Provider Run Fails Before The First Effect

Likely causes:

- provider executable is not on `PATH`
- provider credentials are not configured
- model name is not accepted by that provider
- inline `Agent.define` settings are unsupported by the selected provider

Start with:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini \
  --trace-provider
```

Use [`provider-execution.md`](./provider-execution.md) for provider-specific
preflight behavior.

## Provider Or Host Returned Invalid Output

CamlFlow validates every provider/host/Pi worker result against the declared
return type. The fix is usually in the provider prompt, host effect handler, or
Pi worker final JSON, not in the later workflow step.

Check:

- the effect name and declared return type
- the generated schema in provider traces or JSON-RPC `executeEffect`
- the JSON encoding rules in [`json-encoding.md`](./json-encoding.md)

## JSON-RPC Host Appears Stuck

The bridge is single-active-run by design. Start one `camlflow serve --stdio`
process per active run.

Host flow:

1. send `initialize`
2. send `camlflow/run`
3. answer each `camlflow/executeEffect`
4. read the final `camlflow/run` result
5. send `shutdown` and `exit`

If the host never answers `camlflow/executeEffect`, the workflow waits for that
effect response.

## Pi Harness Cannot Run A Shell Command

Likely causes:

- selected sandbox is `read-only`
- shell `cwd` escapes the sandbox root
- shell `cwd` resolves through a symlink outside the sandbox
- command is empty
- environment map has invalid names or non-string values

Use `workspace-write` or `local` for trusted shell access:

```ts
const agent = await harness.init({ sandbox: "workspace-write" });
const session = await agent.session("work");
await session.shell("git status --short", { cwd: "." });
```

## Pi Harness Reuses Or Leaks State

Lifecycle rules:

- one initialized agent owns one sandbox
- sessions share that sandbox
- `session.close()` closes the Pi conversation only
- `agent.close()` cancels active workflow runs and releases the sandbox
- `session.task(...)` creates a one-shot child session with separate message
  history

Always close sessions and agents in `finally` blocks.

## Package Tests Race

The Pi SDK tests read the built JSON-RPC SDK package. Running both package test
suites concurrently can race while the JSON-RPC SDK rebuilds its `dist`.

Run them sequentially:

```sh
(cd packages/camlflow-ts-json-rpc-sdk && npm install && opam exec --switch 5.4.0 -- npm test)
(cd packages/camlflow-pi-sdk && npm install && opam exec --switch 5.4.0 -- npm test)
```

## Pi SDK Audit Output

`npm audit --omit=dev --json` is the production dependency check used for the
Pi SDK package. Full dev installs may still report moderate findings from the
Pi dependency tree; review upstream Pi updates before taking semver-major audit
fixes.
