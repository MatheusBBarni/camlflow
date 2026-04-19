# Architecture Summary

## Execution Pipeline
- Parse and lower: `lib/parsing/*` converts OCaml parser output into CamlFlow AST and rejects unsupported MVP syntax early.
- Load modules: `lib/project_loader.ml` resolves project `.cml` modules from the root file plus `-I` include paths, lowercasing path segments.
- Type and compile: `lib/typing/*` checks programs and `lib/ir.ml` defines compiled JSON IR plus version gating.
- Run: `lib/runtime/*` evaluates IR with deterministic defaults or provider hooks.
- Bridge: `lib/effect_request.ml`, `lib/effect_bridge.ml`, `lib/provider*.ml`, `lib/rpc_*`, and `lib/cli.ml` expose provider and JSON-RPC surfaces.

## Host-Integration Invariants
- JSON-RPC is JSON-RPC 2.0 over stdio with `Content-Length`.
- One server process handles one active run at a time.
- `camlflow/executeEffect` is the host boundary; streamed output chunks are advisory, final typed results remain authoritative.
- Cancellation is strongest while waiting at effect boundaries, not as arbitrary preemption of every pure compute step.

## Config And Resolution Invariants
- `camlflow.json` can supply default program, entry, include paths, skills dir, provider settings, sandbox, and trace flags.
- CLI commands without an explicit file may walk upward to the nearest `camlflow.json`.
- Qualified names resolve only against project or include-path `.cml` modules; stdlib-style module calls are unsupported by design.

## Token-Bomb Files
- `test/test_camlflow.ml`
- `lib/rpc_server.ml`
- `lib/typing/typing.ml`
- `lib/ir.ml`
- `lib/cli.ml`

Load only the slice you need before editing those files.
