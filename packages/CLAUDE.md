# Packages Scope

This directory mixes maintained Node packages with editor integrations.

Package map:
- `camlflow-ts-json-rpc-sdk` is the maintained host SDK; changes here often require README, examples, tests, and root CI alignment.
- `camlflow-vscode` is a packaging and smoke-test flow around syntax and schema assets.
- `camlflow-zed` is mostly static package data; keep changes minimal and intentional.

Rules:
- SDK changes MUST run `cd camlflow-ts-json-rpc-sdk && npm install && opam exec -- npm test`.
- SDK protocol changes MUST stay aligned with `../docs/json-rpc.md`, `../docs/json-rpc-fixtures.md`, and `../README.md`.
- VS Code changes SHOULD run `cd camlflow-vscode && npm run smoke:highlight`; packaging also requires `npm run sync-schema`.
- Preserve declared Node compatibility (`>=18`) even though CI currently uses Node 24.
