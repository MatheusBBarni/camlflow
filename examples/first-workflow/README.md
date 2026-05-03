# First Workflow Example

This directory is the checked-in companion to
[`../../docs/first-workflow.md`](../../docs/first-workflow.md). It shows the
smallest project shape that combines:

- a typed record input
- one bound agent effect
- `let*` effect sequencing
- project-local `camlflow.json`
- JSON input supplied at run time

The deterministic runtime returns placeholder JSON for unresolved effects, so
this example validates workflow wiring rather than model quality.

From the repository root:

```sh
opam exec -- dune exec camlflow -- check examples/first-workflow/main.cml
opam exec -- dune exec camlflow -- run examples/first-workflow/main.cml \
  --input examples/first-workflow/input.json
```

Expected deterministic output:

```text
steps: 1
"!"
```

From this directory, use the project config:

```sh
opam exec -- dune exec camlflow -- check
opam exec -- dune exec camlflow -- run --input input.json
```

`camlflow.json` supplies the program and entrypoint. Input payloads still come
from `--input` or `--input-json`; project config does not store input paths.

Continue with:

- [First workflow tutorial](../../docs/first-workflow.md)
- [Language reference](../../docs/language-reference.md)
- [JSON encoding](../../docs/json-encoding.md)
- [Project config](../../docs/project-config.md)
