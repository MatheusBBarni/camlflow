# CamlFlow JSON-RPC Host Integration Roadmap

## Goal

Make CamlFlow the **user-authored harness language** for AI tools.

The intended model is:

- the user writes CamlFlow code (`.cml`) as the harness
- an AI tool launches or embeds CamlFlow
- CamlFlow executes pure typed orchestration locally
- when CamlFlow reaches an effectful step (`let*` agent or skill call), it asks the host tool to execute that step
- the host tool returns JSON
- CamlFlow validates that JSON against the declared CamlFlow return type
- CamlFlow resumes execution and eventually returns the final typed workflow output

In one sentence:

> CamlFlow becomes the user-authored typed harness; the AI tool becomes the execution backend for effect steps.

---

## Why this architecture

This is stronger than adding many direct provider adapters first.

With a host protocol, users can:

- write one CamlFlow harness
- reuse it across different AI tools
- keep orchestration logic in CamlFlow instead of rewriting it in TS/Python for each tool

With this split:

### CamlFlow owns

- workflow structure
- typed inputs and outputs
- branching and matching
- pure helper logic
- JSON Schema generation
- result validation
- deterministic execution of pure steps

### The host AI tool owns

- chat and editor UX
- model sessions and memory
- tool execution environment
- provider auth and credentials
- tool-specific prompt shaping and policies
- optional retries, repair loops, or session reuse on the host side

---

## Target execution model

1. User writes `main.cml`
2. Host tool starts `camlflow serve --stdio`
3. Host sends `camlflow/run`
4. CamlFlow loads, checks, and runs the workflow
5. On each effectful step, CamlFlow sends a JSON-RPC request like `camlflow/executeEffect`
6. The host executes that step with its own model/tool/session stack
7. The host returns JSON output
8. CamlFlow validates the output against the declared return type
9. CamlFlow resumes and returns the final workflow result

This keeps CamlFlow language semantics stable while letting each tool remain opinionated about execution.

---

## Recommended implementation sequence

1. **Extract a generic effect-request model**
2. **Add JSON-RPC stdio server mode**
3. **Ship reference host examples and SDK usage examples**
4. **Stabilize the JSON-RPC protocol and JSON IR**
5. **Add tool-specific convenience adapters later**

This means: **host protocol first, provider proliferation second**.

---

# Phase 0 — Lock the contract

## Goal

Define CamlFlow's role clearly before coding the host protocol.

## Product statement

CamlFlow is:

- a typed harness/orchestration language
- a checker, compiler, and runtime
- a JSON-RPC peer that delegates effect execution to host tools

CamlFlow is not responsible for owning:

- chat UI
- editor UX
- long-lived model session UX
- provider auth UX
- tool execution UX

## Deliverable

- `docs/json-rpc.md`

## Decisions to lock for the MVP

- transport: **JSON-RPC 2.0 over stdio**
- framing: **Content-Length** headers
- concurrency: **single active run** per server instance
- execution style: **blocking nested effect requests**
- no streaming in v1
- no durable suspend/resume in v1

## Why Phase 0 matters

It prevents overbuilding and gives later implementation work a stable target.

---

# Phase 1 — Extract a generic effect request model

## Goal

Create one reusable serializable shape for “a CamlFlow step the host tool must execute.”

Today the ingredients are spread across:

- `lib/runtime/runtime_context.ml`
- `lib/provider_prompt.ml`
- `lib/provider_schema.ml`
- `lib/providers_codex.ml`

The next step is to unify that into one effect request object.

## Suggested new modules

- `lib/effect_request.ml`
- `lib/effect_bridge.ml`

## Suggested `Effect_request.t` contents

At minimum:

- `kind`
  - `bound-agent`
  - `bound-skill`
  - `local-prompt-skill`
  - `inline-agent`
- `name`
- `input_json`
- `declared_return_type` as text
- `output_schema`
- `working_directory`
- `skills_directory`
- `skill_markdown` when present
- `inline_definition` when present
- `rendered_prompt` for convenience
- `requested_model` if any
- `unsupported_settings`
- `step_index`
- `run_id`

## Important design choice

The request should expose both:

1. **structured metadata**
2. **a ready-made rendered prompt**

Some host tools will want to use CamlFlow's rendered prompt directly.
Others will want to ignore it and build their own prompt from the structured metadata.

## Files likely touched

- `lib/provider_prompt.ml`
- `lib/provider_schema.ml`
- `lib/runtime/runtime_context.ml`
- `lib/runtime/runtime.ml`
- `lib/providers_codex.ml`
- `test/test_camlflow.ml`

## Acceptance criteria

- the existing Codex path still works
- prompt/schema generation logic lives in one place
- future host mode and future providers can reuse the same effect-request model

---

# Phase 2 — Add JSON-RPC stdio server mode

## Goal

Let external tools use CamlFlow as a subprocess peer.

## CLI addition

Add a new command:

- `camlflow serve --stdio`

## Suggested new modules

- `lib/rpc_protocol.ml`
- `lib/rpc_stdio.ml`
- `lib/rpc_peer.ml`
- `lib/rpc_server.ml`

And update:

- `lib/cli.ml`
- `bin/main.ml`
- `lib/camlflow.ml`
- `lib/dune`

## Proposed JSON-RPC methods

### Client → Server

- `initialize`
- `camlflow/check`
- `camlflow/compile`
- `camlflow/run`
- `shutdown`
- `exit`

### Server → Client

- request: `camlflow/executeEffect`
- notification: `camlflow/trace` (optional in v1)
- notification: `camlflow/diagnostic` (optional in v1)

## Minimal MVP flow

### Host starts a run

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "camlflow/run",
  "params": {
    "program": {
      "path": "examples/problem-coach/main.cml",
      "includePaths": [],
      "skillsDir": "examples/problem-coach/skills"
    },
    "entry": "main",
    "input": { "...": "..." }
  }
}
```

### CamlFlow requests effect execution

```json
{
  "jsonrpc": "2.0",
  "id": "effect-1",
  "method": "camlflow/executeEffect",
  "params": {
    "runId": "run-1",
    "step": 1,
    "effect": {
      "kind": "local-prompt-skill",
      "name": "caveman",
      "input": { "prompt": "..." },
      "outputSchema": { "...": "..." },
      "declaredReturnType": "string",
      "renderedPrompt": "...",
      "skillMarkdown": "...",
      "requestedModel": null,
      "unsupportedSettings": []
    }
  }
}
```

### Host returns typed JSON output

```json
{
  "jsonrpc": "2.0",
  "id": "effect-1",
  "result": {
    "output": "short caveman reply"
  }
}
```

### CamlFlow returns the final workflow result

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "stepsRun": 4,
    "output": {
      "...": "..."
    }
  }
}
```

## Implementation shortcut for MVP

Do **not** build resumable runtime first.

Reuse the current synchronous runtime and install a context handler that:

- converts invocation metadata into an `Effect_request.t`
- sends a JSON-RPC request to the host
- blocks waiting for the response
- validates returned JSON
- resumes execution

## Acceptance criteria

- a mock host can run `examples/provider-hooks/workflow.cml`
- CamlFlow asks the host for every effect step
- the host returns JSON
- CamlFlow validates and continues
- final output is returned over JSON-RPC

---

# Phase 3 — Ship reference host examples

## Goal

Prove the model end to end for non-OCaml tool authors.

## Deliverable

Runnable host examples that cover both:

- raw JSON-RPC framing for tool authors who want zero dependencies
- SDK-backed clients for tool authors who want a higher-level integration path

## Suggested files

- `examples/json-rpc-host/README.md`
- `examples/json-rpc-host/host.js`
- `examples/json-rpc-problem-coach/README.md`
- `examples/json-rpc-problem-coach/host.js`
- `packages/camlflow-ts-json-rpc-sdk/examples/provider-hooks.ts`
- `packages/camlflow-ts-json-rpc-sdk/examples/problem-coach.ts`

## What the example should do

- spawn `camlflow serve --stdio`
- send `initialize`
- send `camlflow/run`
- handle `camlflow/executeEffect`
- route steps to simple mocks or one real model call
- print the final output

## Suggested demo workflow

Use:

- `examples/provider-hooks/workflow.cml` for the smallest end-to-end proof
- then later `examples/problem-coach/main.cml` as the stronger structured-output demo

## Acceptance criteria

A TypeScript host can say:

> “Load this user's `.cml` harness and run it through my tool.”

---

# Phase 4 — Stabilize protocol and IR

## Goal

Make the integration safe for external tools to depend on.

## Protocol versioning

During `initialize`, return:

- protocol version
- capabilities
- supported effect kinds
- whether rendered prompts are included
- whether output schemas are included

## IR versioning

Add explicit version metadata in `lib/ir.ml` so compiled artifacts are clearly versioned.

## Documentation

Add:

- `docs/json-rpc.md`
- protocol examples
- field semantics
- compatibility policy

## Acceptance criteria

- protocol has an explicit version string
- IR has an explicit version
- compatibility policy is documented

---

# Phase 4.5 — Deferred protocol extensions

These are deliberately deferred design notes, not implementation requirements for the current slice.

See also:

- `docs/json-rpc-deferred-extensions.md`

## Cancellation design notes

### Why it matters

Hosts may need to stop a long-running workflow when:

- the user cancels from UI
- the host times out
- the host tears down the current session
- the host decides an effect result is no longer needed

### Proposed direction

Add one of:

- JSON-RPC request cancellation using `$/cancelRequest`
- a CamlFlow-specific method such as `camlflow/cancelRun`

### Suggested semantics

- cancellation should target a **run** or a specific in-flight **request id**
- if CamlFlow is currently blocked on `camlflow/executeEffect`, cancellation should fail the run cleanly
- cancellation should be observable through notifications, likely:
  - `camlflow/trace` with an event like `run-cancelled`
  - `camlflow/diagnostic` when useful

### Non-goal for now

Do not implement partial unwinding or durable resume tied to cancellation in this phase.

## Progress design notes

### Why it matters

Hosts often want UI feedback before the workflow completes.

### Proposed direction

Add a notification such as:

- `camlflow/progress`

### Suggested payload shape

- `runId`
- `stage` or `event`
- `step`
- `message`
- optional counters such as `completedSteps` / `knownSteps`

### Suggested usage

- emit before an effect request starts
- emit after an effect step completes
- emit around pure compile/check/run milestones

### Non-goal for now

Do not attempt percent-perfect progress. Step-oriented progress is enough.

## Streaming design notes

### Why it matters

Some hosts may want token-by-token or chunked previews during effect execution.

### Proposed direction

Keep streaming out of the core run contract initially, but reserve room for notifications like:

- `camlflow/outputChunk`
- `camlflow/effectStream`

### Suggested semantics

- streaming should be advisory only
- the authoritative contract remains the final typed `output`
- streamed chunks should never replace final type validation

### Suggested host model

- host may stream its own preview UI locally
- CamlFlow should only relay stream events if there is a stable protocol need

### Non-goal for now

Do not couple streaming to typed workflow state changes. Only finalized JSON outputs should advance the workflow.

## Recommended order for future extension work

1. cancellation
2. progress notifications
3. optional streaming

That order preserves correctness before UX enhancements.

---

# Phase 5 — Add tool-specific convenience adapters

## Goal

After host mode works, add direct integrations as secondary convenience features.

Examples:

- `--provider opencode`
- `--provider claude-code`
- other direct CLI backends

These become much cheaper once the shared effect-request model exists.

---

## Exact first implementation sequence

### PR 1 — generic effect request extraction

Likely files:

- `lib/effect_request.ml`
- `lib/effect_bridge.ml`
- `lib/provider_prompt.ml`
- `lib/providers_codex.ml`
- `lib/runtime/runtime_context.ml`
- `lib/runtime/runtime.ml`
- `lib/camlflow.ml`
- `test/test_camlflow.ml`

Outcome:

- Codex still works
- request-building logic becomes reusable

### PR 2 — JSON-RPC stdio server

Likely files:

- `lib/rpc_protocol.ml`
- `lib/rpc_stdio.ml`
- `lib/rpc_peer.ml`
- `lib/rpc_server.ml`
- `lib/cli.ml`
- `bin/main.ml`
- `lib/camlflow.ml`
- `lib/dune`
- tests

Outcome:

- `camlflow serve --stdio` works with a mock client

### PR 3 — reference host examples

Likely files:

- `examples/json-rpc-host/host.js`
- `examples/json-rpc-host/README.md`
- `examples/json-rpc-problem-coach/host.js`
- `examples/json-rpc-problem-coach/README.md`
- `packages/camlflow-ts-json-rpc-sdk/examples/provider-hooks.ts`
- `packages/camlflow-ts-json-rpc-sdk/examples/problem-coach.ts`

Outcome:

- non-OCaml developers can immediately understand the integration model
- SDK users can start from maintained example code instead of rebuilding the protocol loop by hand

### PR 4 — protocol and IR stabilization

Likely files:

- `lib/ir.ml`
- `docs/json-rpc.md`
- `README.md`
- tests

Outcome:

- external tools can depend on the protocol and IR more safely

---

## Non-goals for v1

To keep scope sane, do **not** include these in the first protocol version:

- token streaming
- multiple concurrent runs over one connection
- durable suspend/resume
- host-driven cancellation
- protocol-level retries
- forcing the host to understand CamlFlow AST/IR internals

For v1, the host should only need to understand:

- effect metadata
- input JSON
- output schema
- returned JSON

---

## Positioning

Recommended message:

> **Write your harness in CamlFlow.**
>
> Your AI tool can execute it by speaking CamlFlow JSON-RPC and fulfilling typed effect requests.
