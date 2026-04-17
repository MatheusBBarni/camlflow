# Codex provider example

This example exercises three effect kinds through the CLI Codex provider:

- bound agent
- local prompt skill
- inline agent

Files:

- `main.cml`
- `skills/caveman/SKILL.md`

Run:

```sh
dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only
```

Optional trace:

```sh
dune exec camlflow -- run examples/codex/main.cml \
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
dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider opencode \
  --model openai/gpt-5.4-mini \
  --reasoning low
```

Notes:

- the inline agent does not declare `~model`, so CLI `--model` applies
- if you remove `--provider codex`, CamlFlow falls back to deterministic local defaults
- provider trace metadata prints to `stderr`
