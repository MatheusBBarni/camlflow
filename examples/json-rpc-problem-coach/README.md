# JSON-RPC problem-coach host example

This example drives the structured `problem-coach` workflow through CamlFlow's stdio JSON-RPC server.

It demonstrates a stronger end-to-end host integration than the small `json-rpc-host` sample because the final workflow output is a nested `solution_pack` object instead of a single string.

## What it does

The host script:

- starts `camlflow serve --stdio`
- sends `initialize`
- loads `examples/problem-coach/input.json`
- sends `camlflow/run` for `examples/problem-coach/main.cml`
- handles all nested `camlflow/executeEffect` requests
- returns typed JSON payloads for:
  - local prompt skill `caveman`
  - bound skill `edge-case-planner`
  - bound agent `draft-solver`
  - inline agent `answer_packager`
- prints the final structured workflow result

## Run

From the repository root:

```sh
node examples/json-rpc-problem-coach/host.js
```

## Why this example matters

It shows how a host AI tool can:

- let the user keep orchestration in CamlFlow
- satisfy each effect step with its own execution logic
- hand structured JSON back to CamlFlow
- receive a final user-consumable artifact

This is close to the intended "user writes CamlFlow harness; host tool executes the steps" model.
