# Interview pipeline example

This example is meant to stress a larger slice of CamlFlow in one workflow.

It exercises:

- multi-file loading (`main.cml`, `types.cml`, `helpers.cml`)
- `open Types`
- qualified module references through `Helpers.<value>`
- records, variants, options, booleans, and lists
- recursion in pure helper code
- `if` and `match`
- local prompt skill (`caveman`)
- bound skill (`edge-case-planner`)
- bound agent (`solver`)
- inline agent (`reviewer`)
- structured nested report output
- typed JSON input through a file

Files:

- `main.cml`
- `types.cml`
- `helpers.cml`
- `input.json`
- `skills/caveman/SKILL.md`

## Deterministic local run

This works without any provider and is useful to verify parsing, typing, module
resolution, JSON encoding, and deterministic runtime defaults.

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/interview-pipeline/main.cml \
  --skills examples/interview-pipeline/skills \
  --input examples/interview-pipeline/input.json
```

## Codex-backed run

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/interview-pipeline/main.cml \
  --skills examples/interview-pipeline/skills \
  --input examples/interview-pipeline/input.json \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only
```

Optional trace:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/interview-pipeline/main.cml \
  --skills examples/interview-pipeline/skills \
  --input examples/interview-pipeline/input.json \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only \
  --trace-provider
```

## Why this is a good stress test

This example forces CamlFlow to handle:

1. typed record input from JSON
2. variants at the input boundary and options in the final output
3. pure normalization helpers before any effects
4. multiple effect kinds in one pipeline
5. nested structured output at the end

If this example works, it is a much stronger signal than the smaller examples
that the current parser, checker, runtime, provider bridge, and JSON encoding
model are working together correctly.
