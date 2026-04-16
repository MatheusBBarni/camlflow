# Provider-backed CLI execution

CamlFlow can run with deterministic local defaults, or it can route unresolved
agent/skill effects through an external provider.

Beta 1 introduces an opt-in provider-backed execution path in the CLI.

## Current provider

Today the built-in CLI provider is:

- `codex`

Usage stays provider-agnostic at the CLI level:

```sh
camlflow run <file.cml|artifact.json> --provider codex ...
```

## Basic usage

Run from source:

```sh
dune exec camlflow -- run examples/basic/main.cml \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low
```

Run from compiled IR:

```sh
dune exec camlflow -- compile examples/basic/main.cml -o /tmp/basic.ir.json
dune exec camlflow -- run /tmp/basic.ir.json \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini
```

## Provider flags

Provider-backed `run` accepts:

- `--provider <name>`
- `--model <name>`
- `--reasoning <low|medium|high|max>`
- `--provider-profile <name>`
- repeatable `--provider-config key=value`
- `--sandbox <read-only|workspace-write|danger-full-access>`
- repeatable `--allow-write-dir <dir>`
- `--trace-provider`

These flags are rejected on non-`run` commands.

## Preflight

Before execution, CamlFlow checks that:

- `codex` is installed and on `PATH`
- Codex authentication is available through `codex login status`

If preflight fails, the run fails before the workflow starts.

## Runtime behavior

When `--provider codex` is set:

- CamlFlow still orchestrates the workflow
- each `let*` effect becomes a fresh `codex exec` call
- source and compiled IR runs both work
- CamlFlow still validates the returned JSON against the declared CamlFlow type

The Codex adapter uses generated JSON Schema and wraps each step response in a
small object schema so Codex can return non-object CamlFlow values safely.

## Prompt sources by effect kind

The provider adapter builds a prompt envelope from the invocation metadata:

- bound agents → generic agent envelope
- bound skills → generic skill envelope
- local prompt skills → envelope + `SKILL.md`
- inline agents → envelope + inline `system_prompt` and metadata

## Model precedence

For inline agents:

- inline `Agent.define ~model:"..."` wins
- CLI `--model` is used only when the workflow does not declare a model

## Unsupported inline settings

Codex execution currently fails fast on inline settings that are not mapped
faithfully by the CLI adapter.

Today that means:

- `~temperature`

Example failure shape:

```text
provider codex does not support inline setting(s) temperature for agent reviewer
```

## Tracing

Use `--trace-provider` to print provider-step metadata to `stderr`:

```sh
dune exec camlflow -- run examples/basic/main.cml \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini \
  --trace-provider
```

Example trace:

```text
provider[1] start provider=codex kind=bound-agent name=greeter model=gpt-5.4-mini
provider[1] ok elapsed=4.95s
```

`stdout` remains reserved for the normal run result.

## Writable scope

Default provider execution uses:

- sandbox: `workspace-write`
- writable scope: current working directory only

You can tighten or expand that with:

- `--sandbox read-only`
- `--allow-write-dir <dir>`

## Example

See:

- `examples/codex/main.cml`
- `examples/codex/README.md`
