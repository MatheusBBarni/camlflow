# CamlFlow Host Adapter Architecture

This document describes the reusable adapter layer to build before doing any deeper host-specific integration work.

The goal is to validate CamlFlow inside one real AI coding host without embedding CamlFlow runtime logic into that host's internals.

Related docs:

- `docs/json-rpc.md` — current JSON-RPC contract
- `docs/json-rpc-roadmap.md` — background and roadmap context
- `packages/camlflow-ts-json-rpc-sdk/README.md` — maintained TypeScript SDK

---

## Core decision

For Beta 1 closeout, CamlFlow should stay its own engine.

The first real-host integration should:

- spawn `camlflow serve --stdio`
- speak the existing JSON-RPC protocol
- let the host execute `camlflow/executeEffect`
- bridge notifications into the host UI/runtime
- keep CamlFlow's final typed outputs authoritative

The first integration should not copy CamlFlow orchestration logic into a host fork.

---

## Why this shape

This is the shortest path to the remaining Beta 1 questions:

- do CamlFlow effect boundaries feel natural in a real coding-agent UX?
- are trace, diagnostics, progress, cancellation, and output chunks enough?
- does the rendered prompt plus structured metadata give hosts the right control surface?
- where does provider/runtime behavior feel awkward once a real host is in the loop?

A thin adapter gives that signal without coupling CamlFlow to one host's internal architecture.

---

## Design constraints

The adapter should assume the current CamlFlow bridge behavior:

- transport is JSON-RPC 2.0 over stdio with `Content-Length` framing
- the server may issue `camlflow/executeEffect` requests during `camlflow/run`
- the server may emit `camlflow/trace`, `camlflow/diagnostic`, `camlflow/progress`, and `camlflow/outputChunk`
- output chunks are advisory only; the final `camlflow/executeEffect` response and final `camlflow/run` result remain authoritative
- cancellation is currently a safe-boundary feature, especially while CamlFlow is waiting on `camlflow/executeEffect`
- the current bridge is simplest when treated as one active run per server process/session

That last point means a per-run host session is a good default for the first adapter.

---

## Primary components

The first reusable adapter should have three primary pieces.

### 1. `CamlFlowHostSession`

Owns the CamlFlow sidecar process and JSON-RPC client lifecycle.

Responsibilities:

- spawn `camlflow serve --stdio`
- call `initialize`
- send `camlflow/run`
- attach cancellation through `AbortSignal` and `$/cancelRequest`
- track per-run ids, status, and teardown
- capture optional transcripts/artifacts for debugging
- wire server notifications into a notification bridge
- wire `camlflow/executeEffect` into a host effect executor

It should be the only layer that knows about the transport details.

### 2. `CamlFlowEffectExecutor`

Maps `camlflow/executeEffect` requests into the host's normal model/tool execution path.

Responsibilities:

- accept the effect request payload
- decide whether to use `effect.renderedPrompt` directly or synthesize a host-specific prompt from structured metadata
- run the effect through the host's normal execution path
- optionally emit advisory output chunks during execution
- return typed JSON as the effect result
- map host failures into JSON-RPC error responses with short, actionable messages

This is the key boundary for Beta 1 learning.

### 3. `CamlFlowNotificationBridge`

Routes CamlFlow notifications into whatever UX surfaces the host already has.

Responsibilities:

- `camlflow/trace` → debug log, transcript, or expandable step details
- `camlflow/progress` → timeline, status bar, step list, or task header
- `camlflow/diagnostic` → error pane, transcript warning, or inline failure surface
- `camlflow/outputChunk` → live preview, streaming area, or partial output pane

This bridge should stay dumb: presentation mapping only, not orchestration.

---

## Supporting helpers

These can stay internal at first and be extracted later if they prove stable.

### `CamlFlowCancellationBridge`

A small helper for:

- host cancel button / abort gesture / abort signal
- forwarding cancellation to the active CamlFlow request
- forwarding cancellation into the in-flight host effect execution path

### `CamlFlowRunArtifacts`

Useful for Beta 1 validation because it makes real-host friction visible.

Suggested captured data:

- start/end timestamps
- workflow path, entrypoint, and input
- raw or normalized notification summaries
- effect summaries and durations
- host error payloads
- cancellation reason
- final typed output

---

## End-to-end flow

The desired runtime flow is:

1. host user chooses a `.cml` entrypoint
2. host creates `CamlFlowHostSession`
3. session spawns `camlflow serve --stdio`
4. session calls `initialize` with notification preferences enabled
5. session calls `camlflow/run`
6. CamlFlow emits progress/trace/diagnostic notifications as the run advances
7. when an effectful step is reached, CamlFlow sends `camlflow/executeEffect`
8. `CamlFlowEffectExecutor` runs that effect through the host's normal model/tool path
9. optional partial output is relayed via `emitOutputChunk(...)`
10. executor returns typed JSON output
11. CamlFlow continues orchestration until final output is produced
12. session returns the final typed workflow result to the host UI
13. host shuts down the CamlFlow session and stores any debug artifacts

---

## Suggested TypeScript shape

The exact names can change, but the separation should look roughly like this:

```ts
import {
  effectOutput,
  spawnCamlFlowClient,
  type CamlFlowDiagnosticNotification,
  type CamlFlowExecuteEffectParams,
  type CamlFlowEffectHandlerContext,
  type CamlFlowOutputChunkNotification,
  type CamlFlowProgressNotification,
  type CamlFlowRunResult,
  type CamlFlowTraceNotification,
  type JsonValue,
} from "camlflow-ts-json-rpc-sdk";

export interface CamlFlowHostSessionOptions {
  command?: string;
  args?: string[];
  cwd: string;
  notifications?: {
    trace?: boolean;
    diagnostic?: boolean;
    progress?: boolean;
  };
  effectExecutor: CamlFlowEffectExecutor;
  notificationBridge: CamlFlowNotificationBridge;
}

export interface CamlFlowEffectExecutor {
  execute(
    params: CamlFlowExecuteEffectParams,
    context: CamlFlowEffectHandlerContext,
    signal?: AbortSignal,
  ): Promise<JsonValue>;
}

export interface CamlFlowNotificationBridge {
  onTrace?(trace: CamlFlowTraceNotification): Promise<void> | void;
  onDiagnostic?(diagnostic: CamlFlowDiagnosticNotification): Promise<void> | void;
  onProgress?(progress: CamlFlowProgressNotification): Promise<void> | void;
  onOutputChunk?(chunk: CamlFlowOutputChunkNotification): Promise<void> | void;
}

export class CamlFlowHostSession {
  // spawn client, initialize, run workflow, cancel, teardown
}

async function createSession(options: CamlFlowHostSessionOptions) {
  const client = spawnCamlFlowClient({
    command: options.command,
    args: options.args,
    cwd: options.cwd,
    effectHandler: async (params, _request, context) => {
      const output = await options.effectExecutor.execute(params, context);
      return effectOutput(output);
    },
    onTrace: async (trace) => options.notificationBridge.onTrace?.(trace),
    onDiagnostic: async (diagnostic) =>
      options.notificationBridge.onDiagnostic?.(diagnostic),
    onProgress: async (progress) =>
      options.notificationBridge.onProgress?.(progress),
    onOutputChunk: async (chunk) =>
      options.notificationBridge.onOutputChunk?.(chunk),
  });

  await client.initialize({
    notifications: {
      trace: options.notifications?.trace ?? true,
      diagnostic: options.notifications?.diagnostic ?? true,
      progress: options.notifications?.progress ?? true,
    },
  });

  return client;
}
```

Use raw JSON-RPC only when the host cannot use TypeScript or Node stream primitives directly.

---

## Prompt strategy

The effect executor should support two modes.

### Mode A — use `renderedPrompt` directly

This is the right first move for the first real host integration because it minimizes unknowns.

Advantages:

- shortest path to end-to-end validation
- tests the prompt shape CamlFlow already produces
- keeps host adapter code small

### Mode B — host-specific prompt synthesis from structured metadata

This is the next step only if Mode A exposes real friction.

Use the structured fields already present on the effect request:

- `kind`
- `role`
- `name`
- `input`
- `declaredReturnType`
- `outputSchema`
- `skillMarkdown`
- `inlineDefinition`
- `requestedModel`

That allows the host to preserve its own execution style without losing typed boundaries.

---

## Error handling rules

The adapter should keep error handling boring and explicit.

Rules:

- host-side effect failures should return JSON-RPC errors, not fake JSON outputs
- error `message` should be short and actionable
- include optional structured `data` only for diagnostics/debugging
- do not try to invent automatic retries in the first integration
- preserve cancellation as cancellation, not as a generic failure

---

## Extraction order

Build this in three steps.

### Step 1 — one host, local adapter module

- implement the adapter directly in one host fork
- keep the code in one host-local integration directory
- prove end-to-end execution first

### Step 2 — extract reusable adapter layer

Once the first integration stabilizes, extract the transport/session/notification scaffolding into a reusable package or shared module.

### Step 3 — validate in a second host

Only after the first adapter works should CamlFlow be tested in another host fork.

That sequencing gets both signal and leverage.

---

## Beta 1 done criteria for the adapter

This architecture is only successful for Beta 1 if all of the following are true:

- at least one real host fork runs CamlFlow end to end
- that host handles `camlflow/executeEffect`
- trace, diagnostic, progress, cancellation, and output chunks are all exercised in practice
- multiple real workflows are run through the integration
- the team writes down the major friction points discovered from real usage
- the feedback turns into concrete follow-up for provider/runtime behavior, SDK ergonomics, payload shape, and docs

Until then, the adapter is still a validation path, not a completed product surface.
