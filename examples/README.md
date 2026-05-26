# CamlFlow examples

These examples use the new `.cml`-first sandbox orchestrator shape. The `.cml`
files are the user-authored contracts; hosts and SDKs decide sandbox, provider,
tool, logging, cancellation, and resume policy around them.

## Path

1. `basic` - smallest typed workflow smoke test.
2. `orchestrator-session` - issue triage workflow for sandboxed agents and skills.
3. `provider-hooks` - JSON-RPC/provider effect flow used by host smoke tests.
4. `json-rpc-host` - minimal host process around the provider-hooks workflow.
5. `project-config` - nearest `camlflow.json` defaults for an orchestrator project.

Run from the repository root:

```sh
opam exec -- dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
opam exec -- dune exec camlflow -- run examples/orchestrator-session/main.cml \
  --input examples/orchestrator-session/input.json
opam exec -- node examples/json-rpc-host/host.js
```

Deterministic runs validate parsing, typing, JSON input, effect sequencing, and
declared output shapes. Real model/tool behavior belongs to the host layer.
