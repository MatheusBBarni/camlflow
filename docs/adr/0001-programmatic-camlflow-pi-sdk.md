# Programmatic CamlFlow Pi SDK

## Status

Accepted.

## Context

The first `pi-mono` integration proved that CamlFlow can run as a sidecar over
JSON-RPC and delegate each effect to an ephemeral Pi worker session. That
prototype lived in `pi-mono` and was centered on a `/camlflow-run` command, which
made the reusable adapter hard to test and version with CamlFlow.

## Decision

CamlFlow exposes the `pi-mono` integration through
`packages/camlflow-pi-sdk`, a TypeScript package with a typed programmatic API.
The package wraps `camlflow-ts-json-rpc-sdk`, depends on the Pi SDK surface from
`@mariozechner/pi-coding-agent`, and leaves command, command-palette, file
action, and other UI registration to `pi-mono`.

The package does not parse or expose `/camlflow-run`.

## Consequences

- CamlFlow owns the reusable orchestration adapter and JSON-RPC bridge wiring.
- Pi owns model selection, tools, auth, worker sessions, cancellation UI, and
  user-facing command surfaces.
- Each CamlFlow effect maps to a fresh in-memory Pi worker session.
- Final effect success is still the existing JSON-RPC effect response carrying
  parsed JSON, not advisory streamed text.
- The JSON-RPC protocol version, method names, notifications, and framing remain
  unchanged.
