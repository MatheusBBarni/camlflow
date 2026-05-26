import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { mkdtemp, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  CamlFlowResultParseError,
  CamlFlowValidationError,
  assertJsonValue,
  assertNonEmptyString,
  composeAbortSignals,
  createEphemeralSandboxProvider,
  createLocalSandboxProvider,
  createMemorySessionStore,
  createOrchestratorHarness,
  createReadOnlySandboxProvider,
  parseResult,
  relayOutputChunk,
  resolveRoleOverlay,
  resolveSandboxPath,
  scaffoldCamlFlowProject,
} from "../dist/index.js";

test("validates strict JSON values before host side parsing", () => {
  assert.deepEqual(assertJsonValue({ ok: [1, "two", true, null] }), {
    ok: [1, "two", true, null],
  });
  assert.throws(() => assertJsonValue({ bad: Number.NaN }), CamlFlowValidationError);
  assert.throws(() => assertJsonValue({ bad: undefined }), /JSON-serializable/);
  assert.throws(() => assertJsonValue(new Date()), /plain object/);
  const circular = {};
  circular.self = circular;
  assert.throws(() => assertJsonValue(circular), /circular/);
});

test("parses raw JSON, parse, and safeParse result parser shapes", () => {
  assert.deepEqual(parseResult({ answer: 42 }), { answer: 42 });
  assert.equal(parseResult({ answer: 42 }, (value) => value.answer), 42);
  assert.equal(parseResult({ answer: 42 }, { parse: (value) => value.answer + 1 }), 43);
  assert.equal(
    parseResult({ answer: 42 }, { safeParse: (value) => ({ success: true, data: value.answer + 2 }) }),
    44,
  );
  assert.throws(
    () => parseResult({ answer: 42 }, { safeParse: () => ({ success: false, issues: ["bad"] }) }),
    CamlFlowResultParseError,
  );
});

test("composes abort signals for provider and workflow cancellation", () => {
  const parent = new AbortController();
  const child = new AbortController();
  const signal = composeAbortSignals([parent.signal, child.signal]);
  assert.equal(signal.aborted, false);
  child.abort();
  assert.equal(signal.aborted, true);
});

test("relays validated output chunks", async () => {
  const chunks = [];
  await relayOutputChunk({ delta: "hello", done: false }, (chunk) => chunks.push(chunk));
  assert.deepEqual(chunks, [{ delta: "hello", done: false }]);
  await assert.rejects(() => relayOutputChunk({ delta: 1, done: false }), /delta must be a string/);
});

test("memory session store validates and persists records", async () => {
  const store = createMemorySessionStore();
  await store.save({ id: "session-1", sandboxCwd: "/tmp/work", data: { messages: [] } });
  assert.deepEqual(await store.load("session-1"), {
    id: "session-1",
    sandboxCwd: "/tmp/work",
    data: { messages: [] },
  });
  await assert.rejects(
    () => store.save({ id: " ", sandboxCwd: "/tmp/work", data: {} }),
    /session id must be a non-empty string/,
  );
  await store.delete("session-1");
  assert.equal(await store.load("session-1"), undefined);
});

test("rejects empty strings and NUL bytes at generic boundaries", () => {
  assert.equal(assertNonEmptyString("run-1", "run id"), "run-1");
  assert.throws(() => assertNonEmptyString(" ", "run id"), /non-empty/);
  assert.throws(() => assertNonEmptyString("bad\0id", "run id"), /NUL/);
});

test("local sandbox resolves paths and exposes bounded shell", async () => {
  const provider = createLocalSandboxProvider();
  const sandbox = await provider.create({ cwd: process.cwd() }, {});
  assert.equal(sandbox.kind, "local");
  assert.equal(resolveSandboxPath(sandbox.cwd, "."), sandbox.cwd);
  assert.throws(() => sandbox.resolvePath(".."), /escapes sandbox root/);
  const result = await sandbox.shell("node -e \"process.stdin.pipe(process.stdout)\"", {
    stdin: "hello",
  });
  assert.equal(result.code, 0);
  assert.equal(result.stdout, "hello");
  assert.deepEqual(await sandbox.close(), { kind: "local", cwd: sandbox.cwd, cleaned: false });
});

test("read-only sandbox disables trusted shell", async () => {
  const provider = createReadOnlySandboxProvider();
  const sandbox = await provider.create({ cwd: process.cwd() }, {});
  assert.equal(sandbox.kind, "read-only");
  assert.equal(sandbox.shell, undefined);
  await sandbox.close();
});

test("ephemeral sandbox cleans up on close", async () => {
  const provider = createEphemeralSandboxProvider();
  const sandbox = await provider.create({}, {});
  const cwd = sandbox.cwd;
  assert.equal(existsSync(cwd), true);
  const closeResult = await sandbox.close();
  assert.equal(closeResult.cleaned, true);
  assert.equal(existsSync(cwd), false);
});

test("sandbox close preserves dirty worktrees when configured", async () => {
  const provider = createEphemeralSandboxProvider();
  const sandbox = await provider.create({ preserveOnDirtyWorktree: true, isDirty: () => true }, {});
  const closeResult = await sandbox.close();
  assert.equal(closeResult.cleaned, false);
  assert.equal(closeResult.preservedPath, sandbox.cwd);
  assert.equal(existsSync(sandbox.cwd), true);
});

test("sandbox path resolution blocks symlink escapes", async () => {
  const provider = createLocalSandboxProvider();
  const sandbox = await provider.create({ cwd: process.cwd() }, {});
  const outside = await mkdtemp(join(tmpdir(), "camlflow-orchestrator-outside-"));
  const linkPath = join(sandbox.cwd, "camlflow-orchestrator-outside-link");
  try {
    await symlink(outside, linkPath);
    assert.throws(() => sandbox.resolvePath("camlflow-orchestrator-outside-link"), /escapes sandbox root/);
  } finally {
    await sandbox.close();
  }
});

test("orchestrator harness shares sandbox across sessions, tasks, skills, and workflow runs", async () => {
  const calls = [];
  let sessionCounter = 0;
  const provider = createEphemeralSandboxProvider();
  const agentProvider = {
    name: "fake-agent",
    async createSession(options) {
      sessionCounter += 1;
      const session = { id: `agent-${sessionCounter}`, sandbox: options.sandbox, role: options.role };
      calls.push(["createSession", session.id, options.sandbox.cwd, options.role]);
      return session;
    },
    async prompt(session, prompt) {
      calls.push(["prompt", session.id, session.sandbox.cwd, prompt]);
      return { session: session.id, prompt, cwd: session.sandbox.cwd };
    },
    async closeSession(session) {
      calls.push(["closeSession", session.id]);
    },
  };
  const hooks = [];
  const harness = createOrchestratorHarness({
    sandboxProvider: provider,
    sandbox: {},
    agentProvider,
    roles: { workflow: "workflow-role", agent: "agent-role" },
    promptResolver: {
      resolve: ({ name }, { args }) => `skill:${name}:${JSON.stringify(args)}`,
    },
    hooks: {
      beforeRun: (run) => hooks.push(["beforeRun", run.workflowPath, run.sandbox.cwd]),
      afterRun: (run, result) => hooks.push(["afterRun", run.runId, result.output]),
    },
    workflowRunner: (run) => ({
      runId: run.runId,
      output: { workflowPath: run.workflowPath, input: run.input, cwd: run.sandbox.cwd },
      diagnostics: [],
      metadata: {},
    }),
  });

  const agent = await harness.init({ runId: "run-1" });
  const session = await agent.session("parent");
  const promptResult = await session.prompt("hello", { result: (value) => value.prompt });
  assert.equal(promptResult, "hello");
  const skillResult = await session.skill("triage", { args: { issue: 16 } });
  assert.equal(skillResult.prompt, "skill:triage:{\"issue\":16}");
  const taskResult = await session.task("child work");
  assert.equal(taskResult.prompt, "child work");
  const runResult = await agent.runWorkflow({ workflowPath: "flows/main.cml", input: { ok: true } });
  assert.equal(runResult.output.workflowPath, "flows/main.cml");
  assert.equal(runResult.output.cwd, agent.sandbox.cwd);
  await agent.close();

  assert.equal(calls.filter((call) => call[0] === "createSession").length, 2);
  assert.equal(new Set(calls.filter((call) => call[0] === "prompt").map((call) => call[2])).size, 1);
  assert.deepEqual(hooks.map((hook) => hook[0]), ["beforeRun", "afterRun"]);
});

test("role overlays use host call, skill, agent, then workflow precedence", () => {
  assert.equal(resolveRoleOverlay({ workflow: "workflow", agent: "agent" }), "agent");
  assert.equal(resolveRoleOverlay({ workflow: "workflow", skill: "skill" }), "skill");
  assert.equal(resolveRoleOverlay({ workflow: "workflow", hostCall: "host" }), "host");
  assert.equal(resolveRoleOverlay({ workflow: "workflow" }, "call"), "call");
});

test("scaffolds .camlflow project layout without overwriting by default", async () => {
  const root = await mkdtemp(join(tmpdir(), "camlflow-scaffold-"));
  const first = await scaffoldCamlFlowProject(root, { workflowName: "triage" });
  assert.deepEqual(first.skipped, []);
  assert.ok(first.created.includes(".camlflow/workflows/triage.cml"));
  assert.equal(first.workflowPath, ".camlflow/workflows/triage.cml");
  const config = JSON.parse(await readFile(join(root, "camlflow.json"), "utf8"));
  assert.deepEqual(config, {
    program: ".camlflow/workflows/triage.cml",
    entry: "main",
    skillsDir: ".camlflow/skills",
  });
  const second = await scaffoldCamlFlowProject(root, { workflowName: "triage" });
  assert.ok(second.skipped.includes("camlflow.json"));
  assert.ok(second.skipped.includes(".camlflow/workflows/triage.cml"));
});
