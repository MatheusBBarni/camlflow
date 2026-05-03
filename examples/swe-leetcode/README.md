# swe-leetcode example

This example creates an inline agent for LeetCode-style algorithm questions.

It uses:

- a local `caveman` skill to rewrite the request tersely
- an inline agent with model `gpt-5.4`
- a single string input: the algorithm or problem name
- a single string output: the answer

Files:

- `main.cml`
- `skills/caveman/SKILL.md`

Run:

```sh
opam exec -- dune exec camlflow -- run examples/swe-leetcode/main.cml \
  --skills examples/swe-leetcode/skills \
  --input-json '"two sum"' \
  --provider codex \
  --sandbox read-only
```

Optional trace:

```sh
opam exec -- dune exec camlflow -- run examples/swe-leetcode/main.cml \
  --skills examples/swe-leetcode/skills \
  --input-json '"binary search"' \
  --provider codex \
  --sandbox read-only \
  --trace-provider
```

Notes:

- the source identifier is `swe_leetcode`, but the inline agent metadata names it `swe-leetcode`
- the inline agent declares `~model:"5.3-codex-spark"`, so CLI `--model` is not needed
- this example assumes your Codex setup supports that model name
