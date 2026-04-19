# Project-config example

This example shows project-local `camlflow.json` defaults in the smallest
possible setup. The config pins the program path and entrypoint, so `run`,
`check`, and `compile` can all omit the file argument.

From this directory:

```sh
dune exec camlflow -- check
dune exec camlflow -- run --input input.json
dune exec camlflow -- compile -o /tmp/project-config.ir.json
```

From the repo root:

```sh
(cd examples/project-config && dune exec camlflow -- run --input input.json)
```
