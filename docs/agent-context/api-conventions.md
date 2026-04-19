# API And CLI Conventions

## CLI Precedence
- Explicit CLI flags win over `camlflow.json`.
- If no file is passed, `check`, `compile`, and `run` may use the nearest `camlflow.json`.
- `--skills` resolves `<dir>/<name>/SKILL.md`.
- Provider settings include `--provider`, `--model`, `--reasoning`, `--provider-profile`, `--provider-config`, `--sandbox`, `--allow-write-dir`, and `--trace-provider`.

## Versioned Surfaces
- JSON-RPC `initialize` and `camlflow/compile` expose `irVersion`.
- Compiled JSON IR accepts missing version for compatibility but rejects unsupported versions.
- Protocol, IR, SDK types, fixtures, README examples, and tests MUST move together when versioned fields change.

## Provider Contract
- Providers return JSON that is validated against declared CamlFlow return types.
- Inline-agent and local-skill metadata flow through `Runtime.Context.invocation_kind`; keep naming aligned across runtime, prompts, effect requests, and SDK docs.
- Unsupported inline or provider settings SHOULD fail fast with explicit diagnostics.

## Documentation Rule
- Host or protocol docs should describe the public contract, not internal experiments.
- Dated status docs should remain snapshots with explicit dates and branch context.
