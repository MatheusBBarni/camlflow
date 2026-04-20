# CamlFlow MVP Specification

## Plan Summary

Build a **vertical-slice CamlFlow MVP** that turns this repo from a scaffold into a real, executable system:

- real **parser**
- real **type checker**
- real **compiled JSON IR**
- real **runtime/interpreter**
- real **CLI** with `parse`, `check`, `compile`, `run`
- **stubbed/deterministic execution** for agents/skills/providers
- **project-local skill discovery** via `--skills`

This MVP will support an **exact OCaml-style syntax subset** focused on orchestration plus a small functional core.

It will **not** include:
- durable suspension/resume
- remote package registries
- full OCaml stdlib/module calls
- imperative features
- user-defined parametric types
- arbitrary effectful top-level evaluation

---

## 1. User Stories

### Core authoring
1. As a workflow author, I want to define **types, agents, skills, and functions** in an OCaml-style DSL so I can describe typed AI workflows precisely.
2. As a workflow author, I want to use **records, variants, lists, options, pattern matching, recursion, and `if`** so I can write reusable orchestration helpers.
3. As a workflow author, I want to use **`open Foo`** and qualified access like `Foo.bar` so I can split workflows across files.

### Safety and validation
4. As a workflow author, I want CamlFlow to catch **missing context, wrong argument labels, wrong types, unresolved imports, unsupported constructs, and non-exhaustive matches** before runtime.
5. As a workflow author, I want `let*` to clearly represent **effectful sequencing** so pipelines are easy to reason about.

### Execution
6. As a workflow author, I want to **run** workflows locally through a CLI entrypoint so I can validate end-to-end behavior.
7. As a workflow author, I want `Agent.bind`, `Skill.bind`, and `Agent.define` to be executable through **host-provided registries/providers** so the language is useful before real LLM integration.
8. As a workflow author, I want the CLI to discover **project-local skills** from `skills/<name>/SKILL.md` using `--skills <dir>` so I can use prompt-backed skills in local projects.

### Tooling
9. As a developer, I want `compile` to emit a **typed JSON IR with source metadata** so I can inspect, debug, and test compiled workflows.
10. As a developer, I want JSON input/output encoding for values to be **typed and unambiguous** so providers and CLI interop are reliable.

---

## 2. Acceptance Criteria

### Language and syntax
1. The MVP accepts an **exact OCaml-style syntax subset** for supported constructs.
2. Supported top-level declarations:
   - `type`
   - `agent`
   - `skill`
   - `let`
   - `open`
3. Supported executable expression/function features:
   - literals: `string`, `int`, `bool`, `float`, `unit`
   - variables
   - record literals
   - field access
   - variant constructors
   - list literals
   - `Some` / `None`
   - `let` and `let*`
   - labeled function calls
   - `if ... then ... else`
   - `match ... with`
   - recursion
   - primitive operators
4. Unsupported general-purpose constructs are rejected with clear diagnostics.

### Type system
5. Supported types:
   - built-ins: `string`, `int`, `bool`, `float`, `unit`
   - built-in `list` and `option`
   - user-defined records
   - user-defined variants
   - type aliases
6. `file` and `url` are modeled as ordinary aliases over `string`, not built-in opaque types.
7. `agent`, `skill`, and top-level `let` functions require explicit type information sufficient for checking.
8. Function application enforces **strict labeled-argument checking**.
9. Ordinary `let` functions may support **partial application**.
10. `agent` and `skill` invocations must be **fully saturated**.

### Pattern matching and purity
11. Pattern matching supports:
   - variant constructors
   - list patterns `[]` and `x :: xs`
   - wildcard `_`
   - variable patterns
   - tuple patterns
   - record patterns
   - nested patterns
   - option patterns like `Some x`
12. Non-exhaustive matches are **compile errors**.
13. Unreachable patterns must be diagnosed.
14. The MVP remains **purely functional**:
   - no mutation
   - no refs
   - no loops
   - no assignment
   - no imperative control flow
   - `for` / `while` should be rejected explicitly, with guidance to use
     recursion in the current MVP subset

### Effects and runtime
15. `let*` is reserved for **effectful sequencing**.
16. The RHS of `let*` must be an effectful agent/skill/provider-backed call, not an arbitrary pure expression.
17. Effectful evaluation is not allowed at top level; only **pure** top-level bindings/functions are allowed.
18. `Agent.bind "name"` resolves through a named runtime registry.
19. `Skill.bind "name"` resolves through runtime skill mechanisms.
20. `Agent.define ...` is executable through a pluggable agent provider interface.
21. Runtime validates returned values against the declared CamlFlow return type.

### Modules and imports
22. `open Foo.Bar` is supported.
23. Module resolution uses filesystem mapping `foo/bar.cml`.
24. `open` resolution searches current project plus `-I` include paths.
25. Missing modules are **compile errors**.
26. Qualified access like `Foo.bar` is supported.

### CLI
27. CLI commands must include:
   - `parse`
   - `check`
   - `compile`
   - `run`
28. `run` defaults to entrypoint `main`, but supports `--entry <name>`.
29. Entrypoints may be:
   - zero-arg
   - single-arg, supplied with `--input <json-file>` or `--input-json <json>`
30. `compile` produces a **JSON IR artifact**.
31. `run` can execute from source and/or compiled artifact.

### Project-local skills
32. `--skills <dir>` enables project-local skill discovery.
33. A local skill named `foo` is discovered at `skills/foo/SKILL.md`.
34. Local skills are treated as **prompt-backed skills**:
   - runtime loads `SKILL.md`
   - passes typed input plus skill text to a generic skill provider
   - validates typed output
35. CLI should check project-local skills during resolution for MVP.

### Deliverable quality
36. The repo must move from placeholder scaffold to a **real vertical slice** with:
   - parser
   - checker
   - IR
   - runtime
   - CLI
   - tests
   - examples

---

## 3. Technical Requirements

### Frontend
1. Replace placeholder AST/parsing with a real frontend for the supported subset.
2. Preserve **source spans/locations** through parse, type-check, compile, and runtime diagnostics.
3. Reject unsupported constructs clearly, especially:
   - arbitrary module/library calls like `List.length`
   - imperative features
   - unsupported top-level effects

### Type checker
4. Implement a type environment supporting:
   - built-ins
   - aliases
   - variants
   - records
   - function types
   - list/option
5. Enforce:
   - strict labels
   - type-correct field access
   - constructor correctness
   - exhaustive matching
   - purity restrictions at top level
   - no partial application for agents/skills
6. Distinguish **skills** and **agents** in the typed model and diagnostics, even if runtime call plumbing is shared.

### Runtime
7. Runtime must interpret the compiled program deterministically for MVP.
8. `let*` steps must be recorded as effectful runtime steps.
9. Runtime must support:
   - named agent registry
   - named skill registry
   - generic provider for `Agent.define`
   - generic provider for project-local prompt-backed skills
10. Runtime must validate provider outputs against declared return types.

### Modules and compilation
11. Add module loading/resolution for multi-file projects.
12. Add a **typed lowered IR** and JSON serializer/deserializer.
13. Compiled IR must include:
   - typed program structure
   - source locations
   - debug/doc metadata

### CLI
14. Extend CLI from stub to real subcommands.
15. CLI flags should include at minimum:
   - `-I <dir>` for include paths
   - `--entry <name>`
   - `--input <json-file>`
   - `--input-json <json>`
   - `--skills <dir>`

---

## 4. Data Requirements

### Runtime value model
1. CamlFlow values must have a canonical runtime representation.
2. JSON encoding must be explicit and type-safe:
   - records → JSON objects
   - lists → JSON arrays
   - variants → tagged objects like `{ "tag": "PRD", "value": ... }`
   - options → tagged variants, not implicit `null`

### Input/output boundaries
3. The same encoding model must be used for:
   - CLI entrypoint inputs
   - compiled artifact execution
   - provider I/O
   - project-local skill execution
4. Type validation errors must report the expected and actual shape.

### Local skills
5. Project-local skill folders are structured as:
   - `skills/<name>/SKILL.md`
6. The MVP treats `SKILL.md` as executable prompt/spec input for a generic skill provider.

---

## 5. Performance Requirements

1. CLI operations should feel interactive on **small-to-medium local projects**.
2. Parse/check/compile performance should be suitable for multi-file MVP workflows in normal local development.
3. Runtime overhead for deterministic stub execution should be low relative to provider latency.
4. Import resolution and diagnostics should remain responsive for same-project workflows.
5. No network dependency is required for default build/test/demo flows.

---

## 6. Maintainability Requirements

1. Keep clear module boundaries between:
   - syntax
   - parsing
   - typing
   - IR/serialization
   - runtime
   - CLI
2. Preserve a clean public library surface for embedding CamlFlow in host applications.
3. Use deterministic default providers/stubs for tests and examples.
4. Add representative example programs covering:
   - imports
   - records/variants
   - pattern matching
   - `let*`
   - `Agent.bind`
   - `Skill.bind`
   - `Agent.define`
   - local `SKILL.md` resolution
5. Keep diagnostics and source metadata first-class to support future editor/tooling work.

---

## 7. Test Requirements

1. Replace scaffold tests with real tests for:
   - parsing
   - type checking
   - exhaustiveness
   - module resolution
   - JSON encoding/decoding
   - compiled IR generation
   - runtime execution
   - CLI behavior
2. Add end-to-end tests for:
   - zero-arg `main`
   - single-arg `main` with JSON input
   - named registry `Agent.bind`
   - prompt-backed local skills via `--skills`
   - `Agent.define` via stub provider
3. Add negative tests for:
   - unresolved `open`
   - wrong labels
   - unsupported library/module calls
   - non-exhaustive `match`
   - effectful top-level bindings
   - unsaturated agent/skill calls
   - invalid provider output shape
4. Ensure `dune test` runs fully locally and deterministically.

---

## 8. Deployment Requirements

1. The project must build with `dune build`.
2. The project must test with `dune test`.
3. The CLI must run locally via `dune exec camlflow -- ...`.
4. No external LLM/MCP service is required for MVP build/test success.
5. Default packaging remains local OCaml library + executable, suitable for future opam distribution.

---

## 9. Explicit Non-Goals for This MVP

1. Durable suspension/resume across process restarts
2. Real provider schema generation
3. Remote skill/package registries
4. Full OCaml standard library interop
5. Imperative constructs
6. User-defined parametric types
7. Full general-purpose OCaml compatibility

---

## 10. Assumptions Carried Into Implementation

1. Unsupported syntax may be rejected either at parse time or check time, as long as diagnostics are clear.
2. Unreachable `match` branches will be diagnosed; MVP can ship with warnings if full hard-error enforcement is not yet implemented.
3. CLI local skill resolution will prefer project-local `SKILL.md` when `--skills` is provided, while still allowing host-registered skills/providers.
