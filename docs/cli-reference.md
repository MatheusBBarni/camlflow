# CamlFlow CLI Reference

This is the short command reference for running CamlFlow from a repository
checkout. For setup, see [`how-to-run-and-install.md`](./how-to-run-and-install.md).
For authoring `.cml` workflows, see
[`writing-and-running-camlflow.md`](./writing-and-running-camlflow.md).
For common failures and fixes, see
[`troubleshooting.md`](./troubleshooting.md).

Run commands from the repository root through Dune:

```sh
opam exec -- dune exec camlflow -- <command>
```

If your active shell is not using an OCaml 5.4 switch, use:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- <command>
```

If bare `dune exec ...` reports that `(lang dune 3.22)` is not supported, your
shell is using an older Dune binary. Use `opam exec --switch 5.4.0 -- dune ...`
or activate that switch first.

## Commands

| Command | Use |
| --- | --- |
| `parse <file.cml>` | Parse one source file and report declaration count. |
| `check [file.cml] [-I dir]...` | Load, resolve modules, and type-check a workflow. |
| `compile [file.cml] [-I dir]... [-o artifact.json]` | Emit compiled JSON IR. |
| `run [file.cml\|artifact.json] ...` | Execute source or compiled IR. |
| `serve --stdio` | Start the JSON-RPC bridge. |
| `lsp` | Start the language server. |
| `completion <bash\|zsh\|fish>` | Emit shell completions. |

`check`, `compile`, and `run` may omit the file argument when the nearest
`camlflow.json` supplies `program`.
For the full config field reference, see
[`project-config.md`](./project-config.md).

## Authoring Loop

```sh
opam exec -- dune exec camlflow -- parse examples/basic/main.cml
opam exec -- dune exec camlflow -- check examples/basic/main.cml
opam exec -- dune exec camlflow -- compile examples/basic/main.cml -o /tmp/basic.ir.json
opam exec -- dune exec camlflow -- run /tmp/basic.ir.json --input-json '"Ada"'
```

Use source runs while editing. Use compiled IR when a host wants to inspect,
cache, or pass around the checked workflow shape.

## Run Inputs

Use `--input-json` for small inline JSON values:

```sh
opam exec -- dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
opam exec -- dune exec camlflow -- run examples/recursion/main.cml --input-json '4'
```

Use `--input` for structured payloads:

```sh
opam exec -- dune exec camlflow -- run examples/problem-coach/main.cml \
  --skills examples/problem-coach/skills \
  --input examples/problem-coach/input.json
```

If `--input` and `--input-json` are both omitted, the entrypoint must take no
argument.

## Include Paths And Skills

Add module search paths with repeated `-I` flags:

```sh
opam exec -- dune exec camlflow -- check examples/qualified-imports/main.cml \
  -I examples/qualified-imports
```

Use local prompt-backed skills with `--skills`:

```sh
opam exec -- dune exec camlflow -- run examples/local-skill/main.cml \
  --skills examples/local-skill/skills \
  --input-json '"hello"'
```

The skill layout is:

```text
skills/
  skill-name/
    SKILL.md
```

## Project Defaults

`camlflow.json` can provide defaults for program, entrypoint, include paths,
skills, and provider options:

```json
{
  "program": "main.cml",
  "entry": "main",
  "includePaths": ["."],
  "skillsDir": "skills"
}
```

From that project directory:

```sh
opam exec -- dune exec camlflow -- check
opam exec -- dune exec camlflow -- run --input input.json
```

Precedence is:

1. explicit CLI flags
2. nearest `camlflow.json`
3. built-in defaults

Relative `program`, `includePaths`, `skillsDir`, and `allowWriteDirs` entries
resolve from the config file directory.

## Provider Runs

Provider-backed runs delegate each effectful `let*` step to an external tool:

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

Supported provider names:

- `codex`
- `opencode`
- `claude-code`
- `claude-cli`

Provider run flags:

- `--provider <name>`
- `--model <name>`
- `--reasoning <low|medium|high|max>`
- `--provider-profile <name>`
- `--provider-config key=value`
- `--sandbox <read-only|workspace-write|danger-full-access>`
- `--allow-write-dir <dir>`
- `--trace-provider`

Provider credentials and executable configuration live outside `.cml`.

## JSON-RPC Bridge

Start one bridge process per active host run:

```sh
opam exec -- dune exec camlflow -- serve --stdio
```

The bridge speaks JSON-RPC 2.0 over stdio with `Content-Length` framing.
Hosts should send `initialize`, then `camlflow/check`, `camlflow/compile`, or
`camlflow/run`. The server delegates effects back to the host with
`camlflow/executeEffect`.

Prefer the TypeScript SDK for host code:
[`packages/camlflow-ts-json-rpc-sdk`](../packages/camlflow-ts-json-rpc-sdk).

## Shell Completions

```sh
opam exec -- dune exec camlflow -- completion bash > /tmp/camlflow.bash
opam exec -- dune exec camlflow -- completion zsh > /tmp/_camlflow
opam exec -- dune exec camlflow -- completion fish > /tmp/camlflow.fish
```

## Troubleshooting

If Dune reports that it cannot locate `camlflow` while several `dune exec`
commands are running at the same time, rerun the command by itself or install
the CLI into the active switch with `opam exec -- dune install camlflow`.

If `check`, `compile`, or `run` uses the wrong file, rerun with an explicit
source path and record the current working directory. The nearest
`camlflow.json` may be supplying defaults.

If JSON input fails to decode, check tagged variant and option encoding. Variants
use `{ "tag": "Constructor" }`; constructors with payloads add `"value"`.
For the full mapping from CamlFlow types to JSON shapes, see
[`json-encoding.md`](./json-encoding.md).
