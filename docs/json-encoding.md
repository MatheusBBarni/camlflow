# CamlFlow JSON Encoding

CamlFlow uses explicit JSON encodings at every boundary:

- CLI `--input` and `--input-json`
- JSON-RPC `camlflow/run` input
- JSON-RPC `camlflow/executeEffect` output
- provider and Pi worker structured outputs

For common decode failures and fixes, see
[`troubleshooting.md`](./troubleshooting.md).

The runtime decodes input JSON into the declared CamlFlow entrypoint type and
validates effect outputs against the declared return type before the workflow
continues.

## Primitive Types

| CamlFlow type | JSON shape |
| --- | --- |
| `string` | JSON string |
| `int` | JSON integer |
| `float` | JSON number; integers are accepted as floats |
| `bool` | JSON boolean |
| `unit` | `null` |

Examples:

```sh
opam exec -- dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
opam exec -- dune exec camlflow -- run examples/recursion/main.cml --input-json '4'
```

## Records

CamlFlow records encode as JSON objects with the declared field names:

```ocaml
type request = {
  problem_name : string;
  must_cover : string list;
}
```

```json
{
  "problem_name": "two sum",
  "must_cover": ["hash map approach", "time complexity"]
}
```

Every declared field must be present. Do not use undeclared extra fields to
carry workflow data; keep the `.cml` type and JSON payload aligned.

## Lists And Tuples

Lists encode as JSON arrays:

```ocaml
type request = { goals : string list }
```

```json
{ "goals": ["map the main path", "identify risks"] }
```

Tuples also encode as JSON arrays, in tuple order:

```ocaml
let main (item : (string * int)) : string = "ok"
```

```json
["priority", 1]
```

Tuple arrays must have exactly the declared arity.

## Variants

Variants encode as tagged objects.

A nullary constructor uses only `tag`:

```ocaml
type language = Python | TypeScript | OCaml
```

```json
{ "tag": "Python" }
```

A constructor with one payload uses `value`:

```ocaml
type focus = Pattern of string | Constraint of string
```

```json
{ "tag": "Pattern", "value": "dynamic programming" }
```

A constructor with multiple payloads uses `values`:

```ocaml
type coordinate = Point of int * int

let main (point : coordinate) : int =
  match point with
  | Point (x, y) -> x + y
```

```json
{ "tag": "Point", "values": [3, 5] }
```

Constructor names are case-sensitive and must match the `.cml` declaration.

## Options

Options use the same tagged encoding as variants. They do not use bare `null`.

```ocaml
let main (note : string option) : string =
  match note with
  | Some text -> text
  | None -> ""
```

```json
{ "tag": "Some", "value": "extra context" }
```

```json
{ "tag": "None" }
```

Use `null` only for `unit`, not for `None`.

## Larger Example

For this type:

```ocaml
type language = Python | TypeScript | OCaml
type audience = Interview | Production

type request = {
  problem_name : string;
  language : language;
  audience : audience;
  must_cover : string list;
}
```

Use:

```json
{
  "problem_name": "two sum",
  "language": { "tag": "Python" },
  "audience": { "tag": "Interview" },
  "must_cover": [
    "hash map approach",
    "time complexity",
    "duplicate values edge case"
  ]
}
```

Run the checked-in example:

```sh
opam exec -- dune exec camlflow -- run examples/problem-coach/main.cml \
  --skills examples/problem-coach/skills \
  --input examples/problem-coach/input.json
```

## Shell Quoting

Prefer `--input <file.json>` for records or nested values. Use `--input-json`
for small values:

```sh
opam exec -- dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
opam exec -- dune exec camlflow -- run examples/recursion/main.cml --input-json '4'
```

When passing JSON objects inline, wrap the whole JSON value in single quotes so
the shell does not consume double quotes:

```sh
opam exec -- dune exec camlflow -- run examples/problem-coach/main.cml \
  --skills examples/problem-coach/skills \
  --input-json '{"problem_name":"two sum","language":{"tag":"Python"},"audience":{"tag":"Interview"},"must_cover":["hash map approach"]}'
```

For longer inputs, use a file instead.

## Provider And Host Outputs

Providers, JSON-RPC hosts, and Pi workers return JSON too. The same encoding
rules apply to the declared return type of every effectful step.

If an effect declares:

```ocaml
agent plan : request:request -> plan_result = Agent.bind "planner"
```

then the provider or host must return JSON matching `plan_result`. CamlFlow
validates that JSON before later workflow steps can use it.

## Common Decode Failures

`JSON value does not match declared type`:
The JSON shape does not match the expected primitive, list, tuple, record,
variant, option, or unit shape.

`missing JSON field <name>`:
A record field declared in `.cml` is absent from the JSON object.

`variant JSON requires a tag field`:
A variant value must be an object with a string `tag`.

`constructor payload missing value field`:
A one-payload variant constructor needs `value`.

`constructor payload missing values field`:
A multi-payload variant constructor needs `values`.
