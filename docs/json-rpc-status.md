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

That is separate from the core host-protocol implementation summarized above.

---

## Last validated state

Last verified test run for the JSON-RPC bridge slice:

- `dune test` passed with 60 tests after the versioning + fixture-doc work

Recent follow-up documentation additions include:

- explicit error code tables and semantics in `docs/json-rpc.md`
- compatibility policy notes for `protocolVersion` and `irVersion` in `docs/json-rpc.md`
- clearer host error response guidance for `camlflow/executeEffect` in `docs/json-rpc.md`
- capability semantics and host-ignore rules in `docs/json-rpc.md`
- deferred design notes for cancellation, progress, and streaming in `docs/json-rpc-roadmap.md`
- this status snapshot in `docs/json-rpc-status.md`
- the short checklist in `docs/json-rpc-checklist.md`

---

## Remaining tasks

## Tests and fixtures

### 1. Expand automated coverage for protocol errors

Useful additions:

- invalid request (`-32600`)
- method not found (`-32601`)
- explicit `camlflow/check` failure (`-32010`)
- explicit `camlflow/compile` failure (`-32011`)
- explicit `camlflow/run` failure (`-32012`)
- host effect error propagation from `camlflow/executeEffect`

### 2. Expand fixture coverage

Useful additions to `docs/json-rpc-fixtures.md`:

- invalid request example
- unknown method example
- host returns JSON-RPC error for `camlflow/executeEffect`
- run failure transcript with diagnostic + trace events
- optional `shutdown` / `exit` transcript

## Host / SDK integration validation

### 3. Re-validate examples against the current docs

Useful checks:

- `examples/json-rpc-host/host.js`
- `examples/json-rpc-problem-coach/host.js`
- any TypeScript SDK examples or smoke tests

Goal:

- ensure example hosts still match the documented request/response shapes

### 4. Add stronger integration testing around host libraries

Possible follow-up:

- smoke tests for the JS/TS host path
- CI checks that exercise the protocol from outside OCaml

## Deferred design work

### 5. Formalize deferred protocol extensions before implementation

These should stay design-only until the core protocol is stable:

- cancellation
- progress notifications
- streaming / chunked output notifications

Recommended order:

1. cancellation
2. progress
3. optional streaming

## Later / lower priority

### 6. Add direct provider convenience adapters only after host mode is stable

Examples:

- more direct CLI/provider backends
- tool-specific adapters built on top of the shared effect-request model

This should remain secondary to keeping the host protocol stable and well-documented.
