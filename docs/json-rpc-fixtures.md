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

## 3. `camlflow/compile`

This fixture uses a minimal program equivalent to:

```ocaml
let main : string = "ok"
```

### Host → CamlFlow

```json
{
  "jsonrpc": "2.0",
  "id": 3,
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
  "id": 3,
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

## 4. `camlflow/check` before `initialize`

### Host → CamlFlow

```json
{
  "jsonrpc": "2.0",
  "id": 4,
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
  "id": 4,
  "error": {
    "code": -32002,
    "message": "server not initialized"
  }
}
```

---

## 5. Framing example

Every payload above is wrapped on the wire like this:

```text
Content-Length: <bytes>\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
```

The body length must match the exact UTF-8 byte length of the JSON payload.

---

## 6. Related files

- `docs/json-rpc.md`
- `examples/json-rpc-host/host.js`
- `examples/json-rpc-problem-coach/host.js`
- `lib/rpc_protocol.ml`
- `lib/rpc_stdio.ml`
- `lib/rpc_server.ml`
