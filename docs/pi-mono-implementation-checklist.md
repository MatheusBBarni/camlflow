# `pi-mono` Implementation Checklist

Historical note: this checklist describes the first fork-local prototype that
registered `/camlflow-run`. New CamlFlow-side integration work should start from
`packages/camlflow-pi-sdk`, which exposes a typed programmatic API and leaves
command or UI registration to `pi-mono`.

This is the concrete implementation checklist for the first real-host CamlFlow validation inside a `pi-mono` fork.

It assumes the strategy already documented in:

- `docs/pi-sdk-harness.md`
- `docs/host-adapter-architecture.md`
- `docs/pi-mono-host-integration-plan.md`
- `docs/pi-mono-integration-testing.md`

The checklist is intentionally biased toward the shortest path to Beta 1 signal.

---

## Recommended implementation shape

Inside `pi-mono`, the best first product shape is:

- keep CamlFlow external
- spawn `camlflow serve --stdio`
- use the CamlFlow TypeScript SDK directly
- surface the integration as a shipped slash command or built-in extension command
- execute each CamlFlow effect inside an ephemeral pi worker session

The important `pi-mono` seam is already present:

- `packages/coding-agent/src/main.ts` injects `resourceLoaderOptions.extensionFactories`
- `packages/coding-agent/src/core/agent-session-runtime.ts` exposes `runtime.services`

That means the first fork does **not** need to modify pi's RPC mode or TUI internals.

---

## Hard recommendation

Use a built-in extension-factory style integration first, not a new parser-level slash-command implementation.

Why:

- slash commands already exist through `pi.registerCommand(...)`
- command UI, argument completion, notifications, status text, and editor prompts already exist
- `main.ts` already has a clean injection seam for extension factories
- this avoids deep coupling while still letting the fork ship the feature by default

So the first command surface should be implemented as a built-in extension factory that lives in source control, not as an ad hoc one-off example file.

---

## Likely file touch points in `pi-mono`

These are grouped by confidence.

## Must-touch for the first fork

### Dependency/bootstrap

- `packages/coding-agent/package.json`
  - add a dependency path for `camlflow-ts-json-rpc-sdk`
  - if the SDK is not published, choose one of:
    - temporary git/tarball dependency
    - vendored copy inside the fork
    - local `file:` dependency during development

### New integration module

Create a new directory:

```text
packages/coding-agent/src/integrations/camlflow/
  extension.ts
  session.ts
  effect-executor.ts
  notification-bridge.ts
  parse-command.ts
  prompt.ts
  types.ts
```

Suggested responsibilities:

- `extension.ts`
  - registers `/camlflow-run`
  - owns UI/status wiring
  - closes over runtime access via a getter/ref
- `session.ts`
  - wraps CamlFlow sidecar lifecycle
  - initializes the JSON-RPC session
  - runs workflows and handles teardown/cancellation
- `effect-executor.ts`
  - maps `camlflow/executeEffect` into ephemeral pi worker sessions
- `notification-bridge.ts`
  - maps CamlFlow notifications into pi UI/transcript surfaces
- `parse-command.ts`
  - parses command args and validates workflow/input options
- `prompt.ts`
  - builds the pi worker system prompt and final JSON extraction rules
- `types.ts`
  - local integration types and small DTOs

### Runtime injection

- `packages/coding-agent/src/main.ts`
  - add one built-in extension factory for the CamlFlow integration
  - recommended pattern: create a mutable `runtimeRef` and pass an extension factory that reads from it
  - after `createAgentSessionRuntime(...)`, assign `runtimeRef.current = runtime`

This is the cleanest place to make the feature available in the fork without modifying command parsing internals.

### Public exports if needed

- `packages/coding-agent/src/index.ts`
  - export the integration pieces only if you want them reusable from the SDK side
  - optional for the first fork

### Docs

- `packages/coding-agent/README.md`
  - add a short section for `/camlflow-run`
  - document required CamlFlow binary/SDK availability

---

## Probably-touch, depending on how reusable you want the first pass to be

### Service reuse helper

- `packages/coding-agent/src/core/agent-session-services.ts`

Only touch this if you want a helper like:

- `createAgentSessionFromExistingServices(...)`
- `createEphemeralAgentSession(...)`

You can likely avoid this in the first pass by constructing worker sessions directly from `runtime.services`.

### Runtime helper extraction

- `packages/coding-agent/src/core/agent-session-runtime.ts`

This file already exposes `runtime.services`, which is enough for the first pass.

Only touch it if you decide to add a tiny helper for integrations to safely read current runtime state.

---

## Explicitly avoid touching in the first pass

Unless real friction forces it, do **not** touch:

- `packages/coding-agent/src/modes/rpc/*`
- `packages/coding-agent/src/modes/interactive/*`
- `packages/coding-agent/src/core/extensions/runner.ts`
- `packages/coding-agent/src/cli/args.ts`
- `packages/coding-agent/src/core/model-registry.ts`

The first host validation does not need a new CLI mode, new transport, or new TUI primitives.

---

## Implementation phases

## Phase 0 — dependency and bootstrap decisions

### Checklist

- [ ] Decide how the fork will import `camlflow-ts-json-rpc-sdk`
- [ ] Decide how the fork will locate the `camlflow` binary
- [ ] Decide the first shipped command name: recommend `/camlflow-run`
- [ ] Decide whether command arguments are inline-only or can prompt interactively for missing values

### Notes

The first pass should avoid adding new persistent settings.

Use simple defaults first:

- CamlFlow command: `camlflow`
- CamlFlow args: `serve --stdio`
- notifications: trace, diagnostics, progress enabled

---

## Phase 1 — command surface in pi

### Probable files

- `packages/coding-agent/src/integrations/camlflow/extension.ts`
- `packages/coding-agent/src/integrations/camlflow/parse-command.ts`
- `packages/coding-agent/src/main.ts`

### Checklist

- [ ] Register `/camlflow-run`
- [ ] Support at least:
  - workflow path
  - optional `--entry`
  - optional `--input-json`
  - optional `--skills-dir`
- [ ] If args are missing, use `ctx.ui.input(...)` or `ctx.ui.editor(...)` to gather them
- [ ] Validate that the workflow path ends in `.cml`
- [ ] Validate JSON input before the run starts
- [ ] Reject concurrent CamlFlow runs in the same visible pi session for now
- [ ] Use `ctx.ui.setStatus(...)` to show workflow state
- [ ] Render the final typed result into the visible transcript

### Recommended UX

Keep it explicit:

```text
/camlflow-run path/to/workflow.cml --entry main --input-json '{"task":"..."}'
```

If `--input-json` is omitted, let CamlFlow treat the workflow as zero-input.

If the JSON is hard to type inline, open `ctx.ui.editor(...)`.

---

## Phase 2 — CamlFlow sidecar session wrapper

### Probable files

- `packages/coding-agent/src/integrations/camlflow/session.ts`
- `packages/coding-agent/src/integrations/camlflow/types.ts`

### Checklist

- [ ] Wrap `spawnCamlFlowClient(...)` from the CamlFlow TS SDK
- [ ] On command start, spawn `camlflow serve --stdio`
- [ ] Call `initialize(...)` with notification preferences enabled
- [ ] Call `run(...)` with:
  - workflow path
  - include paths if needed
  - entrypoint
  - input JSON
  - skills dir if supplied
- [ ] Return the final typed `camlflow/run` result to the command handler
- [ ] Always call shutdown/exit or equivalent teardown on normal completion
- [ ] Tear down the child process on error or cancellation
- [ ] Track one in-flight run id and one active abort controller

### Nice-to-have but not required first

- transcript/artifact capture to a temp file
- elapsed-time metrics per effect
- debug mode to print raw CamlFlow notifications

---

## Phase 3 — notification bridge

### Probable files

- `packages/coding-agent/src/integrations/camlflow/notification-bridge.ts`
- `packages/coding-agent/src/integrations/camlflow/extension.ts`

### Checklist

- [ ] Map `camlflow/trace` to compact debug output or hidden transcript lines
- [ ] Map `camlflow/progress` to `ctx.ui.setStatus(...)`
- [ ] Map `camlflow/diagnostic` to visible error messages
- [ ] Map `camlflow/outputChunk` to a live effect preview area or transcript block
- [ ] Keep the notification bridge presentation-only

### Recommended first UI mapping

- trace → debug log lines
- progress → status text like `CamlFlow: effect 2 running`
- diagnostic → `ctx.ui.notify(..., "error")` plus transcript entry
- outputChunk → append into a small current-effect preview buffer

No custom TUI component is needed in the first pass.

---

## Phase 4 — effect executor using pi worker sessions

### Probable files

- `packages/coding-agent/src/integrations/camlflow/effect-executor.ts`
- `packages/coding-agent/src/integrations/camlflow/prompt.ts`

### Key design choice

Each `camlflow/executeEffect` request should create a fresh, in-memory pi worker session.

Use:

- `SessionManager.inMemory()`
- `runtime.services.authStorage`
- `runtime.services.modelRegistry`
- `runtime.services.settingsManager`
- a narrow `DefaultResourceLoader` or explicit resource setup
- worker cwd = `effect.workingDirectory ?? runtime.cwd`

### Checklist

- [ ] Build a helper that receives:
  - current runtime
  - CamlFlow effect request
  - output-chunk emitter
  - abort signal
- [ ] Create an ephemeral pi worker session for each effect
- [ ] Reuse the active visible model by default when possible
- [ ] Start with the default built-in coding tools only
- [ ] Do **not** reuse arbitrary visible-session extension state in the first pass
- [ ] Subscribe to worker `message_update` events
- [ ] Forward `text_delta` events into CamlFlow `emitOutputChunk(...)`
- [ ] Optionally capture worker `tool_execution_*` events into local debug metadata
- [ ] Parse the final worker assistant output as JSON
- [ ] Return the parsed JSON as the `camlflow/executeEffect` result
- [ ] Abort the worker session if the CamlFlow run is cancelled

### Important constraint discovered from pi APIs

A plain extension command does **not** get direct access to `authStorage`, `settingsManager`, or `resourceLoader` through `ExtensionCommandContext`.

That is why the shipped integration should close over `runtime.services` rather than living as an ordinary standalone user extension.

That single detail is the main reason to inject this as a built-in extension factory from `main.ts`.

---

## Phase 5 — worker prompt and final JSON contract

### Probable files

- `packages/coding-agent/src/integrations/camlflow/prompt.ts`
- `packages/coding-agent/src/integrations/camlflow/effect-executor.ts`

### Checklist

- [ ] Start with `effect.renderedPrompt` as the main effect prompt body
- [ ] Wrap it with a small pi-specific system prompt that says:
  - execute one CamlFlow effect
  - use tools if needed
  - final answer must be JSON only
  - the JSON must match the declared schema
  - no markdown fences unless unavoidable
- [ ] Accept at most these final-output shapes:
  - raw JSON text
  - one fenced JSON block that can be unwrapped safely
- [ ] Fail the effect if final JSON cannot be parsed
- [ ] Fail the effect if parsed JSON does not match CamlFlow's expected contract on return

### Strong recommendation

Do **not** add retry-on-bad-JSON in the first pass.

Bad JSON is valuable Beta 1 signal.

---

## Phase 6 — cancellation bridge

### Probable files

- `packages/coding-agent/src/integrations/camlflow/session.ts`
- `packages/coding-agent/src/integrations/camlflow/effect-executor.ts`
- `packages/coding-agent/src/integrations/camlflow/extension.ts`

### Checklist

- [ ] Create one `AbortController` for the active visible workflow run
- [ ] On user cancel, abort that controller
- [ ] Let the CamlFlow TS SDK forward cancellation to `$/cancelRequest`
- [ ] If a pi worker session is active, call `workerSession.abort()` too
- [ ] Surface cancellation as cancellation, not a generic error
- [ ] Clear status/progress UI on cancellation

### First-pass behavior target

Safe-boundary correctness is enough.

Do not try to make cancellation smarter than CamlFlow's current contract.

---

## Phase 7 — result rendering in the visible pi session

### Probable files

- `packages/coding-agent/src/integrations/camlflow/extension.ts`
- optionally `packages/coding-agent/src/integrations/camlflow/notification-bridge.ts`

### Checklist

- [ ] Print a concise run summary
- [ ] Show the final typed output
- [ ] Show steps run / elapsed time if cheap to compute
- [ ] Preserve diagnostics if the workflow fails
- [ ] Make it clear that streamed output was advisory and final output is authoritative

### Suggested output shape

Keep it simple:

```text
CamlFlow run complete
workflow: examples/orchestrator-session/main.cml
steps: 4
output:
{ ...typed JSON... }
```

---

## Phase 8 — tests in `pi-mono`

These are probable file touch points, not final required names.

### Likely new tests

- `packages/coding-agent/test/camlflow-extension.test.ts`
- `packages/coding-agent/test/camlflow-effect-executor.test.ts`
- `packages/coding-agent/test/camlflow-host-session.test.ts`

### Existing files worth copying patterns from

- `packages/coding-agent/test/extensions-runner.test.ts`
- `packages/coding-agent/test/sdk-session-manager.test.ts`
- `packages/coding-agent/test/rpc.test.ts` only for style, not because RPC should be changed

### Checklist

- [ ] Unit-test command parsing
- [ ] Unit-test final JSON extraction rules
- [ ] Unit-test notification mapping
- [ ] Unit-test cancellation propagation from visible session to worker session
- [ ] Smoke-test one effect execution path with a mocked CamlFlow SDK client
- [ ] Smoke-test one real spawned CamlFlow session if the fork can rely on a local dev binary

For Beta 1, mocked tests plus manual real-host runs are enough.

---

## Phase 9 — manual validation runs

Run at least these CamlFlow workflows through the `pi-mono` fork:

- [ ] `examples/basic/main.cml`
- [ ] `examples/provider-hooks/workflow.cml`
- [ ] `examples/orchestrator-session/main.cml`

For each run, capture:

- [ ] did the effect boundary feel natural?
- [ ] was `effect.renderedPrompt` good enough?
- [ ] were notifications sufficient?
- [ ] was cancellation clean enough?
- [ ] did the host want more metadata or more control?
- [ ] was the final JSON contract too brittle?

This feedback is the real Beta 1 deliverable.

---

## Minimal viable implementation order

If you want the shortest path, do the work in exactly this order:

1. `package.json` dependency decision
2. `src/integrations/camlflow/types.ts`
3. `src/integrations/camlflow/parse-command.ts`
4. `src/integrations/camlflow/session.ts`
5. `src/integrations/camlflow/extension.ts`
6. `src/main.ts` runtime-ref injection
7. manual run of a pure workflow
8. `src/integrations/camlflow/effect-executor.ts`
9. manual run of an effectful workflow
10. `src/integrations/camlflow/notification-bridge.ts`
11. tests
12. README/docs

That order gets a visible end-to-end path early.

---

## What “done enough for Beta 1” means in `pi-mono`

The first fork is good enough when:

- [ ] `/camlflow-run` works end to end
- [ ] at least one effectful workflow runs through pi worker sessions
- [ ] progress, diagnostics, cancellation, and output chunks are all exercised
- [ ] the implementation does not touch pi RPC or TUI internals
- [ ] real usage reveals concrete friction items for CamlFlow runtime/provider/SDK follow-up

Until then, keep the integration thin and avoid polish work.
