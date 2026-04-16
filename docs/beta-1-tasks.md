# Beta 1 Tasks

This document turns the Beta 1 roadmap items from `README.md` into a concrete implementation checklist.

## Goal

Validate CamlFlow inside real AI coding environments through an opt-in, provider-backed execution path that starts with Codex while keeping the CLI and runtime provider-agnostic.

## Scope decisions locked for this slice

### Execution model
- `camlflow run ... --provider codex`
- provider-backed execution is opt-in
- CamlFlow remains the orchestrator
- each `let*` effect runs as a fresh provider call
- support both source `.cml` and compiled JSON IR artifacts

### Provider architecture
- add a small generic provider abstraction in the library
- add Codex as the first concrete provider
- keep provider logic out of `bin/main.ml` except for top-level wiring

### Effect coverage
Codex should handle all unresolved effect kinds:
- bound agents
- bound skills
- local prompt skills
- inline agents

### Prompting and outputs
- generate JSON Schema from declared CamlFlow return types
- pass that schema to Codex through `codex exec --output-schema`
- still validate returned JSON inside CamlFlow
- use different synthesized prompt envelopes for agents vs skills
- include `SKILL.md` for local prompt skills
- include inline `system_prompt` and metadata for inline agents
- use a generic synthesized envelope for bound names without explicit prompt text

### Model and runtime options
Expose normalized CLI flags:
- `--provider codex`
- `--model <name>`
- `--reasoning <low|medium|high|max>`
- `--provider-profile <name>`
- repeatable `--provider-config key=value`
- `--sandbox <read-only|workspace-write|danger-full-access>`
- repeatable `--allow-write-dir <dir>`
- `--trace-provider`

Rules:
- inline `Agent.define ~model:"..."` wins over CLI `--model`
- unsupported inline settings such as `~temperature` must fail fast under Codex

### Preflight and failures
- preflight provider availability before execution
- verify `codex` is installed
- verify Codex login/auth is available
- fail the run on the first provider error
- no automatic retries in this slice

### Workspace and sandbox defaults
- Codex should see the real workspace
- default sandbox is `workspace-write`
- default writable scope is the current working directory only
- later steps may observe in-scope workspace mutations implicitly

### Tracing
- `--trace-provider` prints safe metadata only
- trace output goes to `stderr`
- default trace payload should include step number, effect kind/name, provider, model, elapsed time, and success/failure

### Testing and docs
- keep `dune test` deterministic and offline
- add unit tests for CLI parsing/validation, schema generation, prompt envelopes, and provider preflight/error mapping
- add docs and a runnable example
- do not mark Beta 1 complete in `README.md` until real-world validation is done

## Task breakdown

### Task 1 — Provider abstraction and CLI scaffolding
- [x] Add a generic provider library layer with normalized provider settings
- [x] Add the first Codex provider adapter entry point
- [x] Extend CLI parsing/help/completion with provider flags
- [x] Keep current deterministic execution unchanged when `--provider` is omitted

### Task 2 — JSON Schema generation
- [ ] Generate JSON Schema from CamlFlow return types
- [ ] Cover primitives, records, variants, options, tuples, and lists
- [ ] Add unit tests for schema generation

### Task 3 — Prompt-envelope synthesis
- [ ] Build distinct envelopes for agent and skill execution
- [ ] Include invocation metadata, typed input JSON, return-type guidance, and schema details
- [ ] Include `SKILL.md` for local skills and inline prompt metadata for inline agents
- [ ] Add offline tests for prompt construction

### Task 4 — Codex adapter
- [ ] Shell out through `codex exec`
- [ ] Use `--output-schema` and `--output-last-message`
- [ ] Map normalized CamlFlow provider options onto Codex CLI flags
- [ ] Implement provider preflight and error mapping
- [ ] Fail fast on unsupported inline settings

### Task 5 — Runtime and CLI wiring
- [ ] Build provider-backed runtime contexts from `run`
- [ ] Add provider tracing support
- [ ] Preserve old deterministic behavior when `--provider` is not set
- [ ] Support both source and compiled IR runs

### Task 6 — Tests, example, and docs
- [ ] Keep automated tests offline and deterministic
- [ ] Add provider CLI tests and adapter unit tests
- [ ] Add a runnable Codex example
- [ ] Add user docs for provider-backed execution

## Recommended implementation order

1. Task 1 — provider abstraction and CLI scaffolding
2. Task 2 — JSON Schema generation
3. Task 3 — prompt-envelope synthesis
4. Task 4 — Codex adapter
5. Task 5 — runtime and CLI wiring
6. Task 6 — tests, example, and docs
