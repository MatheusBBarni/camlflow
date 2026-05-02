# camlflow-ts-json-rpc-sdk

TypeScript SDK for the current CamlFlow JSON-RPC bridge implemented in:

- `lib/rpc_protocol.ml`
- `lib/rpc_stdio.ml`
- `lib/rpc_server.ml`
- `lib/effect_request.ml`

The SDK targets the bridge as it exists today:

- JSON-RPC 2.0 over stdio
- `Content-Length` framing
- host-to-server methods:
  - `initialize`
  - `camlflow/check`
  - `camlflow/compile`
  - `camlflow/run`
  - `shutdown`
  - `exit`
- server-to-host traffic:
  - request: `camlflow/executeEffect`
  - notifications: `camlflow/trace`, `camlflow/diagnostic`, `camlflow/progress`, `camlflow/outputChunk`

## What it includes

- protocol and payload types for initialize, run/check/compile, effect requests, trace, diagnostics, progress, and output-chunk notifications
- a `Content-Length` parser/encoder for raw stream integrations
- a high-level Node client that can:
  - attach to existing streams
  - spawn `camlflow serve --stdio`
  - answer `camlflow/executeEffect` requests with typed JSON

## Install

```sh
npm install
npm run build
npm test
```

## Example

```ts
import {
  effectOutput,
  spawnCamlFlowClient,
  type CamlFlowExecuteEffectParams,
} from "camlflow-ts-json-rpc-sdk";

const client = spawnCamlFlowClient({
  command: "dune",
  args: ["exec", "./bin/main.exe", "--", "serve", "--stdio"],
  cwd: process.cwd(),
  effectHandler: async ({ effect }: CamlFlowExecuteEffectParams) => {
    const input =
      typeof effect.input === "object" && effect.input !== null ? effect.input : {};

    switch (`${effect.kind}:${effect.name}`) {
      case "bound-agent:greeter":
        return effectOutput(`hello ${(input as { name?: string }).name ?? "friend"}`);
      case "local-prompt-skill:caveman":
        return effectOutput(String((input as { prompt?: string }).prompt ?? ""));
      case "inline-agent:reviewer":
        return effectOutput("inline-review");
      default:
        return effectOutput(null);
    }
  },
  onTrace: async (trace) => {
    console.log("trace", trace);
  },
  onDiagnostic: async (diagnostic) => {
    console.error("diagnostic", diagnostic);
  },
  onProgress: async (progress) => {
    console.log("progress", progress);
  },
  onOutputChunk: async (chunk) => {
    console.log("outputChunk", chunk);
  },
});

async function main(): Promise<void> {
  await client.initialize({
    notifications: {
      trace: true,
      diagnostic: true,
      progress: true,
    },
  });

  const result = await client.run<string>({
    program: {
      path: "examples/provider-hooks/workflow.cml",
      includePaths: [],
      skillsDir: "examples/provider-hooks/skills",
    },
    entry: "main",
    input: "Ada",
  });

  console.log(result.output);
  await client.shutdownAndExit();
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
```

## Runnable repository examples

The repository also includes maintained SDK-backed TypeScript example sources in:

- `examples/provider-hooks.ts`
- `examples/attach-streams.ts`
- `examples/problem-coach.ts`
- `examples/cancellation.ts`
- `examples/shared.ts`
- `examples/README.md`

From `packages/camlflow-ts-json-rpc-sdk/` you can run:

```sh
npm run example:provider-hooks
npm run example:attach-streams
npm run example:problem-coach
npm run example:cancellation
```

These examples demonstrate the two main SDK integration styles:

- high-level `spawnCamlFlowClient(...)`
- low-level `new CamlFlowJsonRpcClient({ readable, writable, ... })`

`npm run build` compiles them to `examples-dist/` before the runnable scripts execute.

They now cover:

- a small string-returning workflow
- a larger structured-output workflow
- host-side cancellation with `AbortSignal`
- optional progress callbacks through `camlflow/progress`
- typed output-chunk callbacks through `camlflow/outputChunk`

## `pi-mono` harness scaffold

This harness is historical/manual validation coverage for the original
`/camlflow-run` prototype. New Pi integrations should use
[`../camlflow-pi-sdk`](../camlflow-pi-sdk), which wraps this JSON-RPC SDK behind
a typed programmatic API and leaves command/UI registration to `pi-mono`.

The package now also includes a small Node-based harness for automating the
`pi-mono` host checks described in the repository docs.

From `packages/camlflow-ts-json-rpc-sdk/`:

```sh
npm run doctor:pi-mono
npm run test:pi-mono:launchers
CAMLFLOW_PI_MONO_E2E=1 npm run test:pi-mono
```

The split is intentional:

- `doctor:pi-mono` reports whether the local `pi-mono` checkout, wrapper
  scripts, required build artifacts, and current `camlflow` checkout are ready
- `test:pi-mono:launchers` validates the shell-wrapper contract without needing
  a working `pi-mono` build
- `test:pi-mono` runs the real host checks through `pi --print`

Model-backed host tests are opt-in and require:

```sh
CAMLFLOW_PI_MONO_E2E=1 \
CAMLFLOW_PI_MONO_MODEL_E2E=1 \
CAMLFLOW_PI_MONO_PROVIDER=<provider> \
CAMLFLOW_PI_MONO_MODEL=<model> \
npm run test:pi-mono
```

The slower repo-triage E2E case is additionally gated by
`CAMLFLOW_PI_MONO_DEEP_E2E=1`.

## Session notification preferences

`initialize(...)` accepts optional notification preferences:

```ts
await client.initialize({
  notifications: {
    trace: false,
    diagnostic: true,
    progress: true,
  },
});
```

These toggles apply to the current JSON-RPC session.

## Cancellation

The SDK now supports host-driven cancellation in two ways:

- pass `{ signal }` to `initialize`, `check`, `compile`, `run`, or `shutdown`
- call `client.cancelRequest(id)` directly if you are managing ids yourself

For `run(...)`, aborting the signal sends `$/cancelRequest` to CamlFlow and rejects the local promise with `JsonRpcRequestCancelledError`.

If the server replies with `-32800`, the SDK also normalizes that into `JsonRpcRequestCancelledError`.

The current bridge treats cancellation as a safe-boundary feature, especially while CamlFlow is waiting for `camlflow/executeEffect` or before the next observed effect boundary.

## Progress notifications

The SDK can receive optional `camlflow/progress` notifications through `onProgress`.

These notifications are advisory UI metadata. They do not replace the final typed result contract.

## Output chunk notifications

The SDK includes a live `onOutputChunk` callback surface plus effect-handler helpers for streaming effect output.

Current behavior:

- `initialize().capabilities.streaming` is `true`
- effect handlers receive a third `context` argument with `emitOutputChunk(...)`
- effect handlers can also forward iterable/async-iterable text streams with `context.relayTextOutput(...)`
- the package also exports `relayOutputChunks(...)` and `relayTextOutput(...)` for custom wiring
- `context.emitOutputChunk({ streamId, format, delta, done })` fills `declaredReturnType` and `outputSchema` from the active effect request by default
- pass `declaredReturnType: null` and `outputSchema: null` explicitly to emit an advisory compatibility preview
- CamlFlow relays those `camlflow/outputChunk` notifications back to the host session, including typed metadata or `null` metadata
- typed `done: false` chunks are stream observations; typed `done: true` chunks can complete the active effect from `delta` after normal output validation
- hosts may still return `effectOutput(...)` after a typed final chunk; CamlFlow tolerates the late matching JSON-RPC response

Example:

```ts
effectHandler: async ({ effect }, _request, context) => {
  if (`${effect.kind}:${effect.name}` !== "bound-agent:greeter") {
    return effectOutput("");
  }

  const name = String((effect.input as { name?: string }).name ?? "friend");
  const output = await context.relayTextOutput(
    (async function* () {
      yield "hello ";
      yield name;
    })(),
    { streamId: "greeter-stream" },
  );

  return effectOutput(output);
};
```

## Notes

- `initialize()` returns both `protocolVersion` and `irVersion` so hosts can separately reason about transport compatibility and compiled-artifact compatibility.
- `initialize().capabilities.cancelRequest` tells hosts whether `$/cancelRequest` is supported.
- `initialize().capabilities.progress` tells hosts whether `camlflow/progress` may be emitted.
- `initialize().capabilities.streaming` tells hosts whether `camlflow/outputChunk` notifications are available; it is currently `true`.
- `compile()` returns `irVersion` plus the IR artifact as generic JSON by default. The bridge does not expose a smaller dedicated compile-artifact schema.
- `effect.inlineDefinition` is typed from CamlFlow's current IR serialization, including inline agent metadata and source locations.
- `exit` is modeled as a notification because that is how the current host examples shut the server down.
- `npm test` runs smoke tests against the real CamlFlow stdio server, the repository's Node host examples, and the compiled SDK-backed examples in this package.
