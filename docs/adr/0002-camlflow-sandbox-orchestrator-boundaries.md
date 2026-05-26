# CamlFlow Sandbox Orchestrator Boundaries

## Status

Accepted.

## Context

CamlFlow began as a typed `.cml` workflow language and runtime with direct CLI,
provider, JSON-RPC, and Pi SDK execution paths. Issue #16 reframes the product as
a `.cml`-first sandbox orchestrator: users still author typed workflows in
OCaml-style syntax, while host-side packages own sandbox lifecycle, model access,
tool permissions, sessions, logs, cancellation, and resume.

The existing Pi SDK harness proves the lifecycle shape, but its reusable harness
concepts are mixed with Pi-specific worker-session creation. Before moving code,
the repository needs stable terms and package boundaries so later phases can
extract generic host orchestration without changing JSON-RPC method names,
protocol versions, `.cml` syntax, or the compiler/runtime layering.

## Decision

CamlFlow has two public layers:

1. **Typed workflow core**: the OCaml/Dune implementation of parsing, project
   loading, typing, IR, deterministic runtime, provider effect metadata,
   JSON-RPC bridge, CLI, and LSP/editor surfaces. This layer owns `.cml` syntax,
   type checking, IR generation, effect sequencing, JSON encoding, and output
   validation.
2. **Sandbox orchestrator layer**: host-side libraries and adapters that execute
   `.cml` workflows inside a selected sandbox policy. This layer owns model
   calls, credentials, shell/tool access, sessions, task fan-out, skills,
   lifecycle hooks, stream/log sinks, cancellation, cleanup, and resume.

The canonical nouns are:

- **workflow**: a typed `.cml` program selected for a run.
- **workflow run**: one execution of a workflow entrypoint with input and host
  configuration.
- **orchestrator**: the host-side runtime that creates a sandbox, starts or embeds
  CamlFlow, handles effects, and records run metadata.
- **harness**: a programmatic orchestrator API for host code. The harness is not a
  separate authoring language.
- **sandbox**: a host-owned execution boundary with cwd, env, shell, filesystem,
  tool, cleanup, and preservation policy.
- **sandbox provider**: code that creates and closes sandbox handles.
- **sandbox handle**: an initialized sandbox instance that can expose approved
  tools, optional trusted shell execution, path resolution, and close results.
- **session**: an agent/model conversation context scoped to one sandbox.
- **agent instance**: an initialized model-backed actor created by a provider for
  a session or task.
- **task**: detached child work that shares the sandbox/filesystem while using a
  separate session or message history.
- **skill**: a named prompt/tool behavior invoked by `.cml` or host code and
  executed by the host under sandbox policy.
- **provider**: an adapter for model, agent, tool, sandbox, or storage behavior.
- **tool**: a host-approved capability exposed to an agent provider.
- **result parser**: host-side parsing/validation that turns raw model output into
  a JSON value compatible with the `.cml` declared return type.

The `.cml` source surface owns workflow declarations, types, pure orchestration,
agent/skill effect signatures, and host-visible effect metadata. Host
configuration owns sandbox kind, cwd/env, shell policy, credentials, provider
choice, model names, prompt file resolution, role overlays, log sinks, resume
storage, lifecycle hooks, worktree strategy, and cleanup/preservation rules.

The first generic host package name is **`camlflow-orchestrator`**. It is the
stable product noun for reusable sandbox/session/task lifecycle code. Existing
`camlflow-pi-sdk` remains a scoped compatibility adapter during migration and
should delegate generic lifecycle work to `camlflow-orchestrator` as extraction
proceeds. Pi-specific worker creation, Pi model registry access, Pi auth checks,
and Pi tool construction stay in `camlflow-pi-sdk`.

## Consequences

- User-authored orchestration examples should start from `.cml` workflows. Any
  TypeScript/JavaScript examples are embedding glue around those workflows.
- The JSON-RPC 2.0 stdio bridge, `Content-Length` framing, method names,
  `protocolVersion`, `irVersion`, and single-active-run server model remain
  unchanged unless a later ADR explicitly changes them.
- The OCaml compiler/runtime remains layered as parsing -> project loading ->
  typing -> IR -> runtime/providers -> RPC/CLI.
- Host packages can add sandbox, lifecycle, logging, cancellation, task, session,
  result parsing, and worktree abstractions without moving credentials or direct
  shell policy into `.cml`.
- The Pi SDK is not deprecated by this decision. It is the first compatibility
  adapter over the generic orchestrator boundary.
- Local, read-only, and ephemeral sandbox implementations are the initial target.
  Container or cloud providers require a separate dependency/security decision.

## Phase Map

- **Phase 0** records this ADR and aligns glossary/documentation terminology.
- **Phase 1** extracts a generic host package with provider/session/result-parser
  interfaces and reusable validation/lifecycle utilities behind `.cml` runs.
- **Phase 2** makes local, read-only, and ephemeral sandbox providers first-class,
  including close results and worktree strategies.
- **Phase 3** routes agents, skills, tasks, prompts, and workflow runs through the
  same harness context and sandbox policy.
- **Phase 4** documents and scaffolds `.cml`-centered project conventions plus
  run/dev ergonomics without broadening the OCaml CLI prematurely.
- **Phase 5** normalizes logs, stream events, cancellation, cleanup, and safe
  resume metadata.
- **Phase 6** updates the README, guides, examples, and migration notes so the
  first impression is CamlFlow as a `.cml` sandbox orchestrator with a typed core.
