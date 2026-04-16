# CamlFlow

PRD-aligned, buildable OCaml scaffold for the CamlFlow project.

## What is included

- `lib/` with placeholder modules for:
  - `syntax/`
  - `parsing/`
  - `typing/`
  - `runtime/`
- `bin/` CLI stub
- `test/` Alcotest test harness
- `dune-project` and `camlflow.opam`
- repo tooling files: `.gitignore`, `.ocamlformat`, `.editorconfig`

## Project layout

```text
.
├── bin/
├── docs/
├── lib/
│   ├── syntax/
│   ├── parsing/
│   ├── typing/
│   └── runtime/
└── test/
```

The scaffold is intentionally minimal. It mirrors the PRD structure but does **not** implement the CamlFlow DSL yet.

## Build

```sh
dune build
```

## Test

```sh
dune test
```

## Run the CLI stub

```sh
dune exec camlflow
```

## Notes

- The project targets **OCaml 5.1+**.
- `menhir` is added as a dependency for future parser work, but no parser implementation has been added yet.
- The public library exposes a `Camlflow` module with placeholder submodules for syntax, parsing, typing, and runtime.
