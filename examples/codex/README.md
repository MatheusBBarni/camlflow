# Multi-provider CLI example

This example exercises three effect kinds through built-in CLI providers:

- bound agent
- local prompt skill
- inline agent

Files:

- `main.cml`
- `skills/caveman/SKILL.md`

Run:

```sh
opam exec -- dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only
```

Optional trace:

```sh
opam exec -- dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only \
  --trace-provider
```

OpenCode variant:

```sh
opam exec -- dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider opencode \
  --model openai/gpt-5.4-mini \
  --reasoning low
```

Claude Code variant:

```sh
opam exec -- dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider claude-code \
  --model sonnet \
  --reasoning medium
```

Claude CLI variant:

```sh
ANTHROPIC_API_KEY=... opam exec -- dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider claude-cli \
  --model claude-sonnet-4-6 \
  --reasoning medium
```

Notes:

- the inline agent does not declare `~model`, so CLI `--model` applies
- if you remove `--provider codex`, CamlFlow falls back to deterministic local defaults
- provider trace metadata prints to `stderr`
- `claude-code` uses Anthropic's `claude` CLI in headless print mode
- `claude-cli` uses Anthropic's `ant` API CLI and requires `ANTHROPIC_API_KEY`
