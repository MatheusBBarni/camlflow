import assert from "node:assert/strict";
import test from "node:test";

import {
  PiCamlFlowEffectExecutor,
  PiCamlFlowMissingModelError,
  buildPiCamlFlowEffectPrompt,
  createPiCamlFlowHostSession,
  parseCamlFlowJsonOutput,
} from "../dist/index.js";
import * as sdk from "../dist/index.js";

const fakeModel = {
  provider: "faux",
  id: "model",
  name: "Faux Model",
  api: "faux",
  reasoning: false,
};

function createRuntime(overrides = {}) {
  return {
    cwd: "/tmp/camlflow-pi-sdk",
    session: {
      model: fakeModel,
      thinkingLevel: "off",
    },
    services: {
      modelRegistry: {
        getAvailable: () => [fakeModel],
        find: (provider, modelId) =>
          provider === fakeModel.provider && modelId === fakeModel.id ? fakeModel : undefined,
        hasConfiguredAuth: () => true,
      },
    },
    ...overrides,
  };
}

function createEffectRequest(overrides = {}) {
  return {
    kind: "bound-agent",
    role: "agent",
    name: "greeter",
    input: { name: "Ada" },
    renderedPrompt: "Say hello to Ada.",
    declaredReturnType: "string",
    outputSchema: { type: "string" },
    ...overrides,
  };
}

class FakeWorkerSession {
  constructor(outputText) {
    this.outputText = outputText;
    this.messages = [];
    this.listeners = [];
    this.abortCalled = false;
    this.disposeCalled = false;
    this.promptText = undefined;
    this.promptStarted = new Promise((resolve) => {
      this.resolvePromptStarted = resolve;
    });
    this.promptReleased = new Promise((resolve) => {
      this.releasePrompt = resolve;
    });
  }

  subscribe(listener) {
    this.listeners.push(listener);
    return () => {
      this.listeners = this.listeners.filter((candidate) => candidate !== listener);
    };
  }

  async prompt(text) {
    this.promptText = text;
    this.resolvePromptStarted();
    for (const delta of ["{\"answer\"", ":\"hello\"}"]) {
      for (const listener of this.listeners) {
        listener({
          type: "message_update",
          assistantMessageEvent: {
            type: "text_delta",
            delta,
          },
        });
      }
    }

    if (this.waitForAbort) {
      await this.promptReleased;
    }

    this.messages.push({
      role: "assistant",
      content: [{ type: "text", text: this.outputText }],
      stopReason: this.abortCalled ? "aborted" : "stop",
    });
  }

  async abort() {
    this.abortCalled = true;
    this.releasePrompt();
  }

  dispose() {
    this.disposeCalled = true;
  }
}

test("parses raw and fenced JSON worker output", () => {
  assert.deepEqual(parseCamlFlowJsonOutput('{"answer":42}'), { answer: 42 });
  assert.deepEqual(parseCamlFlowJsonOutput('```json\n{"answer":42}\n```'), {
    answer: 42,
  });
});

test("builds a Pi worker prompt from the rendered CamlFlow effect prompt", () => {
  const prompt = buildPiCamlFlowEffectPrompt(createEffectRequest());
  assert.match(prompt, /Execute the CamlFlow effect bound-agent:greeter/);
  assert.match(prompt, /Return exactly one JSON value/);
  assert.match(prompt, /Say hello to Ada\./);
  assert.match(prompt, /Declared return type: string/);
});

test("executes each effect in an injected ephemeral worker session and relays chunks", async () => {
  const sessions = [];
  const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
    workerSessionFactory: async () => {
      const session = new FakeWorkerSession('```json\n{"answer":"hello Ada"}\n```');
      sessions.push(session);
      return session;
    },
  });
  const chunks = [];

  const result = await executor.executeEffect(createEffectRequest(), {
    emitOutputChunk: (delta, done) => {
      chunks.push({ delta, done });
    },
  });

  assert.deepEqual(result, { answer: "hello Ada" });
  assert.equal(sessions.length, 1);
  assert.equal(sessions[0].disposeCalled, true);
  assert.ok(sessions[0].promptText.includes("Rendered CamlFlow prompt:"));
  assert.ok(chunks.some((chunk) => chunk.done === false && chunk.delta.length > 0));
  assert.deepEqual(chunks.at(-1), { delta: "", done: true });
});

test("rejects malformed worker JSON", async () => {
  const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
    workerSessionFactory: async () => new FakeWorkerSession("not json"),
  });

  await assert.rejects(
    () => executor.executeEffect(createEffectRequest()),
    /CamlFlow effect returned invalid JSON/,
  );
});

test("fails before creating a worker when Pi has no configured model", async () => {
  let workerCreated = false;
  const executor = new PiCamlFlowEffectExecutor(
    createRuntime({
      session: { model: undefined, thinkingLevel: "off" },
      services: {
        modelRegistry: {
          getAvailable: () => [],
          find: () => undefined,
          hasConfiguredAuth: () => false,
        },
      },
    }),
    {
      workerSessionFactory: async () => {
        workerCreated = true;
        return new FakeWorkerSession("{}");
      },
    },
  );

  await assert.rejects(
    () => executor.executeEffect(createEffectRequest()),
    PiCamlFlowMissingModelError,
  );
  assert.equal(workerCreated, false);
});

test("cancellation aborts the active worker session", async () => {
  const session = new FakeWorkerSession("{}");
  session.waitForAbort = true;
  const controller = new AbortController();
  const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
    workerSessionFactory: async () => session,
  });

  const pending = executor.executeEffect(createEffectRequest(), {
    signal: controller.signal,
  });
  await session.promptStarted;
  controller.abort();

  await assert.rejects(pending, /CamlFlow effect cancelled/);
  assert.equal(session.abortCalled, true);
  assert.equal(session.disposeCalled, true);
});

test("host session runs a workflow through the CamlFlow JSON-RPC client factory", async () => {
  const outputChunks = [];
  let fakeClient;
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('{"answer":"hello Ada"}'),
    onOutputChunk: async (chunk) => {
      outputChunks.push(chunk);
    },
    clientFactory: (options) => {
      fakeClient = new FakeCamlFlowClient(options);
      return fakeClient;
    },
  });

  const result = await host.runWorkflow({
    workflowPath: "examples/basic/main.cml",
    entrypoint: "main",
    input: "Ada",
    skillsDir: "examples/basic/skills",
  });

  assert.equal(result.protocolVersion, "0.1.0");
  assert.equal(result.irVersion, "0.1.0");
  assert.equal(result.runId, "run-1");
  assert.deepEqual(result.output, { answer: "hello Ada" });
  assert.deepEqual(fakeClient.runParams.program, {
    path: "examples/basic/main.cml",
    includePaths: [],
    skillsDir: "examples/basic/skills",
  });
  assert.equal(fakeClient.shutdownCalled, true);
  assert.ok(outputChunks.some((chunk) => chunk.streamId === "pi:1:bound-agent:greeter"));
});

test("host session cancel aborts the in-flight JSON-RPC run signal", async () => {
  let fakeClient;
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("{}"),
    clientFactory: (options) => {
      fakeClient = new HangingCamlFlowClient(options);
      return fakeClient;
    },
  });

  const pending = host.runWorkflow({
    workflowPath: "examples/basic/main.cml",
  });
  await fakeClient.runStarted;
  await host.cancel();

  await assert.rejects(pending, /cancelled/);
  assert.equal(fakeClient.runSignal.aborted, true);
  assert.equal(fakeClient.shutdownCalled, true);
});

test("package exports no slash-command parser", () => {
  assert.equal("parseCamlFlowCommand" in sdk, false);
  assert.equal("parseCamlFlowRunCommand" in sdk, false);
  assert.equal(
    Object.keys(sdk).some((name) => name.toLowerCase().includes("slash")),
    false,
  );
});

class FakeCamlFlowClient {
  constructor(options) {
    this.options = options;
    this.shutdownCalled = false;
  }

  async initialize() {
    return {
      protocolVersion: "0.1.0",
      irVersion: "0.1.0",
      capabilities: {},
      effectKinds: [],
    };
  }

  async run(params, options) {
    this.runParams = params;
    this.runOptions = options;
    const effectResult = await this.options.effectHandler(
      {
        runId: "run-1",
        step: 1,
        effect: {
          kind: "bound-agent",
          role: "agent",
          name: "greeter",
          input: { name: "Ada" },
          declaredReturnType: "record",
          outputSchema: { type: "object" },
          workingDirectory: null,
          skillsDirectory: null,
          skillMarkdown: null,
          inlineDefinition: null,
          renderedPrompt: "Say hello to Ada.",
          requestedModel: null,
          unsupportedSettings: [],
          step: 1,
          runId: "run-1",
        },
      },
      { jsonrpc: "2.0", id: 1, method: "camlflow/executeEffect" },
      {
        emitOutputChunk: async (chunk) => {
          await this.options.onOutputChunk?.({
            runId: "run-1",
            step: 1,
            declaredReturnType: "record",
            outputSchema: { type: "object" },
            ...chunk,
          });
        },
      },
    );

    return {
      runId: "run-1",
      stepsRun: 1,
      output: effectResult.output,
    };
  }

  async shutdownAndExit() {
    this.shutdownCalled = true;
  }
}

class HangingCamlFlowClient extends FakeCamlFlowClient {
  constructor(options) {
    super(options);
    this.runStarted = new Promise((resolve) => {
      this.resolveRunStarted = resolve;
    });
  }

  async run(_params, options) {
    this.runSignal = options.signal;
    this.resolveRunStarted();
    return new Promise((_resolve, reject) => {
      options.signal.addEventListener("abort", () => reject(new Error("cancelled")), {
        once: true,
      });
    });
  }
}
