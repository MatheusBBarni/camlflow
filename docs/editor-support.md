# Editor Support

CamlFlow ships editor integrations for `.cml` files and `camlflow.json`
project configs. The editor packages do not execute workflows themselves; they
start the CamlFlow language server and use the shared project-config schema.

Use this guide to connect editor setup with the authoring and running docs.

## What Editors Provide

The current editor integrations provide:

- `.cml` file association
- syntax highlighting
- block comments and bracket behavior
- language-server diagnostics
- hover, definition, references, rename, and document outline
- `camlflow.json` schema validation

Workflow execution still happens through the CLI, JSON-RPC host bridge, or Pi
SDK harness:

- [CLI reference](./cli-reference.md)
- [Language reference](./language-reference.md)
- [Glossary](./glossary.md)
- [Pi SDK harness](./pi-sdk-harness.md)
- [Writing and running CamlFlow](./writing-and-running-camlflow.md)

## Language Server

Both editor packages launch the same command:

```sh
camlflow lsp
```

The `camlflow` executable must be available on the editor process `PATH`. If
the editor was launched from a desktop shell, its `PATH` may differ from your
terminal.

Check the language server from a terminal first:

```sh
camlflow --help
camlflow lsp
```

The `lsp` command stays running until the editor stops it. For a quick terminal
smoke, interrupt it with `Ctrl-C` after it starts.

## VS Code

The VS Code package lives in
[`packages/camlflow-vscode`](../packages/camlflow-vscode/README.md).

Build and test it locally:

```sh
cd packages/camlflow-vscode
npm install
npm test
npm run package
```

For extension development, launch VS Code with the package as the extension
development path:

```sh
code --extensionDevelopmentPath "$(pwd)"
```

If `camlflow` is not on the VS Code process `PATH`, override the LSP command in
VS Code settings:

```json
{
  "camlflow.lsp.command": "/absolute/path/to/camlflow",
  "camlflow.lsp.args": ["lsp"]
}
```

The package contributes JSON schema validation for files named
`camlflow.json`, using the generated copy of the shared schema.

## Zed

The Zed package lives in
[`packages/camlflow-zed`](../packages/camlflow-zed/README.md).

Install it as a development extension:

1. Open Zed.
2. Run `zed: install dev extension`.
3. Select `packages/camlflow-zed`.
4. Open a `.cml` file.

If `camlflow` is not on the Zed process `PATH`, configure the registered
language server name, `camlflow-lsp`:

```json
{
  "lsp": {
    "camlflow-lsp": {
      "binary": {
        "path": "/absolute/path/to/camlflow",
        "arguments": ["lsp"]
      }
    }
  }
}
```

Zed does not currently let this extension inject JSON schema associations
directly. Copy the snippet from
[`packages/camlflow-zed/settings/camlflow-json-schema-settings.jsonc`](../packages/camlflow-zed/settings/camlflow-json-schema-settings.jsonc)
into your workspace or user settings to validate `camlflow.json`.

## Project Config In Editors

Editor validation and CLI execution share the same config shape:

- canonical schema: [`schemas/camlflow.schema.json`](../schemas/camlflow.schema.json)
- config reference: [`docs/project-config.md`](./project-config.md)

The CLI finds the nearest `camlflow.json` when a command is run without an
explicit file:

```sh
cd examples/project-config
camlflow check
camlflow run --input input.json
```

Editor diagnostics come from the language server for `.cml` files and from JSON
schema validation for `camlflow.json`. If CLI and editor behavior disagree,
verify which workspace folder the editor opened and which `camlflow` binary it
starts.

## Smoke Test

After installing either editor integration:

1. Open `examples/basic/main.cml`.
2. Confirm the file is detected as CamlFlow.
3. Confirm syntax highlighting is active.
4. Hover over a declaration or reference.
5. Run go-to-definition on a local symbol.
6. Open `examples/project-config/camlflow.json`.
7. Confirm schema validation or completion is available.
8. Run the same workflow from a terminal:

```sh
camlflow run examples/basic/main.cml --input-json '"Ada"'
```

Expected output:

```text
steps: 1
"!"
```

## Troubleshooting

If the editor shows no LSP features:

- run `camlflow --help` from the same shell used to launch the editor
- configure the absolute LSP binary path
- check the editor's language-server logs
- run `camlflow check <file.cml>` from a terminal for the same file

If `camlflow.json` validation is missing:

- in VS Code, ensure the file is named exactly `camlflow.json`
- in Zed, install the JSON language-server schema snippet
- compare against the [project config reference](./project-config.md)

If module diagnostics differ between editor and terminal:

- check whether the terminal command used explicit `-I` include paths
- check the nearest `camlflow.json`
- prefer running from the same workspace root the editor opened

See [Troubleshooting](./troubleshooting.md) for runtime, provider, JSON-RPC, and
Pi SDK issues.
