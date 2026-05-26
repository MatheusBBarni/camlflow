# Provider hooks example

This workflow drives one bound agent, one local prompt skill, and one inline
agent through host-owned effect handling. It is intentionally small so JSON-RPC
and SDK smoke tests can exercise the full effect path.

```sh
opam exec -- dune exec camlflow -- run examples/provider-hooks/workflow.cml \
  --skills examples/provider-hooks/skills \
  --input-json '"Ada"'
```
