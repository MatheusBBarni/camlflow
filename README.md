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
- project-local skill discovery through `--skills <dir>` and `skills/<name>/SKILL.md`

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

## Key files

- `docs/camlflow-prd.md` — product requirements document
- `docs/mvp-spec-camlflow.md` — approved MVP plan/spec
- `examples/` — runnable examples
- `lib/` — parser, typing, IR, runtime
- `bin/main.ml` — CLI
- `test/test_camlflow.ml` — end-to-end tests
