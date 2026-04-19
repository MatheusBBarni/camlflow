# CamlFlow VS Code Extension

This package contains the first declarative VS Code support for CamlFlow:

- language id: `camlflow`
- file association: `.cml`
- block comments, bracket pairs, auto-closing pairs, indentation rules, and region folding markers
- a baseline TextMate grammar for CamlFlow syntax
- JSON schema validation for `camlflow.json`

## Layout

- `language-configuration.json`: editor behavior for `.cml`
- `syntaxes/camlflow.tmLanguage.json`: TextMate grammar
- `../../schemas/camlflow.schema.json`: canonical project-config schema
- `generated/camlflow.schema.json`: packaged copy used by the extension

The canonical schema lives at the repo root so docs and editor validation can
share one source of truth. Run the sync script before packaging to copy it into
the extension payload.

## Local Packaging

From this directory:

```sh
npm run sync-schema
npx @vscode/vsce package
```

That produces a `.vsix` file in `packages/camlflow-vscode/`.

To install the extension locally:

```sh
code --install-extension camlflow-vscode-0.1.0.vsix
```

If you already have `vsce` installed globally, replace the `npx` command with
`vsce package`.
