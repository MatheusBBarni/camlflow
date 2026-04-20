const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const {
  combinedOutput,
  makeMissingPiMonoRepo,
  runRepoScript,
} = require("./pi-mono-harness");

function extractInitialMessage(output) {
  const match = output.match(/^\s{2}(\/camlflow-run.*)$/m);
  assert.notEqual(match, null, "Expected launcher output to print an indented /camlflow-run command.");
  return match[1];
}

function tokenizeLikePi(input) {
  const tokens = [];
  let current = "";
  let quote = null;
  let escapeNext = false;

  for (const char of input) {
    if (escapeNext) {
      current += char;
      escapeNext = false;
      continue;
    }

    if (quote === null && char === "\\") {
      escapeNext = true;
      continue;
    }

    if (quote === '"' && char === "\\") {
      escapeNext = true;
      continue;
    }

    if (char === "'" || char === '"') {
      if (quote === null) {
        quote = char;
        continue;
      }
      if (quote === char) {
        quote = null;
        continue;
      }
    }

    if (quote === null && /\s/.test(char)) {
      if (current.length > 0) {
        tokens.push(current);
        current = "";
      }
      continue;
    }

    current += char;
  }

  if (escapeNext) {
    current += "\\";
  }

  assert.equal(quote, null, `Unterminated quote in launcher message: ${input}`);
  if (current.length > 0) {
    tokens.push(current);
  }
  return tokens;
}

function extractCommandTokens(output) {
  const initialMessage = extractInitialMessage(output);
  assert.match(initialMessage, /^\/camlflow-run\b/);
  return tokenizeLikePi(initialMessage.slice("/camlflow-run".length).trim());
}

function expectCommandTokens(output, expected) {
  assert.deepEqual(extractCommandTokens(output), expected);
}

function writeExecutable(filePath, contents) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, contents);
  fs.chmodSync(filePath, 0o755);
}

function makeBuiltPiMonoRepo() {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "camlflow-pi-mono-built-"));
  const repoPath = path.join(tempRoot, "pi-mono");

  writeExecutable(
    path.join(repoPath, "pi-test.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'pi-test args:%s\n' "$*"
`,
  );

  for (const relativePath of [
    "packages/ai/dist/index.js",
    "packages/agent/dist/index.js",
    "packages/tui/dist/index.js",
  ]) {
    const artifactPath = path.join(repoPath, relativePath);
    fs.mkdirSync(path.dirname(artifactPath), { recursive: true });
    fs.writeFileSync(artifactPath, "// built\n");
  }

  return {
    path: repoPath,
    cleanup() {
      fs.rmSync(tempRoot, { recursive: true, force: true });
    },
  };
}

function makeOldShellToolchain() {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "camlflow-pi-mono-opam-"));
  const binDir = path.join(tempRoot, "bin");
  const opamLogPath = path.join(tempRoot, "opam.log");

  fs.mkdirSync(binDir, { recursive: true });
  writeExecutable(
    path.join(binDir, "ocamlc"),
    `#!/usr/bin/env bash
set -euo pipefail
printf '5.1.1\n'
`,
  );
  writeExecutable(
    path.join(binDir, "opam"),
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_OPAM_LOG"

if [[ "\${1:-}" == "switch" && "\${2:-}" == "list" && "\${3:-}" == "--short" ]]; then
  printf '5.4.0\n'
  exit 0
fi

if [[ "\${1:-}" == "exec" ]]; then
  shift
  if [[ "\${1:-}" == "--switch" ]]; then
    shift 2
  fi
  if [[ "\${1:-}" == "--" ]]; then
    shift
  fi
  if [[ "\${1:-}" == "ocamlc" && "\${2:-}" == "-version" ]]; then
    printf '5.4.0\n'
    exit 0
  fi
  exec "$@"
fi

echo "unexpected fake opam invocation: $*" >&2
exit 1
`,
  );

  return {
    binDir,
    opamLogPath,
    cleanup() {
      fs.rmSync(tempRoot, { recursive: true, force: true });
    },
  };
}

async function expectLauncherMessage(script, expectedMessage, options = {}) {
  const missingRepo = makeMissingPiMonoRepo();
  try {
    const result = await runRepoScript(script, options.args ?? ["--print"], {
      env: {
        PI_MONO_REPO: missingRepo.path,
        ...options.env,
      },
      timeoutMs: 15000,
    });

    assert.notEqual(
      result.code,
      0,
      `Expected ${script} to stop at preflight with a missing PI_MONO_REPO override`,
    );
    assert.match(result.stdout, /Launching pi-mono with initial message:/);
    assert.match(result.stdout, new RegExp(expectedMessage.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    assert.match(result.stderr, new RegExp(missingRepo.path.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    return result;
  } finally {
    missingRepo.cleanup();
  }
}

test("run-pi-mono.sh reports the overridden PI_MONO_REPO path in preflight errors", async () => {
  const missingRepo = makeMissingPiMonoRepo();
  try {
    const result = await runRepoScript("scripts/run-pi-mono.sh", ["--print", "hello"], {
      env: {
        PI_MONO_REPO: missingRepo.path,
      },
      timeoutMs: 15000,
    });

    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /pi-mono repo not found:/);
    assert.match(result.stderr, new RegExp(missingRepo.path.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  } finally {
    missingRepo.cleanup();
  }
});

test("run-pi-mono.sh falls back to an available 5.4.0 opam switch when the shell switch is too old", async () => {
  const piMonoRepo = makeBuiltPiMonoRepo();
  const toolchain = makeOldShellToolchain();
  try {
    const result = await runRepoScript("scripts/run-pi-mono.sh", ["--print", "hello"], {
      env: {
        PI_MONO_REPO: piMonoRepo.path,
        FAKE_OPAM_LOG: toolchain.opamLogPath,
        PATH: `${toolchain.binDir}:${process.env.PATH}`,
      },
      timeoutMs: 15000,
    });

    assert.equal(result.code, 0);
    assert.match(result.stdout, /pi-test args:--print hello/);
    assert.match(result.stderr, /Using opam switch 5\.4\.0 for CamlFlow/);

    const opamLog = fs.readFileSync(toolchain.opamLogPath, "utf8");
    assert.match(opamLog, /^switch list --short$/m);
    assert.match(opamLog, /^exec --switch 5\.4\.0 -- ocamlc -version$/m);
    assert.match(opamLog, /exec --switch 5\.4\.0 -- .*pi-test\.sh --print hello/);
  } finally {
    toolchain.cleanup();
    piMonoRepo.cleanup();
  }
});

test("run-pi-mono-recursion.sh prints the default recursion command before launch", async () => {
  const result = await expectLauncherMessage(
    "scripts/run-pi-mono-recursion.sh",
    "/camlflow-run examples/recursion/main.cml --entry main --input-json 4",
  );
  expectCommandTokens(combinedOutput(result), [
    "examples/recursion/main.cml",
    "--entry",
    "main",
    "--input-json",
    "4",
  ]);
});

test("run-pi-mono-basic.sh prints the default basic command before launch", async () => {
  const result = await expectLauncherMessage(
    "scripts/run-pi-mono-basic.sh",
    "/camlflow-run examples/basic/main.cml --entry main --input-json",
  );
  expectCommandTokens(combinedOutput(result), [
    "examples/basic/main.cml",
    "--entry",
    "main",
    "--input-json",
    '"Ada"',
  ]);
});

test("run-pi-mono-problem-coach.sh prints the structured default command before launch", async () => {
  const result = await expectLauncherMessage(
    "scripts/run-pi-mono-problem-coach.sh",
    "/camlflow-run examples/problem-coach/main.cml --entry main --input-json",
  );
  expectCommandTokens(combinedOutput(result), [
    "examples/problem-coach/main.cml",
    "--entry",
    "main",
    "--input-json",
    '{"problem_name":"two sum","language":{"tag":"Python"},"audience":{"tag":"Interview"},"must_cover":["hash map approach","time complexity","duplicate values edge case"]}',
    "--skills-dir",
    "examples/problem-coach/skills",
  ]);
});

test("run-pi-mono-interview-pipeline.sh prints a token-safe structured command before launch", async () => {
  const result = await expectLauncherMessage(
    "scripts/run-pi-mono-interview-pipeline.sh",
    "/camlflow-run examples/interview-pipeline/main.cml --entry main --input-json",
  );
  expectCommandTokens(combinedOutput(result), [
    "examples/interview-pipeline/main.cml",
    "--entry",
    "main",
    "--input-json",
    '{"algorithm_name":"longest increasing subsequence","preferred_language":{"tag":"Python"},"target_difficulty":{"tag":"Hard"},"focus":[{"tag":"Pattern","value":"dynamic programming"},{"tag":"Constraint","value":"n up to 10^5"}]}',
    "--skills-dir",
    "examples/interview-pipeline/skills",
  ]);
});

test("run-pi-mono-repo-triage.sh prints the repo-triage default command before launch", async () => {
  const result = await expectLauncherMessage(
    "scripts/run-pi-mono-repo-triage.sh",
    "/camlflow-run examples/repo-triage/main.cml --entry main --input-json",
  );
  expectCommandTokens(combinedOutput(result), [
    "examples/repo-triage/main.cml",
    "--entry",
    "main",
    "--input-json",
    '{"task":"Triage how the pi-mono host integration is wired in this repo and identify the best files to inspect for improving no-model UX, effect streaming, and helper script ergonomics.","suspected_area":"pi-mono host integration docs, scripts, and TypeScript SDK wiring","file_hints":["docs/pi-mono-host-integration-plan.md","docs/pi-mono-implementation-checklist.md","docs/pi-mono-integration-testing.md","packages/camlflow-ts-json-rpc-sdk/src/client.ts","scripts"],"goals":["map the main integration path","identify the highest-value files for a follow-up patch","propose a small validation plan"],"constraints":["ground conclusions in repository evidence","prefer concrete file paths over generic advice","assume the caller wants to test through pi-mono"],"mode":{"tag":"DeepDive"}}',
    "--skills-dir",
    "examples/repo-triage/skills",
  ]);
});

test("launcher scripts respect CAMLFLOW_* overrides when building the initial message", async () => {
  const missingRepo = makeMissingPiMonoRepo();
  try {
    const result = await runRepoScript("scripts/run-pi-mono-recursion.sh", ["--print"], {
      env: {
        PI_MONO_REPO: missingRepo.path,
        CAMLFLOW_WORKFLOW: "examples/recursion/main.cml",
        CAMLFLOW_ENTRY: "main",
        CAMLFLOW_INPUT_JSON: "5",
      },
      timeoutMs: 15000,
    });

    const output = combinedOutput(result);
    assert.match(output, /Launching pi-mono with initial message:/);
    expectCommandTokens(output, [
      "examples/recursion/main.cml",
      "--entry",
      "main",
      "--input-json",
      "5",
    ]);
  } finally {
    missingRepo.cleanup();
  }
});

test("structured launcher overrides remain parseable when JSON values contain apostrophes", async () => {
  const missingRepo = makeMissingPiMonoRepo();
  try {
    const inputJson =
      '{"problem_name":"O\'Reilly graph walk","language":{"tag":"Python"},"audience":{"tag":"Interview"},"must_cover":["candidate\'s reasoning"]}';
    const result = await runRepoScript("scripts/run-pi-mono-problem-coach.sh", ["--print"], {
      env: {
        PI_MONO_REPO: missingRepo.path,
        CAMLFLOW_INPUT_JSON: inputJson,
        CAMLFLOW_SKILLS_DIR: "examples/problem-coach/custom skills",
      },
      timeoutMs: 15000,
    });

    expectCommandTokens(combinedOutput(result), [
      "examples/problem-coach/main.cml",
      "--entry",
      "main",
      "--input-json",
      inputJson,
      "--skills-dir",
      "examples/problem-coach/custom skills",
    ]);
  } finally {
    missingRepo.cleanup();
  }
});
