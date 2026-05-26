# Orchestrator session example

This is the canonical example for the new use pattern. The workflow is `.cml`.
The host chooses sandbox policy, sessions, tasks, skills, logs, cancellation, and
resume behavior around it.

```sh
opam exec -- dune exec camlflow -- check examples/orchestrator-session/main.cml
opam exec -- dune exec camlflow -- run examples/orchestrator-session/main.cml \
  --input examples/orchestrator-session/input.json
```
