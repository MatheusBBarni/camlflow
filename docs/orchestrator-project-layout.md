# CamlFlow Orchestrator Project Layout

The sandbox orchestrator layer uses `.cml` as the authoring surface and keeps
host policy in project configuration or embedding code.

Recommended scaffold:

```text
.
├── camlflow.json
└── .camlflow/
    ├── workflows/
    │   └── main.cml
    ├── roles/
    │   └── default.md
    ├── skills/
    │   └── README.md
    └── connectors/
        └── README.md
```

- `.camlflow/workflows/*.cml` contains user-authored typed workflows.
- `.camlflow/roles/` contains host-selected role overlays.
- `.camlflow/skills/` contains host-resolved skill prompt material.
- `.camlflow/connectors/` documents host-owned provider and sandbox connectors.
- `camlflow.json` points the existing OCaml CLI at the default `.cml` workflow
  and skills directory.

The TypeScript orchestrator package exposes `scaffoldCamlFlowProject(root)` for
SDK-driven `init` flows. The current OCaml CLI remains focused on existing
`parse`, `check`, `compile`, `run`, `serve`, `lsp`, and `completion` commands;
orchestrator `init`, `run`, and `dev` UX should live in host SDKs until a later
CLI merger decision.

Example SDK scaffold:

```ts
import { scaffoldCamlFlowProject } from "camlflow-orchestrator";

await scaffoldCamlFlowProject(process.cwd(), { workflowName: "main" });
```

Run the scaffolded workflow through the existing CLI:

```sh
opam exec -- dune exec camlflow -- check .camlflow/workflows/main.cml
opam exec -- dune exec camlflow -- run .camlflow/workflows/main.cml --input-json '{"name":"Ada"}'
```
