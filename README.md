# CamlFlow

CamlFlow is a typed agent-orchestration language and runtime built around an
OCaml-style DSL.

The goal is to let you develop AI workflows programmatically:
you describe the workflow in code, type-check it, compile it, and run it.
That means you can:

- use skills
- use agents
- create skills
- create agents
- reuse agents you already created

Instead of stitching the workflow together with ad-hoc prompts, you write
typed source code with explicit inputs, outputs, and sequencing.
Project-local skills live under `skills/<name>/SKILL.md`, and inline agents
can be declared directly in `.cml` code.

This repository contains the completed Alpha/MVP vertical slice:
- parser
- type checker
- compiled JSON IR
- deterministic local runtime
- CLI
- tests
- runnable examples

## What this MVP includes

- OCaml-style parser for CamlFlow source files (`.cml`)
- type checking for:
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

## Concrete input/output examples

### 1) Bound agent flow

**Workflow input** (`examples/basic/main.cml`):

```ocaml
agent greeter : name:string -> string = Agent.bind "greeter"

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  greeting ^ "!"
```

**Command**

```sh
dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
```

**Output**

```text
steps: 1
"!"
```

### 2) Pure typed computation

**Workflow input** (`examples/recursion/main.cml`):

```ocaml
let rec sum_to (n : int) : int =
  if n = 0 then 0 else n + sum_to (n - 1)

let main (n : int) : int =
  sum_to n
```

**Command**

```sh
dune exec camlflow -- run examples/recursion/main.cml --input-json '4'
```

**Output**

```text
steps: 0
10
```

### 3) Zero-input workflow with variants + match

**Workflow input** (`examples/variants-match/main.cml`):

```ocaml
type review = Approved | NeedsChanges of string

type report = { author : string; review : review }

let summarize (report : report) : string =
  match report.review with
  | Approved -> report.author ^ " approved"
  | NeedsChanges reason -> report.author ^ " needs changes: " ^ reason

let main : string =
  let report : report =
    { author = "Ada"; review = NeedsChanges "add more tests" }
  in
  summarize report
```

**Command**

```sh
dune exec camlflow -- run examples/variants-match/main.cml
```

**Output**

```text
steps: 0
"Ada needs changes: add more tests"
```

### 4) Existing agent + local skill + inline agent via provider hooks

**Workflow input** (`examples/provider-hooks/workflow.cml`):

```ocaml
skill caveman : prompt:string -> string = Skill.bind "caveman"
agent greeter : name:string -> string = Agent.bind "greeter"
agent reviewer : code:string -> string =
  Agent.define ~model:"stub" ~system_prompt:"Review tersely"

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  let* short = caveman ~prompt:greeting in
  let* review = reviewer ~code:short in
  review
```

**Host command**

```sh
dune exec examples/provider-hooks/host.exe
```

**Output**

```text
steps: 3
"inline-review"
observed: bound-agent greeter
observed: local-prompt-skill caveman
observed: inline-agent reviewer
```

The default CLI runtime is deterministic. Unless you install custom provider
hooks, bound agents and skills synthesize placeholder outputs, which is why
the basic example returns `"!"` and the local-skill example returns `""`.
The provider-hooks example shows how to replace those defaults with host-
defined behavior.

## Quickstart

```sh
dune build
dune test
make run-basic
make run-variants-match
```

Use `dune exec camlflow -- --help` to see the full CLI.

## Build

```sh
dune build
```

## Test

```sh
dune test
```

## CLI

All commands below run through `dune exec camlflow -- ...`.

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

### Run with Codex provider

```sh
dune exec camlflow -- run examples/basic/main.cml \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only
```

### Run Codex provider example with a local skill + inline agent

```sh
dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only
```

### Run swe-leetcode example

```sh
dune exec camlflow -- run examples/swe-leetcode/main.cml \
  --skills examples/swe-leetcode/skills \
  --input-json '"two sum"' \
  --provider codex \
  --sandbox read-only
```

### Run problem-coach example

```sh
dune exec camlflow -- run examples/problem-coach/main.cml \
  --skills examples/problem-coach/skills \
  --input examples/problem-coach/input.json \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only
```

### Run qualified multi-file example

```sh
dune exec camlflow -- run examples/qualified-imports/main.cml --input-json '"Ada"'
```

### Run recursion example

```sh
dune exec camlflow -- run examples/recursion/main.cml --input-json '4'
```

### Run variants + match example

```sh
dune exec camlflow -- run examples/variants-match/main.cml
```

## Minimal CamlFlow example

```ocaml
agent greeter : name:string -> string = Agent.bind "greeter"

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  greeting ^ "!"
```

Default runtime providers are deterministic. For `string` outputs they
synthesize `""`, so this example returns `"!"` unless you install custom
runtime hooks.

## Runnable examples

- `examples/basic/` — minimal bound-agent flow
- `examples/local-skill/` — prompt-backed local skill via `--skills`
- `examples/qualified-imports/` — qualified module refs without `open`
- `examples/recursion/` — recursion and int builtins
- `examples/variants-match/` — records, variants, and pattern matching with a zero-arg `main`
- `examples/inline-agent/` — executable `Agent.define`
- `examples/provider-hooks/` — embedded OCaml host using runtime provider hooks
- `examples/codex/` — CLI Codex provider run using a bound agent, local skill, and inline agent
- `examples/swe-leetcode/` — inline LeetCode solver agent using the caveman skill and a fixed model
- `examples/problem-coach/` — multi-step solver that returns a directly useful final answer pack

## Provider docs

- `docs/provider-execution.md` — CLI provider-backed execution and Codex usage
- `docs/provider-hooks.md` — hook model, invocation metadata, and embedding guide
- `docs/json-rpc.md` — Phase 0 JSON-RPC host-integration contract
- `docs/json-rpc-roadmap.md` — roadmap for CamlFlow as a host-integrated harness runtime
- `examples/provider-hooks/README.md` — runnable provider-hooks example
- `examples/codex/README.md` — runnable Codex provider example
- `examples/swe-leetcode/README.md` — runnable swe-leetcode example
- `examples/problem-coach/README.md` — runnable problem-coach example

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
make run-variants-match
make run-inline-agent
make run-provider-hooks
```

## Key files

- `docs/camlflow-prd.md` — product requirements document
- `docs/mvp-spec-camlflow.md` — approved MVP plan/spec
- `docs/provider-execution.md` — CLI provider-backed execution guide
- `docs/provider-hooks.md` — runtime provider hook reference
- `docs/json-rpc.md` — Phase 0 JSON-RPC host-integration contract
- `docs/json-rpc-roadmap.md` — host-integration roadmap
- `docs/alpha-tasks.md` — Alpha completion checklist and closeout notes
- `docs/beta-1-tasks.md` — Beta 1 implementation checklist
- `examples/` — runnable examples
- `Makefile` — common build, test, and run shortcuts
- `lib/` — parser, typing, IR, runtime
- `bin/main.ml` — CLI
- `test/test_camlflow.ml` — end-to-end tests

## Roadmap

### Alpha (MVP) — complete

Delivered focus: validate the core language shape and execution model.

- [x] CLI for parsing, checking, compiling, and running CamlFlow programs
- [x] Unit and end-to-end tests to validate outputs and behavior
- [x] Typed parser, checker, JSON IR, and deterministic runtime
- [x] Local skill loading and provider hook support
- [x] Basic developer workflows through examples, docs, and Make targets
- [x] Continue improving MVP stability, diagnostics, and language ergonomics
- [x] Expand examples and test coverage for more workflow patterns

### Beta 1

Goal: validate CamlFlow inside real AI coding environments.

- [ ] Integrate with Codex (Codex CLI, OAuth)
- [ ] Test CamlFlow programs from within AI tools such as Codex
- [ ] Validate that generated outputs and orchestration behavior work as intended in real usage
- [ ] Iterate on language/runtime behavior based on AI-tool feedback

### Beta 2

Goal: build the developer experience (DX) layer around the language.

- [ ] Add LSP support for CamlFlow
- [ ] Integrate with IDEs and editors
- [ ] Build editor extensions, icons, and related UX pieces
- [ ] Add a CamlFlow configuration file for project setup
- [ ] Allow users to define entrypoint location, skills location, and related project settings in config
- [ ] Improve project ergonomics for day-to-day development

### Beta 3

Goal: expand model/provider integrations and advanced CLI control.

- [ ] Integrate with Claude Code
- [ ] Integrate with Claude CLI
- [ ] Improve the CLI so users can choose model, reasoning mode, and related execution settings
- [ ] Generalize runtime/provider selection across supported AI coding tools
- [ ] Refine multi-provider workflow execution experience
