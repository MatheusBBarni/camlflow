# Problem coach example

This example is designed to return something directly useful to the user.

Instead of returning an internal pipeline report, it returns a final
`solution_pack` with:

- a useful title
- a direct answer
- ready-to-use code
- complexity summary
- edge cases
- pitfalls
- next steps

It still exercises multiple CamlFlow capabilities:

- multi-file loading (`main.cml`, `types.cml`, `helpers.cml`)
- variant input types at the JSON boundary
- local prompt skill (`caveman`)
- bound skill (`edge-case-planner`)
- bound agent (`draft-solver`)
- inline agent (`answer_packager`)
- structured nested output

Files:

- `main.cml`
- `types.cml`
- `helpers.cml`
- `input.json`
- `skills/caveman/SKILL.md`

## Deterministic local run

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/problem-coach/main.cml \
  --skills examples/problem-coach/skills \
  --input examples/problem-coach/input.json
```

## Codex-backed run

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/problem-coach/main.cml \
  --skills examples/problem-coach/skills \
  --input examples/problem-coach/input.json \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only
```

This is a better day-to-day example because the top-level output is already a
user-consumable artifact instead of a diagnostic pipeline report.
