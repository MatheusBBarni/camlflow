import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import oniguruma from "vscode-oniguruma";
import textmate from "vscode-textmate";

const { loadWASM, OnigScanner, OnigString } = oniguruma;
const { Registry } = textmate;

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const packageDir = path.resolve(__dirname, "..");
const repoRoot = path.resolve(packageDir, "..", "..");

const grammarPath = path.join(packageDir, "syntaxes", "camlflow.tmLanguage.json");
const wasmPath = path.join(
  packageDir,
  "node_modules",
  "vscode-oniguruma",
  "release",
  "onig.wasm"
);

async function walk(dir) {
  const entries = await fs.readdir(dir, { withFileTypes: true });
  const files = await Promise.all(
    entries.map(async (entry) => {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        return walk(fullPath);
      }

      return entry.isFile() && entry.name.endsWith(".cml") ? [fullPath] : [];
    })
  );

  return files.flat().sort();
}

function toArrayBuffer(buffer) {
  return buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
}

function collectScopes(grammar, source) {
  const seen = new Set();
  let ruleStack = null;

  for (const line of source.split(/\r?\n/)) {
    const lineResult = grammar.tokenizeLine(line, ruleStack);
    ruleStack = lineResult.ruleStack;

    for (const token of lineResult.tokens) {
      for (const scope of token.scopes) {
        seen.add(scope);
      }
    }
  }

  return seen;
}

async function main() {
  const grammarJson = JSON.parse(await fs.readFile(grammarPath, "utf8"));
  const wasm = await fs.readFile(wasmPath);

  await loadWASM(toArrayBuffer(wasm));

  const registry = new Registry({
    onigLib: Promise.resolve({
      createOnigScanner(sources) {
        return new OnigScanner(sources);
      },
      createOnigString(source) {
        return new OnigString(source);
      }
    }),
    loadGrammar(scopeName) {
      return scopeName === grammarJson.scopeName ? grammarJson : null;
    }
  });

  const grammar = await registry.loadGrammar("source.camlflow");

  assert(grammar, "failed to load the CamlFlow TextMate grammar");

  const exampleFiles = await walk(path.join(repoRoot, "examples"));
  assert(exampleFiles.length > 0, "expected runnable .cml examples for smoke testing");

  const seenScopes = new Set();

  for (const exampleFile of exampleFiles) {
    const source = await fs.readFile(exampleFile, "utf8");
    const scopes = collectScopes(grammar, source);
    for (const scope of scopes) {
      seenScopes.add(scope);
    }
  }

  const fixtureSource = `
(* outer (* nested *) comment *)
let message = {tag|hello
world|tag}
`;

  for (const scope of collectScopes(grammar, fixtureSource)) {
    seenScopes.add(scope);
  }

  const expectedScopes = [
    "keyword.declaration.camlflow",
    "keyword.control.monadic.camlflow",
    "storage.modifier.camlflow",
    "keyword.control.import.camlflow",
    "keyword.control.camlflow",
    "entity.name.type.camlflow",
    "entity.name.function.camlflow",
    "entity.name.type.constructor.camlflow",
    "variable.parameter.camlflow",
    "variable.other.property.camlflow",
    "string.quoted.double.camlflow",
    "string.quoted.other.camlflow",
    "comment.block.camlflow",
    "constant.numeric.camlflow",
    "keyword.operator.camlflow",
    "variable.other.member.camlflow"
  ];

  for (const expectedScope of expectedScopes) {
    assert(
      seenScopes.has(expectedScope),
      `missing expected grammar scope in smoke test output: ${expectedScope}`
    );
  }

  console.log(
    `Smoke-tested CamlFlow highlighting across ${exampleFiles.length} example files and multiline-string/comment fixtures.`
  );
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
