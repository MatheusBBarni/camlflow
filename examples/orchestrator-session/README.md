# Orchestrator Session Example

This example mirrors the issue-16 sandbox-orchestrator direction. The user
authored contract is still `.cml`; a host SDK such as `camlflow-orchestrator` or
`camlflow-pi-sdk` chooses sandbox, model, task, skill, log, cancellation, and
resume policy around it.

Run the deterministic core smoke path:

```sh
opam exec -- dune exec camlflow -- check examples/orchestrator-session/main.cml
opam exec -- dune exec camlflow -- run examples/orchestrator-session/main.cml \
  --input examples/orchestrator-session/input.json
```

With the default deterministic runtime, `repo_researcher` and `triage` return
placeholder JSON shaped to the declared record types. A real host would resolve
those effects through sandboxed agent sessions and skills.
