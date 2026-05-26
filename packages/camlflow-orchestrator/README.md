# camlflow-orchestrator

Generic sandbox orchestrator primitives for `.cml` CamlFlow workflows.

This package is the host-side layer named by
[`docs/adr/0002-camlflow-sandbox-orchestrator-boundaries.md`](../../docs/adr/0002-camlflow-sandbox-orchestrator-boundaries.md).
It does not replace `.cml` authoring or the OCaml compiler/runtime. Instead, it
defines reusable TypeScript interfaces and utilities for host packages that run
typed workflows inside sandbox policy.

## Included in the first slice

- `SandboxProvider` and `SandboxHandle` interfaces
- `AgentProvider`, `SessionStore`, `ToolProvider`, `PromptResolver`, and
  lifecycle hook interfaces
- strict JSON validation for workflow inputs, effect results, and session data
- result-parser adapters for raw JSON, functions, `parse`, and `safeParse`
- abort-signal composition and output-chunk relay helpers
- an in-memory session store for tests and ephemeral hosts

The Pi compatibility package remains `camlflow-pi-sdk`. During migration, Pi
worker creation, Pi model registry access, Pi auth checks, and Pi tool creation
stay there while shared lifecycle code moves here.

## Test

```sh
npm install
npm test
```
