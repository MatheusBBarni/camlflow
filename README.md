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
- provider-backed CLI execution for Codex, OpenCode, Claude Code, and Claude CLI
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

Quickstart with project-local `camlflow.json` defaults:

```sh
(cd examples/project-config && dune exec camlflow -- check)
(cd examples/project-config && dune exec camlflow -- run --input input.json)
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

## Project-local config

CamlFlow looks for the nearest `camlflow.json` by walking upward from the
current working directory. When that file defines `program`, the `run`,
`check`, and `compile` commands can omit the file argument entirely.

Config precedence is:

- explicit CLI args
- `camlflow.json`
- current built-in defaults

Relative paths in `program`, `includePaths`, `skillsDir`, and
`allowWriteDirs` resolve from the directory that contains `camlflow.json`.

Example shape:

```json
{
  "program": "main.cml",
  "entry": "main",
  "includePaths": ["."],
  "skillsDir": "skills",
  "provider": "codex",
  "model": "gpt-5.4-mini",
  "reasoning": "low",
  "providerProfile": "work",
  "providerConfig": {
    "approval-policy": "never"
  },
  "sandbox": "workspace-write",
  "allowWriteDirs": ["tmp"],
  "traceProvider": false
}
```

Supported fields:

- `program`: default workflow source file or compiled JSON artifact
- `entry`: default entrypoint name
- `includePaths`: extra module search paths
- `skillsDir`: local skill root
- `provider`: unresolved-effect provider, currently `codex`, `opencode`, `claude-code`, or `claude-cli`
- `model`: provider model override
- `reasoning`: provider-agnostic reasoning level, one of `low`, `medium`, `high`, `max`
- `providerProfile`: named provider profile
- `providerConfig`: string-to-string provider config map, equivalent to repeatable `--provider-config key=value`
- `sandbox`: provider sandbox mode, one of `read-only`, `workspace-write`, `danger-full-access`
- `allowWriteDirs`: extra writable directories for provider execution
- `traceProvider`: emit provider trace metadata to stderr

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

### Check with `camlflow.json` defaults

```sh
(cd examples/project-config && dune exec camlflow -- check)
```

### Compile to JSON IR

```sh
dune exec camlflow -- compile examples/basic/main.cml -o /tmp/basic.ir.json
```

### Compile with `camlflow.json` defaults

```sh
(cd examples/project-config && dune exec camlflow -- compile -o /tmp/project-config.ir.json)
```

### Run from source

```sh
dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
```

### Run with `camlflow.json` defaults

```sh
(cd examples/project-config && dune exec camlflow -- run --input input.json)
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

### Run with Claude Code provider

```sh
dune exec camlflow -- run examples/basic/main.cml \
  --input-json '"Ada"' \
  --provider claude-code \
  --model sonnet \
  --reasoning medium
```

### Run with Claude CLI provider

```sh
ANTHROPIC_API_KEY=... dune exec camlflow -- run examples/basic/main.cml \
  --input-json '"Ada"' \
  --provider claude-cli \
  --model claude-sonnet-4-6 \
  --reasoning medium
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
- `examples/project-config/` — minimal project-local `camlflow.json` workflow with omitted program path
- `examples/local-skill/` — prompt-backed local skill via `--skills`
- `examples/qualified-imports/` — qualified module refs without `open`
- `examples/recursion/` — recursion and int builtins
- `examples/variants-match/` — records, variants, and pattern matching with a zero-arg `main`
- `examples/inline-agent/` — executable `Agent.define`
- `examples/model-response-validation/` — typed model response plus branching with `if` and `match`
- `examples/model-response-retry/` — typed model response validation plus recursive retry
- `examples/dev-workflow/` — real end-to-end software workflow harness with approval gating
- `examples/provider-hooks/` — embedded OCaml host using runtime provider hooks
- `examples/json-rpc-host/` — dependency-free Node host speaking CamlFlow JSON-RPC over stdio
- `examples/json-rpc-problem-coach/` — dependency-free Node host running the structured problem-coach workflow over JSON-RPC
- `packages/camlflow-ts-json-rpc-sdk/examples/` — SDK-backed JSON-RPC host examples for spawned and attached clients, including progress, cancellation, and output chunks
- `examples/codex/` — multi-provider CLI run using a bound agent, local skill, and inline agent
- `examples/swe-leetcode/` — inline LeetCode solver agent using the caveman skill and a fixed model
- `examples/problem-coach/` — multi-step solver that returns a directly useful final answer pack
- `examples/repo-triage/` — repository-grounded triage workflow designed to show host-side tool use in `pi-mono`

## Provider docs

- `docs/provider-execution.md` — CLI provider-backed execution across all built-in providers
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
- `examples/codex/README.md` — runnable multi-provider example
- `examples/model-response-validation/README.md` — runnable typed model-response branching example
- `examples/model-response-retry/README.md` — runnable typed model-response retry example
- `examples/dev-workflow/README.md` — runnable end-to-end dev-workflow harness example
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
make run-model-response-validation
make run-model-response-retry
make run-dev-workflow
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
- `docs/beta-2-tasks.md` — Beta 2 DX plan and implementation checklist
- `examples/` — runnable examples
- `Makefile` — common build, test, and run shortcuts
- `lib/` — parser, typing, IR, runtime, provider bridge, and JSON-RPC server
- `packages/camlflow-ts-json-rpc-sdk/` — maintained TypeScript SDK and runnable host examples
- `packages/camlflow-vscode/README.md` — local VS Code extension testing and packaging notes
- `packages/camlflow-zed/README.md` — local Zed extension install and schema-validation notes
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
- [x] Add `pi-mono` launcher scripts, host-integration docs, and opt-in host E2E
  scaffolding for thin sidecar validation

Remaining Beta 1 follow-up:

- [ ] Validate CamlFlow end to end inside at least one real AI coding host through a thin sidecar integration
- [ ] Keep CamlFlow as its own engine (`camlflow serve --stdio`) and reuse a host adapter instead of embedding runtime logic into the host fork
- [ ] Confirm the host bridge handles `camlflow/executeEffect`, progress, cancellation, diagnostics, and output chunks in real usage
- [ ] Run multiple real workflows through that host and capture the biggest friction points
- [ ] Iterate on provider/runtime behavior, SDK ergonomics, payload shapes, and docs based on real host feedback

### Beta 2 — initial DX slice delivered

Goal: build the developer experience (DX) layer around the language.

See `docs/beta-2-tasks.md` for the first concrete DX slice.

Delivered:

- [x] Integrate with IDEs and editors through first-pass VS Code and Zed packages
- [x] Build editor extensions, icons, syntax highlighting, snippets, and related UX pieces
- [x] Add a CamlFlow configuration file for project setup
- [x] Allow users to define entrypoint location, skills location, and related project settings in config
- [x] Improve project ergonomics for day-to-day development through `camlflow.json`,
  schema validation, examples, completions, and updated docs

Remaining Beta 2 follow-up:

- [x] Add LSP support for CamlFlow
- [x] Layer semantic editor features on top of the baseline extensions
- [x] Add go-to-definition, rename, hover, outline, and diagnostics
- [ ] Add formatting and code actions

### Beta 3 — multi-provider CLI foundation mostly delivered

Goal: expand model/provider integrations and advanced CLI control.

Delivered:

- [x] Improve the CLI so users can choose model, reasoning mode, sandbox,
  profile, provider config, and related execution settings
- [x] Generalize runtime/provider selection across the currently supported AI
  coding tools shipped in-repo (`codex`, `opencode`, `claude-code`, and
  `claude-cli`)
- [x] Tighten model-response validation so providers must return the wrapped
  `{"result": ...}` contract before CamlFlow decodes typed output
- [x] Prove typed model responses can drive `if` / `match` workflow branching
  through a runnable example and regression coverage
- [x] Extend typed model-response workflows with option-aware validation helpers
  and a recursive retry pattern that works in the current MVP subset

Remaining Beta 3 follow-up:

- [x] Integrate with Claude Code
- [x] Integrate with Claude CLI
- [ ] Expand workflow control flow around typed model responses with future
  iteration constructs such as `for` / `while` when the language grows beyond
  the current MVP subset
- [x] Refine multi-provider workflow execution experience

Today the MVP keeps typed model-response control flow inside the pure subset:
`if`, `match`, and recursion. `for` and `while` remain future-language work,
and CamlFlow now diagnoses them explicitly so authors fall back to recursive
helpers like `examples/model-response-retry/`.

Example target shape for this Beta 3 slice:

```ocaml
type action = TEST | RUN

type code_response = {
  action : action;
  accuracy : int;
  description : string;
}
```

This would let a workflow author branch on model output in typed code, for
example by checking `if response.accuracy < 90 then ...` or matching on
`response.action` to decide whether to run tests, continue execution, or retry
with a different prompt/provider strategy. A concrete minimal version now lives
in `examples/model-response-validation/`, and a recursive retry-oriented version
lives in `examples/model-response-retry/`.
