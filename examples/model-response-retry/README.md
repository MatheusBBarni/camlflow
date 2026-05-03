# Model response retry example

This example extends the typed model-response slice with:

- option-based validation helpers via `is_some` and `unwrap_or`
- a recursive retry helper that re-prompts the model when validation fails
- typed branching over both the response payload and the retry outcome

Workflow file:

- `main.cml`

## Deterministic local run

Without a real provider, the deterministic fallback synthesizes the declared
`code_response` value:

- `action = TEST`
- `accuracy = 0`
- `description = ""`
- `retry_hint = None`

That forces the recursive retry path until the example exhausts its max
attempts.

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/model-response-retry/main.cml \
  --input-json '"let x = 1"'
```

Equivalent shortcut:

```sh
make run-model-response-retry INLINE_AGENT_INPUT='"let x = 1"'
```

Expected deterministic output:

```text
steps: 3
"exhausted: "
```

## Provider-backed run

With a real provider, the same workflow can return a richer typed review:

```ocaml
type code_response = {
  action : action;
  accuracy : int;
  description : string;
  retry_hint : string option;
}
```

The workflow validates that response with `needs_retry`, derives retry text with
`unwrap_or`, and uses a recursive helper today instead of `for` / `while`.

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/model-response-retry/main.cml \
  --input-json '"let x = 1"' \
  --provider codex \
  --model gpt-5.4-mini \
  --reasoning low \
  --sandbox read-only
```
