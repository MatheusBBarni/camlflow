# CamlFlow

CamlFlow is a typed workflow language and runtime for orchestrating agent and
skill effects while delegating real model, tool, and host execution to providers
or host integrations.

## Language

**CamlFlow Pi SDK**:
A thin TypeScript host adapter that gives `pi-mono` a Pi-shaped API for running CamlFlow workflows through the existing JSON-RPC SDK.
_Avoid_: pi-sdk integration, pi refactor, pi bridge rewrite, Flue-style authoring SDK, `/camlflow-run` command

**Pi SDK**:
The `@mariozechner/pi-coding-agent` TypeScript SDK surface used to create Pi agent sessions, run prompts, subscribe to session events, and abort active work.
_Avoid_: full pi-mono dependency, Pi RPC mode

## Relationships

- The **CamlFlow Pi SDK** builds on the existing TypeScript JSON-RPC SDK.
- The **CamlFlow Pi SDK** depends on the **Pi SDK** surface exposed by `@mariozechner/pi-coding-agent`.
- The **CamlFlow Pi SDK** is consumed by `pi-mono` host integration code.
- The **CamlFlow Pi SDK** is scoped to the `pi-mono` integration rather than a generic host-adapter abstraction.
- The **CamlFlow Pi SDK** does not replace CamlFlow workflow authoring or the JSON-RPC protocol.
- The **CamlFlow Pi SDK** treats each CamlFlow effect as a separate Pi worker-session boundary.
- The **CamlFlow Pi SDK** declares the **Pi SDK** as a peer dependency and uses it as a dev dependency for local tests and examples.
- The **CamlFlow Pi SDK** should expose a programmatic API rather than a `/camlflow-run` slash command.
- The **CamlFlow Pi SDK** accepts workflow execution through typed `run` options such as workflow path, entrypoint, input, skills directory, and abort signal.

## Example dialogue

> **Dev:** "Should the Pi integration change the JSON-RPC protocol?"
> **Domain expert:** "No. The **CamlFlow Pi SDK** should wrap the existing bridge with a Pi-friendly API."

## Flagged ambiguities

- "pi-sdk integration/refactor" was resolved to mean a new `packages/camlflow-pi-sdk` package in this repo, not a `/camlflow-run` slash command.
