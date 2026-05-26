# CamlFlow Project Config

`camlflow.json` lets a project pin repeated CLI defaults next to its `.cml`
files. It is optional; every field can still be supplied explicitly through CLI
flags or host SDK options.

For install and run commands, see
[`how-to-run-and-install.md`](./how-to-run-and-install.md). For CLI flags, see
[`cli-reference.md`](./cli-reference.md).

## Lookup And Precedence

For `check`, `compile`, and `run`, CamlFlow searches from the current working
directory upward for the nearest file named `camlflow.json`.

Precedence is:

1. explicit CLI flags
2. nearest `camlflow.json`
3. built-in defaults

When debugging, use an explicit source path to avoid accidental nearest-config
behavior:

```sh
opam exec -- dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
```

## Minimal Config

```json
{
  "program": "main.cml",
  "entry": "main"
}
```

From that directory:

```sh
opam exec -- dune exec camlflow -- check
opam exec -- dune exec camlflow -- run --input input.json
opam exec -- dune exec camlflow -- compile -o /tmp/main.ir.json
```

See [`examples/project-config`](../examples/project-config).

## Full Shape

```json
{
  "program": "main.cml",
  "entry": "main",
  "includePaths": ["."],
  "skillsDir": "skills",
  "provider": "codex",
  "model": "gpt-5.4-mini",
  "reasoning": "low",
  "providerProfile": "work",
  "providerConfig": {
    "approval-policy": "never"
  },
  "sandbox": "workspace-write",
  "allowWriteDirs": ["tmp"],
  "traceProvider": false
}
```

## Fields

| Field | Type | Applies to | Notes |
| --- | --- | --- | --- |
| `program` | non-empty path string | `check`, `compile`, `run` | Source or artifact path used when the command omits a file argument. |
| `entry` | string | `run` | Entrypoint name. Defaults to `main`. |
| `includePaths` | non-empty path string array | `check`, `compile`, `run` | Extra `.cml` module search paths. |
| `skillsDir` | non-empty path string | `run` | Root for local `skills/<name>/SKILL.md`. |
| `provider` | string enum | `run` | `codex`, `opencode`, `claude-code`, or `claude-cli`. |
| `model` | string | `run` | Provider model override when the workflow does not set one inline. |
| `reasoning` | string enum | `run` | `low`, `medium`, `high`, or `max`. |
| `providerProfile` | string | `run` | Provider-specific profile name. |
| `providerConfig` | object of string values | `run` | Equivalent to repeated `--provider-config key=value`. Keys cannot be empty or contain `=`. |
| `sandbox` | string enum | `run` | Direct CLI provider sandbox: `read-only`, `workspace-write`, or `danger-full-access`. |
| `allowWriteDirs` | non-empty path string array | `run` | Extra writable directories for provider execution. |
| `traceProvider` | boolean | `run` | Enables provider trace metadata. |

Unknown fields are rejected.

## Path Resolution

Relative paths in these fields resolve from the directory containing
`camlflow.json`:

- `program`
- `includePaths`
- `skillsDir`
- `allowWriteDirs`

Absolute paths stay absolute. Empty path strings are rejected.

Example:

```text
flows/
  camlflow.json
  src/main.cml
  lib/types.cml
```

```json
{
  "program": "src/main.cml",
  "includePaths": ["lib"]
}
```

If the shell is in `flows/subdir`, the nearest config still resolves
`src/main.cml` and `lib` relative to `flows/`.

## Command-Specific Behavior

`check` and `compile` use:

- `program`
- `includePaths`

`run` uses:

- `program`
- `entry`
- `includePaths`
- `skillsDir`
- provider fields

Provider fields are not accepted by `check` or `compile`.

## Provider Defaults

Provider defaults in `camlflow.json` behave like CLI provider flags. This config:

```json
{
  "program": "examples/provider-hooks/workflow.cml",
  "skillsDir": "examples/provider-hooks/skills",
  "provider": "codex",
  "model": "gpt-5.4-mini",
  "reasoning": "low",
  "sandbox": "read-only",
  "traceProvider": true
}
```

is equivalent to:

```sh
opam exec -- dune exec camlflow -- run examples/provider-hooks/workflow.cml \
  --skills examples/provider-hooks/skills \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only \
  --trace-provider
```

Provider credentials and executable setup still live outside `camlflow.json`.

## Relationship To JSON-RPC And Pi SDK

`camlflow.json` is a CLI/project convenience. JSON-RPC and Pi SDK hosts usually
pass the same values explicitly:

- JSON-RPC `program.path`
- JSON-RPC `program.includePaths`
- JSON-RPC `program.skillsDir`
- Pi SDK `runWorkflow({ workflowPath, includePaths, skillsDir, ... })`

Hosts can choose to read project config themselves, but the JSON-RPC protocol
does not require that.

## Common Errors

`invalid field <name> ... unknown field`:
Remove or rename the field. Config validation is strict.

`invalid field provider ... unknown provider`:
Use one of `codex`, `opencode`, `claude-code`, or `claude-cli`.

`invalid field reasoning ... unknown reasoning level`:
Use `low`, `medium`, `high`, or `max`.

`invalid field sandbox ... unknown sandbox`:
Use `read-only`, `workspace-write`, or `danger-full-access`.

`invalid field allowWriteDirs[0] ... expected non-empty path`:
Path fields and path-list entries cannot be empty strings.

`invalid field providerConfig.foo ... expected string`:
Every `providerConfig` value must be a string.
