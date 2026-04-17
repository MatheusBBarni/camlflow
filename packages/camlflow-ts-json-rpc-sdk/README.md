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
  - notifications: `camlflow/trace`, `camlflow/diagnostic`, `camlflow/progress`
  - reserved scaffold: `camlflow/outputChunk` (not emitted by the current server)

## What it includes

- protocol and payload types for initialize, run/check/compile, effect requests, trace, diagnostics, progress, and the reserved output-chunk scaffold
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
});

async function main(): Promise<void> {
  await client.initialize({
    notifications: {
      trace: true,
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

## Session notification preferences

`initialize(...)` accepts optional notification preferences:

```ts
await client.initialize({
  notifications: {
    trace: false,
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

## Reserved streaming scaffold

The SDK now includes a reserved `onOutputChunk` callback surface plus protocol types for future streaming work.

Current behavior:

- `initialize().capabilities.streaming` is `false`
- the current server does not emit `camlflow/outputChunk`
- hosts should treat streaming as unavailable unless a future server version advertises otherwise

## Notes

- `initialize()` returns both `protocolVersion` and `irVersion` so hosts can separately reason about transport compatibility and compiled-artifact compatibility.
- `initialize().capabilities.cancelRequest` tells hosts whether `$/cancelRequest` is supported.
- `initialize().capabilities.progress` tells hosts whether `camlflow/progress` may be emitted.
- `initialize().capabilities.streaming` tells hosts whether `camlflow/outputChunk` is available; it is currently `false`.
- `compile()` returns `irVersion` plus the IR artifact as generic JSON by default. The bridge does not expose a smaller dedicated compile-artifact schema.
- `effect.inlineDefinition` is typed from CamlFlow's current IR serialization, including inline agent metadata and source locations.
- `exit` is modeled as a notification because that is how the current host examples shut the server down.
- `npm test` runs smoke tests against the real CamlFlow stdio server, the repository's Node host examples, and the compiled SDK-backed examples in this package.
