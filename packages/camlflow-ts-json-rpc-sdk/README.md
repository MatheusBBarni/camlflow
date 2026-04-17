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
  - notifications: `camlflow/trace`, `camlflow/diagnostic`

## What it includes

- protocol and payload types for initialize, run/check/compile, effect requests, trace, and diagnostics
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
});

async function main(): Promise<void> {
  await client.initialize();

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

The repository also includes maintained SDK-backed example scripts in:

- `examples/provider-hooks.js`
- `examples/attach-streams.js`
- `examples/problem-coach.js`
- `examples/README.md`

From `packages/camlflow-ts-json-rpc-sdk/` you can run:

```sh
npm run example:provider-hooks
npm run example:attach-streams
npm run example:problem-coach
```

These examples demonstrate the two main SDK integration styles:

- high-level `spawnCamlFlowClient(...)`
- low-level `new CamlFlowJsonRpcClient({ readable, writable, ... })`

They also cover both a small string-returning workflow and a larger structured-output workflow.

## Notes

- `initialize()` returns both `protocolVersion` and `irVersion` so hosts can separately reason about transport compatibility and compiled-artifact compatibility.
- `compile()` returns `irVersion` plus the IR artifact as generic JSON by default. The bridge does not expose a smaller dedicated compile-artifact schema.
- `effect.inlineDefinition` is typed from CamlFlow's current IR serialization, including inline agent metadata and source locations.
- `exit` is modeled as a notification because that is how the current host examples shut the server down.
- `npm test` runs smoke tests against the real CamlFlow stdio server, the repository's Node host examples, and the SDK-backed example scripts in this package.
