# CamlFlow Language Reference

This is a compact reference for the `.cml` language surface that works today.
CamlFlow intentionally looks like a small typed OCaml-style language, but it is
not full OCaml.

For a tutorial, start with [First workflow](./first-workflow.md). For runtime
commands, see [CLI reference](./cli-reference.md). For input and output shapes,
see [JSON encoding](./json-encoding.md).

## Files And Modules

A CamlFlow source file uses the `.cml` extension.

```ocaml
type payload = { name : string }

let main (name : string) : string =
  "Hello " ^ name
```

Each source file is a module. Module names come from file paths and are resolved
from the main file plus include paths. For example:

```text
flow/
  main.cml
  helpers.cml
```

`main.cml` can refer to declarations from `helpers.cml` through `Helpers`:

```ocaml
let main (name : string) : string =
  let payload : Helpers.payload = Helpers.make name in
  payload.name
```

Use `open Helpers` when you want unqualified names from another loaded module.
Only loaded `.cml` modules resolve; OCaml standard-library modules such as
`List` are not available by module-qualified calls.

## Declarations

Top-level declarations include:

- `type`
- `let`
- `let rec`
- `agent`
- `skill`
- `open`

```ocaml
open Types

type status = Ready | Blocked of string

let rec sum_to (n : int) : int =
  if n = 0 then 0 else n + sum_to (n - 1)

agent reviewer : code:string -> string = Agent.bind "reviewer"

skill caveman : prompt:string -> string = Skill.bind "caveman"
```

## Primitive Types

Supported primitive types:

- `string`
- `int`
- `float`
- `bool`
- `unit`

```ocaml
let message : string = "ok"
let count : int = 3
let ratio : float = 0.5
let enabled : bool = true
let done_value : unit = ()
```

`unit` encodes as JSON `null` at host boundaries.

## Compound Types

Records:

```ocaml
type request = {
  name : string;
  tags : string list;
}
```

Variants:

```ocaml
type mode = Quick | DeepDive
type focus = Pattern of string | Coordinate of int * int
```

Options:

```ocaml
let fallback (note : string option) : string =
  match note with
  | Some text -> text
  | None -> ""
```

Tuples:

```ocaml
let first (pair : (string * int)) : string =
  match pair with
  | (name, _) -> name
```

Lists:

```ocaml
type request = { goals : string list }
```

For the exact JSON representation of each shape, see
[JSON encoding](./json-encoding.md).

## Expressions

Common expressions:

```ocaml
let full = "Hello " ^ name in
let next = count + 1 in
let allowed = enabled && count > 0 in
if allowed then full else "blocked"
```

Conditionals require a boolean condition and both branches must have the same
type.

Pattern matching is used for variants, options, and tuples:

```ocaml
let describe (mode : mode) : string =
  match mode with
  | Quick -> "quick"
  | DeepDive -> "deep"
```

Matches must be exhaustive.

## Functions

Functions use annotated parameters and return types:

```ocaml
let greet (name : string) : string =
  "Hello " ^ name
```

Multiple parameters are curried:

```ocaml
let surround (left : string) (right : string) (text : string) : string =
  left ^ text ^ right
```

Recursive functions use `let rec`:

```ocaml
let rec sum_to (n : int) : int =
  if n = 0 then 0 else n + sum_to (n - 1)
```

Entrypoints can have no arguments or one argument. For CLI, JSON-RPC, and Pi SDK
host runs, one record argument is usually the most ergonomic shape.

## Effects With Agents And Skills

Agents and skills describe host-executed work. They are typed like functions,
but calls are effectful.

Use `Agent.bind` for a named external agent:

```ocaml
agent greeter : name:string -> string = Agent.bind "greeter"
```

Use `Skill.bind` for a named skill:

```ocaml
skill caveman : prompt:string -> string = Skill.bind "caveman"
```

Use `Agent.define` when the workflow should carry host-visible metadata:

```ocaml
agent reviewer : code:string -> string =
  Agent.define
    ~name:"reviewer"
    ~model:"gpt-5.4-mini"
    ~system_prompt:"Review the code tersely."
```

Calls to agents and skills must be sequenced with `let*`:

```ocaml
let main (name : string) : string =
  let* greeting = greeter ~name:name in
  greeting ^ "!"
```

The declared return type is enforced when the provider, JSON-RPC host, or Pi
worker returns JSON.

## Labeled Calls

Agent and skill parameters are labeled:

```ocaml
agent planner : task:string -> goals:string list -> string list =
  Agent.bind "planner"

let main (task : string) : string list =
  let goals : string list = ["find risks"; "propose checks"] in
  let* plan = planner ~task:task ~goals:goals in
  plan
```

Record fields use dot access:

```ocaml
let title (request : request) : string =
  request.name
```

Record construction uses field assignment:

```ocaml
let make (name : string) : request =
  { name = name; tags = [] }
```

Empty list literals need type context. Add an annotation when the type is not
otherwise obvious:

```ocaml
let goals : string list = []
```

## Built-In Helpers

CamlFlow includes a small helper surface for common workflow logic. Examples in
this repository use:

```ocaml
is_some maybe_value
unwrap_or maybe_value fallback
```

Use pattern matching when you need more control:

```ocaml
let describe (note : string option) : string =
  match note with
  | Some text -> text
  | None -> "none"
```

## Operators

Common operators include:

- string concatenation: `^`
- arithmetic: `+`, `-`, `*`, `/`
- comparison: `=`, `<>`, `<`, `<=`, `>`, `>=`
- boolean: `&&`, `||`

Operator operands must type-check; CamlFlow does not coerce arbitrary values.

## Comments And Formatting

Block comments use OCaml-style delimiters:

```ocaml
(* Explain a workflow-specific invariant here. *)
```

Use `opam exec -- dune fmt` to format OCaml/Dune sources in this repository.
The formatter check is part of the normal validation path.

## Deliberate Limits

CamlFlow is a workflow DSL, not a full OCaml runtime:

- no arbitrary OCaml standard-library module calls such as `List.map`
- no host shell access from `.cml` itself
- no secret handling inside source files
- provider, JSON-RPC, and Pi hosts own model execution and tools
- `let*` is required for effect sequencing
- project config does not store input payload paths; pass input with `--input`
  or `--input-json`

When in doubt, keep `.cml` responsible for typed orchestration and put tool use,
credentials, and sandbox policy in the host or provider layer.

## Next References

- [First workflow](./first-workflow.md)
- [Writing and running CamlFlow](./writing-and-running-camlflow.md)
- [Workflow cookbook](./workflow-cookbook.md)
- [JSON encoding](./json-encoding.md)
- [Project config](./project-config.md)
- [Pi SDK harness](./pi-sdk-harness.md)
