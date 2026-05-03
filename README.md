# CamlFlow

CamlFlow is a typed workflow language and runtime for AI orchestration.

You write workflows in `.cml` using an OCaml-style syntax, type-check them,
compile them to JSON IR, and run them either:

- directly through the CLI
- through a host process over JSON-RPC 2.0 on stdio
- through built-in provider adapters for external coding/model CLIs

The important boundary is simple:

- CamlFlow owns parsing, typing, pure orchestration, effect metadata, and
  output validation.
- The host or provider owns model execution, tool use, credentials, and UX.

## What Works Today

- typed `.cml` workflows with `type`, `let`, `agent`, `skill`, and `open`
- records, variants, lists, options, tuples, `if`, `match`, recursion, and
  labeled calls
- explicit effect sequencing with `let*`
- multi-file project loading with lowercase module-path resolution
- CLI commands: `parse`, `check`, `compile`, `run`, `serve`, `lsp`,
  `completion`
- compiled JSON IR artifacts
- deterministic local runtime for development and tests
- local prompt-backed skills from `skills/<name>/SKILL.md`
- inline agents via `Agent.define`
- provider-backed execution via `codex`, `opencode`, `claude-code`, and
  `claude-cli`
- JSON-RPC 2.0 bridge over stdio with `Content-Length` framing
- TypeScript SDK in
  [`packages/camlflow-ts-json-rpc-sdk`](./packages/camlflow-ts-json-rpc-sdk)
- Pi host adapter SDK and Flue-style sandbox harness in
  [`packages/camlflow-pi-sdk`](./packages/camlflow-pi-sdk)
- editor support in
  [`packages/camlflow-vscode`](./packages/camlflow-vscode) and
  [`packages/camlflow-zed`](./packages/camlflow-zed)

## What CamlFlow Looks Like

```ocaml
agent greeter : name:string -> string = Agent.bind "greeter"

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  greeting ^ "!"
```

That file lives at [`examples/basic/main.cml`](./examples/basic/main.cml).

Run it with:

```sh
opam exec -- dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
```

With the default deterministic runtime, bound agents and skills return
placeholder data until you wire in a real provider or host effect handler. In
practice, the basic example currently produces `"!"`, not `"Hello Ada!"`.

## Quickstart

For a complete install and usage walkthrough, including opam switch setup,
optional local CLI installation, SDK packages, editor setup, and
troubleshooting, see
[`docs/how-to-run-and-install.md`](./docs/how-to-run-and-install.md).

Prerequisites:

- OCaml 5.4 or newer
- Dune 3.22 or newer
- Node.js 18 or newer for TypeScript SDK and editor packages

If your default opam switch is older than OCaml 5.4, create or select a
compatible switch first:

```sh
opam switch create 5.4.0 ocaml-base-compiler.5.4.0
eval "$(opam env --switch 5.4.0)"
```

Install dependencies and build:

```sh
opam install . --deps-only --with-test --yes
opam exec -- dune build
opam exec -- dune test
```

Inspect the CLI and run the smallest examples:

```sh
opam exec -- dune exec camlflow -- --help
opam exec -- dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
opam exec -- dune exec camlflow -- run examples/recursion/main.cml --input-json '4'
opam exec -- dune exec camlflow -- run examples/variants-match/main.cml
opam exec -- dune exec camlflow -- serve --stdio
```

If you did not activate the OCaml 5.4 switch in your shell, run the same
commands through it explicitly:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- --help
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
```

Try a local skill:

```sh
opam exec -- dune exec camlflow -- run examples/local-skill/main.cml \
  --skills examples/local-skill/skills \
  --input-json '"hello"'
```

Try project-local defaults from `camlflow.json`:

```sh
(cd examples/project-config && opam exec -- dune exec camlflow -- check)
(cd examples/project-config && opam exec -- dune exec camlflow -- run --input input.json)
```

## CLI Surface

Run all commands through `opam exec -- dune exec camlflow -- ...` inside the
repo.

Available commands:

- `parse <file.cml>`: parse one source file and report module/declaration info
- `check [file.cml] [-I dir]...`: load, resolve, and type-check a program
- `compile [file.cml] [-I dir]... [-o artifact.json]`: emit JSON IR
- `run [file.cml|artifact.json] ...`: execute from source or compiled IR
- `serve --stdio`: start the JSON-RPC bridge
- `lsp`: start the language server
- `completion <bash|zsh|fish>`: generate shell completion scripts

The CLI can omit the file argument for `check`, `compile`, and `run` when the
current directory or a parent contains a `camlflow.json` with a `program`
field. The nearest config wins.

## Examples Worth Running

- [`examples/basic`](./examples/basic): smallest bound-agent example
- [`examples/recursion`](./examples/recursion): pure typed computation
- [`examples/variants-match`](./examples/variants-match): records, variants,
  and `match`
- [`examples/qualified-imports`](./examples/qualified-imports): multi-file
  loading and qualified references
- [`examples/local-skill`](./examples/local-skill): `Skill.bind` plus local
  `SKILL.md`
- [`examples/project-config`](./examples/project-config): nearest
  `camlflow.json` fallback behavior
- [`examples/codex`](./examples/codex): bound agent + local skill + inline
  agent through a provider-backed CLI run
- [`examples/provider-hooks`](./examples/provider-hooks): embedding CamlFlow in
  an OCaml host with runtime hooks
- [`examples/problem-coach`](./examples/problem-coach),
  [`examples/repo-triage`](./examples/repo-triage), and
  [`examples/dev-workflow`](./examples/dev-workflow): larger structured-output
  workflows closer to real host use

## Provider-Backed Runs

When you pass `--provider`, CamlFlow still owns orchestration and type
validation, but each effectful `let*` step is delegated to an external tool.

Currently supported providers:

- `codex`
- `opencode`
- `claude-code`
- `claude-cli`

Example with Codex:

```sh
opam exec -- dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only
```

Common run-only flags:

- `--provider <name>`
- `--model <name>`
- `--reasoning <low|medium|high|max>`
- `--provider-profile <name>`
- repeatable `--provider-config key=value`
- `--sandbox <read-only|workspace-write|danger-full-access>`
- repeatable `--allow-write-dir <dir>`
- `--trace-provider`

Useful details:

- source runs and compiled-IR runs use the same provider plumbing
- returned JSON is validated against the declared CamlFlow type
- local prompt skills include the contents of `SKILL.md` in the provider prompt
- inline `Agent.define ~model:"..."` overrides CLI `--model`
- unsupported inline settings such as `~temperature` fail fast in the current
  direct CLI adapters

Provider-specific behavior and preflight checks are documented in
[`docs/provider-execution.md`](./docs/provider-execution.md).

## `camlflow.json` Project Defaults

`camlflow.json` is how you pin a default program, entrypoint, skill root, and
provider settings for a project.

Example:

```json
{
  "program": "main.cml",
  "entry": "main",
  "includePaths": ["."],
  "skillsDir": "skills",
  "provider": "codex",
  "model": "gpt-5.4-mini",
  "reasoning": "low",
  "providerProfile": "work",
  "providerConfig": {
    "approval-policy": "never"
  },
  "sandbox": "workspace-write",
  "allowWriteDirs": ["tmp"],
  "traceProvider": false
}
```

Precedence is:

1. explicit CLI flags
2. nearest `camlflow.json`
3. built-in defaults

Relative paths in `program`, `includePaths`, `skillsDir`, and
`allowWriteDirs` resolve relative to the directory that contains the config
file.

See
[`examples/project-config/camlflow.json`](./examples/project-config/camlflow.json)
for a minimal checked-in example.

## JSON-RPC Bridge

Start the bridge with:

```sh
opam exec -- dune exec camlflow -- serve --stdio
```

Current transport and execution model:

- JSON-RPC 2.0 over stdio
- `Content-Length` framing
- one active workflow run per server instance
- blocking host delegation for effect execution
- advisory trace, diagnostic, and progress notifications
- `camlflow/outputChunk` notifications for effect-output streaming; legacy untyped chunks remain advisory, while typed final chunks with matching `declaredReturnType` and `outputSchema` can complete the active effect after normal output validation

Current host-to-server methods:

- `initialize`
- `camlflow/check`
- `camlflow/compile`
- `camlflow/run`
- `shutdown`
- `exit`

Current server-to-host request:

- `camlflow/executeEffect`

Important compatibility note:

- `protocolVersion` covers the outer JSON-RPC contract
- `irVersion` covers compiled artifact compatibility

Protocol details live in [`docs/json-rpc.md`](./docs/json-rpc.md).

## Pi SDK Adapter

`packages/camlflow-pi-sdk` is the maintained `pi-mono` integration boundary.
It wraps `camlflow-ts-json-rpc-sdk`, declares
`@mariozechner/pi-coding-agent` as a peer dependency, and exposes a typed
`createPiCamlFlowHostSession(...).runWorkflow(...)` API for native Pi command,
palette, or UI surfaces.

It also exposes a programmable harness shaped around
`createPiCamlFlowHarness(...).init({ sandbox, model })`,
`agent.session(id?)`, and `session.prompt/skill/task/shell`. Supported sandbox
presets are `local` / `workspace-write`, `read-only`, `ephemeral`, and custom
host-owned configs or factories. `session.shell(...)` runs as trusted host code,
so secrets can be passed through explicit environment variables without placing
them in model-visible prompts.

The package does not parse `/camlflow-run`. Existing slash-command launcher
docs and scripts are historical/manual validation scaffolding for the old
prototype path.

If you want a host-side client instead of hand-rolling the protocol, start
with
[`packages/camlflow-ts-json-rpc-sdk`](./packages/camlflow-ts-json-rpc-sdk).

## Editor Support

CamlFlow ships an LSP entrypoint plus editor packages:

- `opam exec -- dune exec camlflow -- lsp`
- [`packages/camlflow-vscode`](./packages/camlflow-vscode): VS Code extension
- [`packages/camlflow-zed`](./packages/camlflow-zed): Zed extension

The editor packages both expect a `camlflow` executable on `PATH` and launch
`camlflow lsp`.

## Repository Layout

- [`lib`](./lib): parser, typing, IR, runtime, CLI, LSP, provider adapters,
  JSON-RPC server
- [`test/test_camlflow.ml`](./test/test_camlflow.ml): primary regression suite
- [`examples`](./examples): runnable source examples and host demos
- [`docs`](./docs): protocol, provider, and integration docs
- [`packages/camlflow-ts-json-rpc-sdk`](./packages/camlflow-ts-json-rpc-sdk):
  TypeScript client SDK and examples
- [`packages/camlflow-vscode`](./packages/camlflow-vscode): VS Code extension
- [`packages/camlflow-zed`](./packages/camlflow-zed): Zed extension

## Current Boundaries And Landmines

- CamlFlow is not full OCaml. `.cml` files do not get arbitrary stdlib/module
  calls such as `List.map`.
- Module resolution lowercases module names and only searches the project file
  plus include paths.
- `check`, `compile`, and `run` without an explicit file may pick up the
  nearest `camlflow.json`, so repros should record the working directory.
- The default runtime is deterministic and returns placeholder data for bound
  agents and skills until you configure real hooks or a provider.
- The JSON-RPC bridge is intentionally single-active-run; do not assume one
  `serve --stdio` process can multiplex concurrent runs.
- CamlFlow does not currently offer durable suspend/resume or full streamed
  workflow state. Typed final effect-output chunks over JSON-RPC can complete an
  individual active effect, but the bridge remains single-active-run.

## Related Docs

- [`docs/json-rpc.md`](./docs/json-rpc.md)
- [`docs/provider-execution.md`](./docs/provider-execution.md)
- [`docs/provider-hooks.md`](./docs/provider-hooks.md)
- [`docs/json-rpc-status.md`](./docs/json-rpc-status.md)
- [`docs/how-to-run-and-install.md`](./docs/how-to-run-and-install.md)
- [`packages/camlflow-ts-json-rpc-sdk/README.md`](./packages/camlflow-ts-json-rpc-sdk/README.md)
