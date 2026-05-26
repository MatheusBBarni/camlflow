const assert = require("node:assert/strict");
const test = require("node:test");

const {
  assertContainsAll,
  collectPiMonoPreflight,
  combinedOutput,
  formatPreflightIssues,
  modelCliArgsFromEnv,
  readBoolEnv,
  runRepoScript,
} = require("./pi-mono-harness");

const e2eEnabled = readBoolEnv("CAMLFLOW_PI_MONO_E2E");
const modelBackedEnabled = readBoolEnv("CAMLFLOW_PI_MONO_MODEL_E2E");
const deepE2eEnabled = readBoolEnv("CAMLFLOW_PI_MONO_DEEP_E2E");
const suiteSkipReason =
  "Set CAMLFLOW_PI_MONO_E2E=1 to run pi-mono host E2E tests through --print mode.";

test(
  "pi-mono E2E preflight is satisfied before host tests run",
  { skip: e2eEnabled ? false : suiteSkipReason, timeout: 70000 },
  async () => {
    const report = await collectPiMonoPreflight({ checkCamlFlowBuild: true });
    assert.equal(
      report.ok,
      true,
      `pi-mono E2E preflight failed:\n${formatPreflightIssues(report)}`,
    );
  },
);

test(
  "pure basic workflow completes through pi --print",
  { skip: e2eEnabled ? false : suiteSkipReason, timeout: 120000 },
  async () => {
    const result = await runRepoScript(
      "scripts/run-pi-mono.sh",
      [
        "--no-session",
        "--print",
        "/camlflow-run examples/basic/main.cml --entry main --input-json '\"Ada\"'",
      ],
      { timeoutMs: 120000 },
    );

    const output = combinedOutput(result);
    assert.equal(result.code, 0, output);
    assertContainsAll(output, [
      "CamlFlow run complete",
      "workflow: examples/basic/main.cml",
      "entry: main",
      "steps: 0",
      /output:\s+Hello Ada/,
    ]);
  },
);

test(
  "provider-hooks workflow gives actionable no-model guidance with --no-env",
  { skip: e2eEnabled ? false : suiteSkipReason, timeout: 120000 },
  async () => {
    const result = await runRepoScript(
      "scripts/run-pi-mono.sh",
      [
        "--no-env",
        "--no-session",
        "--print",
        '/camlflow-run examples/provider-hooks/workflow.cml --entry main --input-json "Ada" --skills-dir examples/provider-hooks/skills',
      ],
      { timeoutMs: 120000 },
    );

    const output = combinedOutput(result);
    assert.notEqual(result.code, 0, "Expected the no-model workflow run to fail cleanly.");
    assertContainsAll(output, [
      "No pi model selected. Pure CamlFlow workflows can still run, but effectful workflows will fail. Use /model to select one.",
      "CamlFlow effect execution needs a pi model. Use /model, then rerun /camlflow-run.",
    ]);
  },
);

test(
  "provider-hooks workflow succeeds with a configured model",
  {
    skip: !e2eEnabled
      ? suiteSkipReason
      : !modelBackedEnabled
        ? "Set CAMLFLOW_PI_MONO_MODEL_E2E=1 plus CAMLFLOW_PI_MONO_PROVIDER and CAMLFLOW_PI_MONO_MODEL to run model-backed E2E tests."
        : false,
    timeout: 180000,
  },
  async () => {
    const modelArgs = modelCliArgsFromEnv();
    assert.equal(modelArgs.ok, true, modelArgs.error);

    const result = await runRepoScript(
      "scripts/run-pi-mono.sh",
      [
        "--no-session",
        ...modelArgs.args,
        "--print",
        '/camlflow-run examples/provider-hooks/workflow.cml --entry main --input-json "Ada" --skills-dir examples/provider-hooks/skills',
      ],
      { timeoutMs: 180000 },
    );

    const output = combinedOutput(result);
    assert.equal(result.code, 0, output);
    assertContainsAll(output, [
      "CamlFlow run complete",
      "workflow: examples/provider-hooks/workflow.cml",
      "steps: 3",
      "output:",
    ]);
  },
);

test(
  "orchestrator workflow returns a structured triage plan through pi",
  {
    skip: !e2eEnabled
      ? suiteSkipReason
      : !modelBackedEnabled
        ? "Set CAMLFLOW_PI_MONO_MODEL_E2E=1 plus CAMLFLOW_PI_MONO_PROVIDER and CAMLFLOW_PI_MONO_MODEL to run model-backed E2E tests."
        : false,
    timeout: 240000,
  },
  async () => {
    const modelArgs = modelCliArgsFromEnv();
    assert.equal(modelArgs.ok, true, modelArgs.error);

    const result = await runRepoScript(
      "scripts/run-pi-mono-problem-coach.sh",
      ["--no-session", ...modelArgs.args, "--print"],
      { timeoutMs: 240000 },
    );

    const output = combinedOutput(result);
    assert.equal(result.code, 0, output);
    assertContainsAll(output, [
      "CamlFlow run complete",
      "workflow: examples/orchestrator-session/main.cml",
      '"summary"',
      '"next_steps"',
      '"validation"',
    ]);
  },
);

test(
  "repo-triage launcher returns a structured triage plan through pi",
  {
    skip: !e2eEnabled
      ? suiteSkipReason
      : !modelBackedEnabled
        ? "Set CAMLFLOW_PI_MONO_MODEL_E2E=1 plus CAMLFLOW_PI_MONO_PROVIDER and CAMLFLOW_PI_MONO_MODEL to run model-backed E2E tests."
        : !deepE2eEnabled
          ? "Set CAMLFLOW_PI_MONO_DEEP_E2E=1 to run the slower repo-triage host test."
          : false,
    timeout: 300000,
  },
  async () => {
    const modelArgs = modelCliArgsFromEnv();
    assert.equal(modelArgs.ok, true, modelArgs.error);

    const result = await runRepoScript(
      "scripts/run-pi-mono-repo-triage.sh",
      ["--no-session", ...modelArgs.args, "--print"],
      { timeoutMs: 300000 },
    );

    const output = combinedOutput(result);
    assert.equal(result.code, 0, output);
    assertContainsAll(output, [
      "CamlFlow run complete",
      "workflow: examples/orchestrator-session/main.cml",
      '"summary"',
      '"next_steps"',
      '"validation"',
    ]);
  },
);
