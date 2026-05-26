# CamlFlow Documentation

This directory contains both current user-facing guides and historical planning
notes. Start with the current guides unless you are working on protocol or
implementation internals.

## Start Here

- [`how-to-run-and-install.md`](./how-to-run-and-install.md): install from this
  checkout, run the CLI, start JSON-RPC mode, run package tests, and set up
  editors.
- [`writing-and-running-camlflow.md`](./writing-and-running-camlflow.md): write
  `.cml` workflows, use `let*`, agents, skills, modules, project defaults,
  provider runs, JSON-RPC hosts, and the Pi harness.
- [`first-workflow.md`](./first-workflow.md): step-by-step tutorial from one
  `.cml` file to structured input, effects, project config, providers,
  JSON-RPC, and Pi harness usage.
- [`language-reference.md`](./language-reference.md): compact syntax and
  declaration reference for the supported `.cml` language surface.
- [`examples/README.md`](../examples/README.md): guided path through runnable
  examples.
- [`workflow-cookbook.md`](./workflow-cookbook.md): copyable patterns for common
  `.cml` workflow shapes.
- [`run-modes.md`](./run-modes.md): choose between deterministic CLI, provider
  CLI, JSON-RPC host, and Pi SDK harness execution.
- [`orchestrator-project-layout.md`](./orchestrator-project-layout.md): proposed
  `.camlflow/` workflow, role, skill, and connector scaffold for orchestrator
  host projects.
- [`orchestrator-observability.md`](./orchestrator-observability.md): host-side
  event, cancellation, resume, and structured failure metadata conventions.
- [`glossary.md`](./glossary.md): shared vocabulary for workflows, effects,
  hosts, providers, JSON-RPC, Pi harness sessions, and sandboxes.
- [`editor-support.md`](./editor-support.md): VS Code and Zed setup, LSP
  configuration, schema validation, and editor smoke checks.
- [`troubleshooting.md`](./troubleshooting.md): common failures and fixes.

## Author References

- [`cli-reference.md`](./cli-reference.md): command shapes, flags, project
  defaults, provider options, completions, and CLI troubleshooting.
- [`language-reference.md`](./language-reference.md): supported declarations,
  types, expressions, effects, operators, and known language limits.
- [`project-config.md`](./project-config.md): `camlflow.json` fields,
  precedence, path resolution, and provider defaults.
- [`json-encoding.md`](./json-encoding.md): CamlFlow type-to-JSON mappings for
  inputs and provider/host/Pi outputs.
- [`run-modes.md`](./run-modes.md): execution-mode comparison and bring-up
  order for workflows.
- [`orchestrator-project-layout.md`](./orchestrator-project-layout.md): SDK
  scaffold conventions for `.cml`-first sandbox orchestrator projects.
- [`orchestrator-observability.md`](./orchestrator-observability.md): event log,
  cancellation, and resume primitives for orchestrator hosts.
- [`glossary.md`](./glossary.md): terminology used across authoring, runtime,
  host, provider, and Pi harness docs.
- [`provider-execution.md`](./provider-execution.md): direct CLI provider
  behavior, preflight, sandbox flags, model selection, and provider tracing.
- [`provider-hooks.md`](./provider-hooks.md): OCaml runtime hooks for host-owned
  effect execution.

## Host And SDK Integration

- [`json-rpc.md`](./json-rpc.md): current JSON-RPC protocol reference.
- [`json-rpc-fixtures.md`](./json-rpc-fixtures.md): concrete wire examples.
- [`pi-sdk-harness.md`](./pi-sdk-harness.md): maintained Pi SDK host-session and
  Flue-style harness guide.
- [`host-adapter-architecture.md`](./host-adapter-architecture.md): host adapter
  architecture notes.
- [`adr/0002-camlflow-sandbox-orchestrator-boundaries.md`](./adr/0002-camlflow-sandbox-orchestrator-boundaries.md):
  canonical terms and package boundaries for the `.cml` sandbox orchestrator
  direction.
- [`../packages/camlflow-ts-json-rpc-sdk/README.md`](../packages/camlflow-ts-json-rpc-sdk/README.md):
  TypeScript JSON-RPC SDK.
- [`../packages/camlflow-pi-sdk/README.md`](../packages/camlflow-pi-sdk/README.md):
  Pi adapter and sandbox-aware harness.
- [`editor-support.md`](./editor-support.md): editor package setup and LSP
  troubleshooting for local development.

## Status And Roadmaps

These documents are useful for understanding how the current shape emerged, but
they are not the shortest path for new users.

- [`json-rpc-status.md`](./json-rpc-status.md): status snapshot for the JSON-RPC
  track.
- [`json-rpc-roadmap.md`](./json-rpc-roadmap.md): JSON-RPC roadmap and design
  context.
- [`json-rpc-deferred-extensions.md`](./json-rpc-deferred-extensions.md):
  deferred protocol extension notes.
- [`json-rpc-checklist.md`](./json-rpc-checklist.md): concise JSON-RPC task
  checklist.
- [`mvp-spec-camlflow.md`](./mvp-spec-camlflow.md): MVP product/technical spec.
- [`alpha-tasks.md`](./alpha-tasks.md), [`beta-1-tasks.md`](./beta-1-tasks.md),
  and [`beta-2-tasks.md`](./beta-2-tasks.md): milestone task notes.

## Pi Historical Notes

The current maintained Pi integration path is
[`pi-sdk-harness.md`](./pi-sdk-harness.md) plus
[`../packages/camlflow-pi-sdk`](../packages/camlflow-pi-sdk).

These older documents describe the original `pi-mono` `/camlflow-run`
prototype, manual launchers, and fork-local implementation plan:

- [`pi-mono-host-integration-plan.md`](./pi-mono-host-integration-plan.md)
- [`pi-mono-implementation-checklist.md`](./pi-mono-implementation-checklist.md)
- [`pi-mono-integration-testing.md`](./pi-mono-integration-testing.md)
- [`pi-mono-manual-tests.md`](./pi-mono-manual-tests.md)

## Maintainer Context

- [`agent-context/architecture.md`](./agent-context/architecture.md)
- [`agent-context/api-conventions.md`](./agent-context/api-conventions.md)
- [`agent-context/testing-guide.md`](./agent-context/testing-guide.md)
- [`adr/0001-programmatic-camlflow-pi-sdk.md`](./adr/0001-programmatic-camlflow-pi-sdk.md)
- [`adr/0002-camlflow-sandbox-orchestrator-boundaries.md`](./adr/0002-camlflow-sandbox-orchestrator-boundaries.md)
- [`docs-validation.md`](./docs-validation.md)

## Documentation Maintenance

When behavior changes:

- validate runnable snippets with [`docs-validation.md`](./docs-validation.md)
- update the author guide and CLI reference for user-visible command or flag
  changes
- update `json-encoding.md` when type/JSON encoding changes
- update `json-rpc.md`, fixtures, and SDK READMEs when protocol shapes change
- update `pi-sdk-harness.md` and the Pi SDK README when harness lifecycle,
  sandbox, shell, or runtime contracts change
- keep historical status docs as snapshots unless the project state they
  describe has changed
