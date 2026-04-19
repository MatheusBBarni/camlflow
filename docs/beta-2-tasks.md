# Beta 2 Tasks

This document turns the Beta 2 roadmap items from `README.md` into a concrete
DX plan for the first editor and project-config slice.

## Goal

Ship the first real developer-experience layer around CamlFlow by making local
projects easier to open, understand, and run, starting with VS Code support and
an optional project-local `camlflow.json`.

## Scope decisions locked for this slice

### Editor surface

- start with VS Code only
- ship a standalone VS Code extension package for `.cml` and `camlflow.json`
- use declarative VS Code language features first:
  - language id and file associations
  - TextMate grammar for syntax highlighting
  - `language-configuration.json` for comments, brackets, auto-closing, and indentation
  - snippets for common CamlFlow forms
  - JSON schema validation for `camlflow.json`
- do not block the first DX slice on LSP work
- treat LSP as the follow-up once the baseline extension and config story are working

### Icon direction

- use an OCaml-inspired camel icon for the first pass
- recolor it to purple for CamlFlow branding
- verify license and attribution before publishing the extension
- if the OCaml mark cannot be reused cleanly, replace it with an in-house purple derivative before release

### Config model

- add an optional project-local `camlflow.json`
- the config should cover values users currently pass through CLI flags, plus project defaults for the main workflow file
- resolve relative paths from the directory that contains `camlflow.json`
- precedence should be:
  - explicit CLI args
  - `camlflow.json`
  - current built-in defaults
- keep `providerConfig` string-to-string in v1 so it stays aligned with repeatable `--provider-config key=value`
- `parse` stays explicit
- `run`, `check`, and `compile` may use configured `program` when the file argument is omitted

### Config fields for v1

- `program`
- `entry`
- `includePaths`
- `skillsDir`
- `provider`
- `model`
- `reasoning`
- `providerProfile`
- `providerConfig`
- `sandbox`
- `allowWriteDirs`
- `traceProvider`

### Packaging

- keep CLI and config-loading implementation in OCaml
- keep the VS Code extension in its own package directory
- keep one shared JSON schema artifact for `camlflow.json` so docs and editor validation do not drift

## Draft `camlflow.json` shape

```json
{
  "program": "examples/codex/main.cml",
  "entry": "main",
  "includePaths": ["."],
  "skillsDir": "examples/codex/skills",
  "provider": "codex",
  "model": "gpt-5.4-mini",
  "reasoning": "low",
  "providerConfig": {
    "approval-policy": "never"
  },
  "sandbox": "workspace-write",
  "allowWriteDirs": ["tmp"],
  "traceProvider": false
}
```

## Task checklists

### Task 1 - Project config foundation

- [x] Add a dedicated config module to decode, validate, and normalize `camlflow.json`
- [x] Detect `camlflow.json` from the working directory using project-root lookup
- [x] Resolve config-relative paths correctly
- [x] Merge config defaults into CLI options without changing current flag semantics
- [x] Permit `run`, `check`, and `compile` to omit the file argument when `program` is configured
- [x] Preserve current behavior exactly when no config file exists

### Task 2 - Config diagnostics and tests

- [x] Add tests for valid config decoding and normalization
- [x] Add tests for invalid enum values, wrong JSON shapes, and bad path values
- [x] Add CLI tests covering `CLI > config > defaults`
- [x] Add regression tests for positional program override, provider-setting override, and current input validation
- [x] Make config errors include the config path and failing field name

### Task 3 - VS Code extension scaffold

- [x] Create a VS Code extension package
- [x] Recommended location: `packages/camlflow-vscode/`
- [x] Contribute the `camlflow` language id and associate it with `.cml`
- [x] Register `language-configuration.json` for comments, brackets, auto-closing pairs, indentation, and folding behavior
- [x] Register a TextMate grammar for `.cml`
- [x] Register JSON schema validation for `camlflow.json`
- [x] Add extension README and local packaging instructions

### Task 4 - Syntax highlighting and editing UX

- [x] Highlight core keywords:
  - `type`
  - `let`
  - `let*`
  - `rec`
  - `agent`
  - `skill`
  - `open`
  - `if`
  - `then`
  - `else`
  - `match`
  - `with`
- [x] Highlight type names, variant constructors, labels, strings, numbers, comments, operators, and field access consistently
- [x] Cover multiline strings and OCaml-style block comments in the grammar
- [x] Add starter snippets for `let main`, `agent`, `skill`, `match`, and type declarations
- [x] Smoke-test highlighting against the runnable examples in `examples/`

### Task 5 - Icon and branding

- [x] Create purple light and dark icon assets for the language contribution
- [x] Apply the icon to the VS Code language contribution so `.cml` gets a sensible fallback icon
- [x] Verify icon asset provenance before publish
- [x] Add a short repo note describing the temporary icon source and replacement plan if needed

### Task 6 - Docs and developer workflow

- [ ] Update README quickstart and CLI examples to show `camlflow.json`-backed runs
- [ ] Document config precedence and supported fields
- [ ] Add a minimal sample project that uses `camlflow.json`
- [ ] Add contributor notes for testing and packaging the VS Code extension locally

### Task 7 - Zed IDE integration

- [ ] Add a dedicated Zed extension package for CamlFlow
- [ ] Recommended location: `packages/camlflow-zed/`
- [ ] Associate `.cml` files with CamlFlow inside Zed
- [ ] Reuse the shared TextMate grammar so syntax highlighting does not drift from VS Code
- [ ] Reuse the shared `camlflow.json` schema so config validation stays aligned across editors
- [ ] Add local install and smoke-test instructions for the Zed package

## Assumptions to confirm before implementation

- nearest-config discovery should walk upward from the current working directory
- `check` and `compile`, not just `run`, should honor configured `program`
- `providerConfig` values remain strings in JSON for now
- VS Code baseline support lands before any LSP work

## Recommended implementation order

1. Task 1 - project config foundation
2. Task 2 - config diagnostics and tests
3. Task 3 - VS Code extension scaffold
4. Task 4 - syntax highlighting and editing UX
5. Task 5 - icon and branding
6. Task 6 - docs and developer workflow
7. Task 7 - Zed IDE integration

## Deferred after this first DX slice

- [ ] LSP server for CamlFlow
- [ ] semantic tokens layered on top of the TextMate grammar
- [ ] go-to-definition, rename, hover, outline, and diagnostics inside VS Code
- [ ] formatting and code actions

## Done criteria for the initial DX slice

- [ ] `camlflow run` can use project defaults from `camlflow.json`
- [ ] `.cml` files open in VS Code with the correct language id, syntax highlighting, comments, and bracket behavior
- [ ] `camlflow.json` has autocomplete and validation in VS Code
- [ ] `.cml` gets a CamlFlow-branded purple icon fallback
- [ ] README documents the new DX flow without removing current explicit CLI usage
