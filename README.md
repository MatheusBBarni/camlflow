# CamlFlow

CamlFlow is a typed agent-orchestration language and runtime built around an
OCaml-style DSL.

The goal is to let you develop AI workflows programmatically: you describe the
workflow in code, type-check it, compile it, and run it.

CamlFlow's current direction is to act as a typed harness/orchestration engine:

- author workflows in `.cml`
- run them directly through the CLI
- or host them over JSON-RPC 2.0 stdio from tools, UIs, and automation hosts
- let external providers or host processes execute effect steps
- keep final typed outputs authoritative even when trace, progress, or advisory
  output chunks are streamed

Instead of stitching the workflow together with ad-hoc prompts, you write
typed source code with explicit inputs, outputs, and sequencing.
Project-local skills live under `skills/<name>/SKILL.md`, and inline agents
can be declared directly in `.cml` code.

This repository contains the completed Alpha/MVP vertical slice plus the host
integration slice:
- parser
- type checker
- compiled JSON IR
- deterministic local runtime
- CLI and provider-backed execution
- JSON-RPC stdio server
- TypeScript SDK and host examples
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
- provider-backed CLI execution for Codex and OpenCode
- JSON-RPC host integration over stdio:
  - `serve --stdio`
  - host → server methods for `initialize`, `camlflow/check`, `camlflow/compile`, `camlflow/run`, `shutdown`, and `exit`
  - server → host effect execution through `camlflow/executeEffect`
  - trace, diagnostic, and progress notifications
  - host cancellation through `$/cancelRequest`, including pure-compute cancellation polling
  - per-session notification preferences for trace, diagnostic, and progress
  - advisory output streaming through `camlflow/outputChunk`
- TypeScript SDK for spawned or attached JSON-RPC stdio clients
- CLI commands:
  - `parse`
  - `check`
  - `compile`
  - `run`
  - `serve`
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
- authoritative incremental workflow state from streamed output
- concurrent multi-run multiplexing on one server connection
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

## Host integration docs

For the current `pi-mono` host integration work, see:

- `docs/pi-mono-host-integration-plan.md`
- `docs/pi-mono-implementation-checklist.md`
- `docs/pi-mono-integration-testing.md`
- `examples/repo-triage/README.md`

Useful launchers from this repo:

- `scripts/run-pi-mono.sh`
- `scripts/run-pi-mono-problem-coach.sh`
- `scripts/run-pi-mono-repo-triage.sh`

## Quickstart

```sh
dune build
dune test
make run-basic
make run-variants-match
```

JSON-RPC host integration quickstart:

```sh
dune exec camlflow -- serve --stdio
# or, for the maintained Node SDK examples:
cd packages/camlflow-ts-json-rpc-sdk && npm install && npm test
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

### Serve over stdio for JSON-RPC hosts

```sh
dune exec camlflow -- serve --stdio
```

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

### Run with OpenCode provider

```sh
dune exec camlflow -- run examples/basic/main.cml \
  --input-json '"Ada"' \
  --provider opencode \
  --model openai/gpt-5.4-mini \
  --reasoning low
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

### Run repo-triage example

```sh
dune exec camlflow -- run examples/repo-triage/main.cml \
  --skills examples/repo-triage/skills \
  --input examples/repo-triage/input.json
```

For the `pi-mono` host demo:

```sh
./scripts/run-pi-mono-repo-triage.sh
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
- `examples/json-rpc-host/` — dependency-free Node host speaking CamlFlow JSON-RPC over stdio
- `examples/json-rpc-problem-coach/` — dependency-free Node host running the structured problem-coach workflow over JSON-RPC
- `packages/camlflow-ts-json-rpc-sdk/examples/` — SDK-backed JSON-RPC host examples for spawned and attached clients, including progress, cancellation, and output chunks
- `examples/codex/` — CLI Codex provider run using a bound agent, local skill, and inline agent
- `examples/swe-leetcode/` — inline LeetCode solver agent using the caveman skill and a fixed model
- `examples/problem-coach/` — multi-step solver that returns a directly useful final answer pack
- `examples/repo-triage/` — repository-grounded triage workflow designed to show host-side tool use in `pi-mono`

## Provider docs

- `docs/provider-execution.md` — CLI provider-backed execution and Codex usage
- `docs/provider-hooks.md` — hook model, invocation metadata, and embedding guide
- `docs/json-rpc.md` — Phase 0 JSON-RPC host-integration contract
- `docs/json-rpc-fixtures.md` — concrete JSON-RPC request/response transcripts
- `docs/json-rpc-roadmap.md` — roadmap for CamlFlow as a host-integrated harness runtime
- `docs/json-rpc-deferred-extensions.md` — follow-up design notes for deeper cancellation, progress, and streaming work
- `docs/json-rpc-status.md` — current JSON-RPC progress summary and validated state
- `docs/json-rpc-checklist.md` — concise JSON-RPC remaining-tasks checklist
- `docs/host-adapter-architecture.md` — reusable sidecar adapter plan for real host integrations
- `docs/pi-mono-host-integration-plan.md` — concrete first-host plan for a `pi-mono` fork
- `docs/pi-mono-implementation-checklist.md` — concrete `pi-mono` implementation checklist with likely file touch points
- `examples/provider-hooks/README.md` — runnable provider-hooks example
- `examples/json-rpc-host/README.md` — runnable dependency-free JSON-RPC host example
- `examples/json-rpc-problem-coach/README.md` — runnable dependency-free structured JSON-RPC host example
- `packages/camlflow-ts-json-rpc-sdk/README.md` — TypeScript SDK guide
- `packages/camlflow-ts-json-rpc-sdk/examples/README.md` — runnable SDK-backed JSON-RPC host examples
- `examples/codex/README.md` — runnable Codex provider example
- `examples/swe-leetcode/README.md` — runnable swe-leetcode example
- `examples/problem-coach/README.md` — runnable problem-coach example
- `examples/repo-triage/README.md` — runnable repo-triage example aimed at `pi-mono` host testing

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
- `docs/json-rpc-fixtures.md` — concrete JSON-RPC request/response transcripts
- `docs/json-rpc-roadmap.md` — host-integration roadmap
- `docs/json-rpc-deferred-extensions.md` — follow-up design notes for deeper cancellation, progress, and streaming work
- `docs/json-rpc-status.md` — current JSON-RPC progress summary and validated state
- `docs/json-rpc-checklist.md` — concise JSON-RPC remaining-tasks checklist
- `docs/host-adapter-architecture.md` — reusable sidecar adapter plan for real host integrations
- `docs/pi-mono-host-integration-plan.md` — concrete first-host plan for a `pi-mono` fork
- `docs/pi-mono-implementation-checklist.md` — concrete `pi-mono` implementation checklist with likely file touch points
- `docs/alpha-tasks.md` — Alpha completion checklist and closeout notes
- `docs/beta-1-tasks.md` — Beta 1 implementation checklist
- `examples/` — runnable examples
- `Makefile` — common build, test, and run shortcuts
- `lib/` — parser, typing, IR, runtime, provider bridge, and JSON-RPC server
- `packages/camlflow-ts-json-rpc-sdk/` — maintained TypeScript SDK and runnable host examples
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

### Beta 1 — provider and host integration slice delivered

Goal: validate CamlFlow inside real AI coding environments through provider-backed
execution and host integration, closing the slice with a thin sidecar
integration into at least one real host fork instead of embedding CamlFlow
into host internals.

Delivered:

- [x] Integrate with Codex through opt-in CLI provider execution
- [x] Integrate with OpenCode through opt-in CLI provider execution
- [x] Add normalized provider CLI flags for model, reasoning, sandbox, profiles,
  provider config, and tracing
- [x] Generate JSON Schema from CamlFlow return types for provider-backed effect execution
- [x] Support bound agents, bound skills, local prompt skills, and inline agents
  through the provider bridge
- [x] Add a JSON-RPC 2.0 stdio server through `serve --stdio`
- [x] Add host-driven effect execution through `camlflow/executeEffect`
- [x] Add trace, diagnostic, and progress notifications for host integrations
- [x] Add host cancellation through `$/cancelRequest`, including pure-compute
  cancellation polling
- [x] Add per-session notification preferences for trace, diagnostic, and progress
- [x] Add advisory output streaming through `camlflow/outputChunk`
- [x] Add a maintained TypeScript JSON-RPC SDK plus runnable Node host examples
- [x] Add offline tests and end-to-end examples for provider-backed and JSON-RPC execution

Remaining Beta 1 follow-up:

- [ ] Validate CamlFlow end to end inside at least one real AI coding host through a thin sidecar integration
- [ ] Keep CamlFlow as its own engine (`camlflow serve --stdio`) and reuse a host adapter instead of embedding runtime logic into the host fork
- [ ] Confirm the host bridge handles `camlflow/executeEffect`, progress, cancellation, diagnostics, and output chunks in real usage
- [ ] Run multiple real workflows through that host and capture the biggest friction points
- [ ] Iterate on provider/runtime behavior, SDK ergonomics, payload shapes, and docs based on real host feedback

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
