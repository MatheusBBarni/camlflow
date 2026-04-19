const assert = require("node:assert/strict");
const test = require("node:test");

const {
  combinedOutput,
  makeMissingPiMonoRepo,
  runRepoScript,
} = require("./pi-mono-harness");

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

test("run-pi-mono-recursion.sh prints the default recursion command before launch", async () => {
  await expectLauncherMessage(
    "scripts/run-pi-mono-recursion.sh",
    "/camlflow-run examples/recursion/main.cml --entry main --input-json 4",
  );
});

test("run-pi-mono-basic.sh prints the default basic command before launch", async () => {
  await expectLauncherMessage(
    "scripts/run-pi-mono-basic.sh",
    '/camlflow-run examples/basic/main.cml --entry main --input-json "Ada"',
  );
});

test("run-pi-mono-problem-coach.sh prints the structured default command before launch", async () => {
  await expectLauncherMessage(
    "scripts/run-pi-mono-problem-coach.sh",
    "/camlflow-run examples/problem-coach/main.cml --entry main --input-json",
  );
});

test("run-pi-mono-repo-triage.sh prints the repo-triage default command before launch", async () => {
  await expectLauncherMessage(
    "scripts/run-pi-mono-repo-triage.sh",
    "/camlflow-run examples/repo-triage/main.cml --entry main --input-json",
  );
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
    assert.match(output, /--input-json 5/);
  } finally {
    missingRepo.cleanup();
  }
});
