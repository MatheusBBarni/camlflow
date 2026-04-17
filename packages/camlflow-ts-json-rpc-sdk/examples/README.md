# camlflow-ts-json-rpc-sdk examples

These examples show how to drive CamlFlow's JSON-RPC stdio bridge with the
repository's TypeScript SDK.

They assume you are running from this repository checkout, because each example:

- starts `dune exec ./bin/main.exe -- serve --stdio`
- points at repository examples such as `examples/provider-hooks/workflow.cml`
- imports the locally built SDK from `../dist`
- is authored in TypeScript and compiled to `examples-dist/`
- can consume optional trace, diagnostic, progress, and cancellation signals

## Setup

From `packages/camlflow-ts-json-rpc-sdk/`:

```sh
npm install
npm run build
```

## Run the examples

### 1. High-level spawned client

```sh
npm run example:provider-hooks
```

Source: `examples/provider-hooks.ts`

Demonstrates:

- `spawnCamlFlowClient(...)`
- `initialize`, `compile`, and `run`
- a typed effect handler for the provider-hooks workflow
- trace and diagnostic notification callbacks

### 2. Attach to existing streams

```sh
npm run example:attach-streams
```

Source: `examples/attach-streams.ts`

Demonstrates:

- manually spawning `camlflow serve --stdio`
- constructing `new CamlFlowJsonRpcClient({ readable, writable, ... })`
- using the SDK with an already-created process or transport owner

### 3. Structured-output workflow

```sh
npm run example:problem-coach
```

Source: `examples/problem-coach.ts`

Demonstrates:

- a multi-step workflow with structured JSON outputs
- reading JSON input from `examples/problem-coach/input.json`
- routing multiple effect kinds through one SDK effect handler

### 4. Cancellation with progress callbacks

```sh
npm run example:cancellation
```

Source: `examples/cancellation.ts`

Demonstrates:

- `AbortController`-driven cancellation for `client.run(...)`
- normalized `JsonRpcRequestCancelledError`
- progress callbacks through `camlflow/progress`
- observing the `run-cancelled` lifecycle

## Validation

`npm test` also runs smoke coverage for the compiled example scripts so they stay in sync with the current bridge.
