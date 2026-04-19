# Docs Scope

Docs are split between evergreen contract docs and dated status or plan snapshots.

Update sets:
- Protocol or host-contract changes MUST keep `../README.md`, `json-rpc.md`, `json-rpc-fixtures.md`, and relevant SDK docs aligned.
- Provider or runtime-hook changes MUST keep `provider-hooks.md` and `provider-execution.md` aligned with code and CLI flags.
- `json-rpc-status.md` and `alpha-*` or `beta-*` task docs SHOULD only change when status or plan actually changes.
- Keep commands exact and copy-pasteable; prefer real flags over prose summaries.
- Large docs are token bombs. Edit only the touched files instead of re-reading every protocol document.
