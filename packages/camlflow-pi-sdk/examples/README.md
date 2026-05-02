# camlflow-pi-sdk examples

These examples show how `pi-mono` host code can use the programmatic CamlFlow
Pi adapter. They are compile-checked integration sketches rather than
standalone CLIs: a real Pi command, palette action, or panel supplies the
`PiCamlFlowRuntime` from its active Pi session.

## Setup

From `packages/camlflow-pi-sdk/`:

```sh
npm install
npm run build
```

The build compiles the SDK first and then compiles these examples against the
generated `dist/` declarations.

## Examples

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

## Validation

`npm test` builds these examples before running the SDK tests, so type drift in
the integration snippets is caught by package-local smoke coverage.
