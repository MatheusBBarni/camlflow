# camlflow-pi-sdk

Programmatic Pi adapter for CamlFlow workflows.

This package wraps `camlflow-ts-json-rpc-sdk` and maps each
`camlflow/executeEffect` request onto an ephemeral in-memory Pi worker session.
It intentionally does not register or parse `/camlflow-run`; command palettes,
slash commands, file actions, and other UI entrypoints remain owned by `pi-mono`.

See
[`docs/adr/0001-programmatic-camlflow-pi-sdk.md`](../../docs/adr/0001-programmatic-camlflow-pi-sdk.md)
for the integration boundary decision.

## Install

```sh
npm install camlflow-pi-sdk camlflow-ts-json-rpc-sdk @mariozechner/pi-coding-agent
```

`@mariozechner/pi-coding-agent` is a peer dependency so the host controls the
exact Pi SDK version.

## Usage

For complete, compile-checked host-side examples, see
[`examples/`](./examples). The examples cover a native Pi command or palette
action, streamed worker output, and user cancellation.

```ts
import { createPiCamlFlowHostSession } from "camlflow-pi-sdk";

const host = createPiCamlFlowHostSession({
  runtime: {
    cwd: runtime.cwd,
    session: {
      model: runtime.session.model,
      thinkingLevel: runtime.session.thinkingLevel,
    },
    services: {
      agentDir: runtime.services.agentDir,
      authStorage: runtime.services.authStorage,
      modelRegistry: runtime.services.modelRegistry,
    },
  },
  onProgress: async (progress) => {
    console.log("progress", progress.stage, progress.message);
  },
  onDiagnostic: async (diagnostic) => {
    console.error("diagnostic", diagnostic.message);
  },
  onTrace: async (trace) => {
    console.log("trace", trace.event);
  },
  onOutputChunk: async (chunk) => {
    console.log("chunk", chunk.delta);
  },
});

const controller = new AbortController();
const result = await host.runWorkflow({
  workflowPath: "examples/problem-coach/main.cml",
  entrypoint: "main",
  input: {
    problem_name: "two sum",
    language: { tag: "Python" },
  },
  skillsDir: "examples/problem-coach/skills",
  signal: controller.signal,
});

console.log(result.output);
```

By default, the adapter starts `camlflow serve --stdio` and talks to it through
the existing JSON-RPC bridge. Override `camlflow.command`, `camlflow.args`, or
`camlflow.cwd` when the host needs to spawn a local checkout through Dune.

## Effect Execution

For each CamlFlow effect, the adapter:

- creates a fresh Pi worker session with `SessionManager.inMemory()`
- uses the current Pi model, thinking level, model registry, auth storage, and
  coding tools
- sends CamlFlow's rendered effect prompt with a small JSON-only wrapper
- relays Pi text deltas as `camlflow/outputChunk` notifications
- parses the final assistant message as JSON and returns it through the existing
  `camlflow/executeEffect` response contract

Abort signals are shared by the CamlFlow run request and the active Pi worker
session. Calling `host.cancel()` aborts both sides of the current run.

## Local Validation

```sh
npm install
npm test
```

The package-local tests use injected fake CamlFlow clients and fake Pi worker
sessions, so they do not require live model credentials.
