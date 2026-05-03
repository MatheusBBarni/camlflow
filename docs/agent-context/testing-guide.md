# Testing Guide

## Core Command
- Run `opam exec -- dune test` for all behavior changes in `lib/`, `bin/`, `examples/`, or `test/`.

## When To Run Extra Checks
- Run `opam exec -- dune build` when CLI entrypoints, install surfaces, or dune wiring changes.
- Run `cd packages/camlflow-ts-json-rpc-sdk && npm install && opam exec -- npm test` for RPC, schema, SDK, or host-example changes.
- Run `cd packages/camlflow-vscode && npm run smoke:highlight` for syntax, schema, or editor package changes.
- Run the focused checklist in `docs/docs-validation.md` for user-facing docs, examples, SDK READMEs, and editor README changes.

## Test-Shape Guidance
- `test/test_camlflow.ml` is intentionally central; extend nearby sections instead of spinning out a second harness by default.
- Parser and type diagnostics should prefer `expect_error_contains`.
- Runtime and provider behavior should assert structured outputs with `Alcotest.check`.
- RPC behavior should reuse the `run_rpc_server_with_messages` helper stack.

## CI Mismatch To Remember
- CI pins erratique packages before `opam install`; local opam resolution problems may not reproduce without those pins.
- CI Node coverage currently exercises the SDK smoke tests and host examples, not the VS Code package.
