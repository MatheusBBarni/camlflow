# `pi-mono` Host Integration Plan

Historical note: this document records the original `pi-mono` fork plan that
proved the integration path with a `/camlflow-run` command. The maintained
CamlFlow-owned integration boundary is now the programmatic
`packages/camlflow-pi-sdk` package; Pi UI registration remains in `pi-mono`.

This document turns the Beta 1 real-host validation goal into a concrete first-host plan.

Recommendation: start with `pi-mono`.

Why:

- it is JS/TS-based, so it can use the maintained CamlFlow TypeScript SDK directly
- it already exposes strong host seams through the pi coding-agent SDK, runtime events, extensions, and TUI/RPC layers
- it matches the target behavior well: multi-step coding-agent execution, tool calls, cancellation, and streamed UI
- it is a better Beta 1 signal source than another CLI-only provider bridge because it exercises a real agent host UX

Related docs:

- `docs/pi-sdk-harness.md`
- `docs/host-adapter-architecture.md`
- `docs/pi-mono-implementation-checklist.md`
- `docs/pi-mono-integration-testing.md`
- `docs/json-rpc.md`
- `packages/camlflow-ts-json-rpc-sdk/README.md`

---

## Integration principle

The `pi-mono` integration should follow the sidecar model.

Do this:

- keep CamlFlow external
- spawn `camlflow serve --stdio`
- use the CamlFlow TypeScript SDK inside the `pi-mono` fork
- map `camlflow/executeEffect` onto pi's normal model/tool execution path
- surface CamlFlow notifications inside pi's existing UI surfaces

Do not do this first:

- do not copy CamlFlow execution logic into pi
- do not merge CamlFlow orchestration into pi's core agent loop
- do not start with nested transport layers like `pi --mode rpc` inside the adapter

For the first pass, use pi's SDK directly, not pi's RPC mode. CamlFlow already provides the transport boundary. Adding pi RPC inside that would create transport-in-transport complexity with little Beta 1 upside.

---

## Best seam inside `pi-mono`

Use pi's SDK plus a thin host command surface.

The first implementation should be a small integration module in the fork, not a deep rewrite.

Good seams already exist in `pi-mono`:

- `packages/coding-agent/src/core/sdk.ts` and `createAgentSession(...)`
- `packages/coding-agent/src/core/agent-session.ts` event subscription model
- `packages/coding-agent/src/main.ts` and the existing runtime construction path
- extension/command surfaces documented in `packages/coding-agent/README.md` and the pi docs

### Recommended first UX

Add one explicit entrypoint such as:

- a slash command like `/camlflow-run`
- or a dedicated command-palette action
- or a lightweight fork-only command wired into the coding-agent package

The UX should ask for or accept:

- workflow path
- optional entrypoint name
- optional JSON input
- optional skills directory override

Keep this explicit for the first pass. Do not try to auto-detect `.cml` files from arbitrary chat messages yet.

---

## Proposed module layout in the fork

A reasonable first layout inside `pi-mono` would be:

```text
packages/coding-agent/src/integrations/camlflow/
  session.ts
  effect-executor.ts
  notification-bridge.ts
  commands.ts
  types.ts
```

The names can change, but the responsibilities should stay separate.

### `session.ts`

Implements `PiCamlFlowHostSession`.

Responsibilities:

- spawn CamlFlow through the TS SDK
- call `initialize`
- call `camlflow/run`
- manage teardown and cancellation
- attach notification callbacks
- pass `camlflow/executeEffect` requests into the pi effect executor

### `effect-executor.ts`

Implements `PiCamlFlowEffectExecutor`.

Responsibilities:

- convert CamlFlow effect metadata into a pi execution request
- run the effect through pi's normal model/tool path using `createAgentSession(...)`
- subscribe to pi session events
- emit CamlFlow output chunks from pi text deltas
- return typed JSON output for the effect
- translate pi failures and aborts into JSON-RPC errors/cancellation

### `notification-bridge.ts`

Implements `PiCamlFlowNotificationBridge`.

Responsibilities:

- map `camlflow/trace` into a debug/log surface
- map `camlflow/progress` into a timeline or status area
- map `camlflow/diagnostic` into an error message or transcript entry
- map `camlflow/outputChunk` into a live preview area

### `commands.ts`

Defines the user-visible entrypoint.

Responsibilities:

- register `/camlflow-run` or equivalent
- collect arguments
- kick off `PiCamlFlowHostSession`
- render the final typed result
- offer cancellation through the normal pi UX

---

## Effect execution strategy

This is the most important design choice.

### Use an ephemeral pi `AgentSession` per effect

For the first pass, each `camlflow/executeEffect` should create a fresh in-memory pi session using the current effective model/tool configuration.

Why this is the right first move:

- it avoids contaminating the user's main chat history
- it keeps effect execution boundaries aligned with CamlFlow boundaries
- it makes cancellation easier
- it keeps state handling simple because CamlFlow already owns orchestration state
- it is the easiest way to learn whether the effect boundary feels natural in practice

Suggested session setup:

- `SessionManager.inMemory()`
- same cwd as the workflow run or effect working directory
- same effective model selection the user chose in pi
- same core tools pi normally exposes
- a minimal dedicated system prompt for "execute one CamlFlow effect and return typed JSON"
- initially disable optional extensions unless there is a strong reason to reuse them

That last point matters. Extension behavior inside hidden effect-worker sessions could introduce noise. Start narrow.

### Why not reuse the visible interactive session?

Avoid that in the first version.

Reusing the live user session would make it harder to:

- preserve a clean transcript
- keep effect execution isolated
- cancel one effect cleanly
- guarantee typed final output extraction
- reason about which host messages belong to user chat versus workflow machinery

---

## Prompt strategy for the pi effect worker

Start with CamlFlow's `effect.renderedPrompt`.

That keeps the first version small and validates CamlFlow's current prompt rendering in a real host.

The worker prompt should still add a narrow host wrapper that tells pi to:

- use tools normally if needed
- produce one final JSON value matching the declared schema
- avoid surrounding commentary
- treat streamed text as advisory only

If this proves awkward, the second pass can synthesize a pi-specific prompt from structured fields like:

- `effect.kind`
- `effect.name`
- `effect.input`
- `effect.outputSchema`
- `effect.skillMarkdown`
- `effect.inlineDefinition`
- `effect.requestedModel`

---

## How to stream output chunks from pi

The pi worker session should subscribe to its own events.

Useful mappings:

- pi `message_update` text deltas from the effect worker → `emitOutputChunk(...)`
- pi tool execution start/end events → local pi UI timeline details for that effect
- final pi assistant message → parsed JSON result returned to CamlFlow

Important rule:

- streamed deltas are only advisory
- only the parsed final JSON result should be returned as the `camlflow/executeEffect` success payload

---

## Cancellation path

Cancellation must bridge both systems.

### Host-side flow

1. user presses pi's normal abort gesture
2. the workflow command aborts the active `AbortController`
3. `PiCamlFlowHostSession` sends `$/cancelRequest` for the active CamlFlow run
4. if an effect worker session is active, call `session.abort()` on that pi worker too
5. surface the result as cancelled, not as a generic failure

The first version only needs safe-boundary correctness, matching CamlFlow's current contract.

---

## Notification mapping in pi

Map CamlFlow notifications onto the cheapest real pi surfaces first.

### `camlflow/trace`

First pass:

- append compact debug lines to a transcript/debug area
- or show them behind a collapsible "workflow debug" section

### `camlflow/progress`

First pass:

- show current stage in status text
- show current step number
- optionally keep a short timeline list

### `camlflow/diagnostic`

First pass:

- render as a visible error/warning entry in the workflow transcript area

### `camlflow/outputChunk`

First pass:

- show a live preview panel for the current effect
- or append streamed text into the effect transcript block

Keep the UI thin. Beta 1 needs signal, not perfect polish.

---

## Suggested implementation phases

## Phase 1 — command and sidecar launcher

Deliver:

- explicit `/camlflow-run` entrypoint
- workflow path + input collection
- `PiCamlFlowHostSession`
- `initialize` + `camlflow/run`
- final result rendering

Success condition:

- a pure or trivial workflow runs end to end from pi

## Phase 2 — effect execution bridge

Deliver:

- `PiCamlFlowEffectExecutor`
- per-effect ephemeral pi worker session
- final JSON extraction and return
- cancellation of active effect session

Success condition:

- effectful workflows complete through pi's own model/tool path

## Phase 3 — observability bridge

Deliver:

- trace mapping
- progress mapping
- diagnostics mapping
- output chunk mapping

Success condition:

- real pi users can see workflow progress and failures clearly enough to debug runs

## Phase 4 — real validation runs

Run at least:

- `examples/basic/main.cml`
- `examples/provider-hooks/workflow.cml`
- `examples/orchestrator-session/main.cml`

For each run, record:

- what felt natural
- what felt awkward
- where metadata was missing
- where prompt rendering was insufficient
- where cancellation felt racy
- where pi wanted more control than the current CamlFlow contract provides

---

## Main risks to watch

### 1. Final JSON extraction from pi output

pi is a coding agent, not a schema-locked response API by default.

The worker session will need a strict final-output convention and host-side JSON parsing before returning to CamlFlow.

### 2. Extension interference

Some pi extensions may make sense for visible sessions but not for hidden effect workers.

Default to a narrow worker runtime first.

### 3. Overly chatty streaming

pi text deltas may be too noisy as `outputChunk` traffic.

If so, batch or coalesce chunks in the executor before emitting them.

### 4. Effect isolation versus host memory

A fresh worker per effect is correct for validation, but some hosts may later want run-scoped memory.

Do not optimize for that until the first integration is working.

### 5. Model/provider awkwardness

pi's chosen model or tool behavior may not fit every CamlFlow effect equally well.

That is useful Beta 1 feedback, not a reason to deeply couple the systems early.

---

## What counts as done

The `pi-mono` integration is a successful Beta 1 closeout input only when all of this is true:

- pi runs at least one non-trivial CamlFlow workflow end to end
- `camlflow/executeEffect` is handled through pi's normal model/tool path
- progress, cancellation, diagnostics, and output chunks are all exercised
- multiple workflows are run in normal coding-agent usage, not only toy smoke tests
- the biggest friction points are written down and fed back into CamlFlow runtime/provider/SDK/docs work

At that point, the real-host follow-up can move from "remaining Beta 1 work" into documented Beta 2 input.

---

## Short recommendation

If only one host is used first, use `pi-mono`.

Build it as:

- one explicit command surface
- one thin CamlFlow sidecar session wrapper
- one pi-backed effect executor
- one notification bridge

That is the fastest path to real UX feedback without hard-coding CamlFlow into one host's internals.
