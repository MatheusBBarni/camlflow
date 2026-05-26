# First CamlFlow Workflow

This tutorial starts with one `.cml` file, runs it locally, adds structured
input, adds an effect, then shows where provider, JSON-RPC, and Pi harness runs
fit.

Use this when you want the shortest path from an empty file to a workflow you
can run and host.

The checked-in companion project is
[`examples/basic`](../examples/basic).

## Prerequisites

Build CamlFlow from the repository first:

```sh
opam install . --deps-only --with-test --yes
opam exec -- dune build
```

If your shell uses an older opam switch, pass the switch explicitly:

```sh
opam install . --deps-only --with-test --yes --switch 5.4.0
opam exec --switch 5.4.0 -- dune build
```

All commands below assume you are in the repository root.

For sections that run from `/tmp/camlflow-first`, capture the built CLI path:

```sh
CAMLFLOW_BIN="$(pwd)/_build/default/bin/main.exe"
```

## 1. Write A Pure Workflow

Create `/tmp/camlflow-first/main.cml`:

```ocaml
let main (name : string) : string =
  "Hello " ^ name
```

Check and run it:

```sh
opam exec -- dune exec camlflow -- check /tmp/camlflow-first/main.cml
opam exec -- dune exec camlflow -- run /tmp/camlflow-first/main.cml --input-json '"Ada"'
```

Expected output:

```text
steps: 0
"Hello Ada"
```

`check` loads and type-checks the workflow. `run` executes it.

## 2. Use Structured Input

Most real workflows should use one record argument. That keeps CLI, JSON-RPC,
and Pi SDK calls predictable.

Replace `/tmp/camlflow-first/main.cml`:

```ocaml
type request = {
  name : string;
  punctuation : string;
}

let main (request : request) : string =
  "Hello " ^ request.name ^ request.punctuation
```

Run it with an inline JSON object:

```sh
opam exec -- dune exec camlflow -- run /tmp/camlflow-first/main.cml \
  --input-json '{"name":"Ada","punctuation":"!"}'
```

Expected output:

```text
steps: 0
"Hello Ada!"
```

For larger inputs, put the JSON in a file:

```json
{
  "name": "Ada",
  "punctuation": "!"
}
```

Then run:

```sh
opam exec -- dune exec camlflow -- run /tmp/camlflow-first/main.cml \
  --input /tmp/camlflow-first/input.json
```

See [JSON encoding](./json-encoding.md) for records, variants, options, tuples,
and lists.

## 3. Add An Effect

Agents and skills are effects. Use `let*` when a workflow must wait for an
effect result.

Replace `/tmp/camlflow-first/main.cml`:

```ocaml
type request = {
  name : string;
  punctuation : string;
}

agent greeter : name:string -> string = Agent.bind "greeter"

let main (request : request) : string =
  let* greeting = greeter ~name:request.name in
  greeting ^ request.punctuation
```

Run it locally:

```sh
opam exec -- dune exec camlflow -- run /tmp/camlflow-first/main.cml \
  --input-json '{"name":"Ada","punctuation":"!"}'
```

With the deterministic local runtime, unresolved effects return placeholder
JSON. That lets you validate parsing, typing, orchestration, and output
decoding before wiring in a real provider or host.

## 4. Add A Project Config

For repeated runs, add `/tmp/camlflow-first/camlflow.json`:

```json
{
  "program": "main.cml",
  "entry": "main"
}
```

Add `/tmp/camlflow-first/input.json`:

```json
{
  "name": "Ada",
  "punctuation": "!"
}
```

Then run from the project directory:

```sh
cd /tmp/camlflow-first
"$CAMLFLOW_BIN" check
"$CAMLFLOW_BIN" run --input input.json
```

When no source file is provided, CamlFlow finds the nearest `camlflow.json`.
Input still comes from `--input` or `--input-json`; project config does not
store input payload paths.
See [Project config](./project-config.md) for lookup rules and field
precedence.

## 5. Run With A Provider

Provider-backed CLI runs are useful when you want a quick terminal-owned model
execution path:

```sh
opam exec -- dune exec camlflow -- run /tmp/camlflow-first/main.cml \
  --input /tmp/camlflow-first/input.json \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only
```

Provider runs require the provider CLI and credentials to be configured outside
CamlFlow. Keep provider-specific credentials out of `.cml` files.

See [Provider execution](./provider-execution.md) for providers, sandbox flags,
model selection, and trace output.

## 6. Host The Workflow Over JSON-RPC

Use JSON-RPC when another process should own effect execution:

```sh
opam exec -- dune exec camlflow -- serve --stdio
```

The server speaks JSON-RPC 2.0 over stdio with `Content-Length` framing. A host
initializes the bridge, runs a workflow, and handles effect requests.

Start with:

- [JSON-RPC protocol](./json-rpc.md)
- [TypeScript JSON-RPC SDK](../packages/camlflow-ts-json-rpc-sdk/README.md)
- [JSON-RPC host examples](../examples/json-rpc-host/README.md)

## 7. Use The Pi SDK Harness

Use the Pi SDK harness when host TypeScript wants a Flue-like API with one
agent-owned sandbox, sessions, tasks, skills, shell access, and workflow runs.

```ts
import { createPiCamlFlowHarness } from "camlflow-pi-sdk";

const harness = createPiCamlFlowHarness({ runtime });
const agent = await harness.init({ sandbox: "workspace-write" });

try {
  const session = await agent.session("first-workflow");
  const answer = await session.prompt("Summarize this workflow.");

  const result = await agent.runWorkflow("/tmp/camlflow-first/main.cml", {
    input: { name: "Ada", punctuation: "!" },
  });

  console.log(answer, result.output);
} finally {
  await agent.close();
}
```

Use one agent per sandbox lifetime. Use separate sessions or `session.task(...)`
for separate message histories. See [Pi SDK harness](./pi-sdk-harness.md) for
sandbox presets, shell constraints, cancellation, lifecycle, and JSON contracts.

## Development Loop

A practical loop is:

1. Write pure types and helper functions.
2. Add agent or skill declarations only at the boundaries.
3. Run `check` after syntax or type changes.
4. Run deterministic CLI execution with representative JSON input.
5. Add `camlflow.json` when command lines become repetitive.
6. Add provider, JSON-RPC, or Pi harness execution only after the workflow
   contract is stable.

For more patterns, continue with:

- [Workflow cookbook](./workflow-cookbook.md)
- [Language reference](./language-reference.md)
- [Glossary](./glossary.md)
- [Run modes](./run-modes.md)
- [Writing and running CamlFlow](./writing-and-running-camlflow.md)
- [CLI reference](./cli-reference.md)
- [Troubleshooting](./troubleshooting.md)
