# CamlFlow JSON-RPC Deferred Extensions

## Status

Partially implemented.

The current `0.1.0` bridge now includes an initial cancellation slice using `$/cancelRequest`.
Progress notifications and streaming remain design notes only.
These notes exist to make future work more deliberate and more compatible with the current bridge.

Current stable references:

- `docs/json-rpc.md`
- `docs/json-rpc-fixtures.md`
- `docs/json-rpc-roadmap.md`

---

## Purpose

This document formalizes the three protocol areas that came up during the initial JSON-RPC bridge work:

1. cancellation follow-up after the first implemented slice
2. progress notifications
3. streaming previews

The goal is to define likely direction, invariants, and non-goals **before** broader implementation continues.

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

## Current direction

The first implemented slice now uses JSON-RPC request cancellation semantics through `$/cancelRequest`.

Current implemented behavior:

1. the host may send `$/cancelRequest` targeting the top-level `camlflow/run` request id
2. CamlFlow marks the active run as cancellation-requested
3. if CamlFlow is blocked on `camlflow/executeEffect`, it cancels at that safe boundary
4. the original `camlflow/run` request completes with `-32800`
5. CamlFlow emits `run-cancelled`

Possible future extension, only if that proves insufficient:

- add `camlflow/cancelRun`

## Proposed cancellation target

Cancellation should target one of:

- the original host → server run request id
- an active `runId`

The protocol should avoid cancellation targeted at arbitrary internal runtime state.

## Remaining behavior questions

The current implementation already does the following:

1. marks the run as cancellation-requested
2. cancels cleanly at an observed safe boundary
3. completes the original `camlflow/run` request as cancelled
4. emits an observable run-level event

The remaining questions are about how much farther cancellation should go beyond that first slice.

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

The current implementation now uses a distinct cancellation code rather than overloading generic run failure:

- `-32800` for cancelled runs
- not `-32012`

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
- should pure-compute segments eventually become cancellable before the next effect boundary?

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
