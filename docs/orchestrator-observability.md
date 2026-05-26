# Orchestrator Observability, Cancellation, and Resume

The generic orchestrator package normalizes host-side lifecycle signals without
changing the JSON-RPC protocol.

## Event stream

`createOrchestratorHarness({ eventSink })` automatically emits timestamped
events for sandbox creation, sandbox readiness, session creation, prompt
start/finish/error, workflow start/finish/error, session close, and sandbox
close.

Hosts can also emit the remaining event kinds themselves when they integrate
their own hooks or manual instrumentation: prompt chunks, shell start/finish,
cancellation, and resume capture.

These events are host logs, not `.cml` syntax. Hosts can write them to stdout,
files, telemetry callbacks, or test assertions.

## Cancellation

`createCancellationScope()` returns an `AbortSignal` and an idempotent
`cancel(reason)` method. Hosts should pass the signal into sandbox creation,
workflow runs, prompt calls, task calls, and shell calls. The OCaml JSON-RPC
bridge still cancels strongest at effect boundaries; the orchestrator adds
host-level cancellation for work it owns.

## Resume

`createMemoryResumeStore()` captures explicit run snapshots:

- `runId`
- completed `step`
- JSON-safe `state`
- optional failed raw output
- optional parser or provider failure metadata

Resume should only be offered when the selected agent provider can safely restore
message history or when the workflow step is known to be complete. Hosts should
surface structured-output failure metadata so users can repair parser/schema
issues without rerunning completed work unnecessarily.
