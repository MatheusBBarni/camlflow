# CamlFlow JSON-RPC Deferred Extensions

## Status

Design notes only.

Nothing in this document is implemented by the current `0.1.0` protocol.
These notes exist to make future work more deliberate and more compatible with the current bridge.

Current stable references:

- `docs/json-rpc.md`
- `docs/json-rpc-fixtures.md`
- `docs/json-rpc-roadmap.md`

---

## Purpose

This document formalizes the three deferred protocol areas that came up during the initial JSON-RPC bridge work:

1. cancellation
2. progress notifications
3. streaming previews

The goal is to define likely direction, invariants, and non-goals **before** implementation starts.

---

## Shared design principles

These principles apply to all deferred extensions below.

### 1. Preserve the typed final-result contract

CamlFlow's core guarantee is still:

- the host returns JSON
- CamlFlow validates it against the declared type
- only validated final values advance workflow state

Any future extension must keep that invariant intact.

### 2. Prefer additive protocol changes

Deferred extensions should, as much as possible, be introduced as:

- optional notifications
- optional capability flags
- optional request fields

That keeps existing hosts compatible for longer.

### 3. Keep host integrations simple first

If a feature can be implemented as either:

- a broad new runtime model, or
- a narrow additive protocol feature

prefer the narrower feature first.

### 4. Make observability explicit

If future cancellation, progress, or streaming behavior changes run state, hosts should be able to observe that through explicit notifications rather than implicit timing behavior.

---

## 1. Cancellation

## Why it matters

Hosts may need to stop a run when:

- the user presses cancel in the UI
- the host session is reset
- the host has its own timeout budget
- an in-flight effect step is no longer useful

## Preferred direction

Start by designing around JSON-RPC request cancellation semantics, with a fallback CamlFlow-specific method only if needed.

Preferred order:

1. support `$/cancelRequest`
2. if that proves insufficient, add `camlflow/cancelRun`

## Proposed cancellation target

Cancellation should target one of:

- the original host → server run request id
- an active `runId`

The protocol should avoid cancellation targeted at arbitrary internal runtime state.

## Proposed behavior

If a run is cancelled:

1. CamlFlow marks the run as cancellation-requested
2. if CamlFlow is blocked on `camlflow/executeEffect`, the run should terminate cleanly at the next safe boundary
3. the original `camlflow/run` request should complete as cancelled, not as a successful result
4. CamlFlow should emit an observable run-level event

## Proposed notifications

Cancellation should emit a trace event like:

- `run-cancelled`

Possible trace payload:

```json
{
  "event": "run-cancelled",
  "runId": "run-1",
  "step": 2,
  "effect": null,
  "details": {
    "reason": "host-cancelled"
  }
}
```

A diagnostic may also be emitted when useful, but cancellation should not require a diagnostic if the trace event already carries enough machine-readable intent.

## Response semantics

If cancellation is surfaced as a request failure, the protocol should use a distinct cancellation code rather than overloading generic run failure.

Recommended direction:

- prefer a dedicated cancelled code
- do not fold cancellation into `-32012`

That keeps cancellation distinguishable from ordinary execution failure.

## Non-goals

Cancellation does **not** imply:

- durable checkpointing
- automatic resume
- partial result recovery
- host control over already-committed workflow state

## Open questions

- should the first terminal event win if an effect result arrives while cancellation is racing?
- should cancelled runs emit diagnostics by default or only trace events?
- should a host be allowed to cancel only the top-level run, or also a nested effect request explicitly?

---

## 2. Progress notifications

## Why it matters

Hosts often want to show UI feedback while a run is active.

Without progress notifications, the host only sees:

- the initial run request
- optional trace notifications
- the final result or error

That is enough for correctness, but not ideal for UI.

## Preferred direction

Add a dedicated optional notification:

- `camlflow/progress`

This should remain advisory and UI-oriented.

## Proposed payload shape

```json
{
  "runId": "run-1",
  "stage": "effect-start",
  "step": 2,
  "message": "Executing bound-agent greeter",
  "completedSteps": 1,
  "knownSteps": null,
  "cancellable": true
}
```

Recommended fields:

- `runId: string`
- `stage: string`
- `step: int | null`
- `message: string | null`
- `completedSteps: int | null`
- `knownSteps: int | null`
- `cancellable: boolean | null`

## Suggested stage vocabulary

A minimal useful set would be:

- `check-start`
- `check-finish`
- `compile-start`
- `compile-finish`
- `run-start`
- `effect-start`
- `effect-finish`
- `run-finish`
- `run-error`
- `run-cancelled`

## Semantics

Progress should be treated as:

- best-effort
- monotonic when possible
- safe to ignore

Hosts must not treat progress notifications as authoritative proof that workflow state has committed.

## Non-goals

Progress does **not** need to provide:

- exact percent completion
- a complete static step count ahead of time
- detailed token-level model telemetry

Step-oriented progress is enough for the first iteration.

## Open questions

- should `camlflow/progress` remain separate from `camlflow/trace`, or should trace be extended instead?
- should hosts be able to opt out of progress separately from trace?
- should pure-step milestones be emitted by default or only effect milestones?

---

## 3. Streaming previews

## Why it matters

Some hosts may want to display:

- token-by-token previews
- chunked partial model output
- partial thought or draft previews during a long effect step

That can improve UX, but it is dangerous if it becomes entangled with typed workflow state.

## Preferred direction

If streaming is added, it should remain explicitly non-authoritative.

Possible notification names:

- `camlflow/effectStream`
- `camlflow/outputChunk`

## Proposed payload shape

One possible effect-stream payload:

```json
{
  "runId": "run-1",
  "step": 3,
  "streamId": "stream-1",
  "format": "text",
  "delta": "partial chunk",
  "done": false
}
```

Recommended fields:

- `runId: string`
- `step: int | null`
- `streamId: string`
- `format: string`
- `delta: string | object`
- `done: boolean`

## Core invariant

Only the final `camlflow/executeEffect` response should be treated as the authoritative typed result.

Streaming events must **not**:

- mutate typed workflow state
- count as completed effect output
- bypass final JSON validation

## Host model

Hosts are free to:

- show streaming previews locally
- buffer or discard chunks
- ignore the stream entirely

CamlFlow should only relay stream events if there is a clear protocol need and the extension stays optional.

## Non-goals

Streaming does **not** imply:

- resumable partial outputs
- typed incremental workflow execution
- host-visible internal runtime snapshots

## Open questions

- should stream payloads be text-only initially, or allow structured JSON deltas?
- should streaming notifications be attached only to effect steps, or also to top-level run output?
- how should stream completion and cancellation interact?

---

## Recommended implementation order

If these extensions are implemented later, the recommended order remains:

1. cancellation
2. progress notifications
3. optional streaming previews

Reasoning:

- cancellation protects correctness and user control first
- progress improves UX without changing authority boundaries
- streaming has the highest complexity-to-value ratio and the most room for accidental semantic drift

---

## Compatibility guidance for future rollout

When these features are introduced, prefer:

- new capability flags such as `cancel`, `progress`, `streaming`
- optional notifications that older hosts may ignore
- preserving `camlflow/run` and `camlflow/executeEffect` final-result behavior unchanged

Any rollout that changes the meaning of existing fields or errors should trigger a protocol version change.
