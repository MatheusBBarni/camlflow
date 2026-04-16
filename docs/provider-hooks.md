# CamlFlow Provider Hooks

CamlFlow can run workflows with deterministic local defaults, but the runtime is designed to let a host application replace those defaults with custom provider hooks.

This document shows how to wire those hooks from OCaml and what metadata each hook receives.

## Available runtime hooks

The runtime context lives in:

- `Camlflow.Runtime.Context`

Available hooks:

- `with_agent_handler`
- `with_skill_handler`
- `with_default_provider`
- `with_inline_agent_provider`
- `with_prompt_skill_provider`
- `with_effect_observer`
- `with_working_directory`
- `with_skills_directory`

## Hook roles

### 1. Named bound agent handlers

Use `with_agent_handler` when a workflow contains:

```ocaml
agent greeter : name:string -> string = Agent.bind "greeter"
```

The handler receives:

- `name`
- `input` JSON
- declared `return_type`
- type index for validation / synthesis

### 2. Named bound skill handlers

Use `with_skill_handler` when a workflow contains:

```ocaml
skill summarize : prompt:string -> string = Skill.bind "summarize"
```

This is useful for deterministic, host-owned skill implementations.

### 3. Default provider fallback

Use `with_default_provider` to intercept bound agents and bound skills when no explicit named handler is registered.

This is the easiest way to plug in a single generic backend.

### 4. Inline agent provider

Use `with_inline_agent_provider` for workflows that declare:

```ocaml
agent reviewer : code:string -> string =
  Agent.define ~model:"stub" ~system_prompt:"Review tersely"
```

The hook receives the inline agent name plus the parsed inline definition metadata.

### 5. Prompt-backed local skill provider

Use `with_prompt_skill_provider` for project-local skills discovered through:

- `--skills <dir>` in the CLI, or
- `with_skills_directory` in the embedded runtime context

The runtime loads:

- `skills/<name>/SKILL.md`

and passes that markdown into the provider hook.

### 6. Effect observer

Use `with_effect_observer` to observe every effectful invocation after it completes.

This is useful for:

- logging
- tracing
- metrics
- debugging
- test assertions

## Invocation metadata

Both `with_default_provider` and `with_effect_observer` use the structured `invocation` record.

Important fields:

- `invocation_kind`
  - `Bound_agent`
  - `Bound_skill`
  - `Local_prompt_skill`
  - `Inline_agent`
- `invocation_name`
- `invocation_input`
- `invocation_return_type`
- `invocation_types`
- `invocation_working_directory`
- `invocation_skills_directory`
- `invocation_markdown`
- `invocation_definition`

## End-to-end OCaml example

See:

- `examples/provider-hooks/workflow.cml`
- `examples/provider-hooks/host.ml`

Core pattern:

```ocaml
let context =
  Camlflow.Runtime.Context.empty
  |> Camlflow.Runtime.Context.with_working_directory (Sys.getcwd ())
  |> Camlflow.Runtime.Context.with_skills_directory "examples/provider-hooks/skills"
  |> Camlflow.Runtime.Context.with_default_provider (fun invocation ->
       match invocation.Camlflow.Runtime.Context.invocation_kind with
       | Bound_agent -> Ok (`String ("agent:" ^ invocation.invocation_name))
       | Bound_skill -> Ok (`String ("skill:" ^ invocation.invocation_name))
       | _ -> Error "unexpected invocation kind")
  |> Camlflow.Runtime.Context.with_inline_agent_provider
       (fun ~name:_ ~definition:_ ~input:_ ~return_type:_ ~types:_ ->
         Ok (`String "inline-review"))
  |> Camlflow.Runtime.Context.with_prompt_skill_provider
       (fun ~name:_ ~markdown:_ ~input:_ ~return_type:_ ~types:_ ->
         Ok (`String "prompt-skill"))
  |> Camlflow.Runtime.Context.with_effect_observer
       (fun invocation ~output:_ ->
         Printf.printf "effect: %s\n" invocation.invocation_name)
```

## Validation model

Provider hooks return JSON, not raw CamlFlow values.

After a hook returns, the runtime validates that JSON against the declared CamlFlow return type.

That means your provider can stay JSON-native, while CamlFlow preserves typed workflow guarantees.

## Suggested usage model

- Use `with_agent_handler` / `with_skill_handler` for exact deterministic bindings.
- Use `with_default_provider` for one generic fallback.
- Use `with_inline_agent_provider` for `Agent.define`.
- Use `with_prompt_skill_provider` for local `SKILL.md` prompt-backed skills.
- Use `with_effect_observer` for logging and tracing.
