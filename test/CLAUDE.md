# Test Scope

`test/test_camlflow.ml` is the primary regression suite.

Rules:
- Add cases beside related helpers and existing scenario clusters; create parallel helper stacks only when a new pattern repeats.
- CLI or config changes SHOULD add parser/merge tests plus execution tests when runtime behavior changes.
- RPC changes SHOULD reuse `run_rpc_server_with_messages`, `find_rpc_request`, and response helpers before inventing new harnesses.
- Provider or config changes SHOULD cover both explicit CLI flags and nearest-`camlflow.json` fallback behavior when relevant.
- Keep failures specific; use `expect_error_contains` for diagnostic checks and `Alcotest.check` for stable structured outputs.

Commands:
- MUST run `opam exec -- dune test`.
- MUST run `cd ../packages/camlflow-ts-json-rpc-sdk && npm install && opam exec -- npm test` when SDK or RPC behavior changes.
