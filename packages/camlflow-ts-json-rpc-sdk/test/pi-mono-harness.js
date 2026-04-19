const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const sdkPackageRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(__dirname, "..", "..", "..");

const defaultPiMonoRepo =
  process.env.PI_MONO_REPO || path.join(os.homedir(), "projects", "pi-mono");

const requiredPiMonoBuildArtifacts = [
  path.join(defaultPiMonoRepo, "packages/ai/dist/index.js"),
  path.join(defaultPiMonoRepo, "packages/agent/dist/index.js"),
  path.join(defaultPiMonoRepo, "packages/tui/dist/index.js"),
];

function runProcess(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let settled = false;
    const timeoutMs = options.timeoutMs ?? 30000;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill("SIGKILL");
      reject(new Error(`Timed out running ${command} ${args.join(" ")}`));
    }, timeoutMs);

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });

    child.once("error", (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(error);
    });

    child.once("close", (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ code, signal, stdout, stderr });
    });
  });
}

function runRepoScript(scriptRelativePath, args = [], options = {}) {
  return runProcess(path.join(repoRoot, scriptRelativePath), args, {
    cwd: repoRoot,
    env: {
      ...process.env,
      ...options.env,
    },
    timeoutMs: options.timeoutMs,
  });
}

function combinedOutput(result) {
  return [result.stdout, result.stderr].filter(Boolean).join("\n");
}

function makeMissingPiMonoRepo() {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "camlflow-pi-mono-missing-"));
  const missingPath = path.join(tempRoot, "missing-pi-mono");
  return {
    path: missingPath,
    cleanup() {
      fs.rmSync(tempRoot, { recursive: true, force: true });
    },
  };
}

function readBoolEnv(name) {
  return process.env[name] === "1";
}

function modelCliArgsFromEnv() {
  const provider = process.env.CAMLFLOW_PI_MONO_PROVIDER;
  const model = process.env.CAMLFLOW_PI_MONO_MODEL;
  if (!provider || !model) {
    return {
      ok: false,
      error:
        "Set CAMLFLOW_PI_MONO_PROVIDER and CAMLFLOW_PI_MONO_MODEL to run model-backed pi-mono E2E tests.",
    };
  }

  return {
    ok: true,
    args: ["--provider", provider, "--model", model],
    provider,
    model,
  };
}

async function collectPiMonoPreflight(options = {}) {
  const piMonoRepo = process.env.PI_MONO_REPO || defaultPiMonoRepo;
  const piTestScript = path.join(piMonoRepo, "pi-test.sh");
  const tsxBin = path.join(piMonoRepo, "node_modules/.bin/tsx");
  const buildArtifacts = [
    path.join(piMonoRepo, "packages/ai/dist/index.js"),
    path.join(piMonoRepo, "packages/agent/dist/index.js"),
    path.join(piMonoRepo, "packages/tui/dist/index.js"),
  ];

  const report = {
    repoRoot,
    sdkPackageRoot,
    piMonoRepo,
    scripts: {
      runPiMono: path.join(repoRoot, "scripts/run-pi-mono.sh"),
      runPiMonoRecursion: path.join(repoRoot, "scripts/run-pi-mono-recursion.sh"),
      runPiMonoBasic: path.join(repoRoot, "scripts/run-pi-mono-basic.sh"),
      runPiMonoProblemCoach: path.join(repoRoot, "scripts/run-pi-mono-problem-coach.sh"),
      runPiMonoRepoTriage: path.join(repoRoot, "scripts/run-pi-mono-repo-triage.sh"),
    },
    exists: {
      piMonoRepo: fs.existsSync(piMonoRepo),
      piTestScript: fs.existsSync(piTestScript),
      tsxBin: fs.existsSync(tsxBin),
    },
    buildArtifacts: buildArtifacts.map((artifactPath) => ({
      path: artifactPath,
      exists: fs.existsSync(artifactPath),
    })),
    issues: [],
  };

  if (!report.exists.piMonoRepo) {
    report.issues.push(`pi-mono repo not found: ${piMonoRepo}`);
  }
  if (!report.exists.piTestScript) {
    report.issues.push(`pi-test.sh not found: ${piTestScript}`);
  }
  if (!report.exists.tsxBin) {
    report.issues.push(`tsx not found: ${tsxBin}`);
  }

  for (const artifact of report.buildArtifacts) {
    if (!artifact.exists) {
      report.issues.push(`Missing pi-mono build artifact: ${artifact.path}`);
    }
  }

  if (options.checkCamlFlowBuild) {
    const buildProbe = await runProcess(
      "dune",
      ["exec", "./bin/main.exe", "--", "--help"],
      {
        cwd: repoRoot,
        timeoutMs: options.buildTimeoutMs ?? 60000,
      },
    );
    report.camlflowBuild = {
      ok: buildProbe.code === 0,
      code: buildProbe.code,
      stdout: buildProbe.stdout,
      stderr: buildProbe.stderr,
    };
    if (!report.camlflowBuild.ok) {
      report.issues.push("Current camlflow checkout does not build cleanly for CLI execution.");
    }
  }

  report.ok = report.issues.length === 0;
  return report;
}

function formatPreflightIssues(report) {
  return report.issues.map((issue) => `- ${issue}`).join("\n");
}

function assertContainsAll(text, expected) {
  for (const value of expected) {
    assert.match(text, value instanceof RegExp ? value : new RegExp(escapeForRegex(value)));
  }
}

function escapeForRegex(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

module.exports = {
  assertContainsAll,
  collectPiMonoPreflight,
  combinedOutput,
  defaultPiMonoRepo,
  formatPreflightIssues,
  makeMissingPiMonoRepo,
  modelCliArgsFromEnv,
  readBoolEnv,
  repoRoot,
  requiredPiMonoBuildArtifacts,
  runProcess,
  runRepoScript,
  sdkPackageRoot,
};
