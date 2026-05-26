# camlflow-pi-sdk

Programmatic Pi compatibility adapter and sandbox-aware agent harness for
CamlFlow workflows.

This package wraps `camlflow-ts-json-rpc-sdk` and maps each
`camlflow/executeEffect` request onto an ephemeral in-memory Pi worker session.
It intentionally does not register or parse `/camlflow-run`; command palettes,
slash commands, file actions, and other UI entrypoints remain owned by `pi-mono`.

It also exposes a small Flue-style harness API around Pi:

- `createPiCamlFlowHarness(...).init({ sandbox, model })`
- `agent.session(id?)`
- `session.prompt(...)`
- `session.skill(...)`
- `session.task(...)`
- `session.shell(...)`

The package root exports the harness, host-session factory, effect executor,
effect prompt builder, JSON-output parser, and typed error classes. It does not
export Pi slash-command parsers; skill execution stays behind `session.skill(...)`.

The harness keeps CamlFlow's typed workflow execution and Pi's model/tool
runtime separate from trusted host orchestration code.

The generic host lifecycle boundary now lives in
[`packages/camlflow-orchestrator`](../camlflow-orchestrator). This package stays
Pi-specific: Pi worker-session creation, Pi model registry access, Pi auth
checks, and Pi tool construction remain here during migration.

See
[`docs/adr/0001-programmatic-camlflow-pi-sdk.md`](../../docs/adr/0001-programmatic-camlflow-pi-sdk.md)
for the integration boundary decision.
For the CamlFlow authoring path before you embed workflows in Pi, see
[`docs/writing-and-running-camlflow.md`](../../docs/writing-and-running-camlflow.md).
For the supported `.cml` syntax surface, see
[`docs/language-reference.md`](../../docs/language-reference.md).
For shared CamlFlow/Pi terminology, see
[`docs/glossary.md`](../../docs/glossary.md).
For the JSON shapes Pi workers must return for typed workflow effects, see
[`docs/json-encoding.md`](../../docs/json-encoding.md).
For a focused host-session vs Flue-style harness guide, see
[`docs/pi-sdk-harness.md`](../../docs/pi-sdk-harness.md).

## Install

```sh
npm install camlflow-pi-sdk camlflow-ts-json-rpc-sdk @mariozechner/pi-coding-agent
```

`@mariozechner/pi-coding-agent` is a peer dependency so the host controls the
exact Pi SDK version.

## Usage

For complete, compile-checked host-side examples and guidance on choosing
between a workflow host session and the Flue-style harness, see
[`examples/`](./examples). The examples cover a native Pi command or palette
action, streamed worker output, user cancellation, and sandbox-aware agent
orchestration.

```ts
import { createPiCamlFlowHostSession } from "camlflow-pi-sdk";

const host = createPiCamlFlowHostSession({
  runtime: {
    cwd: runtime.cwd,
    session: {
      model: runtime.session.model,
      thinkingLevel: runtime.session.thinkingLevel,
    },
    services: {
      agentDir: runtime.services.agentDir,
      authStorage: runtime.services.authStorage,
      modelRegistry: runtime.services.modelRegistry,
    },
  },
  onProgress: async (progress) => {
    console.log("progress", progress.stage, progress.message);
  },
  onDiagnostic: async (diagnostic) => {
    console.error("diagnostic", diagnostic.message);
  },
  onTrace: async (trace) => {
    console.log("trace", trace.event);
  },
  onOutputChunk: async (chunk) => {
    console.log("chunk", chunk.delta);
  },
});

const controller = new AbortController();
const result = await host.runWorkflow({
  workflowPath: "examples/problem-coach/main.cml",
  entrypoint: "main",
  input: {
    problem_name: "two sum",
    language: { tag: "Python" },
  },
  skillsDir: "examples/problem-coach/skills",
  signal: controller.signal,
});

console.log(result.output);
```

By default, the adapter starts `camlflow serve --stdio` and talks to it through
the existing JSON-RPC bridge. Override `camlflow.command`, `camlflow.args`, or
`camlflow.cwd` when the host needs to spawn a local checkout through Dune.
The `runtime` object is validated up front: `cwd`, `session`,
`session.thinkingLevel`, `services`, optional `services.agentDir`, and a
`modelRegistry` with `getAvailable`, `find`, and `hasConfiguredAuth` methods
must be present before any worker session or JSON-RPC client is created.
`modelRegistry.getAvailable()` must return an array of Pi model objects with
non-empty `provider`, `id`, `name`, and `api` fields, `find(...)` must return the
same NUL-free string shape, and `hasConfiguredAuth(...)` must return a boolean.
Exported option bags, callbacks, injected factory functions, and injected `workerSessionFactory`
/ `clientFactory` results are shape-checked before prompts, `initialize`, or
`run` are called, so bad host wiring fails at the boundary instead of surfacing
as a later method error. The latest assistant-role message from injected worker
sessions is authoritative and must contain shaped text content before results are
parsed; malformed latest output is rejected instead of falling back to older
assistant text. Streamed `text_delta` events must carry string deltas. Assistant
`stopReason` and `errorMessage` status fields must be strings when present.
Worker `subscribe(...)` calls must return an unsubscribe function before
prompting starts. Injected JSON-RPC clients must also return shaped `initialize` and `run` results: non-empty protocol/IR versions, object
boolean capabilities, known effect kinds, a non-empty run id, non-negative step
count, and strict JSON result objects and workflow output. `camlflow` spawn
overrides are checked as spawn-safe values too: command/cwd/env/arg strings
reject NUL bytes, args must be strings, stderr must be `inherit` or `pipe`, and
callback overrides must be functions.
Trace, diagnostic, progress, and output-chunk notifications are validated as
strict JSON-RPC payloads before host callbacks run, so malformed notification
data fails at the adapter boundary.
Inbound `executeEffect` request envelopes are also validated before they are
mapped into Pi worker prompts, including string/integer request ids, strict JSON
params, run metadata, known effect kinds, kind/role pairing, inline agent
definition metadata, and effect request fields. Inline definitions are accepted
only for `inline-agent` effects and are required for that effect kind. The
adapter uses the validated JSON-RPC request `params` as the source of truth, and
the effect-handler context must provide `emitOutputChunk` before any worker
session is created.
`workflowPath` must be non-empty, and a pre-aborted `signal` rejects before the
JSON-RPC client is spawned. `entrypoint`, `skillsDir`, and `includePaths`
entries must also be non-empty when provided. Runtime option objects are checked
at API boundaries, including prompt/task/skill options, shell `cwd`/`env`/`stdin`
fields, `AbortSignal`-shaped cancellation inputs, and optional effect request
metadata fields. Effect `outputSchema` must be a strict JSON object. Workflow
input, effect input, and skill args must be strict JSON values: no `undefined`,
functions, symbols, bigint values, circular
references, non-finite numbers, sparse arrays, or non-plain objects such as
`Date` and `Map`. Hidden object properties, symbol keys, `toJSON` rewrites, and
array side properties are also rejected because JSON would silently omit or
rewrite them. Trusted shell strings reject embedded NUL bytes, and env maps must
be plain enumerable objects with non-empty names that do not contain `=`. Runtime
cwd, sandbox cwd, workflow paths, include paths, and effect control strings such
as effect name, kind, declared return type, directory, and run id reject embedded
NUL bytes before filesystem, spawn, prompt, or stream-id APIs see them. Sandbox
factories must resolve to an explicit preset, config, or custom sandbox object;
malformed or missing factory results are rejected instead of silently falling
back to `local`.

## Flue-Style Harness

Use `createPiCamlFlowHarness` when host code wants to orchestrate an agent
directly and optionally call CamlFlow workflows from that same runtime:

```ts
import { createPiCamlFlowHarness } from "camlflow-pi-sdk";

const harness = createPiCamlFlowHarness({ runtime });
const agent = await harness.init({
  id: "triage",
  sandbox: "local",
  model: runtime.session.model,
});

const session = await agent.session("issue-42");

try {
  const findings = await session.task("Inspect the checkout and list likely risk areas.", {
    result: "json",
  });
  const plan = await session.skill("triage", {
    args: { issueNumber: 42, findings },
    result: "json",
  });
  const summary = JSON.stringify(plan);

  await session.shell("git add -A && git commit --file -", {
    stdin: `fix: ${summary}`,
    env: { GITHUB_TOKEN: process.env.GITHUB_TOKEN ?? "" },
  });

  const workflow = await agent.runWorkflow({
    workflowPath: "examples/repo-triage/main.cml",
    input: { task: "Summarize the current checkout." },
  });

  console.log(workflow.output);
} finally {
  await session.close();
  await agent.close();
}
```

Supported sandbox presets:

- `local` / `workspace-write`: Pi coding tools plus trusted host shell in the
  selected working directory.
- `read-only`: Pi read/search/list tools; `session.shell(...)` is disabled.
- `ephemeral`: a temporary local workspace with Pi coding tools and shell,
  removed when the agent closes unless `cleanup: false` is set.
- custom configs: pass `{ kind, cwd, tools, shell, dispose }` to plug in a
  host-owned sandbox implementation.
- sandbox factories: pass `(cwd) => ({ kind, cwd, tools, shell, dispose })` to
  lazily create a sandbox once per initialized agent.
Unknown sandbox kinds are rejected at runtime. Custom sandboxes must provide
their own `tools` list or factory, and sandbox configs validate `cwd`, `tools`,
`shell`, `cleanup`, and `dispose` before any worker session is created.
Automatic directory removal and the `cleanup` flag are limited to `ephemeral`;
use `dispose` for custom cleanup of host-owned sandboxes.

`session.shell(...)` is host-side trusted code. Pass sensitive environment
variables there instead of placing secrets in prompts or files visible to the
model. Shell commands must be non-empty, and `timeoutMs` must be a finite
non-negative number. Custom shell executors must return `{ code, signal,
stdout, stderr }` with a non-negative integer or null `code`, a non-empty
NUL-free string or null `signal`, and string stdout/stderr values. Shell `cwd` values are
resolved inside the sandbox root; attempts to escape that root with `..` or an
absolute path fail before the command starts. For built-in local shell
sandboxes, `cwd` is also checked after filesystem symlink resolution.

`prompt(...)` and `skill(...)` return text by default. Pass `result: "json"` to
parse the final assistant message as JSON, or pass a parser/schema object with
`parse(value)` or `safeParse(value)` for host-side validation. Parser option
shapes are checked before the prompt is sent, so malformed parser wiring fails
without invoking Pi.
Prompt and task text must be non-empty after trimming.

`session.task(...)` runs a focused one-shot child session with separate message
history and the same sandbox, then closes that child session after the prompt
finishes.
`session.skill(name, ...)` validates Pi skill names before creating a
`/skill:name` command; names must use lowercase letters, digits, and single
hyphens. Skill `args` must be JSON-serializable before the Pi prompt is sent.

The initialized `agent` owns sandbox state. Multiple sessions opened from the
same agent share the same sandbox, and `agent.runWorkflow(...)` executes
CamlFlow effect workers in that sandbox. Closing an individual session disposes
the Pi conversation only; closing the agent cancels active workflow runs and
releases the sandbox. Calling `session.abort()` aborts both the active Pi worker
turn and any in-flight trusted shell command started from that session.
Prompt and skill calls are serial per session; open a second session or use
`session.task(...)` for independent concurrent work.
Agent `cwd`, `id`, and string `model` overrides are validated before the agent
is created. Named model overrides use `provider/model` and must resolve through
the runtime model registry.

## Effect Execution

For each CamlFlow effect, the adapter:

- creates a fresh Pi worker session with `SessionManager.inMemory()`
- uses the current Pi model, thinking level, model registry, auth storage, and
  sandbox-selected Pi tools
- sends CamlFlow's rendered effect prompt with a small JSON-only wrapper
- relays Pi text deltas as `camlflow/outputChunk` notifications
- parses the final assistant message as JSON and returns it through the existing
  `camlflow/executeEffect` response contract

Abort signals are shared by the CamlFlow run request and the active Pi worker
session. Calling `host.cancel()` aborts both sides of the current run and
suppresses shutdown errors from the already-cancelled JSON-RPC client.
Successful workflow runs report auto-shutdown failures unless
`autoShutdown: false` is set.
If cancellation lands while a worker session is still being created, the late
worker is aborted and disposed before any prompt is sent.

## Local Validation

```sh
npm install
npm test
```

The package-local tests use injected fake CamlFlow clients and fake Pi worker
sessions, so they do not require live model credentials.
