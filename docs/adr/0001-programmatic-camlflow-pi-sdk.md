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

The package also exposes a Flue-style agent harness API on top of Pi:
`createPiCamlFlowHarness(...).init({ sandbox, model })`,
`agent.session(id?)`, and `session.prompt/skill/task/shell`. This API is
host-side orchestration sugar around Pi sessions and the existing CamlFlow
JSON-RPC bridge; it does not change CamlFlow syntax or JSON-RPC method names.
The shared runtime object is validated up front, including `cwd`, `session`,
`session.thinkingLevel`, `services`, optional `services.agentDir`, and the
required model registry methods, so bad host wiring fails before worker sessions
or JSON-RPC clients are created. The model registry's
available-model lookup must return an array of Pi model objects, model lookups
must return the same NUL-free string shape, and auth checks must return booleans. Exported
option bags, callbacks, injected factory functions, worker sessions, and
JSON-RPC clients are shape-checked before the adapter calls prompt, initialize,
or run. The latest assistant-role message from injected worker sessions is
authoritative and must contain shaped text content before results are parsed;
malformed latest output is rejected instead of falling back to older assistant
text. Streamed `text_delta` events must carry string deltas. Assistant
`stopReason` and `errorMessage` status fields must be strings when present.
Worker `subscribe(...)` calls must return an unsubscribe function before
prompting starts. Harness result parser option shapes are validated before a
prompt is sent, avoiding Pi side effects for malformed host parser wiring.
Injected JSON-RPC client
`initialize` and `run` results are validated before they are exposed through the
harness, including protocol/IR versions,
boolean capabilities, effect kinds, run id, step count, and strict JSON workflow
result objects and output. `camlflow` spawn overrides are validated before use
so malformed commands, args, cwd, env, stderr, or callback overrides do not
reach the JSON-RPC process launcher. Trace, diagnostic, progress, and
output-chunk notifications are validated as strict JSON-RPC payloads before host
callbacks run. Inbound `executeEffect` request envelopes are validated before
they are mapped into Pi worker prompts, including string/integer request ids,
strict JSON params, run metadata, known effect kinds, kind/role pairing, inline
agent definition metadata, and effect request fields. Inline definitions are
accepted only for `inline-agent` effects and are required for that effect kind.
The validated JSON-RPC request `params` are the source of truth, and the
effect-handler context must provide `emitOutputChunk` before any worker session
is created.

Sandbox support is represented as host-owned presets and custom configs:
`local` / `workspace-write`, `read-only`, `ephemeral`, or `{ kind, cwd, tools,
shell, dispose }`. Hosts may also pass a sandbox factory that lazily returns
one of those configs for an initialized agent; factories must return an explicit
preset, config, or custom sandbox rather than relying on fallback defaults. The
sandbox chooses the Pi tools available to model turns, while
`session.shell(...)` remains trusted host code for explicit commands and
environment variables. Built-in local shell sandboxes validate `cwd` after
filesystem symlink resolution.
Unknown sandbox kinds are rejected at runtime, and custom sandboxes must provide
their own `tools` list or factory. Automatic directory cleanup and the
`cleanup` flag are limited to `ephemeral` sandboxes; custom or host-owned
sandboxes use `dispose` for cleanup.

An initialized harness agent owns one sandbox. Sessions share that sandbox,
`agent.runWorkflow(...)` reuses it for CamlFlow effect workers, and
`agent.close()` cancels active workflow runs and releases it. `session.close()`
only closes the Pi conversation. Prompt and skill calls are serial per session;
hosts can open multiple sessions or use `session.task(...)` for independent
concurrent work. Skill names are validated against Pi's lowercase
letter/digit/hyphen naming rules before a `/skill:name` command is generated.
Prompt and task text must be non-empty after trimming.
Agent `cwd`, `id`, and string `model` overrides are validated before agent
creation; named models must resolve through the runtime model registry.
Workflow paths must also be non-empty, and pre-aborted workflow signals reject
before the JSON-RPC client is spawned. `entrypoint`, `skillsDir`, and
`includePaths` entries must be non-empty when provided. Runtime option objects
are validated at public API boundaries, including prompt/task/skill options,
trusted shell fields, cancellation signals, and optional effect request metadata.
Effect `outputSchema` must be a strict JSON object. Workflow input, effect
input, and skill args must be strict JSON values; JavaScript-only values such as
`undefined`, functions, symbols, bigint values,
circular references, non-finite numbers, sparse arrays, and non-plain objects
are rejected before the adapter spawns or prompts anything. Hidden properties,
symbol keys, `toJSON` rewrites, and array side properties are also rejected
because JSON would silently omit or rewrite them.
Trusted shell command, cwd, stdin, and env strings reject embedded NUL bytes;
env maps must be plain enumerable objects, and env names must also be non-empty
and must not contain `=`. Custom shell results must use a non-negative integer or
null `code`, a non-empty NUL-free string or null `signal`, and string
stdout/stderr values. Runtime cwd, sandbox cwd, workflow paths, include paths,
and effect control strings such as effect name, kind, declared return type,
directory, and run id also reject embedded NUL bytes before filesystem, spawn,
prompt, or stream-id APIs see them.
Host sessions auto-shutdown the JSON-RPC client after runs by default; shutdown
failures are reported after otherwise successful runs and suppressed when a
primary run failure or explicit cancellation already occurred.

The package does not parse or expose `/camlflow-run`.

## Consequences

- CamlFlow owns the reusable orchestration adapter and JSON-RPC bridge wiring.
- Pi owns model selection, tools, auth, worker sessions, cancellation UI, and
  user-facing command surfaces.
- Host harness code owns sandbox selection, trusted shell execution, and secret
  injection boundaries.
- Each CamlFlow effect maps to a fresh in-memory Pi worker session.
- Effect cancellation during worker creation aborts and disposes the late worker
  before any prompt is sent.
- Final effect success is still the existing JSON-RPC effect response carrying
  parsed JSON, not advisory streamed text.
- The JSON-RPC protocol version, method names, notifications, and framing remain
  unchanged.
