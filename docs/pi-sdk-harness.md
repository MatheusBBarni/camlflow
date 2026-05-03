# CamlFlow Pi SDK Harness

This is the maintained CamlFlow-owned integration path for Pi-style hosts. It
uses `packages/camlflow-pi-sdk`, which wraps the JSON-RPC bridge and exposes two
TypeScript APIs:

- `createPiCamlFlowHostSession(...)` for running a known `.cml` workflow from a
  native Pi command, palette action, panel, or other UI surface.
- `createPiCamlFlowHarness(...)` for Flue-style agent orchestration with
  sandbox ownership, named sessions, prompt/task/skill calls, trusted shell, and
  workflow runs.

The package does not parse `/camlflow-run` or own Pi UI registration. Pi or any
other host owns commands, menus, panels, auth UX, and model selection.
For the supported `.cml` syntax surface, see
[`language-reference.md`](./language-reference.md).
For common host, sandbox, and package-test failures, see
[`troubleshooting.md`](./troubleshooting.md).

## Choose The API

Use `createPiCamlFlowHostSession(...)` when the host already knows the workflow
path and wants to run it:

```ts
import { createPiCamlFlowHostSession } from "camlflow-pi-sdk";

const host = createPiCamlFlowHostSession({ runtime });

const result = await host.runWorkflow({
  workflowPath: "examples/problem-coach/main.cml",
  skillsDir: "examples/problem-coach/skills",
  input: {
    problem_name: "two sum",
    language: { tag: "Python" },
    audience: { tag: "Interview" },
    must_cover: ["hash map approach", "time complexity"],
  },
});

console.log(result.output);
```

Use `createPiCamlFlowHarness(...)` when the host wants a Flue-style agent object
first:

```ts
import { createPiCamlFlowHarness } from "camlflow-pi-sdk";

const harness = createPiCamlFlowHarness({ runtime });
const agent = await harness.init({
  id: "repo-triage",
  sandbox: "workspace-write",
  model: runtime.session.model,
});

const session = await agent.session("issue-42");

try {
  const findings = await session.task("Inspect this checkout and list risks.", {
    result: "json",
  });

  const plan = await session.skill("triage", {
    args: { issueNumber: 42, findings },
    result: "json",
  });

  const workflow = await agent.runWorkflow({
    workflowPath: "examples/repo-triage/main.cml",
    skillsDir: "examples/repo-triage/skills",
    input: {
      task: "Triage the current repository.",
      suspected_area: "Pi harness integration",
      file_hints: [],
      goals: ["ground findings in repository evidence"],
      constraints: ["keep output actionable"],
      mode: { tag: "Quick" },
    },
  });

  console.log(plan, workflow.output);
} finally {
  await session.close();
  await agent.close();
}
```

## Runtime Boundary

The host supplies Pi runtime services:

- current working directory
- current selected model and thinking level
- model registry and auth storage
- Pi session factory and tool services

CamlFlow supplies:

- `.cml` parsing, type-checking, and execution
- JSON-RPC bridge lifecycle
- effect metadata and output schema generation
- validation of every provider/Pi worker JSON result

Do not put credentials, sandbox policy, or shell commands in `.cml` prompts.
Keep those in host code or `session.shell(...)`.

## Sandboxes

Harness presets:

| Preset | Use |
| --- | --- |
| `local` | Alias for workspace-write local tools and trusted shell. |
| `workspace-write` | Pi coding tools and trusted shell in the selected workspace. |
| `read-only` | Read/search/list tools; `session.shell(...)` is disabled. |
| `ephemeral` | Temporary workspace with tools and shell, removed on `agent.close()` unless cleanup is disabled. |

Custom sandboxes can pass explicit `cwd`, `tools`, `shell`, and `dispose`.
Sandbox factories can lazily create one sandbox per initialized agent:

```ts
const agent = await harness.init({
  sandbox: async (cwd) => ({
    kind: "custom",
    cwd,
    tools: () => myTools,
    shell: myShellExecutor,
    dispose: async () => {
      await releaseResources();
    },
  }),
});
```

The initialized `agent` owns the sandbox. Sessions share it. `session.close()`
closes only the Pi conversation; `agent.close()` cancels active workflow runs
and releases the sandbox.

## Trusted Shell

`session.shell(...)` is host-side trusted execution:

```ts
await session.shell("git status --short", {
  cwd: ".",
  timeoutMs: 10_000,
});
```

Use it for explicit host commands and secret-bearing environment variables:

```ts
await session.shell("deploy-tool release", {
  env: { DEPLOY_TOKEN: process.env.DEPLOY_TOKEN ?? "" },
});
```

Built-in local shell sandboxes constrain `cwd` to the sandbox root, including
symlink-aware filesystem checks. Shell commands must be non-empty. Environment
maps must be plain objects with valid names and string values.

## Workflow Inputs And Outputs

`runWorkflow(...)`, `session.skill(..., { args })`, and parsed prompt results
all use strict JSON values. CamlFlow type encoding rules are documented in
[`json-encoding.md`](./json-encoding.md).

Important shapes:

- variants use `{ "tag": "Constructor" }`
- one-payload variants use `{ "tag": "Constructor", "value": ... }`
- multi-payload variants use `{ "tag": "Constructor", "values": [...] }`
- options use `{ "tag": "Some", "value": ... }` or `{ "tag": "None" }`

Pi workers must return JSON matching the declared CamlFlow return type for each
effectful step. CamlFlow validates that JSON before the next workflow step runs.

## Concurrency And Cancellation

Rules:

- one JSON-RPC bridge process handles one active CamlFlow run
- one harness agent owns one sandbox
- one session runs one prompt/skill turn at a time
- use another session or `session.task(...)` for independent concurrent work
- `session.abort()` cancels the active prompt turn and trusted shell command
- `host.cancel()` or `agent.close()` cancels active workflow runs

Host code should always close sessions and agents in `finally` blocks.

## Examples

Compile-checked examples live in
[`packages/camlflow-pi-sdk/examples`](../packages/camlflow-pi-sdk/examples):

- `command-runner.ts`: native Pi command/palette-style workflow run
- `cancellation-and-streams.ts`: panel-style cancellation and output chunks
- `flue-style-harness.ts`: sessions, skills, task, shell, sandbox, workflow run

Run package validation:

```sh
cd packages/camlflow-pi-sdk
npm install
opam exec -- npm test
```

When your shell is not already on OCaml 5.4:

```sh
opam exec --switch 5.4.0 -- npm test
```

## Historical Pi Docs

Older `pi-mono` documents in this repo describe the `/camlflow-run` prototype
and manual launchers. They remain useful as historical validation notes, but new
CamlFlow-side integration work should start from `packages/camlflow-pi-sdk`.
