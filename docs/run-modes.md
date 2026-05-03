# Run Modes

CamlFlow workflows can run in four practical modes. The `.cml` contract stays
the same; the difference is who handles effects such as agents and skills.

Use this guide when deciding how to execute a workflow after it type-checks.

## Summary

| Mode | Best for | Effect executor |
| --- | --- | --- |
| Deterministic CLI | authoring, parser/type/runtime checks, CI smoke | built-in placeholder runtime |
| Provider CLI | quick terminal-owned model runs | configured provider CLI |
| JSON-RPC host | custom applications and non-Pi hosts | host process callback |
| Pi SDK harness | Flue-style Pi agent orchestration | Pi worker session in a sandbox |

## Deterministic CLI

Use deterministic CLI runs first. They are fast, local, and do not require model
credentials.

```sh
opam exec -- dune exec camlflow -- check examples/first-workflow/main.cml
opam exec -- dune exec camlflow -- run examples/first-workflow/main.cml \
  --input examples/first-workflow/input.json
```

What this validates:

- source parsing
- type checking
- module resolution
- JSON input decoding
- effect sequencing
- final output validation

What it does not validate:

- model quality
- provider credentials
- host tool access
- Pi sandbox behavior

Bound agents and skills return deterministic placeholder JSON, so an effectful
workflow may return a syntactically valid but semantically empty value.

## Provider CLI

Use provider CLI runs when you want a terminal command to own real model
execution.

```sh
opam exec -- dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only \
  --trace-provider
```

This mode is useful for local end-to-end smoke tests and prompt iteration.
CamlFlow still owns typed orchestration and output validation, but the provider
CLI owns model execution, credentials, and tool behavior.

Use provider config only for host/runtime settings. Keep secrets out of `.cml`
files and committed `camlflow.json`.

See [Provider execution](./provider-execution.md) for provider names, sandbox
flags, model selection, unsupported inline settings, and trace output.

## JSON-RPC Host

Use JSON-RPC host mode when another process should own effect execution.

```sh
opam exec -- dune exec camlflow -- serve --stdio
```

The bridge speaks JSON-RPC 2.0 over stdio with `Content-Length` framing. A host
initializes the bridge, starts a run, handles `camlflow/executeEffect`, and
returns JSON matching the declared effect return type.

Use one server process per active run. The current bridge is single-active-run
by design.

Start with:

- [JSON-RPC protocol](./json-rpc.md)
- [TypeScript JSON-RPC SDK](../packages/camlflow-ts-json-rpc-sdk/README.md)
- [JSON-RPC host example](../examples/json-rpc-host/README.md)

## Pi SDK Harness

Use the Pi SDK harness when TypeScript host code wants a Flue-style API:

```ts
const harness = createPiCamlFlowHarness({ runtime });
const agent = await harness.init({ sandbox: "workspace-write" });

try {
  const session = await agent.session("triage");
  const answer = await session.prompt("Summarize the current repo.");

  const result = await agent.runWorkflow("examples/repo-triage/main.cml", {
    skillsDir: "examples/repo-triage/skills",
    input: {
      task: "Find integration risks.",
      suspected_area: "Pi SDK harness",
      file_hints: ["packages/camlflow-pi-sdk/src/index.ts"],
      goals: ["map the entrypoints"],
      constraints: ["use concrete file paths"],
      mode: { tag: "QuickScan" },
    },
  });

  console.log(answer, result.output);
} finally {
  await agent.close();
}
```

The harness owns a sandbox for the agent lifetime. Sessions share that sandbox
but keep message history separate. Use `session.task(...)` for one-shot child
sessions and `session.shell(...)` only where the sandbox allows trusted shell
execution.

See [Pi SDK harness](./pi-sdk-harness.md) for sandbox presets, shell
constraints, cancellation, lifecycle, result parsing, and JSON contracts.

## Choosing A Mode

Use this order when bringing up a workflow:

1. `check` the source.
2. Run deterministic CLI execution with representative JSON input.
3. Add `camlflow.json` only for stable repeated defaults.
4. Use provider CLI for terminal-owned model smoke tests.
5. Use JSON-RPC for application-owned effect execution.
6. Use Pi SDK harness for Flue-style agent sessions and sandboxed Pi workflows.

If a workflow fails before the first effect, fix `.cml`, config, or input JSON.
If it fails at an effect boundary, inspect the provider, host, or Pi worker
output against [JSON encoding](./json-encoding.md).
