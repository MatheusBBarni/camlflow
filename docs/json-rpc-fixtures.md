# CamlFlow JSON-RPC Fixtures

This document provides concrete JSON-RPC request/response transcripts for the current CamlFlow host protocol.

Notes:

- these fixtures follow the current implementation on branch `feat/json-rpc-bridge`
- for readability, the examples below show the JSON payloads only
- on the wire, each payload is wrapped with `Content-Length` framing over stdio
- path values are representative examples; actual absolute paths depend on the host process working directory

---

## 1. `initialize`

### Host → CamlFlow

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {}
}
```

### CamlFlow → Host

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "0.1.0",
    "irVersion": "0.1.0",
    "capabilities": {
      "check": true,
      "compile": true,
      "run": true,
      "executeEffect": true,
      "trace": true,
      "diagnostic": true,
      "progress": true,
      "streaming": true,
      "cancelRequest": true,
      "renderedPrompt": true,
      "outputSchema": true
    },
    "effectKinds": [
      "bound-agent",
      "bound-skill",
      "local-prompt-skill",
      "inline-agent"
    ]
  }
}
```

---

## 2. `camlflow/run` with the provider-hooks workflow

This fixture uses a workflow like `examples/provider-hooks/workflow.cml`.

### Host → CamlFlow

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "camlflow/run",
  "params": {
    "program": {
      "path": "examples/provider-hooks/workflow.cml",
      "includePaths": [],
      "skillsDir": "examples/provider-hooks/skills"
    },
    "entry": "main",
    "input": "Ada"
  }
}
```

### CamlFlow → Host trace notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/trace",
  "params": {
    "event": "run-start",
    "runId": "run-1",
    "step": null,
    "effect": null,
    "details": {
      "programPath": "examples/provider-hooks/workflow.cml",
      "entry": "main"
    }
  }
}
```

### CamlFlow → Host progress notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/progress",
  "params": {
    "runId": "run-1",
    "stage": "run-start",
    "step": null,
    "message": "Running main",
    "completedSteps": 0,
    "knownSteps": null,
    "cancellable": true
  }
}
```

### CamlFlow → Host progress notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/progress",
  "params": {
    "runId": "run-1",
    "stage": "effect-start",
    "step": 1,
    "message": "Executing bound-agent greeter",
    "completedSteps": 0,
    "knownSteps": null,
    "cancellable": true
  }
}
```

### CamlFlow → Host effect request, step 1

```json
{
  "jsonrpc": "2.0",
  "id": "effect-1",
  "method": "camlflow/executeEffect",
  "params": {
    "runId": "run-1",
    "step": 1,
    "effect": {
      "kind": "bound-agent",
      "role": "agent",
      "name": "greeter",
      "input": {
        "name": "Ada"
      },
      "declaredReturnType": "string",
      "outputSchema": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "string"
      },
      "workingDirectory": "/repo/camlflow",
      "skillsDirectory": "examples/provider-hooks/skills",
      "skillMarkdown": null,
      "inlineDefinition": null,
      "renderedPrompt": "You are executing a CamlFlow agent step.\nThis is a bound agent with no inline prompt text. Infer intent from the agent name and typed input.\nReturn only JSON that matches the required schema exactly.\nDo not wrap the JSON in markdown fences and do not add commentary.\n\nInvocation:\n- kind: bound-agent\n- role: agent\n- name: greeter\n- working_directory: /repo/camlflow\n- skills_directory: examples/provider-hooks/skills\n- declared_return_type: string\n\nInput JSON:\n{ \"name\": \"Ada\" }\n\nOutput JSON Schema:\n{\n  \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",\n  \"type\": \"string\"\n}",
      "requestedModel": null,
      "unsupportedSettings": [],
      "step": 1,
      "runId": "run-1"
    }
  }
}
```

### Host → CamlFlow optional output chunk, step 1

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/outputChunk",
  "params": {
    "runId": "run-1",
    "step": 1,
    "streamId": "greeter-stream",
    "format": "text",
    "delta": "hello ",
    "done": false
  }
}
```

### CamlFlow → Host relayed output chunk, step 1

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/outputChunk",
  "params": {
    "runId": "run-1",
    "step": 1,
    "streamId": "greeter-stream",
    "format": "text",
    "delta": "hello ",
    "done": false
  }
}
```

### Host → CamlFlow effect response, step 1

```json
{
  "jsonrpc": "2.0",
  "id": "effect-1",
  "result": {
    "output": "hello Ada"
  }
}
```

### CamlFlow → Host progress notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/progress",
  "params": {
    "runId": "run-1",
    "stage": "effect-finish",
    "step": 1,
    "message": "Finished bound-agent greeter",
    "completedSteps": 1,
    "knownSteps": null,
    "cancellable": true
  }
}
```

### CamlFlow → Host trace notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/trace",
  "params": {
    "event": "effect-result",
    "runId": "run-1",
    "step": 1,
    "effect": {
      "kind": "bound-agent",
      "name": "greeter"
    },
    "details": {
      "status": "ok"
    }
  }
}
```

### CamlFlow → Host progress notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/progress",
  "params": {
    "runId": "run-1",
    "stage": "run-finish",
    "step": null,
    "message": "Run finished",
    "completedSteps": 3,
    "knownSteps": null,
    "cancellable": false
  }
}
```

### CamlFlow → Host final run response

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "runId": "run-1",
    "stepsRun": 3,
    "output": "inline-review"
  }
}
```

---

## 3. `camlflow/check`

This fixture uses a minimal program equivalent to:

```ocaml
let main : string = "ok"
```

### Host → CamlFlow

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "camlflow/check",
  "params": {
    "program": {
      "path": "/tmp/main.cml",
      "includePaths": [],
      "skillsDir": null
    }
  }
}
```

### CamlFlow → Host

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "modules": 1,
    "rootModule": "Main"
  }
}
```

---

## 4. `camlflow/compile`

This fixture uses the same minimal program:

```ocaml
let main : string = "ok"
```

### Host → CamlFlow

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "camlflow/compile",
  "params": {
    "program": {
      "path": "/tmp/main.cml",
      "includePaths": [],
      "skillsDir": null
    }
  }
}
```

### CamlFlow → Host

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "irVersion": "0.1.0",
    "artifact": {
      "version": "0.1.0",
      "root_module": "Main",
      "modules": [
        {
          "name": "Main",
          "path": "/tmp/main.cml",
          "decls": [
            {
              "kind": "let",
              "decl": {
                "name": "main",
                "params": [],
                "type": { "kind": "string" },
                "body": {
                  "loc": {
                    "file": "/tmp/main.cml",
                    "start": { "line": 1, "column": 20, "offset": 20 },
                    "end": { "line": 1, "column": 24, "offset": 24 }
                  },
                  "data": {
                    "kind": "literal",
                    "value": { "kind": "string", "value": "ok" }
                  }
                },
                "recursive": false,
                "loc": {
                  "file": "/tmp/main.cml",
                  "start": { "line": 1, "column": 0, "offset": 0 },
                  "end": { "line": 1, "column": 24, "offset": 24 }
                }
              }
            }
          ],
          "loc": {
            "file": "/tmp/main.cml",
            "start": { "line": 1, "column": 0, "offset": 0 },
            "end": { "line": 1, "column": 24, "offset": 24 }
          }
        }
      ]
    }
  }
}
```

---

## 5. `camlflow/check` before `initialize`

### Host → CamlFlow

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "camlflow/check"
}
```

### CamlFlow → Host diagnostic notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/diagnostic",
  "params": {
    "severity": "error",
    "message": "server not initialized",
    "method": "camlflow/check",
    "runId": null,
    "step": null,
    "effect": null
  }
}
```

### CamlFlow → Host error response

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "error": {
    "code": -32002,
    "message": "server not initialized"
  }
}
```

---

## 6. Invalid request (`-32600`)

This fixture shows a well-formed JSON payload that is **not** a valid JSON-RPC request object because it omits `jsonrpc`.

### Host → CamlFlow

```json
{
  "id": 6,
  "method": "initialize"
}
```

### CamlFlow → Host diagnostic notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/diagnostic",
  "params": {
    "severity": "error",
    "message": "missing jsonrpc version",
    "method": "(invalid-request)",
    "runId": null,
    "step": null,
    "effect": null
  }
}
```

### CamlFlow → Host error response

```json
{
  "jsonrpc": "2.0",
  "id": null,
  "error": {
    "code": -32600,
    "message": "missing jsonrpc version"
  }
}
```

---

## 7. Unknown method after `initialize` (`-32601`)

Assume an earlier `initialize` request already succeeded on this connection.

### Host → CamlFlow

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "camlflow/unknown",
  "params": {}
}
```

### CamlFlow → Host diagnostic notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/diagnostic",
  "params": {
    "severity": "error",
    "message": "method not found",
    "method": "camlflow/unknown",
    "runId": null,
    "step": null,
    "effect": null
  }
}
```

### CamlFlow → Host error response

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "error": {
    "code": -32601,
    "message": "method not found"
  }
}
```

---

## 8. `camlflow/run` failure before any effect step (`-32012`)

Assume an earlier `initialize` request already succeeded on this connection.

This fixture uses a program whose `main` requires input, but the host omits `input`.

### Host → CamlFlow

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "camlflow/run",
  "params": {
    "program": {
      "path": "/tmp/main.cml",
      "includePaths": [],
      "skillsDir": null
    },
    "entry": "main"
  }
}
```

### CamlFlow → Host trace notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/trace",
  "params": {
    "event": "run-start",
    "runId": "run-1",
    "step": null,
    "effect": null,
    "details": {
      "programPath": "/tmp/main.cml",
      "entry": "main"
    }
  }
}
```

### CamlFlow → Host trace notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/trace",
  "params": {
    "event": "run-error",
    "runId": "run-1",
    "step": null,
    "effect": null,
    "details": {
      "message": "run failed for /tmp/main.cml: entrypoint requires input"
    }
  }
}
```

### CamlFlow → Host diagnostic notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/diagnostic",
  "params": {
    "severity": "error",
    "message": "run failed for /tmp/main.cml: entrypoint requires input",
    "method": "camlflow/run",
    "runId": "run-1",
    "step": null,
    "effect": null
  }
}
```

### CamlFlow → Host error response

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "error": {
    "code": -32012,
    "message": "run failed for /tmp/main.cml: entrypoint requires input"
  }
}
```

---

## 9. Host returns JSON-RPC error for `camlflow/executeEffect`

Assume an earlier `initialize` succeeded and `camlflow/run` has already reached the first effect step.

This fixture shows a host failing the first effect step.

### CamlFlow → Host effect request

```json
{
  "jsonrpc": "2.0",
  "id": "effect-1",
  "method": "camlflow/executeEffect",
  "params": {
    "runId": "run-1",
    "step": 1,
    "effect": {
      "kind": "bound-agent",
      "role": "agent",
      "name": "greeter",
      "input": {
        "name": "Ada"
      },
      "declaredReturnType": "string",
      "outputSchema": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "string"
      },
      "workingDirectory": "/repo/camlflow",
      "skillsDirectory": null,
      "skillMarkdown": null,
      "inlineDefinition": null,
      "renderedPrompt": "...",
      "requestedModel": null,
      "unsupportedSettings": [],
      "step": 1,
      "runId": "run-1"
    }
  }
}
```

### Host → CamlFlow error response

```json
{
  "jsonrpc": "2.0",
  "id": "effect-1",
  "error": {
    "code": -32000,
    "message": "model timeout"
  }
}
```

### CamlFlow → Host trace notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/trace",
  "params": {
    "event": "effect-error",
    "runId": "run-1",
    "step": 1,
    "effect": {
      "kind": "bound-agent",
      "name": "greeter"
    },
    "details": {
      "message": "host returned JSON-RPC error -32000 for greeter: model timeout"
    }
  }
}
```

### CamlFlow → Host diagnostic notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/diagnostic",
  "params": {
    "severity": "error",
    "message": "host returned JSON-RPC error -32000 for greeter: model timeout",
    "method": null,
    "runId": "run-1",
    "step": 1,
    "effect": {
      "kind": "bound-agent",
      "name": "greeter"
    }
  }
}
```

### CamlFlow → Host trace notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/trace",
  "params": {
    "event": "run-error",
    "runId": "run-1",
    "step": null,
    "effect": null,
    "details": {
      "message": "run failed for /tmp/workflow.cml: host returned JSON-RPC error -32000 for greeter: model timeout"
    }
  }
}
```

### CamlFlow → Host final error response

```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "error": {
    "code": -32012,
    "message": "run failed for /tmp/workflow.cml: host returned JSON-RPC error -32000 for greeter: model timeout"
  }
}
```

---

## 10. Host cancels `camlflow/run` with `$/cancelRequest`

Assume an earlier `initialize` succeeded and `camlflow/run` has already reached the first effect step.

### Host → CamlFlow cancellation notification

```json
{
  "jsonrpc": "2.0",
  "method": "$/cancelRequest",
  "params": {
    "id": 10
  }
}
```

### CamlFlow → Host trace notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/trace",
  "params": {
    "event": "run-cancelled",
    "runId": "run-1",
    "step": 1,
    "effect": {
      "kind": "bound-agent",
      "name": "greeter"
    },
    "details": {
      "reason": "host-cancelled"
    }
  }
}
```

### CamlFlow → Host progress notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/progress",
  "params": {
    "runId": "run-1",
    "stage": "run-cancelled",
    "step": 1,
    "message": "run cancelled by host",
    "completedSteps": 0,
    "knownSteps": null,
    "cancellable": false
  }
}
```

### CamlFlow → Host diagnostic notification

```json
{
  "jsonrpc": "2.0",
  "method": "camlflow/diagnostic",
  "params": {
    "severity": "error",
    "message": "run cancelled by host",
    "method": "camlflow/run",
    "runId": "run-1",
    "step": 1,
    "effect": {
      "kind": "bound-agent",
      "name": "greeter"
    }
  }
}
```

### CamlFlow → Host final error response

```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "error": {
    "code": -32800,
    "message": "run cancelled by host"
  }
}
```

A late host response for the cancelled in-flight `camlflow/executeEffect` request is currently ignored.

---

## 11. `shutdown` followed by `exit`

Assume an earlier `initialize` request already succeeded on this connection.

### Host → CamlFlow

```json
{
  "jsonrpc": "2.0",
  "id": 11,
  "method": "shutdown",
  "params": {}
}
```

### CamlFlow → Host

```json
{
  "jsonrpc": "2.0",
  "id": 11,
  "result": null
}
```

### Host → CamlFlow notification

```json
{
  "jsonrpc": "2.0",
  "method": "exit"
}
```

After receiving `exit`, the current server loop stops without sending a reply.

---

## 12. Framing example

Every payload above is wrapped on the wire like this:

```text
Content-Length: <bytes>\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
```

The body length must match the exact UTF-8 byte length of the JSON payload.

---

## 13. Related files

- `docs/json-rpc.md`
- `examples/json-rpc-host/host.js`
- `examples/json-rpc-host/host.js`
- `lib/rpc_protocol.ml`
- `lib/rpc_stdio.ml`
- `lib/rpc_server.ml`
