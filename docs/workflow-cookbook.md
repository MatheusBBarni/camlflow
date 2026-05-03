# CamlFlow Workflow Cookbook

Use these patterns as starting points for `.cml` workflows. For the language
walkthrough, see [`writing-and-running-camlflow.md`](./writing-and-running-camlflow.md).
For JSON input shapes, see [`json-encoding.md`](./json-encoding.md).

## Small Bound Agent

Use this when a host, provider, or Pi worker should implement the effect:

```ocaml
agent greeter : name:string -> string = Agent.bind "greeter"

let main (name : string) : string =
  let* greeting = greeter ~name:name in
  greeting ^ "!"
```

Run deterministically while authoring:

```sh
opam exec -- dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
```

Then add a provider or host when you want real model execution.

## Pure Helpers Before Effects

Keep normalization and branching in `.cml` so host effects receive clean inputs:

```ocaml
type language = Python | TypeScript | OCaml

type request = {
  problem_name : string;
  language : language;
}

type normalized_request = {
  title : string;
  language_name : string;
}

let language_name (language : language) : string =
  match language with
  | Python -> "Python"
  | TypeScript -> "TypeScript"
  | OCaml -> "OCaml"

let normalize (request : request) : normalized_request =
  {
    title = request.problem_name;
    language_name = language_name request.language;
  }
```

## Local Prompt Skill

Use local skills when prompt behavior should live next to the project:

```ocaml
skill caveman : prompt:string -> string = Skill.bind "caveman"

let main (prompt : string) : string =
  let* answer = caveman ~prompt:prompt in
  answer
```

Layout:

```text
skills/
  caveman/
    SKILL.md
```

Run:

```sh
opam exec -- dune exec camlflow -- run examples/local-skill/main.cml \
  --skills examples/local-skill/skills \
  --input-json '"hello"'
```

## Inline Agent Metadata

Use `Agent.define` when the workflow contract should carry agent metadata:

```ocaml
agent reviewer : code:string -> string =
  Agent.define
    ~name:"reviewer"
    ~style:"concise"
    ~system_prompt:"Review the code and return the requested JSON."
```

Provider and JSON-RPC/Pi hosts receive that metadata in the effect request.
Inline `~model:"..."` wins over CLI `--model` for direct provider runs.

## Structured Output Pack

Declare the return type you want the provider or host to produce:

```ocaml
type answer_pack = {
  title : string;
  summary : string;
  risks : string list;
  next_steps : string list;
}

agent packager : prompt:string -> answer_pack = Agent.bind "packager"

let main (prompt : string) : answer_pack =
  let* pack = packager ~prompt:prompt in
  pack
```

The provider/host/Pi worker must return JSON matching `answer_pack`. CamlFlow
validates the shape before returning from `let*`.

## Branching Between Effects

Use pure branching to decide which effect to run:

```ocaml
type mode = Quick | DeepDive

agent quick_triage : task:string -> string = Agent.bind "quick-triage"
agent deep_triage : task:string -> string = Agent.bind "deep-triage"

let main (task : string) (mode : mode) : string =
  match mode with
  | Quick ->
      let* answer = quick_triage ~task:task in
      answer
  | DeepDive ->
      let* answer = deep_triage ~task:task in
      answer
```

Input:

```json
{ "tag": "Quick" }
```

If your entrypoint has more than one argument, hosts should call it through
compiled IR or a wrapper that supplies labeled inputs. For CLI authoring,
prefer one record argument for structured workflows.

## One Record Argument For CLI And Hosts

For CLI, JSON-RPC, and Pi SDK runs, one record argument is usually the most
ergonomic entrypoint shape:

```ocaml
type mode = Quick | DeepDive

type triage_request = {
  task : string;
  file_hints : string list;
  mode : mode;
}

agent triager : request:triage_request -> string = Agent.bind "triager"

let main (request : triage_request) : string =
  let* answer = triager ~request:request in
  answer
```

Input:

```json
{
  "task": "Find likely regression risks.",
  "file_hints": ["lib/runtime/runtime.ml", "packages/camlflow-pi-sdk/src/index.ts"],
  "mode": { "tag": "Quick" }
}
```

## Multi-File Project

Split larger workflows into modules:

```text
my-flow/
  camlflow.json
  main.cml
  types.cml
  helpers.cml
  skills/
    triage/
      SKILL.md
```

Use `open Types` or qualified names:

```ocaml
open Types

let main (request : triage_request) : report =
  Helpers.empty_report request.task
```

`camlflow.json`:

```json
{
  "program": "main.cml",
  "entry": "main",
  "includePaths": ["."],
  "skillsDir": "skills"
}
```

Run from the project directory:

```sh
opam exec -- dune exec camlflow -- check
opam exec -- dune exec camlflow -- run --input input.json
```

## Provider Debug Loop

When a provider-backed run fails, keep the `.cml` workflow stable and inspect
the effect boundary:

```sh
opam exec -- dune exec camlflow -- run examples/codex/main.cml \
  --skills examples/codex/skills \
  --input-json '"Ada"' \
  --provider codex \
  --model gpt-5.4-mini \
  --trace-provider
```

Look at:

- effect kind and name
- declared return type
- generated schema
- provider stderr
- JSON returned by the provider

## Pi Harness Wrapper

Use `.cml` for typed workflow shape and the Pi harness for sandbox/session/shell
orchestration:

```ts
const agent = await harness.init({ sandbox: "workspace-write" });
const session = await agent.session("triage");

try {
  const prep = await session.task("Inspect the checkout and identify risk areas.", {
    result: "json",
  });

  const workflow = await agent.runWorkflow({
    workflowPath: "examples/repo-triage/main.cml",
    skillsDir: "examples/repo-triage/skills",
    input: {
      task: "Triage the current repository.",
      suspected_area: "runtime and Pi harness",
      file_hints: [],
      goals: ["ground findings in repository evidence"],
      constraints: ["return actionable next steps"],
      mode: { tag: "Quick" },
    },
  });

  console.log(prep, workflow.output);
} finally {
  await session.close();
  await agent.close();
}
```

## What To Avoid

- Do not rely on OCaml stdlib module calls such as `List.map`; only loaded
  `.cml` modules resolve.
- Do not hide credentials or shell commands inside prompts.
- Do not use `null` for `None`; use `{ "tag": "None" }`.
- Do not assume one JSON-RPC `serve --stdio` process can run multiple workflows
  concurrently.
- Do not use one Pi harness session for overlapping prompt/skill turns; open
  another session or use `session.task(...)`.
