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

## Local Test And Packaging

From this directory:

```sh
npm install
npm test
npm run package
```

`npm test` runs the TextMate smoke highlighter against the checked-in examples.
`npm run package` syncs the shared `camlflow.json` schema and emits a `.vsix`
file in `packages/camlflow-vscode/`.

For a quick editor smoke test without packaging, launch VS Code against this
directory as an extension development target:

```sh
code --extensionDevelopmentPath "$(pwd)"
```

To install the extension locally:

```sh
code --install-extension camlflow-vscode-0.1.0.vsix
```

If you already have `vsce` installed globally, `npm run package` can be
replaced with `npm run sync-schema && vsce package`.

## Icon Provenance

The current `icons/camlflow-*.svg` assets are original, repo-authored camel file
icons created for this extension. They do not reuse the OCaml logo or other
third-party artwork, so no external attribution is required for this first pass.

If CamlFlow adopts a different official brand mark before publish, replace these
two SVGs in place and keep the manifest paths stable so the extension packaging
and language contribution do not need to change.
