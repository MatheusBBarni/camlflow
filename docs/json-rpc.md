# CamlFlow JSON-RPC Protocol (Phase 0 Draft)

## Status

Draft. This document locks the **Phase 0** contract for exposing CamlFlow as a host-integrated harness runtime.

The goal of this phase is not to finalize every request payload, but to lock the core execution model before implementation.

## Companion docs

- `docs/json-rpc-fixtures.md` — concrete request/response transcripts
- `docs/json-rpc-roadmap.md` — roadmap and deferred extension notes
- `docs/json-rpc-status.md` — current progress snapshot and fuller summary
- `docs/json-rpc-checklist.md` — concise remaining-task checklist

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

During `initialize`, CamlFlow returns:

- `protocolVersion`
- `irVersion`
- `capabilities`
- `effectKinds`

The first protocol version is expected to include:

- `initialize`
- `camlflow/check`
- `camlflow/compile`
- `camlflow/run`
- `shutdown`
- `exit`

### Current method schemas

#### `initialize`

Host request params:

```json
{}
```

Server result fields:

- `protocolVersion: string`
- `irVersion: string`
- `capabilities: object`
- `effectKinds: string[]`

#### `camlflow/check`

Host request params:

```json
{
  "program": {
    "path": "string",
    "includePaths": ["string"],
    "skillsDir": "string | null"
  },
  "entry": "string (optional, ignored by check)",
  "input": "json (optional, ignored by check)"
}
```

Server result fields:

- `modules: int`
- `rootModule: string`

#### `camlflow/compile`

Host request params use the same `program` object shape as `camlflow/check`.

Server result fields:

- `irVersion: string`
- `artifact: program-json`

`artifact.version` is currently the same as `irVersion`.

#### `camlflow/run`

Host request params:

```json
{
  "program": {
    "path": "string",
    "includePaths": ["string"],
    "skillsDir": "string | null"
  },
  "entry": "string",
  "input": "any valid JSON value"
}
```

Server result fields:

- `runId: string`
- `stepsRun: int`
- `output: json | null`

`input` is optional; if omitted, the workflow must not require an argument.

#### `shutdown`

Host request params:

```json
{}
```

Server result:

```json
null
```

#### `exit`

Host sends a notification or request with method `exit`.

The current implementation stops the server loop after receiving it.

### Current error code table

The current implementation uses these JSON-RPC error codes.

#### Standard JSON-RPC shaped errors

- `-32600` — invalid JSON-RPC request payload
- `-32601` — method not found

#### CamlFlow server lifecycle errors

- `-32002` — server not initialized

#### CamlFlow operation errors

- `-32010` — `camlflow/check` failed
- `-32011` — `camlflow/compile` failed
- `-32012` — `camlflow/run` failed

### Error code semantics

#### `-32600` invalid request

Returned when the incoming payload is not a valid JSON-RPC request object for the current server.

Typical causes:

- missing `jsonrpc`
- unsupported `jsonrpc` version
- missing `method`
- malformed request envelope

#### `-32601` method not found

Returned when the request method is well-formed but unsupported.

#### `-32002` server not initialized

Returned when the host calls a method that requires prior `initialize` before the server has been initialized.

#### `-32010` check failed

Returned when `camlflow/check` fails due to program loading, parse, module-resolution, or typing errors.

#### `-32011` compile failed

Returned when `camlflow/compile` fails due to program loading, parse, module-resolution, or typing errors.

#### `-32012` run failed

Returned when `camlflow/run` fails due to:

- program load/check failures
- invalid host effect responses
- host-side effect execution failures
- runtime evaluation errors

When possible, CamlFlow also emits a `camlflow/diagnostic` notification alongside the request error response.

### Compatibility policy

`protocolVersion` and `irVersion` are separate compatibility surfaces.

#### Protocol compatibility

The JSON-RPC protocol version must change when the wire contract changes in a host-visible way.

Changes that require a protocol version bump include:

- removing or renaming methods
- removing or renaming response fields
- changing the meaning of existing fields or error codes
- making a previously optional field required
- adding a new required server → host request during a run
- changing the required handling contract for `camlflow/executeEffect`

Changes that are intended to remain backward-compatible within the same protocol version include:

- documentation clarifications
- adding optional fields that hosts may ignore
- adding optional keys under `details`
- adding new capability flags that default to ignorable behavior
- adding optional notifications that hosts may ignore

Hosts should ignore unknown capability keys, unknown optional fields, and unknown event-specific `details` keys.

#### IR compatibility

`irVersion` applies to compiled artifact structure, not to the outer JSON-RPC transport.

An IR version bump is required when compiled program JSON changes in a way that affects decoding or execution, for example:

- changing required artifact fields
- renaming artifact fields
- changing the meaning of existing IR nodes
- changing encoded type or expression forms incompatibly

Pure documentation changes and additive optional metadata do not require an IR version bump.

#### Relationship between the two versions

- protocol changes do not automatically require an IR version bump
- IR changes do not automatically require a protocol version bump
- hosts that only call `camlflow/run` may care mainly about `protocolVersion`
- hosts that persist or exchange compiled artifacts must also check `irVersion`

### Server → Client requests

During a run, CamlFlow may send requests back to the host.

The first protocol version is expected to include:

- `camlflow/executeEffect`

The current implementation also emits the optional notification:

- `camlflow/trace`

The current implementation also emits the optional notification:

- `camlflow/diagnostic`

Hosts may ignore `camlflow/trace` and `camlflow/diagnostic` if they do not need them.

### Capability semantics

The current `capabilities` object is intentionally coarse for `0.1.0`.

Current meaning:

- `check`, `compile`, `run` — the server implements these host → server methods
- `executeEffect` — the server may issue `camlflow/executeEffect` requests during effectful runs
- `trace`, `diagnostic` — the server may emit these optional notifications
- `renderedPrompt`, `outputSchema` — effect requests include these convenience fields

Decision for `0.1.0`:

- keep the current flat capability map
- treat `trace` and `diagnostic` as optional observability features
- defer finer-grained capability sub-objects until a real compatibility need appears

Host requirements for `0.1.0`:

- hosts must send `initialize` before calling methods that require initialization
- hosts that want to run effectful workflows must handle `camlflow/executeEffect`
- hosts may ignore `camlflow/trace` and `camlflow/diagnostic`
- hosts should ignore unknown future capability keys

### `camlflow/trace` notifications

The current trace stream is safe metadata only. It is intended for logging, debugging, and protocol inspection.

Current events include:

- `run-start`
- `effect-request`
- `effect-result`
- `effect-error`
- `run-finish`
- `run-error`

A trace payload includes:

- `event`
- `runId`
- `step`
- `effect` summary when relevant
- optional `details`

### `camlflow/diagnostic` notifications

The current diagnostic stream is for machine-readable error reporting outside normal request failures.

A diagnostic payload includes:

- `severity`
- `message`
- `method`
- `runId`
- `step`
- `effect` summary when relevant

Current notification shapes:

#### `camlflow/trace`

```json
{
  "event": "string",
  "runId": "string | null",
  "step": "int | null",
  "effect": {
    "kind": "string",
    "name": "string"
  },
  "details": {}
}
```

`effect` may be `null` when the event is run-scoped.
`details` is optional and event-specific.

#### `camlflow/diagnostic`

```json
{
  "severity": "error",
  "message": "string",
  "method": "string | null",
  "runId": "string | null",
  "step": "int | null",
  "effect": {
    "kind": "string",
    "name": "string"
  }
}
```

`effect` may be `null` when the diagnostic is not tied to a single effect step.

### Current host error propagation behavior

If the host returns a JSON-RPC error in response to `camlflow/executeEffect`, CamlFlow currently:

1. treats the effect step as failed
2. emits `camlflow/trace` / `camlflow/diagnostic` notifications when applicable
3. fails the enclosing `camlflow/run` request with `-32012`

This keeps the top-level run contract simple while preserving machine-readable detail in notifications.

For concrete transcripts, see `docs/json-rpc-fixtures.md`.

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

#### `camlflow/executeEffect`

Server → host request params:

```json
{
  "runId": "string | null",
  "step": 1,
  "effect": {
    "kind": "bound-agent | bound-skill | local-prompt-skill | inline-agent",
    "role": "agent | skill",
    "name": "string",
    "input": {},
    "declaredReturnType": "string",
    "outputSchema": {},
    "workingDirectory": "string | null",
    "skillsDirectory": "string | null",
    "skillMarkdown": "string | null",
    "inlineDefinition": "object | null",
    "renderedPrompt": "string",
    "requestedModel": "string | null",
    "unsupportedSettings": ["string"],
    "step": 1,
    "runId": "string | null"
  }
}
```

Host → server success result:

```json
{
  "output": "json value matching the declared CamlFlow return type"
}
```

Host → server failure result should use a JSON-RPC error response.

Recommended shape:

```json
{
  "jsonrpc": "2.0",
  "id": "effect-1",
  "error": {
    "code": -32000,
    "message": "model timeout",
    "data": {
      "retryable": true,
      "category": "timeout",
      "provider": "host-local"
    }
  }
}
```

Host error response guidance:

- `message` should be short and actionable
- `code` may be host-defined if the host has its own error taxonomy
- `data` is optional machine-readable context
- useful optional `data` fields include:
  - `retryable: boolean`
  - `category: string`
  - `provider: string`
  - `details: object | string`

Current CamlFlow behavior:

- CamlFlow reliably uses the host error `message` when failing the enclosing run
- CamlFlow does not currently preserve host `error.data` as a stable top-level contract
- hosts should treat `error.data` as best-effort debugging context until a richer propagation contract is standardized

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
