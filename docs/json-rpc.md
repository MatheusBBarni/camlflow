# CamlFlow JSON-RPC Protocol (Phase 0 Draft)

## Status

Draft. This document locks the **Phase 0** contract for exposing CamlFlow as a host-integrated harness runtime.

The goal of this phase is not to finalize every request payload, but to lock the core execution model before implementation.

---

## Purpose

CamlFlow should be usable as a typed harness language inside other AI tools.

The intended workflow is:

- the user writes CamlFlow code as the harness
- the host AI tool starts CamlFlow as a JSON-RPC peer
- CamlFlow executes pure typed orchestration locally
- effectful steps are delegated to the host tool
- the host returns JSON results
- CamlFlow validates those results against declared types
- CamlFlow continues until final output is produced

In this model, CamlFlow is a **typed orchestration engine**, not the owner of the surrounding tool UX.

---

## Ownership boundaries

### CamlFlow owns

- parsing, checking, and compiling `.cml`
- pure workflow execution
- effect step discovery
- effect metadata generation
- JSON Schema generation for expected outputs
- validation of returned JSON against declared CamlFlow types
- final workflow output production

### The host AI tool owns

- chat/editor UX
- model/provider selection
- long-lived model sessions and memory
- tool execution strategy
- auth and credentials
- host-specific prompt rewriting or step routing
- optional retries and repair loops outside the CamlFlow runtime

---

## MVP contract decisions locked in Phase 0

### 1. Transport

The MVP transport is:

- **JSON-RPC 2.0 over stdio**

This is the primary integration path for external AI tools.

### 2. Message framing

Messages use:

- **Content-Length** framing

This matches established editor/tooling protocols and avoids newline-delimited JSON ambiguity.

### 3. Concurrency model

The MVP server supports:

- **one active workflow run per server instance**

The first protocol version does not attempt multiplexed concurrent runs on one connection.

### 4. Execution style

Effect execution uses:

- **blocking request/response delegation**

When CamlFlow encounters an effectful step, it sends a request to the host and waits for a response before continuing workflow execution.

### 5. Streaming

The MVP does **not** include:

- token streaming
- partial-output streaming
- incremental workflow result streaming

### 6. Suspension/resume

The MVP does **not** include:

- durable suspend/resume across process restarts
- persisted checkpoints

Execution remains in-process and synchronous from CamlFlow's perspective.

---

## Core execution model

A host-integrated run looks like this:

1. Host starts `camlflow serve --stdio`
2. Host initializes the JSON-RPC session
3. Host asks CamlFlow to run a workflow
4. CamlFlow loads and checks source, or loads compiled IR
5. CamlFlow begins execution
6. On each effectful step, CamlFlow sends the host an effect-execution request
7. The host executes the step using its own model/tool stack
8. The host returns JSON output
9. CamlFlow validates the JSON output against the declared step return type
10. CamlFlow resumes the workflow
11. CamlFlow returns the final typed workflow result

---

## Protocol directionality

### Client → Server methods

The host is the JSON-RPC client and CamlFlow is the JSON-RPC server.

The first protocol version is expected to include:

- `initialize`
- `camlflow/check`
- `camlflow/compile`
- `camlflow/run`
- `shutdown`
- `exit`

### Server → Client requests

During a run, CamlFlow may send requests back to the host.

The first protocol version is expected to include:

- `camlflow/executeEffect`

Optional later notifications may include:

- `camlflow/trace`
- `camlflow/diagnostic`

These notifications are not required for the Phase 0 contract.

---

## Effect request contract

The protocol should expose both:

1. **structured effect metadata**
2. **a ready-made rendered prompt**

This is important because different host tools will want different levels of control.

### Some hosts will want

- to use CamlFlow's prompt rendering directly

### Other hosts will want

- to ignore the rendered prompt
- to build a tool-specific prompt from structured metadata

So effect requests should ultimately carry at least:

- effect kind
- effect name
- typed input JSON
- declared return type
- output JSON Schema
- local skill markdown if present
- inline agent metadata if present
- rendered prompt for convenience

---

## Supported effect kinds

The host protocol is expected to support all unresolved CamlFlow effect kinds already present in the runtime:

- bound agents
- bound skills
- local prompt-backed skills
- inline agents

This keeps the host protocol aligned with the runtime invocation model already documented in `docs/provider-hooks.md`.

---

## Validation rule

The host returns JSON, not raw CamlFlow values.

After receiving a host response, CamlFlow must:

1. decode the JSON response payload
2. validate it against the declared CamlFlow return type
3. fail the run if the returned JSON shape is invalid

This rule is core to the value proposition: the host may execute however it wants, but CamlFlow preserves typed workflow guarantees.

---

## CLI direction

The intended CLI entrypoint for host mode is:

```sh
camlflow serve --stdio
```

Phase 0 locks this direction so later implementation work can target one explicit startup contract.

---

## Non-goals for the first protocol version

The first JSON-RPC version should not attempt to solve:

- token streaming
- concurrent multi-run multiplexing on one connection
- durable checkpoints
- host-driven cancellation
- protocol-level retries
- forcing the host to understand CamlFlow AST internals

The host should only need to understand:

- run requests
- effect execution requests
- JSON inputs and outputs
- output schemas

---

## Intended positioning

Recommended product framing:

> Write your harness in CamlFlow.
>
> Your AI tool can execute it by speaking CamlFlow JSON-RPC and fulfilling typed effect requests.

This keeps CamlFlow language-first while making it portable across multiple AI tool environments.

---

## Next phase

Phase 1 should extract a shared serializable effect-request model so that:

- direct providers
- JSON-RPC host mode
- future tool adapters

all consume the same invocation-to-request pipeline.
