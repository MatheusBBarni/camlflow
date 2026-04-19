# Library Scope

This directory holds the compiler, runtime, provider, RPC, and CLI implementation.

Load @../docs/agent-context/architecture.md before wide refactors.

Working map:
- `parsing/*` lowers OCaml AST into CamlFlow syntax and SHOULD reject unsupported MVP syntax with precise errors.
- `project_loader.ml` and `typing/*` MUST stay aligned on module naming, qualification, and ambiguity rules.
- `ir.ml` is the compatibility boundary for compiled artifacts; version changes need docs and tests.
- `runtime/*`, `effect_request.ml`, `effect_bridge.ml`, and `provider*.ml` MUST stay aligned on invocation metadata and validated JSON outputs.
- `rpc_protocol.ml`, `rpc_stdio.ml`, `rpc_server.ml`, and `cli.ml` expose host-facing contracts; treat them as compatibility-sensitive.

Landmines:
- `rpc_server.ml`, `typing.ml`, `ir.ml`, and `cli.ml` are token bombs; read the smallest relevant slice first.
- The JSON-RPC server is single-active-run; preserve one-run-per-process assumptions unless a deliberate contract change is in scope.
- The default provider path is deterministic placeholder output, so integration behavior may look successful without real model execution.

Verification:
- Run `opam exec -- dune test` after behavior changes.
- Add a targeted case to `../test/test_camlflow.ml` for every user-visible change.
