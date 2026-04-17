# JSON-RPC host example

This example shows how an external tool can use CamlFlow over stdio JSON-RPC.

The host script:

- starts `camlflow serve --stdio`
- sends `initialize`
- sends `camlflow/run`
- handles nested `camlflow/executeEffect` requests
- returns JSON outputs for each effect step
- receives the final typed workflow output
- logs optional `camlflow/trace` notifications

It uses the existing provider-hooks workflow:

- `../provider-hooks/workflow.cml`
- `../provider-hooks/skills/caveman/SKILL.md`

## Run

From the repository root:

```sh
node examples/json-rpc-host/host.js
```

## What it demonstrates

- JSON-RPC 2.0 over stdio with `Content-Length` framing
- CamlFlow as the user-authored harness
- the host tool as the executor for effect steps
- structured host responses flowing back into CamlFlow execution

## Expected shape

You should see:

- an `initialize` response with protocol metadata and capabilities
- a `run` response with a final `stepsRun` count and `output`

This example is intentionally small and dependency-free so tool authors can copy the framing and request/response pattern into their own integrations.
