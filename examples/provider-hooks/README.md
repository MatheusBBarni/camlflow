# Provider Hooks Example

Files:

- `workflow.cml` — CamlFlow workflow using:
  - `Agent.bind`
  - `Skill.bind`
  - `Agent.define`
- `host.ml` — OCaml host embedding CamlFlow with custom runtime hooks
- `skills/caveman/SKILL.md` — local prompt-backed skill input

Run:

```sh
opam exec -- dune exec examples/provider-hooks/host.exe
```
