# Claude Code Context

Read @AGENTS.md first.

Load scoped context only when needed:
- @lib/CLAUDE.md for parser, typechecker, runtime, provider, CLI, or RPC work.
- @test/CLAUDE.md for regression additions and behavior verification.
- @packages/CLAUDE.md for SDK or editor package changes.
- @docs/CLAUDE.md for protocol, roadmap, or README updates.

On-demand summaries:
- @docs/agent-context/architecture.md
- @docs/agent-context/testing-guide.md
- @docs/agent-context/api-conventions.md

Session management:
- When context gets heavy (~40 messages), update @HANDOFF.md, run `/clear`, and resume from HANDOFF.
- After resume or compaction, re-check AGENTS landmines before touching `lib/rpc_server.ml`, `lib/typing/typing.ml`, `lib/ir.ml`, `lib/cli.ml`, or `test/test_camlflow.ml`.

Compounding rule:
- When a preventable mistake happens, fix it, then add one line to @AGENTS.md that would have prevented it.
