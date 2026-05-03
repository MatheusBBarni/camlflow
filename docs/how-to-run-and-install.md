# How To Install And Run CamlFlow

This guide is for installing CamlFlow from this repository checkout and running
the maintained CLI, JSON-RPC bridge, SDK examples, and editor integrations.
For a map of all current and historical docs, see
[`README.md`](./README.md).
For `.cml` authoring patterns, JSON input shapes, and choosing between CLI,
provider, JSON-RPC, and Pi harness execution, see
[`writing-and-running-camlflow.md`](./writing-and-running-camlflow.md).
For a step-by-step first workflow tutorial, see
[`first-workflow.md`](./first-workflow.md).
For a compact command and flag reference, see
[`cli-reference.md`](./cli-reference.md).
For `camlflow.json` fields and path resolution, see
[`project-config.md`](./project-config.md).
For JSON input and output encoding rules, see
[`json-encoding.md`](./json-encoding.md).
For VS Code and Zed language-server setup, see
[`editor-support.md`](./editor-support.md).
For Pi host integration and the Flue-style harness, see
[`pi-sdk-harness.md`](./pi-sdk-harness.md).
For common failures and fixes, see
[`troubleshooting.md`](./troubleshooting.md).

CamlFlow is not published here as a binary release. The supported local path is
to clone the repository, install the OCaml dependencies with `opam`, and run the
CLI through Dune or install it into your active opam switch.

## Requirements

Install these first:

- `git`
- `opam` 2.x
- OCaml 5.4.x
- Dune 3.22 or newer
- Node.js 18 or newer for TypeScript SDK and editor packages
- `npm` for packages under `packages/`

The `dune` binary on your shell `PATH` may be older than the one installed in
the opam switch. If `dune exec ...` reports that `(lang dune 3.22)` is not
supported, run commands through the switch explicitly:

```sh
opam exec --switch 5.4.0 -- dune --version
opam exec --switch 5.4.0 -- dune exec camlflow -- --help
```

The core package requires OCaml 5.4 or newer. If your default opam switch is
older, create or select a compatible switch before installing dependencies:

```sh
opam switch create 5.4.0 ocaml-base-compiler.5.4.0
eval "$(opam env --switch 5.4.0)"
```

If a `5.4.0` switch already exists, you can use it without changing your shell
environment by adding `--switch 5.4.0` to `opam exec` commands:

```sh
opam exec --switch 5.4.0 -- ocamlc -version
```

## Clone And Build

```sh
git clone https://github.com/MatheusBBarni/camlflow.git
cd camlflow
opam install . --deps-only --with-test --yes
opam exec -- dune build
opam exec -- dune test
```

When your shell is not already using the OCaml 5.4 switch, run the same commands
through that switch explicitly:

```sh
opam install . --deps-only --with-test --yes --switch 5.4.0
opam exec --switch 5.4.0 -- dune build
opam exec --switch 5.4.0 -- dune test
```

## Run The CLI From The Checkout

During development, prefer running the CLI through Dune:

```sh
opam exec -- dune exec camlflow -- --help
```

Use the explicit switch form if needed:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- --help
```

Small examples:

```sh
opam exec -- dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
opam exec -- dune exec camlflow -- run examples/recursion/main.cml --input-json '4'
opam exec -- dune exec camlflow -- run examples/variants-match/main.cml
```

For a guided path through pure workflows, local skills, project config,
structured examples, JSON-RPC hosts, and Pi SDK harness examples, see
[`examples/README.md`](../examples/README.md).

The default runtime is deterministic. Bound agents and skills produce
placeholder values until you configure a provider or host effect handler, so the
basic example currently returns `"!"`.

## Optional Local CLI Install

To make `camlflow` available on the active opam switch `PATH`, install the Dune
package after building:

```sh
opam exec -- dune install camlflow
eval "$(opam env)"
camlflow --help
```

For an explicit switch:

```sh
opam exec --switch 5.4.0 -- dune install camlflow
eval "$(opam env --switch 5.4.0)"
camlflow --help
```

Editor packages and external host tools expect this installed `camlflow`
executable, or an equivalent wrapper, to be available on `PATH`.

## Common CLI Tasks

For a fuller explanation of `.cml` syntax, `let*`, agents, skills, modules,
JSON input encoding, provider-backed runs, and the Pi SDK harness, use the
authoring guide:
[`writing-and-running-camlflow.md`](./writing-and-running-camlflow.md).
For exact command forms and flag precedence, use the CLI reference:
[`cli-reference.md`](./cli-reference.md).

Parse and type-check a source file:

```sh
opam exec -- dune exec camlflow -- parse examples/basic/main.cml
opam exec -- dune exec camlflow -- check examples/basic/main.cml
```

Compile to JSON IR and run the artifact:

```sh
opam exec -- dune exec camlflow -- compile examples/basic/main.cml -o /tmp/basic.ir.json
opam exec -- dune exec camlflow -- run /tmp/basic.ir.json --input-json '"Ada"'
```

Run with local prompt-backed skills:

```sh
opam exec -- dune exec camlflow -- run examples/local-skill/main.cml \
  --skills examples/local-skill/skills \
  --input-json '"hello"'
```

Use nearest `camlflow.json` project defaults:

```sh
(cd examples/project-config && opam exec -- dune exec camlflow -- check)
(cd examples/project-config && opam exec -- dune exec camlflow -- run --input input.json)
```

Generate shell completions:

```sh
opam exec -- dune exec camlflow -- completion bash > /tmp/camlflow.bash
opam exec -- dune exec camlflow -- completion zsh > /tmp/_camlflow
opam exec -- dune exec camlflow -- completion fish > /tmp/camlflow.fish
```

## Provider-Backed Runs

Provider-backed runs delegate effectful `let*` steps to an external tool while
CamlFlow keeps type-checking, orchestration, and output validation.

Supported provider names:

- `codex`
- `opencode`
- `claude-code`
- `claude-cli`

Example:

```sh
opam exec -- dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only
```

The provider executable and credentials must already be configured outside
CamlFlow. See [`provider-execution.md`](./provider-execution.md) for provider
preflight checks, sandbox options, and model selection details.

## JSON-RPC Host Mode

Start the bridge with:

```sh
opam exec -- dune exec camlflow -- serve --stdio
```

The bridge uses JSON-RPC 2.0 over stdio with `Content-Length` framing. Hosts
must send `initialize` before `camlflow/check`, `camlflow/compile`, or
`camlflow/run`.

Host integrations should start one `serve --stdio` process per active run. The
bridge is intentionally single-active-run and should not be treated as a
multi-run server.

Protocol details live in [`json-rpc.md`](./json-rpc.md).

## TypeScript JSON-RPC SDK

The TypeScript SDK lives in
[`packages/camlflow-ts-json-rpc-sdk`](../packages/camlflow-ts-json-rpc-sdk).

```sh
cd packages/camlflow-ts-json-rpc-sdk
npm install
opam exec -- npm test
```

Run the maintained examples:

```sh
npm run example:provider-hooks
npm run example:attach-streams
npm run example:problem-coach
npm run example:cancellation
```

These examples compile TypeScript into `examples-dist/`, spawn or attach to
`camlflow serve --stdio`, handle `camlflow/executeEffect`, and demonstrate
progress, diagnostics, output chunks, and cancellation.

## Pi SDK Adapter

The maintained Pi integration boundary is
[`packages/camlflow-pi-sdk`](../packages/camlflow-pi-sdk).

```sh
cd packages/camlflow-pi-sdk
npm install
npm test
```

This package wraps the JSON-RPC SDK and exposes two host-side APIs:

- `createPiCamlFlowHostSession(...).runWorkflow(...)` for native Pi command,
  palette, or panel code
- `createPiCamlFlowHarness(...).init({ sandbox, model })` for Flue-style
  `agent.session(...).prompt/skill/task/shell` orchestration

The maintained Pi integration guide is
[`pi-sdk-harness.md`](./pi-sdk-harness.md).

Supported harness sandbox presets are `local` / `workspace-write`,
`read-only`, `ephemeral`, and custom host-owned configs or factories. The
package constrains trusted shell `cwd` values to the sandbox root and
checks built-in local shell paths after symlink resolution. Automatic directory
removal and the `cleanup` flag are limited to `ephemeral`; use `dispose` for
custom sandbox cleanup.
The package intentionally does not parse `/camlflow-run`; Pi UI registration
remains in `pi-mono`.

Compile-checked host sketches are in
[`packages/camlflow-pi-sdk/examples`](../packages/camlflow-pi-sdk/examples).

## Editor Setup

Both editor packages launch the same language server:

```sh
camlflow lsp
```

Install the CLI into your opam switch first, or configure the editor package to
point at a wrapper that runs `opam exec -- dune exec camlflow -- lsp`.

VS Code:

```sh
cd packages/camlflow-vscode
npm install
npm test
npm run package
code --install-extension camlflow-vscode-0.1.0.vsix
```

Zed:

1. Open Zed.
2. Run `zed: install dev extension`.
3. Select `packages/camlflow-zed`.
4. Ensure `camlflow` is on the `PATH` visible to Zed.

See the package READMEs for editor-specific configuration:

- [`packages/camlflow-vscode/README.md`](../packages/camlflow-vscode/README.md)
- [`packages/camlflow-zed/README.md`](../packages/camlflow-zed/README.md)

For a maintained editor setup and smoke-test guide, see
[`editor-support.md`](./editor-support.md).

## Troubleshooting

For the full troubleshooting guide, see
[`troubleshooting.md`](./troubleshooting.md).

### `ocaml-base-compiler` conflict during `opam install`

Your active switch is probably older than OCaml 5.4. Use a compatible switch:

```sh
opam install . --deps-only --with-test --yes --switch 5.4.0
```

Then run commands through that switch:

```sh
opam exec --switch 5.4.0 -- dune test
```

### `Program 'camlflow' not found`

Inside the checkout, use Dune:

```sh
opam exec -- dune exec camlflow -- --help
```

Outside the checkout or from editor integrations, install the executable into
the active opam switch:

```sh
opam exec -- dune install camlflow
eval "$(opam env)"
```

### Effectful examples return placeholders

This is expected with the deterministic default runtime. Configure a provider,
use provider hooks, or run through a host integration when you need real model
execution.

### `check`, `compile`, or `run` uses the wrong file

When no file argument is provided, CamlFlow searches for the nearest
`camlflow.json`. Re-run with an explicit file path when debugging:

```sh
opam exec -- dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
```
