# HANDOFF

## Current Task
- `nv-context` bootstrap for Claude Code and Codex is in place.
- Shared baseline lives in `AGENTS.md`; Claude-specific loading starts at `CLAUDE.md`.

## Key Decisions
- Use `AGENTS.md` as the single shared instruction source for Codex and Claude Code.
- Keep root `CLAUDE.md` slim and load scoped files only on demand.
- Use helper scripts behind `hooks-config.json` so `.claude/settings.local.json` stays readable and easy to audit.
- Re-inject compacted context through `SessionStart` after compaction, with `PreCompact` writing the snapshot file because Claude hook context injection happens on `SessionStart`, not during the compaction hook itself.

## Open Questions
- Should the git-commit Claude hook always require Node package tests, or keep them conditional on local installs?
- Should the repo split the largest token-bomb files (`test/test_camlflow.ml`, `lib/rpc_server.ml`, `lib/typing/typing.ml`, `lib/ir.ml`, `lib/cli.ml`) or keep them centralized?
- Should the review-learning workflow append learned rules under `## Patterns`, or should a dedicated section be added later?

## Files Modified
- `AGENTS.md`
- `CLAUDE.md`
- `lib/CLAUDE.md`
- `test/CLAUDE.md`
- `docs/CLAUDE.md`
- `packages/CLAUDE.md`
- `docs/agent-context/*.md`
- `hooks-config.json`
- `.claudeignore`
- `.githooks/*`
- `scripts/agent-hooks/*`
- `.github/workflows/learn-from-reviews.yml`

## Next Steps
- Activate Claude hooks by copying `hooks-config.json` into `.claude/settings.local.json`.
- Enable the git hook wrapper with `chmod +x .githooks/pre-commit .githooks/nv-context-sync.sh && git config core.hooksPath .githooks`.
- Re-run `/nv-context` after major protocol, CI, or dependency changes.
