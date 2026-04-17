# Provider-backed CLI execution

CamlFlow can run with deterministic local defaults, or it can route unresolved
agent/skill effects through an external provider.

Beta 1 introduces an opt-in provider-backed execution path in the CLI.

## Current providers

Today the built-in CLI providers are:

- `codex`
- `opencode`

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

Before execution, CamlFlow checks provider-specific basics.

### `codex`

CamlFlow checks that:

- `codex` is installed and on `PATH`
- Codex authentication is available through `codex login status`

### `opencode`

CamlFlow checks that:

- `opencode` is installed and on `PATH`

If preflight fails, the run fails before the workflow starts.

## Runtime behavior

When a provider is set:

- CamlFlow still orchestrates the workflow
- each `let*` effect becomes a fresh provider call
- source and compiled IR runs both work
- CamlFlow still validates the returned JSON against the declared CamlFlow type

### `codex`

When `--provider codex` is set:

- each effect becomes a fresh `codex exec` call
- generated JSON Schema is passed through `--output-schema`
- the final provider message is parsed from `--output-last-message`

### `opencode`

When `--provider opencode` is set:

- each effect becomes a fresh `opencode run --format json` call
- CamlFlow appends a strict wrapped JSON response contract to the prompt
- CamlFlow parses the final text event from Opencode's JSON event stream

Both adapters use a wrapped `{"result": ...}` response shape so non-object CamlFlow values remain safe to transport.

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

For `opencode`, `--reasoning` is mapped onto `--variant` values such as `minimal`, `medium`, `high`, and `max`.

## Unsupported inline settings

Current direct CLI adapters fail fast on inline settings that are not mapped
faithfully by the adapter.

Today that means:

- `~temperature`

Example failure shape:

```text
provider codex does not support inline setting(s) temperature for agent reviewer
```

The Opencode adapter behaves the same way for unsupported inline settings.

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

`codex` supports:

- `--sandbox read-only`
- `--sandbox workspace-write`
- `--sandbox danger-full-access`
- `--allow-write-dir <dir>`

`opencode` currently maps CamlFlow's default provider mode onto OpenCode's coarse auto-permission mode.

That means the adapter currently does **not** support:

- non-default `--sandbox`
- `--allow-write-dir`
- `--provider-profile`
- `--provider-config`

In other words, the first Opencode slice is a convenience adapter, not a full sandbox-policy mapping.

## Examples

Codex:

```sh
dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini
```

Opencode:

```sh
dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider opencode \
  --model openai/gpt-5.4-mini
```
