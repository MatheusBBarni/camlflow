# CamlFlow Agent Guide

## Commands
- MUST install core OCaml dependencies with `opam install . --deps-only --with-test --yes`.
- MUST format OCaml/Dune sources with `opam exec -- dune fmt` before finishing source edits.
- MUST run core regression checks with `opam exec -- dune test`.
- MUST build the CLI and library with `opam exec -- dune build`.
- MUST inspect CLI behavior with `dune exec camlflow -- --help`.
- MUST reproduce source execution with `dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'`.
- MUST start the JSON-RPC bridge with `dune exec camlflow -- serve --stdio`.
- MUST run SDK smoke coverage after `packages/camlflow-ts-json-rpc-sdk` changes with `cd packages/camlflow-ts-json-rpc-sdk && npm install && opam exec -- npm test`.
- SHOULD run extension smoke coverage after `packages/camlflow-vscode` changes with `cd packages/camlflow-vscode && npm run smoke:highlight`.

## Stack
- MUST treat this repo as an OCaml 5.4 + Dune 3.22 core with Node-based SDK/editor packages.
- MUST preserve the compiler/runtime layering: parsing -> project loading -> typing -> IR -> runtime/providers -> RPC/CLI.
- MUST treat the host bridge as JSON-RPC 2.0 over stdio with `Content-Length` framing.
- SHOULD reuse shared provider plumbing in `lib/effect_request.ml`, `lib/effect_bridge.ml`, and `lib/provider_schema.ml` instead of forking adapter logic.

## Boundaries
### Always
- MUST add or update focused regression tests in `test/test_camlflow.ml` for parser, typing, runtime, CLI, project-config, provider, or RPC behavior changes.
- MUST update paired docs when protocol or flag semantics change: `README.md`, relevant `docs/json-rpc*.md`, `docs/provider-execution.md`, and `docs/provider-hooks.md`.
- MUST run package-local tests when touching `packages/`.
- SHOULD prefer reproductions with explicit file arguments instead of relying on cwd-sensitive defaults.

### Ask First
- MUST ask before splitting or heavily restructuring `test/test_camlflow.ml`, `lib/rpc_server.ml`, `lib/typing/typing.ml`, `lib/ir.ml`, or `lib/cli.ml`; they are large and tightly coupled.
- MUST ask before changing JSON-RPC `protocolVersion`, `irVersion`, request or notification names, or provider CLI flag semantics.
- MUST ask before adding dependencies, new CI jobs, or cross-package build steps.

### Never
- NEVER assume one `camlflow serve --stdio` process can multiplex concurrent runs.
- NEVER rely on OCaml stdlib/module-qualified calls such as `List.map` inside `.cml`; only project `.cml` modules resolve.
- NEVER edit `_build/`, `.opam-switch/`, or package build output as source of truth.
- NEVER remove the nearest-`camlflow.json` fallback behavior without updating CLI help, tests, and docs together.

## Landmines
- `check`, `compile`, and `run` without an explicit file may load the nearest `camlflow.json`; repros MUST record cwd and config path.
- Module resolution lowercases module paths and only searches project/include-path `.cml` files; ambiguous or cyclic module errors usually come from path/layout issues, not typing.
- The default runtime returns synthesized placeholder JSON for agents and skills until provider hooks or provider CLI settings are configured.
- The JSON-RPC bridge is single-active-run by design and cancellation is strongest at effect boundaries; host integrations SHOULD use one server process per run.
- `test/test_camlflow.ml` is the main regression surface and is over 3k lines; add cases near related helpers instead of scattering new helper stacks.
- CI pins erratique packages to GitHub mirrors before `opam install`; local dependency failures SHOULD be compared against `.github/workflows/ci.yml`.

## Patterns
- Parsing and lowering rules live in `lib/parsing/*`; unsupported CamlFlow syntax SHOULD fail there with precise diagnostics.
- Type-system and module-resolution changes MUST preserve alignment between `lib/project_loader.ml`, `lib/typing/*`, and the runtime/module lookup paths.
- Provider-facing changes SHOULD keep `Runtime.Context.invocation_kind`, rendered prompts, effect requests, adapter validation, and SDK docs in sync.
- Status docs such as `docs/json-rpc-status.md` are snapshots, not evergreen specs; update them only when the project state changes.
