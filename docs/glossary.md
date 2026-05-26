# CamlFlow Glossary

Use this glossary to keep terms consistent across `.cml` authoring, CLI runs,
JSON-RPC hosts, provider adapters, the generic orchestrator, and the Pi SDK
harness.

## Workflow

A typed CamlFlow program. Workflows live in `.cml` files, type-check before
execution, and usually expose a `main` entrypoint.

```ocaml
let main (name : string) : string =
  "Hello " ^ name
```

## Workflow Run

One execution of a workflow entrypoint with a concrete input payload and host
configuration. A run may execute deterministically in the OCaml runtime, ask a
provider to resolve effects, or be driven by a host/orchestrator over JSON-RPC.

## Orchestrator

The host-side layer that creates or selects a sandbox, starts or embeds CamlFlow,
handles workflow effects, and records lifecycle metadata such as progress, logs,
cancellation, cleanup, and resume state.

The orchestrator is not a replacement for `.cml`; it is the runtime environment
around typed `.cml` workflows.

## Harness

A programmatic API for embedding the orchestrator in host code. Harnesses expose
sessions, tasks, skills, trusted shell hooks, and workflow runs while keeping
credentials and tool policy outside `.cml`.

The generic host package name is `camlflow-orchestrator`. `camlflow-pi-sdk`
remains the Pi compatibility adapter during migration.

## Entrypoint

The top-level function selected for a run. The default entrypoint is `main`.
The CLI flag is `--entry`; the project-config field is `entry`.

```json
{
  "program": "main.cml",
  "entry": "main"
}
```

Input payloads are not stored in `camlflow.json`; pass them with `--input` or
`--input-json`.

## Pure Orchestration

The part of a workflow that CamlFlow evaluates directly: type declarations,
helper functions, branching, matching, records, variants, and other deterministic
logic.

Keep as much normalization and decision-making here as practical so effects
receive typed, stable inputs.

## Effect

Host-executed work represented by an `agent` or `skill` declaration. Effects are
sequenced with `let*`.

```ocaml
let* answer = reviewer ~code:code in
answer
```

CamlFlow validates the JSON returned by an effect against the declared return
type before the workflow continues.

## Agent

A typed effect intended for model-backed work. Agents can be bound by name:

```ocaml
agent reviewer : code:string -> string = Agent.bind "reviewer"
```

or defined inline with host-visible metadata:

```ocaml
agent reviewer : code:string -> string =
  Agent.define ~name:"reviewer" ~system_prompt:"Review tersely."
```

## Skill

A named prompt/tool behavior. In `.cml`, skills are declared with `Skill.bind`:

```ocaml
skill caveman : prompt:string -> string = Skill.bind "caveman"
```

For local prompt-backed skills, the CLI resolves
`skills/<name>/SKILL.md` from the configured skills directory.

## Deterministic Runtime

The built-in local runtime used when no provider or host effect executor is
configured. It returns placeholder JSON for unresolved effects and is useful for
parser, type, module, JSON, and orchestration validation.

It does not evaluate model quality.

## Provider

A pluggable adapter for host-owned execution. In the OCaml CLI this can be a
direct effect adapter for an external coding/model CLI, such as `codex`,
`opencode`, `claude-code`, or `claude-cli`. In the orchestrator layer it can also
mean sandbox, agent, tool, session-store, prompt-resolver, or result-parser
integration code.

Providers own credentials, model calls, and tool behavior. CamlFlow owns the
typed workflow contract and output validation.

## Host

An external process or application that owns effect execution. Hosts usually
communicate with CamlFlow through JSON-RPC over stdio.

Use one `camlflow serve --stdio` process per active run.

## JSON-RPC Bridge

The stdio protocol surface started by:

```sh
camlflow serve --stdio
```

It uses JSON-RPC 2.0 with `Content-Length` framing. The server sends
`camlflow/executeEffect` requests to the host when a workflow reaches an effect.

## Pi SDK Harness

The CamlFlow-owned TypeScript package that wraps JSON-RPC workflow execution and
Pi worker sessions:

```ts
const harness = createPiCamlFlowHarness({ runtime });
const agent = await harness.init({ sandbox: "workspace-write" });
```

It provides a Flue-style API with agent-owned sandboxes, sessions, tasks, skill
calls, trusted shell access where allowed, and workflow runs.

As the generic orchestrator layer is extracted, this package stays as a
Pi-specific compatibility adapter over shared host lifecycle boundaries.

## Session

A host-side conversation context. Sessions share the selected sandbox but keep
message history separate. In the Pi adapter, sessions are backed by Pi worker
sessions.

Use separate sessions for separate conversations. Use `session.task(...)` for
one-shot child sessions that should share the sandbox but not the parent message
history.

## Sandbox

A host-selected execution boundary for orchestrator work. Built-in presets start
with `local`, `workspace-write`, `read-only`, and `ephemeral`.

Sandbox policy controls tool availability and trusted shell behavior. Automatic
directory cleanup is limited to `ephemeral` sandboxes.

## Sandbox Provider

Host code that creates sandbox handles from a policy. Providers decide cwd/env,
tool access, shell availability, cleanup, and preservation behavior.

## Sandbox Handle

An initialized sandbox instance. A handle can expose approved tools, optional
trusted shell execution, cwd-bound path resolution, lifecycle hooks, and a close
result that says whether cleanup happened or a worktree was preserved.

## Task

Detached child work that shares the sandbox/filesystem while using separate
message history. Use tasks for isolated research, implementation, or review
branches that should not pollute the parent session.

## Trusted Shell

The host-side shell API exposed by the Pi harness when the selected sandbox
allows it:

```ts
await session.shell("pwd");
```

The built-in local shell constrains `cwd` to the sandbox root and checks paths
after symlink resolution.

## Structured Output

JSON returned by a provider, host, or Pi worker that must match a declared
CamlFlow type.

```ocaml
type answer_pack = {
  title : string;
  next_steps : string list;
}
```

If the JSON shape is wrong, CamlFlow fails at the effect boundary instead of
letting later workflow steps consume invalid data.

## Result Parser

Host-side parsing and validation that turns raw provider or model output into a
JSON value compatible with a `.cml` declared return type. Result parsers should
return failure metadata precise enough to debug without rerunning completed work.

## Project Config

`camlflow.json`, a project-local file for repeated CLI defaults such as
`program`, `entry`, `includePaths`, `skillsDir`, provider fields, and sandbox
flags.

Config lookup searches upward from the current working directory. Explicit CLI
flags take precedence over config fields.

## Module

A `.cml` file loaded by the project or include paths. Module resolution
lowercases module paths and only resolves `.cml` modules, not arbitrary OCaml
standard-library modules.

```ocaml
let payload : Helpers.payload = Helpers.make name
```

## More Detail

- [First workflow](./first-workflow.md)
- [Language reference](./language-reference.md)
- [Run modes](./run-modes.md)
- [Sandbox orchestrator ADR](./adr/0002-camlflow-sandbox-orchestrator-boundaries.md)
- [Project config](./project-config.md)
- [JSON encoding](./json-encoding.md)
- [Pi SDK harness](./pi-sdk-harness.md)
