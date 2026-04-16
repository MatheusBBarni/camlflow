# CamlFlow

CamlFlow MVP for typed agent orchestration in an OCaml-style DSL.

## Implemented in this repo

- OCaml-style parser for CamlFlow source files (`.cml`)
- typed checking for:
  - `type`, `let`, `agent`, `skill`, `open`
  - records, variants, tuples, lists, options
  - `if`, `match`, recursion, labeled calls, `let*`
  - stricter effect semantics: agent/skill calls must appear directly on the RHS of `let*`
  - expanded builtin operator support for ints, floats, booleans, strings, equality, and ordering
- multi-file loading through:
  - `open Foo` → `foo.cml`
  - qualified references like `Helpers.make` and `Helpers.payload`
- compiled JSON IR
- deterministic local runtime
- richer provider hooks:
  - default bound-agent / bound-skill provider fallback
  - effect observer hook with invocation metadata
  - prompt-backed local skill metadata
- CLI commands:
  - `parse`
  - `check`
  - `compile`
  - `run`
- improved CLI diagnostics for:
  - unknown commands and flags
  - missing flag values
  - wrong command/flag combinations
  - missing files and invalid directories
  - invalid JSON input and invalid JSON IR artifacts
- project-local skill discovery through `--skills <dir>` and `skills/<name>/SKILL.md`
- Makefile targets for common build, test, and run flows

## Still out of scope for this MVP

- durable suspend/resume
- real LLM/provider schema generation
- remote registries/packages
- full OCaml stdlib compatibility
- imperative features
- user-defined parametric types

## Build

```sh
dune build
```

## Test

```sh
dune test
```

## CLI

Show help:

```sh
dune exec camlflow -- --help
```

Show subcommand help:

```sh
dune exec camlflow -- help run
dune exec camlflow -- parse --help
```

Generate shell completion:

```sh
dune exec camlflow -- completion bash > /tmp/camlflow.bash
dune exec camlflow -- completion zsh > /tmp/_camlflow
dune exec camlflow -- completion fish > /tmp/camlflow.fish
```

### Parse

```sh
dune exec camlflow -- parse examples/basic/main.cml
```

### Check

```sh
dune exec camlflow -- check examples/basic/main.cml
```

### Compile to JSON IR

```sh
dune exec camlflow -- compile examples/basic/main.cml -o /tmp/basic.ir.json
```

### Run from source

```sh
dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
```

### Run from compiled artifact

```sh
dune exec camlflow -- run /tmp/basic.ir.json --input-json '"Ada"'
```

### Run with project-local skills

```sh
dune exec camlflow -- run examples/local-skill/main.cml \
  --skills examples/local-skill/skills \
  --input-json '"hello"'
```

### Run qualified multi-file example

```sh
dune exec camlflow -- run examples/qualified-imports/main.cml --input-json '"Ada"'
```

### Run recursion example

```sh
dune exec camlflow -- run examples/recursion/main.cml --input-json '4'
```

## Example CamlFlow source

```ocaml
agent greeter : name:string -> string = Agent.bind "greeter"

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  greeting ^ "!"
```

Default runtime providers are deterministic. For `string` outputs they synthesize `""`, so this example returns `"!"`.

## Additional examples

- `examples/basic/` — minimal bound-agent flow
- `examples/local-skill/` — prompt-backed local skill via `--skills`
- `examples/qualified-imports/` — qualified module refs without `open`
- `examples/recursion/` — recursion and int builtins
- `examples/inline-agent/` — executable `Agent.define`
- `examples/provider-hooks/` — embedded OCaml host using runtime provider hooks

## Provider hook docs

- `docs/provider-hooks.md` — hook model, invocation metadata, and embedding guide
- `examples/provider-hooks/README.md` — runnable provider-hooks example

## Make targets

```sh
make build
make test
make cli-help
make completion-bash
make completion-zsh
make completion-fish
make run FILE=examples/basic/main.cml INPUT_JSON='"Ada"'
make run FILE=examples/local-skill/main.cml SKILLS=examples/local-skill/skills INPUT_JSON='"hello"'
make run-basic
make run-local-skill
make run-qualified
make run-recursion
make run-inline-agent
make run-provider-hooks
```

## Key files

- `docs/camlflow-prd.md` — product requirements document
- `docs/mvp-spec-camlflow.md` — approved MVP plan/spec
- `docs/provider-hooks.md` — runtime provider hook reference
- `examples/` — runnable examples
- `Makefile` — common build, test, and run shortcuts
- `lib/` — parser, typing, IR, runtime
- `bin/main.ml` — CLI
- `test/test_camlflow.ml` — end-to-end tests
