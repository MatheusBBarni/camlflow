# Provider-backed CLI execution

CamlFlow can run with deterministic local defaults, or it can route unresolved
agent/skill effects through an external provider.

For the full authoring path from `.cml` scripts through deterministic CLI,
provider CLI, JSON-RPC host mode, and the Pi SDK harness, see
[`writing-and-running-camlflow.md`](./writing-and-running-camlflow.md).
For the JSON shapes providers must return for declared CamlFlow types, see
[`json-encoding.md`](./json-encoding.md).

Beta 1 introduces an opt-in provider-backed execution path in the CLI.

## Current providers

Today the built-in CLI providers are:

- `codex`
- `opencode`
- `claude-code`
- `claude-cli`

Usage stays provider-agnostic at the CLI level:

```sh
camlflow run <file.cml|artifact.json> --provider codex ...
```

## Basic usage

Run from source:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/basic/main.cml \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low
```

Run from compiled IR:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- compile examples/basic/main.cml -o /tmp/basic.ir.json
opam exec --switch 5.4.0 -- dune exec camlflow -- run /tmp/basic.ir.json \
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

### `claude-code`

CamlFlow checks that:

- `claude` is installed and on `PATH`
- Claude Code authentication is available through `claude auth status`

### `claude-cli`

CamlFlow checks that:

- `ant` is installed and on `PATH`
- `ANTHROPIC_API_KEY` is set in the environment

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
- CamlFlow parses OpenCode's newline-delimited JSON event stream
- CamlFlow concatenates all `text` event chunks before decoding the final wrapped JSON payload
- if OpenCode emits an `error` event, CamlFlow surfaces that message as the step failure

### `claude-code`

When `--provider claude-code` is set:

- each effect becomes a fresh `claude -p --output-format json` call
- CamlFlow passes the wrapped JSON Schema through `--json-schema`
- CamlFlow runs Claude Code in `--bare` print mode with no session persistence
- CamlFlow parses the validated `structured_output` payload from Claude Code's JSON response

### `claude-cli`

When `--provider claude-cli` is set:

- each effect becomes a fresh `ant messages create --format json` call
- CamlFlow sends the wrapped JSON Schema through `output_config.format`
- CamlFlow maps `--reasoning` onto Anthropic's `output_config.effort`
- CamlFlow parses the returned message JSON, then decodes the JSON string from `content[0].text`

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

For `claude-code`, `--reasoning` is mapped onto `--effort low|medium|high|max`.

For `claude-cli`, `--reasoning` is mapped onto Anthropic's `output_config.effort`.

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

The Claude Code and Claude CLI adapters behave the same way for unsupported inline settings.

## Tracing

Use `--trace-provider` to print provider-step metadata to `stderr`:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/basic/main.cml \
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

Separately from `--trace-provider`, CamlFlow records a structured typed trace node for each effectful step. These nodes capture the typed input, rendered prompt, requested model and unsupported inline settings, output when available, validation status, and timing. JSON-RPC runs expose them through `camlflow/trace` `details.traceNode` and the final `camlflow/run` `traceNodes` result field. CLI runs keep normal stdout unchanged; trace nodes are runtime observability data, not authoritative workflow output.

## Capability summary

### `codex`

Current adapter capabilities:

- supports model override
- supports reasoning mapping
- supports provider profiles and raw provider config overrides
- supports sandbox selection and extra writable directories
- supports wrapped JSON output-schema enforcement

### `opencode`

Current adapter capabilities:

- supports model override
- supports reasoning mapping through `--variant`
- supports wrapped JSON response parsing from JSON event output
- supports provider tracing

Current adapter limitations:

- no mapping for non-default sandbox selection yet
- no mapping for extra writable directories yet
- no mapping for provider profiles yet
- no mapping for arbitrary provider config overrides yet

### `claude-code`

Current adapter capabilities:

- supports model override
- supports reasoning mapping through `--effort`
- supports extra accessible directories through repeatable `--add-dir`
- supports wrapped JSON structured output through `--json-schema`
- supports provider tracing

Current adapter limitations:

- no mapping for `--provider-profile`
- no mapping for arbitrary `--provider-config`
- no faithful read-only sandbox mapping yet

### `claude-cli`

Current adapter capabilities:

- supports model override
- supports reasoning mapping through `output_config.effort`
- supports wrapped JSON structured output through `output_config.format`
- supports provider tracing

Current adapter limitations:

- requires an explicit model from CLI or inline `Agent.define ~model`
- no sandbox mapping
- no extra writable directory mapping
- no mapping for `--provider-profile`
- no mapping for arbitrary `--provider-config`

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

`claude-code` currently maps workspace-capable execution onto Claude Code's coarse non-interactive permission-bypass mode. It supports extra accessible directories, but it does **not** yet expose a faithful read-only sandbox mapping.

`claude-cli` is a direct API adapter, so it does **not** expose filesystem sandboxing or writable-scope controls.

## OpenCode error handling notes

The adapter currently fails a step when any of the following happens:

- OpenCode exits non-zero
- OpenCode emits an `error` event in its JSON event stream
- OpenCode emits no final `text` payload
- the final text payload is not valid wrapped JSON
- the wrapped JSON does not contain `result`

This keeps failure modes explicit and easier to debug when integrating a new host environment.

## Examples

Codex:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini
```

Opencode:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider opencode \
  --model openai/gpt-5.4-mini
```

Claude Code:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider claude-code \
  --model sonnet \
  --reasoning medium
```

Claude CLI:

```sh
ANTHROPIC_API_KEY=... opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider claude-cli \
  --model claude-sonnet-4-6 \
  --reasoning medium
```
