# Writing And Running CamlFlow Workflows

This guide is the author-facing path for writing `.cml` workflows and choosing
the right execution mode now that CamlFlow has both direct CLI execution and the
Pi SDK Flue-style harness.

Use this guide after the repository is built. For setup commands, see
[`how-to-run-and-install.md`](./how-to-run-and-install.md).
For a step-by-step tutorial from an empty file, see
[`first-workflow.md`](./first-workflow.md).
For a compact syntax and declaration reference, see
[`language-reference.md`](./language-reference.md).
For copyable workflow patterns, see
[`workflow-cookbook.md`](./workflow-cookbook.md).
For an execution-mode comparison, see
[`run-modes.md`](./run-modes.md).
For shared terminology, see
[`glossary.md`](./glossary.md).
For a compact command and flag reference, see
[`cli-reference.md`](./cli-reference.md).
For common failures and fixes, see
[`troubleshooting.md`](./troubleshooting.md).

## Mental Model

CamlFlow splits a workflow into two parts:

- pure typed orchestration in `.cml`
- effect execution by a host, provider, or Pi agent

CamlFlow owns parsing, type-checking, module loading, effect metadata, JSON
encoding, and output validation. The host owns model execution, tool use,
credentials, sandbox policy, and user experience.

That means a CamlFlow script should describe the workflow contract and sequencing
clearly. It should not hide provider-specific shell commands or secret handling
inside prompts.

## Pick An Execution Mode

Use deterministic CLI runs while developing pure logic or checking that a
workflow type-checks:

```sh
opam exec -- dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
```

Use provider-backed CLI runs when you want quick end-to-end model execution from
a terminal:

```sh
opam exec -- dune exec camlflow -- run examples/provider-hooks/workflow.cml \
  --skills examples/provider-hooks/skills \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only
```

Use JSON-RPC host mode when a non-Pi tool wants to own effect execution:

```sh
opam exec -- dune exec camlflow -- serve --stdio
```

Use the Pi SDK harness when host TypeScript wants a Flue-like agent API with
sandbox selection, sessions, skills, shell commands, and workflow runs:

```ts
const harness = createPiCamlFlowHarness({ runtime });
const agent = await harness.init({ sandbox: "workspace-write" });
const session = await agent.session("triage");
```

The maintained Pi integration guide is
[`pi-sdk-harness.md`](./pi-sdk-harness.md).

## Smallest Workflow

Create `main.cml`:

```ocaml
agent greeter : name:string -> string = Agent.bind "greeter"

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  greeting ^ "!"
```

Check and run it:

```sh
opam exec -- dune exec camlflow -- check main.cml
opam exec -- dune exec camlflow -- run main.cml --input-json '"Ada"'
```

`let` binds pure values. `let*` sequences an effectful agent or skill call and
waits for the host/provider/Pi worker to return typed JSON.

With the default deterministic runtime, unresolved agents and skills return
placeholder values. That is useful for parser, typing, and orchestration checks,
but not for model quality evaluation.

## Types And JSON

CamlFlow supports primitives, records, variants, options, tuples, lists, pattern
matching, recursion, and labeled calls.

Example record and variant types:

```ocaml
type language = Python | TypeScript | OCaml

type request = {
  problem_name : string;
  language : language;
  must_cover : string list;
}
```

JSON input uses explicit typed encodings:

- records are JSON objects
- lists are JSON arrays
- variants are tagged objects
- options are tagged variants, not implicit `null`

Example input:

```json
{
  "problem_name": "two sum",
  "language": { "tag": "Python" },
  "must_cover": ["hash map approach", "time complexity"]
}
```

Constructors with payloads use `value`:

```json
{ "tag": "Some", "value": "extra context" }
```

For a larger reference, compare
[`examples/orchestrator-session/main.cml`](../examples/orchestrator-session/main.cml) with
[`examples/orchestrator-session/input.json`](../examples/orchestrator-session/input.json).
For the full JSON encoding reference, including unit, tuples, multi-payload
variants, options, and common decode failures, see
[`json-encoding.md`](./json-encoding.md).
For a runnable learning path across the examples directory, see
[`examples/README.md`](../examples/README.md).

## Agents

Use `Agent.bind` when the implementation is supplied by the runtime provider,
JSON-RPC host, or Pi worker:

```ocaml
agent draft_solver : request:normalized_request -> draft_solution =
  Agent.bind "draft-solver"
```

Use `Agent.define` when the workflow itself should carry host-visible agent
metadata:

```ocaml
agent answer_packager :
  request:normalized_request -> draft:draft_solution -> solution_pack =
  Agent.define
    ~name:"problem-coach-packager"
    ~style:"practical"
    ~system_prompt:"Turn an algorithm draft into a user-facing answer pack."
```

Inline `~model:"..."` wins over CLI `--model` in provider-backed runs.
Unsupported inline settings, such as `~temperature` in current direct CLI
providers, fail fast instead of being silently ignored.

## Skills

Use `Skill.bind` for a named skill:

```ocaml
skill caveman : prompt:string -> string = Skill.bind "caveman"

let main (prompt : string) : string =
  let* answer = caveman ~prompt:prompt in
  answer
```

For local prompt-backed skills, create:

```text
skills/
  caveman/
    SKILL.md
```

Run with:

```sh
opam exec -- dune exec camlflow -- run examples/provider-hooks/workflow.cml \
  --skills examples/provider-hooks/skills \
  --input-json '"hello"'
```

Provider and host runs include the `SKILL.md` text in the effect metadata. The
Pi harness also exposes `session.skill(name, { args })`, which validates Pi
skill names before creating a `/skill:name` prompt.

## Modules And Project Layout

CamlFlow module resolution lowercases module paths and searches the project file
plus include paths. A common layout is:

```text
my-flow/
  camlflow.json
  main.cml
  types.cml
  helpers.cml
  skills/
    triage/
      SKILL.md
```

Use `open Types` for unqualified names or qualified module paths directly:

```ocaml
open Types

let main (name : string) : Helpers.payload =
  Helpers.make name
```

CamlFlow is not full OCaml. Do not rely on arbitrary OCaml stdlib or
module-qualified calls such as `List.map` inside `.cml`; only loaded `.cml`
modules resolve.

## Project Defaults

`camlflow.json` lets a project omit repeated CLI flags:

```json
{
  "program": "main.cml",
  "entry": "main",
  "includePaths": ["."],
  "skillsDir": "skills",
  "provider": "codex",
  "model": "gpt-5.4-mini",
  "reasoning": "low",
  "sandbox": "workspace-write"
}
```

From that directory:

```sh
opam exec -- dune exec camlflow -- check
opam exec -- dune exec camlflow -- run --input input.json
```

Precedence is explicit CLI flags, then nearest `camlflow.json`, then built-in
defaults. Relative `program`, `includePaths`, `skillsDir`, and `allowWriteDirs`
paths resolve from the config file's directory.
For the full field reference, see
[`project-config.md`](./project-config.md).

## CLI Authoring Loop

Use this loop while authoring:

```sh
opam exec -- dune exec camlflow -- parse main.cml
opam exec -- dune exec camlflow -- check main.cml
opam exec -- dune exec camlflow -- compile main.cml -o /tmp/main.ir.json
opam exec -- dune exec camlflow -- run /tmp/main.ir.json --input input.json
```

Use `--input-json` for small values and `--input` for structured payloads:

```sh
opam exec -- dune exec camlflow -- run examples/orchestrator-session/main.cml \
  --skills examples/provider-hooks/skills \
  --input examples/orchestrator-session/input.json
```

Compiled IR and source runs use the same runtime and provider plumbing. The IR
artifact is useful when a host wants to inspect or cache the typed workflow
shape.

## Provider-Backed CLI Runs

Provider-backed runs are the quickest way to run effectful workflows without
writing host code.

Supported provider names:

- `codex`
- `opencode`
- `claude-code`
- `claude-cli`

Provider runs still validate every returned JSON value against the declared
CamlFlow type. If the provider returns malformed JSON or the wrong shape, the
effect fails and the enclosing workflow fails.

Use `--trace-provider` while debugging:

```sh
opam exec -- dune exec camlflow -- run examples/provider-hooks/workflow.cml \
  --skills examples/provider-hooks/skills \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini \
  --trace-provider
```

Provider sandbox modes are CLI-provider sandbox modes:
`read-only`, `workspace-write`, and `danger-full-access`. These are separate
from the Pi SDK harness sandbox presets.

See [`provider-execution.md`](./provider-execution.md) for provider preflight
and provider-specific behavior.
For a compact flag list, see [`cli-reference.md`](./cli-reference.md).

## JSON-RPC Host Runs

Use JSON-RPC when another process owns effect execution. Start one server process
per active run:

```sh
opam exec -- dune exec camlflow -- serve --stdio
```

Host flow:

1. start `camlflow serve --stdio`
2. send `initialize`
3. send `camlflow/run`
4. answer each `camlflow/executeEffect` request with typed JSON
5. read the final `camlflow/run` result

The bridge is JSON-RPC 2.0 over stdio with `Content-Length` framing. It is
single-active-run by design.

Use the TypeScript SDK instead of hand-rolling framing when possible:
[`packages/camlflow-ts-json-rpc-sdk`](../packages/camlflow-ts-json-rpc-sdk).

## Pi SDK Flue-Style Harness

Use `packages/camlflow-pi-sdk` when integrating inside Pi or another TypeScript
host that can provide Pi runtime services.

Install in the host project:

```sh
npm install camlflow-pi-sdk camlflow-ts-json-rpc-sdk @mariozechner/pi-coding-agent
```

Minimal harness shape:

```ts
import { createPiCamlFlowHarness } from "camlflow-pi-sdk";

const harness = createPiCamlFlowHarness({ runtime });
const agent = await harness.init({
  id: "repo-triage",
  sandbox: "workspace-write",
  model: runtime.session.model,
});

const session = await agent.session("issue-42");

try {
  const findings = await session.task("Inspect this checkout and list risk areas.", {
    result: "json",
  });

  const triage = await session.skill("triage", {
    args: { issueNumber: 42, findings },
    result: "json",
  });

  const workflow = await agent.runWorkflow({
    workflowPath: "examples/orchestrator-session/main.cml",
    skillsDir: "examples/provider-hooks/skills",
    input: {
      task: "Triage the current repository.",
      suspected_area: "Pi harness integration",
      file_hints: [],
      goals: ["ground findings in repository evidence"],
      constraints: ["keep the result actionable"],
      mode: { tag: "Quick" },
    },
  });

  console.log(triage, workflow.output);
} finally {
  await session.close();
  await agent.close();
}
```

Harness sandbox presets:

- `local` / `workspace-write`: Pi coding tools plus trusted host shell
- `read-only`: Pi read/search/list tools; no trusted shell
- `ephemeral`: temporary workspace cleaned up when the agent closes
- custom config or factory: host-owned `cwd`, tools, shell, and cleanup

`session.shell(...)` is trusted host code, not a model-visible prompt. Use it
for explicit commands and secret-bearing environment variables. The built-in
local shell constrains `cwd` to the sandbox root, including symlink-aware checks.

Important lifecycle rules:

- one initialized agent owns one sandbox
- sessions share the agent sandbox
- `session.close()` closes only that Pi conversation
- `agent.close()` cancels active workflow runs and releases the sandbox
- prompt and skill calls are serial per session
- use another session or `session.task(...)` for independent concurrent work

See [`packages/camlflow-pi-sdk/README.md`](../packages/camlflow-pi-sdk/README.md)
and
[`packages/camlflow-pi-sdk/examples/flue-style-harness.ts`](../packages/camlflow-pi-sdk/examples/flue-style-harness.ts).
For the host/session/sandbox decision guide, see
[`pi-sdk-harness.md`](./pi-sdk-harness.md).

## Choosing Boundaries

Keep these boundaries in mind:

- Put deterministic branching, type declarations, and output shape in `.cml`.
- Put provider/model credentials outside `.cml`.
- Put file-system write policy and shell commands in the host or Pi harness.
- Use local `SKILL.md` files for reusable prompt behavior.
- Use inline `Agent.define` metadata only when that metadata belongs to the
  workflow contract.
- Keep JSON inputs explicit; avoid relying on host-side coercion.

## Common Failures

`unbound module` or missing qualified name:
Check include paths, lowercase module resolution, and whether the file is part
of the project or `camlflow.json` include paths.

`expected JSON value for type ...`:
Check the input encoding. Variants and options must use `{ "tag": ... }`, with
`value` when the constructor carries a payload.

Provider returns invalid output:
The provider must return JSON matching the declared return type. Re-run with
`--trace-provider` and inspect the effect name, declared return type, and schema.

`check`, `compile`, or `run` picked the wrong file:
You may be under a different nearest `camlflow.json`. Reproduce with an explicit
file path or record the current working directory.

Pi harness shell cannot access a path:
Check the selected harness sandbox. Built-in local shell commands cannot escape
the sandbox root, even through symlinks.
