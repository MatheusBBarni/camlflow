# CamlFlow Zed Extension

This package provides the first Zed editor slice for CamlFlow:

- associates `.cml` files with `CamlFlow`
- uses Zed's tree-sitter extension model with the maintained OCaml grammar as a base
- mirrors the shared VS Code grammar's CamlFlow-specific keyword surface with extra query rules for `agent` and `skill`
- reuses the shared `schemas/camlflow.schema.json` artifact for `camlflow.json` validation through Zed's JSON language-server settings

This package does not ship an LSP yet. It is a baseline syntax/highlighting integration for the Beta 2 DX slice.

## Layout

- `extension.toml`: Zed extension manifest
- `languages/camlflow/config.toml`: language registration for `.cml`
- `languages/camlflow/*.scm`: tree-sitter query files for highlighting, brackets, indentation, and outline
- `settings/camlflow-json-schema-settings.jsonc`: copy/paste snippet for wiring `camlflow.json` to the shared schema in Zed
- `../../schemas/camlflow.schema.json`: canonical shared config schema

## Local Install

1. Open Zed.
2. Run `zed: install dev extension` from the command palette.
3. Select `packages/camlflow-zed`.
4. If needed, reload Zed and open a `.cml` file.

If you need diagnostics while developing the extension, use `zed: open log`. For more verbose logs, launch Zed from a terminal with `zed --foreground`.

## `camlflow.json` Schema Validation

Zed's extension model does not currently let this package inject JSON schema associations directly. The supported path is configuring the built-in `json-language-server` in Zed settings.

Copy the snippet from `settings/camlflow-json-schema-settings.jsonc` into your workspace or user `settings.json`. Inside this repo, the schema URL can stay:

```json
{
  "lsp": {
    "json-language-server": {
      "settings": {
        "json": {
          "schemas": [
            {
              "fileMatch": [
                "**/camlflow.json"
              ],
              "url": "./schemas/camlflow.schema.json"
            }
          ]
        }
      }
    }
  }
}
```

That `./schemas/camlflow.schema.json` path is resolved from the worktree root, so it works when you open this repository in Zed.

## Smoke Test

1. Install the dev extension from `packages/camlflow-zed`.
2. Open `examples/basic/main.cml` or `examples/project-config/main.cml`.
3. Verify the language mode is `CamlFlow`.
4. Check that block comments `(* ... *)`, bracket pairing, and basic syntax highlighting are active.
5. Add the JSON language-server snippet to Zed settings.
6. Open `examples/project-config/camlflow.json` and verify schema-backed validation/completion against `schemas/camlflow.schema.json`.

## Notes

Zed uses tree-sitter rather than TextMate for syntax highlighting. That means this package cannot consume `packages/camlflow-vscode/syntaxes/camlflow.tmLanguage.json` directly. Instead, it keeps the two editor packages aligned by:

- using the same `.cml` file association
- carrying over the same CamlFlow-specific declaration keywords (`agent`, `skill`)
- pointing `camlflow.json` validation at the same shared JSON schema artifact
