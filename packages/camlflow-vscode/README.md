# CamlFlow VS Code Extension

This package contains the first declarative VS Code support for CamlFlow:

- language id: `camlflow`
- file association: `.cml`
- block comments, bracket pairs, auto-closing pairs, indentation rules, and region folding markers
- a baseline TextMate grammar for CamlFlow syntax
- light and dark fallback file icons for `.cml` through the language contribution
- JSON schema validation for `camlflow.json`

## Layout

- `language-configuration.json`: editor behavior for `.cml`
- `syntaxes/camlflow.tmLanguage.json`: TextMate grammar
- `icons/camlflow-light.svg` and `icons/camlflow-dark.svg`: language-mode fallback icons for `.cml`
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

## Icon Provenance

The current `icons/camlflow-*.svg` assets are original, repo-authored camel file
icons created for this extension. They do not reuse the OCaml logo or other
third-party artwork, so no external attribution is required for this first pass.

If CamlFlow adopts a different official brand mark before publish, replace these
two SVGs in place and keep the manifest paths stable so the extension packaging
and language contribution do not need to change.
