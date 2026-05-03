# camlflow-pi-sdk examples

These examples show how `pi-mono` host code can use the programmatic CamlFlow
Pi adapter. They are compile-checked integration sketches rather than
standalone CLIs: a real Pi command, palette action, or panel supplies the
`PiCamlFlowRuntime` from its active Pi session.

For the maintained host-session vs Flue-style harness guide, see
[`docs/pi-sdk-harness.md`](../../../docs/pi-sdk-harness.md).

## Setup

From `packages/camlflow-pi-sdk/`:

```sh
npm install
npm run build
```

The build compiles the SDK first and then compiles these examples against the
generated `dist/` declarations.

## Examples

### Which API Should I Start With?

Use `createPiCamlFlowHostSession(...)` when a Pi command, palette action, or
panel already knows which `.cml` workflow it wants to run. This is the smallest
embedding surface: one host session owns one JSON-RPC bridge process, forwards
workflow progress into Pi UI, and maps CamlFlow effects onto Pi worker sessions.

Use `createPiCamlFlowHarness(...)` when host code wants a Flue-style agent
object first. The harness owns the sandbox, opens named Pi sessions, supports
one-shot `task(...)` calls, invokes Pi skills, runs trusted shell commands, and
can call CamlFlow workflows from the same agent runtime.

| Goal | Start with |
| --- | --- |
| Add a "Run CamlFlow workflow" command to Pi | `command-runner.ts` |
| Build a panel with cancel and streamed output state | `cancellation-and-streams.ts` |
| Orchestrate sessions, skills, shell, and workflows like Flue | `flue-style-harness.ts` |

### Native command runner

Source: `examples/command-runner.ts`

Demonstrates:

- creating one `PiCamlFlowHostSession` per command invocation
- forwarding progress, diagnostics, and streamed Pi worker output into a host UI
- running a repository checkout through `opam exec -- dune exec camlflow -- serve --stdio`
- keeping command registration outside this package

### Cancellation and streams

Source: `examples/cancellation-and-streams.ts`

Demonstrates:

- wiring a panel-style controller around the single-active-run host session
- using an `AbortController` and `host.cancel()` for user cancellation
- streaming `camlflow/outputChunk` text into UI state
- normalizing success, cancellation, and failure states

### Flue-style harness

Source: `examples/flue-style-harness.ts`

Demonstrates:

- initializing a sandbox-aware agent with `createPiCamlFlowHarness`
- opening a named session and calling `session.skill(...)`
- running a one-shot detached child session with `session.task(...)`
- running trusted host shell commands with explicit environment variables
- invoking a typed CamlFlow workflow from the same agent runtime

## Validation

`npm test` builds these examples before running the SDK tests, so type drift in
the integration snippets is caught by package-local smoke coverage.
