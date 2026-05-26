# Documentation Validation

Use this checklist when editing user-facing docs, examples, SDK READMEs, or
editor README files. It is intentionally command-oriented so documentation can
stay synchronized with the actual CLI, JSON encoding, project config, JSON-RPC
bridge, and Pi SDK harness behavior.

## Baseline

Use the OCaml 5.4 switch for local validation:

```sh
opam install . --deps-only --with-test --yes --switch 5.4.0
opam exec --switch 5.4.0 -- dune fmt
opam exec --switch 5.4.0 -- dune test
timeout 180s opam exec --switch 5.4.0 -- dune build
```

Then smoke the public CLI surfaces:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- --help
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/basic/main.cml --input-json '"Ada"'
timeout 2s opam exec --switch 5.4.0 -- dune exec camlflow -- serve --stdio
```

## Runnable Doc Snippets

When a doc contains a source or input example, copy it into `/tmp` and run it
through the actual CLI. Prefer explicit file paths for source examples:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- check /tmp/example/main.cml
opam exec --switch 5.4.0 -- dune exec camlflow -- run /tmp/example/main.cml --input /tmp/example/input.json
```

For config-backed examples outside the repository root, use the built binary.
Nested `dune exec` can fail because it is no longer running from the workspace
root:

```sh
CAMLFLOW_BIN="$(pwd)/_build/default/bin/main.exe"
(cd /tmp/example && "$CAMLFLOW_BIN" check && "$CAMLFLOW_BIN" run --input input.json)
```

Remember:

- `camlflow.json` uses `entry`, not `entrypoint`
- `camlflow.json` does not store input paths
- input payloads come from `--input` or `--input-json`
- empty list literals often need type context, such as
  `let goals : string list = []`

## Checked-In Examples

Run examples added or changed by the docs edit. For the first workflow example:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- check examples/basic/main.cml
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/basic/main.cml \
  --input examples/basic/input.json

CAMLFLOW_BIN="$(pwd)/_build/default/bin/main.exe"
(cd examples/basic && "$CAMLFLOW_BIN" check && "$CAMLFLOW_BIN" run --input input.json)
```

For structured examples:

```sh
opam exec --switch 5.4.0 -- dune exec camlflow -- run examples/orchestrator-session/main.cml \
  --skills examples/provider-hooks/skills \
  --input examples/orchestrator-session/input.json
```

## Markdown Links

Run a scoped local-link check after adding or moving docs:

```sh
node <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.cwd();
const starts = [
  'README.md',
  'docs',
  'examples',
  'packages/camlflow-pi-sdk/README.md',
  'packages/camlflow-pi-sdk/examples/README.md',
  'packages/camlflow-ts-json-rpc-sdk/README.md',
  'packages/camlflow-ts-json-rpc-sdk/examples/README.md',
  'packages/camlflow-vscode/README.md',
  'packages/camlflow-zed/README.md',
];
const files = [];
function walk(item) {
  const full = path.join(root, item);
  if (!fs.existsSync(full)) return;
  const stat = fs.statSync(full);
  if (stat.isDirectory()) {
    for (const entry of fs.readdirSync(full, { withFileTypes: true })) {
      if (['node_modules', 'dist', 'examples-dist', '_build', 'target'].includes(entry.name)) continue;
      walk(path.join(item, entry.name));
    }
  } else if (stat.isFile() && item.endsWith('.md')) {
    files.push(full);
  }
}
starts.forEach(walk);
const missing = [];
for (const file of files) {
  const text = fs.readFileSync(file, 'utf8');
  const re = /\[[^\]\n]+\]\(([^\)\n]+)\)/g;
  for (const match of text.matchAll(re)) {
    let target = match[1].trim();
    if (!target || target.startsWith('#') || /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(target)) continue;
    target = target.replace(/^<|>$/g, '');
    const noAnchor = target.split('#')[0];
    if (!noAnchor) continue;
    const resolved = path.resolve(path.dirname(file), decodeURI(noAnchor));
    if (!fs.existsSync(resolved)) missing.push(`${path.relative(root, file)} -> ${target}`);
  }
}
if (missing.length) {
  console.error(missing.join('\n'));
  process.exit(1);
}
console.log(`checked ${files.length} markdown files; all scoped local links resolve`);
NODE
```

## Package Docs

Run package-local checks when package docs or examples change:

```sh
(cd packages/camlflow-ts-json-rpc-sdk && npm install && opam exec --switch 5.4.0 -- npm test)
(cd packages/camlflow-pi-sdk && npm install && opam exec --switch 5.4.0 -- npm test)
(cd packages/camlflow-vscode && npm test)
```

Do not run the Pi SDK and JSON-RPC SDK tests in parallel when the Pi SDK reads
the JSON-RPC SDK `dist` while the JSON-RPC SDK is rebuilding it.

If `packages/camlflow-zed` changed, run `cargo check` when Rust tooling is
available. In environments without `cargo`, record that as a blocked check.

## Final Hygiene

Before finishing a docs change:

```sh
git diff --check
(cd packages/camlflow-pi-sdk && npm audit --omit=dev --json)
ps -eo pid,ppid,command | rg '(/home/adminai/projects/camlflow|dune|camlflow|npm test|node --test|cargo check)'
```

The Pi SDK full dev install may still report moderate dev-only findings from
the Pi dependency tree. The production audit above should remain clean.
