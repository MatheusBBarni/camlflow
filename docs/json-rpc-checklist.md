# CamlFlow JSON-RPC Remaining Tasks Checklist

This is the short checklist version of the current JSON-RPC host-integration work.

For the fuller narrative summary, see `docs/json-rpc-status.md`.

---

## Now

- [x] Re-check that docs still match the current implementation in `lib/rpc_server.ml`
- [x] Re-check that `docs/json-rpc-fixtures.md` matches current request/response shapes
- [x] Document compatibility policy for protocol and IR versioning

## Protocol stabilization

- [x] Define clearer host error conventions for `camlflow/executeEffect`
- [x] Decide whether capabilities need finer-grained signaling
- [x] Clarify what hosts may safely ignore vs what is required

## Tests

- [x] Add automated coverage for invalid request (`-32600`)
- [x] Add automated coverage for method not found (`-32601`)
- [x] Add automated coverage for `camlflow/check` failure (`-32010`)
- [x] Add automated coverage for `camlflow/compile` failure (`-32011`)
- [x] Add automated coverage for `camlflow/run` failure (`-32012`)
- [x] Add automated coverage for host effect error propagation from `camlflow/executeEffect`

## Fixtures and docs

- [x] Add invalid request transcript to `docs/json-rpc-fixtures.md`
- [x] Add unknown method transcript to `docs/json-rpc-fixtures.md`
- [x] Add host effect error transcript to `docs/json-rpc-fixtures.md`
- [x] Add run failure transcript with diagnostic + trace events
- [x] Add optional `shutdown` / `exit` transcript

## Host / SDK validation

- [x] Re-validate `examples/json-rpc-host/host.js` against the current docs
- [x] Re-validate `examples/json-rpc-problem-coach/host.js` against the current docs
- [x] Re-validate any TypeScript SDK examples or smoke tests against the current docs
- [x] Add stronger external smoke tests for JS/TS host integrations

## Deferred design only

- [ ] Formalize cancellation design before implementation
- [ ] Formalize progress notification design before implementation
- [ ] Formalize streaming design before implementation

Recommended order:

1. cancellation
2. progress
3. optional streaming

## Later

- [ ] Add more direct provider convenience adapters only after host mode is stable
