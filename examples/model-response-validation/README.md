# Model response validation example

This example is the Beta 3 typed-model-response slice in minimal form.

It shows:

- an inline `Agent.define`
- a typed provider/model response declared as a record plus variant
- the prompt only describing task intent, while response structure comes from the declared type
- branching on model output with both `if` and `match`

Workflow file:

- `main.cml`

## Deterministic local run

This runs without any real provider. The deterministic fallback synthesizes the
declared `code_response` shape, so the example still proves parsing, typing,
JSON decoding, and typed branching over the response object.

```sh
dune exec ./bin/main.exe -- run examples/model-response-validation/main.cml \
  --input-json '"let x = 1"'
```

Equivalent shortcut:

```sh
make run-model-response-validation INLINE_AGENT_INPUT='"let x = 1"'
```

Expected deterministic output:

```text
steps: 1
"retry-after-tests: "
```

## Provider-backed run

With a real provider, the same workflow asks the model to return a value that
matches:

```ocaml
type action = TEST | RUN

type code_response = {
  action : action;
  accuracy : int;
  description : string;
}
```

The workflow then branches on `response.accuracy` and `response.action`.

Example:

```sh
dune exec ./bin/main.exe -- run examples/model-response-validation/main.cml \
  --input-json '"let x = 1"' \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only
```
