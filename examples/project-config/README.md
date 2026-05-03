# Project-config example

This example shows project-local `camlflow.json` defaults in the smallest
possible setup. The config pins the program path and entrypoint, so `run`,
`check`, and `compile` can all omit the file argument.

For the full config field reference, see
[`../../docs/project-config.md`](../../docs/project-config.md).

From this directory:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- check
opam exec --switch 5.4.0 -- dune exec camlflow -- run --input input.json
opam exec --switch 5.4.0 -- dune exec camlflow -- compile -o /tmp/project-config.ir.json
```

From the repo root:

```sh
(cd examples/project-config && opam exec --switch 5.4.0 -- dune exec camlflow -- run --input input.json)
```
