# CamlFlow JSON-RPC Status

Date: 2026-04-17  
Branch: `feat/json-rpc-bridge`

This document is a snapshot of what is done so far on the JSON-RPC host-integration track and what remains.

For a shorter task list, see `docs/json-rpc-checklist.md`.

---

## Accomplished so far

### 1. Phase 0 protocol docs landed

Completed:

- `docs/json-rpc.md`
- `docs/json-rpc-roadmap.md`
- README links to the JSON-RPC docs and examples

These docs lock the core model:

- CamlFlow is the typed harness/orchestration engine
- external tools are the effect execution backends
- transport is JSON-RPC 2.0 over stdio
- framing is `Content-Length`
- MVP execution is blocking request/response
- MVP server supports one active run per server instance
- v1 does not include suspend/resume or streaming

### 2. Reusable effect request model was extracted

Completed:

- `lib/effect_request.ml`
- export from `lib/camlflow.ml`

This gives CamlFlow a reusable serialized shape for host-executed effect steps.

### 3. Host-backed effect bridge was added

Completed:

- `lib/effect_bridge.ml`
- `lib/providers_codex.ml` refactored to reuse the bridge

This keeps request construction and output validation shared between direct providers and host-backed execution.

### 4. JSON-RPC stdio server was implemented

Completed:

- `lib/rpc_protocol.ml`
- `lib/rpc_stdio.ml`
- `lib/rpc_server.ml`
- `serve` command wiring in `lib/cli.ml`
- CLI dispatch in `bin/main.ml`
- embeddable entrypoint `Camlflow.Rpc_server.run ~input ~output`
- stdio entrypoint `Camlflow.Rpc_server.run_stdio ()`

Current server methods include:

- `initialize`
- `camlflow/check`
- `camlflow/compile`
- `camlflow/run`
- `shutdown`
- `exit`

Current server-to-host method/notifications include:

- `camlflow/executeEffect`
- `camlflow/trace`
- `camlflow/diagnostic`

### 5. Host examples were added

Completed:

- `examples/json-rpc-host/host.js`
- `examples/json-rpc-host/README.md`
- `examples/json-rpc-problem-coach/host.js`
- `examples/json-rpc-problem-coach/README.md`

These prove the end-to-end model for both simple and structured-output workflows.

### 6. Trace and diagnostic notifications were added

Completed in `lib/rpc_server.ml`:

- trace notification: `camlflow/trace`
- diagnostic notification: `camlflow/diagnostic`

Current trace coverage includes events such as:

- `run-start`
- `effect-request`
- `effect-result`
- `run-finish`
- `run-error`

### 7. End-to-end server tests landed

Completed:

- JSON-RPC end-to-end tests in `test/test_camlflow.ml`

Coverage includes:

- initialize + run flow
- host effect round-trips
- pre-initialize failure behavior
- compile result versioning

### 8. Protocol and IR versioning landed

Completed:

- `lib/ir.ml` now carries `ir_version = "0.1.0"`
- compiled artifacts include `version`
- IR decoding accepts missing version for compatibility and rejects unsupported versions
- JSON-RPC `initialize` returns `irVersion`
- JSON-RPC `camlflow/compile` returns `irVersion`

### 9. Protocol fixture and schema docs expanded

Completed:

- `docs/json-rpc-fixtures.md`
- expanded method-schema sections in `docs/json-rpc.md`

Docs now cover:

- `initialize`
- `camlflow/check`
- `camlflow/compile`
- `camlflow/run`
- `shutdown`
- `exit`
- `camlflow/executeEffect`
- `camlflow/trace`
- `camlflow/diagnostic`

### 10. Parallel branch work now also includes a TypeScript SDK commit

Observed on this branch:

- `feat: add TypeScript JSON-RPC SDK for CamlFlow`

That work has now been followed by SDK alignment and smoke-test improvements on this branch.

### 11. SDK types and smoke tests were aligned with the current protocol

Completed in `packages/camlflow-ts-json-rpc-sdk`:

- `CamlFlowInitializeResult` now includes `irVersion`
- `CamlFlowCompileResult` now includes `irVersion`
- `npm test` now runs Node smoke tests against:
  - the SDK client itself
  - `examples/json-rpc-host/host.js`
  - `examples/json-rpc-problem-coach/host.js`
- README instructions now mention `npm test` and the current version fields

---

## Last validated state

Last verified test run for the JSON-RPC bridge slice:

- `dune test` passed with 66 tests after protocol-error coverage was added
- `cd packages/camlflow-ts-json-rpc-sdk && npm test` passed with 3 smoke tests

Recent follow-up documentation additions include:

- explicit error code tables and semantics in `docs/json-rpc.md`
- compatibility policy notes for `protocolVersion` and `irVersion` in `docs/json-rpc.md`
- clearer host error response guidance for `camlflow/executeEffect` in `docs/json-rpc.md`
- capability semantics and host-ignore rules in `docs/json-rpc.md`
- expanded protocol fixtures for invalid requests, unknown methods, run failures, host effect errors, and shutdown/exit in `docs/json-rpc-fixtures.md`
- deferred design notes for cancellation, progress, and streaming in `docs/json-rpc-roadmap.md`
- a formal design-only extensions doc in `docs/json-rpc-deferred-extensions.md`
- this status snapshot in `docs/json-rpc-status.md`
- the short checklist in `docs/json-rpc-checklist.md`

---

## Remaining tasks

## Later / lower priority

### 1. Add direct provider convenience adapters only after host mode is stable

Examples:

- more direct CLI/provider backends
- tool-specific adapters built on top of the shared effect-request model

This should remain secondary to keeping the host protocol stable and well-documented.
