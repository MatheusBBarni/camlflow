import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { mkdtemp, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  PiCamlFlowEffectExecutor,
  PiCamlFlowMissingModelError,
  buildPiCamlFlowEffectPrompt,
  createPiCamlFlowHarness,
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

function createExecuteEffectParams(overrides = {}) {
  const effectOverrides = overrides.effect ?? {};
  return {
    runId: "run-1",
    step: 1,
    ...overrides,
    effect: {
      ...createEffectRequest({
        declaredReturnType: "record",
        outputSchema: { type: "object" },
        workingDirectory: null,
        skillsDirectory: null,
        skillMarkdown: null,
        inlineDefinition: null,
        requestedModel: null,
        unsupportedSettings: [],
        step: 1,
        runId: "run-1",
      }),
      ...effectOverrides,
    },
  };
}

function createLocation(overrides = {}) {
  return {
    file: "examples/basic/main.cml",
    start: { line: 1, column: 0, offset: 0 },
    end: { line: 1, column: 10, offset: 10 },
    ...overrides,
  };
}

function createInlineDefinition(overrides = {}) {
  return {
    model: "faux/model",
    temperature: null,
    system_prompt: "Review tersely.",
    metadata: [
      { name: "tone", value: { kind: "string", value: "terse" } },
      { name: "retries", value: { kind: "int", value: 1 } },
      { name: "enabled", value: { kind: "bool", value: true } },
      { name: "weight", value: { kind: "float", value: 0.5 } },
      { name: "marker", value: { kind: "unit" } },
    ],
    loc: createLocation(),
    ...overrides,
  };
}

function countAbortSignalListeners(signal) {
  const originalAdd = signal.addEventListener.bind(signal);
  const originalRemove = signal.removeEventListener.bind(signal);
  const counts = { added: 0, removed: 0 };
  signal.addEventListener = (type, listener, options) => {
    if (type === "abort") {
      counts.added += 1;
    }
    return originalAdd(type, listener, options);
  };
  signal.removeEventListener = (type, listener, options) => {
    if (type === "abort") {
      counts.removed += 1;
    }
    return originalRemove(type, listener, options);
  };
  return counts;
}

class FakeWorkerSession {
  constructor(outputText) {
    this.outputText = outputText;
    this.messages = [];
    this.listeners = [];
    this.abortCalled = false;
    this.disposeCalled = false;
    this.disposeCalls = 0;
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
    if (this.abortError) {
      throw this.abortError;
    }
    this.releasePrompt();
  }

  dispose() {
    this.disposeCalls += 1;
    if (this.disposeError) {
      throw this.disposeError;
    }
    this.disposeCalled = true;
  }
}

test("parses raw and fenced JSON worker output", () => {
  assert.deepEqual(parseCamlFlowJsonOutput('{"answer":42}'), { answer: 42 });
  assert.deepEqual(parseCamlFlowJsonOutput('```json\n{"answer":42}\n```'), {
    answer: 42,
  });
  assert.throws(
    () => parseCamlFlowJsonOutput(42),
    /JSON output must be a string/,
  );
});

test("builds a Pi worker prompt from the rendered CamlFlow effect prompt", () => {
  const prompt = buildPiCamlFlowEffectPrompt(createEffectRequest());
  assert.match(prompt, /Execute the CamlFlow effect bound-agent:greeter/);
  assert.match(prompt, /Return exactly one JSON value/);
  assert.match(prompt, /Say hello to Ada\./);
  assert.match(prompt, /Declared return type: string/);
});

test("rejects invalid CamlFlow effect requests before worker creation", async () => {
  const circularSchema = {};
  circularSchema.self = circularSchema;
  const circularInput = {};
  circularInput.self = circularInput;
  const hiddenInput = { visible: true };
  Object.defineProperty(hiddenInput, "hidden", {
    value: "secret",
    enumerable: false,
  });
  const symbolInput = { visible: true };
  symbolInput[Symbol("hidden")] = "secret";
  const toJsonInput = { visible: true };
  Object.defineProperty(toJsonInput, "toJSON", {
    value: () => ({ rewritten: true }),
    enumerable: false,
  });
  const extraArrayInput = ["item"];
  extraArrayInput.extra = "hidden";
  const cases = [
    {
      request: null,
      message: /effect request must be an object/,
    },
    {
      request: [],
      message: /effect request must be an object/,
    },
    {
      request: createEffectRequest({ kind: "" }),
      message: /effect kind must not be empty/,
    },
    {
      request: createEffectRequest({ kind: "bound-agent\0" }),
      message: /effect kind must not contain NUL bytes/,
    },
    {
      request: createEffectRequest({ name: " " }),
      message: /effect name must not be empty/,
    },
    {
      request: createEffectRequest({ name: "greeter\0" }),
      message: /effect name must not contain NUL bytes/,
    },
    {
      request: createEffectRequest({ renderedPrompt: 42 }),
      message: /effect renderedPrompt must not be empty/,
    },
    {
      request: createEffectRequest({ workingDirectory: " " }),
      message: /effect workingDirectory must not be empty/,
    },
    {
      request: createEffectRequest({ workingDirectory: "bad\0cwd" }),
      message: /effect workingDirectory must not contain NUL bytes/,
    },
    {
      request: createEffectRequest({ skillsDirectory: 42 }),
      message: /effect skillsDirectory must not be empty/,
    },
    {
      request: createEffectRequest({ skillsDirectory: "bad\0skills" }),
      message: /effect skillsDirectory must not contain NUL bytes/,
    },
    {
      request: createEffectRequest({ skillMarkdown: "" }),
      message: /effect skillMarkdown must not be empty/,
    },
    {
      request: createEffectRequest({ requestedModel: "" }),
      message: /effect requestedModel must not be empty/,
    },
    {
      request: createEffectRequest({ requestedModel: "bad\0model" }),
      message: /effect requestedModel must not contain NUL bytes/,
    },
    {
      request: createEffectRequest({ declaredReturnType: "" }),
      message: /effect declaredReturnType must not be empty/,
    },
    {
      request: createEffectRequest({ declaredReturnType: "record\0" }),
      message: /effect declaredReturnType must not contain NUL bytes/,
    },
    {
      request: createEffectRequest({ runId: " " }),
      message: /effect runId must not be empty/,
    },
    {
      request: createEffectRequest({ runId: "run\0id" }),
      message: /effect runId must not contain NUL bytes/,
    },
    {
      request: createEffectRequest({ step: 1.5 }),
      message: /effect step must be a non-negative integer/,
    },
    {
      request: createEffectRequest({ input: undefined }),
      message: /effect input must be JSON serializable/,
    },
    {
      request: createEffectRequest({ input: { value: Number.NaN } }),
      message: /effect input must be JSON serializable/,
    },
    {
      request: createEffectRequest({ input: { value: () => undefined } }),
      message: /effect input must be JSON serializable/,
    },
    {
      request: createEffectRequest({ input: new Date() }),
      message: /effect input must be JSON serializable/,
    },
    {
      request: createEffectRequest({ input: [, "hole"] }),
      message: /effect input must be JSON serializable/,
    },
    {
      request: createEffectRequest({ input: hiddenInput }),
      message: /effect input must be JSON serializable/,
    },
    {
      request: createEffectRequest({ input: symbolInput }),
      message: /effect input must be JSON serializable/,
    },
    {
      request: createEffectRequest({ input: toJsonInput }),
      message: /effect input must be JSON serializable/,
    },
    {
      request: createEffectRequest({ input: extraArrayInput }),
      message: /effect input must be JSON serializable/,
    },
    {
      request: createEffectRequest({ outputSchema: circularSchema }),
      message: /effect outputSchema must be JSON serializable/,
    },
    {
      request: createEffectRequest({ outputSchema: [] }),
      message: /effect outputSchema must be an object/,
    },
    {
      request: createEffectRequest({ input: circularInput }),
      message: /effect input must be JSON serializable/,
    },
  ];

  for (const { request, message } of cases) {
    let workerCreated = false;
    const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
      workerSessionFactory: async () => {
        workerCreated = true;
        return new FakeWorkerSession("{}");
      },
    });

    assert.throws(() => buildPiCamlFlowEffectPrompt(request), message);
    await assert.rejects(() => executor.executeEffect(request), message);
    assert.equal(workerCreated, false);
  }
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

test("streaming output chunk failures do not fail effect execution", async () => {
  const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
    workerSessionFactory: async () => new FakeWorkerSession('{"answer":"hello Ada"}'),
  });
  const doneChunks = [];

  const result = await executor.executeEffect(createEffectRequest(), {
    emitOutputChunk: (delta, done) => {
      if (!done && delta.length > 0) {
        throw new Error("chunk failed");
      }
      doneChunks.push({ delta, done });
    },
  });

  assert.deepEqual(result, { answer: "hello Ada" });
  assert.deepEqual(doneChunks, [{ delta: "", done: true }]);
});

test("rejects malformed worker text delta events", async () => {
  let session;
  const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
    workerSessionFactory: async () => {
      session = new FakeWorkerSession('{"answer":"unreachable"}');
      session.prompt = async () => {
        for (const listener of session.listeners) {
          listener({
            type: "message_update",
            assistantMessageEvent: {
              type: "text_delta",
              delta: 42,
            },
          });
        }
        session.messages.push({
          role: "assistant",
          content: [{ type: "text", text: '{"answer":"unreachable"}' }],
          stopReason: "stop",
        });
      };
      return session;
    },
  });

  await assert.rejects(
    () => executor.executeEffect(createEffectRequest()),
    /text_delta event delta must be a string/,
  );
  assert.equal(session.disposeCalled, true);
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

test("rejects malformed worker assistant message content", async () => {
  const cases = [
    {
      content: undefined,
      message: /assistant message content must be an array/,
    },
    {
      content: { type: "text", text: "{}" },
      message: /assistant message content must be an array/,
    },
    {
      content: [null],
      message: /assistant message content\[0\] must be an object/,
    },
    {
      content: [{ text: "{}" }],
      message: /assistant message content\[0\] type must be a string/,
    },
    {
      content: [{ type: "text", text: 42 }],
      message: /assistant message content\[0\] text must be a string/,
    },
    {
      content: [{ type: "tool_use", id: "call-1" }],
      message: /assistant message must include text content/,
    },
  ];

  for (const { content, message } of cases) {
    const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
      workerSessionFactory: async () => {
        const session = new FakeWorkerSession("{}");
        session.prompt = async () => {
          session.messages.push({
            role: "assistant",
            content,
            stopReason: "stop",
          });
        };
        return session;
      },
    });

    await assert.rejects(
      () => executor.executeEffect(createEffectRequest()),
      message,
    );
  }
});

test("rejects malformed latest worker assistant message instead of reusing stale output", async () => {
  const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
    workerSessionFactory: async () => {
      const session = new FakeWorkerSession("{}");
      session.messages.push({
        role: "assistant",
        content: [{ type: "text", text: '{"answer":"stale"}' }],
        stopReason: "stop",
      });
      session.prompt = async () => {
        session.messages.push({
          role: "assistant",
          content: "malformed",
          stopReason: "stop",
        });
      };
      return session;
    },
  });

  await assert.rejects(
    () => executor.executeEffect(createEffectRequest()),
    /assistant message content must be an array/,
  );
});

test("rejects malformed worker assistant message status fields", async () => {
  const cases = [
    {
      status: { stopReason: 42 },
      message: /assistant message stopReason must be a string/,
    },
    {
      status: { stopReason: "error", errorMessage: { message: "boom" } },
      message: /assistant message errorMessage must be a string/,
    },
  ];

  for (const { status, message } of cases) {
    const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
      workerSessionFactory: async () => {
        const session = new FakeWorkerSession("{}");
        session.prompt = async () => {
          session.messages.push({
            role: "assistant",
            content: [{ type: "text", text: "{}" }],
            ...status,
          });
        };
        return session;
      },
    });

    await assert.rejects(
      () => executor.executeEffect(createEffectRequest()),
      message,
    );
  }
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

test("rejects malformed model registry results before worker creation", async () => {
  const cases = [
    {
      runtime: createRuntime({
        session: { model: undefined, thinkingLevel: "off" },
        services: {
          modelRegistry: {
            getAvailable: () => null,
            find: () => undefined,
            hasConfiguredAuth: () => false,
          },
        },
      }),
      request: createEffectRequest(),
      message: /modelRegistry\.getAvailable must return an array/,
    },
    {
      runtime: createRuntime({
        session: { model: undefined, thinkingLevel: "off" },
        services: {
          modelRegistry: {
            getAvailable: () => [{}],
            find: () => undefined,
            hasConfiguredAuth: () => false,
          },
        },
      }),
      request: createEffectRequest(),
      message: /available model 0 provider must not be empty/,
    },
    {
      runtime: createRuntime({
        session: { model: undefined, thinkingLevel: "off" },
        services: {
          modelRegistry: {
            getAvailable: () => [{ ...fakeModel, name: "bad\0name" }],
            find: () => undefined,
            hasConfiguredAuth: () => false,
          },
        },
      }),
      request: createEffectRequest(),
      message: /available model 0 name must not contain NUL bytes/,
    },
    {
      runtime: createRuntime({
        session: { model: undefined, thinkingLevel: "off" },
        services: {
          modelRegistry: {
            getAvailable: () => [{ ...fakeModel, api: "bad\0api" }],
            find: () => undefined,
            hasConfiguredAuth: () => false,
          },
        },
      }),
      request: createEffectRequest(),
      message: /available model 0 api must not contain NUL bytes/,
    },
    {
      runtime: createRuntime({
        session: { model: undefined, thinkingLevel: "off" },
        services: {
          modelRegistry: {
            getAvailable: () => [],
            find: () => ({}),
            hasConfiguredAuth: () => true,
          },
        },
      }),
      request: createEffectRequest({ requestedModel: "faux/model" }),
      message: /requested model provider must not be empty/,
    },
    {
      runtime: createRuntime({
        session: { model: undefined, thinkingLevel: "off" },
        services: {
          modelRegistry: {
            getAvailable: () => [],
            find: () => fakeModel,
            hasConfiguredAuth: () => "yes",
          },
        },
      }),
      request: createEffectRequest({ requestedModel: "faux/model" }),
      message: /hasConfiguredAuth must return a boolean/,
    },
  ];

  for (const { runtime, request, message } of cases) {
    let workerCreated = false;
    const executor = new PiCamlFlowEffectExecutor(runtime, {
      workerSessionFactory: async () => {
        workerCreated = true;
        return new FakeWorkerSession("{}");
      },
    });

    await assert.rejects(
      () => executor.executeEffect(request),
      message,
    );
    assert.equal(workerCreated, false);
  }
});

test("rejects invalid runtime configuration before worker or client creation", async () => {
  const cases = [
    {
      runtime: null,
      message: /runtime must be an object/,
    },
    {
      runtime: createRuntime({ cwd: " " }),
      message: /runtime cwd must not be empty/,
    },
    {
      runtime: createRuntime({ cwd: "/tmp/bad\0cwd" }),
      message: /runtime cwd must not contain NUL bytes/,
    },
    {
      runtime: createRuntime({ session: null }),
      message: /runtime session must be an object/,
    },
    {
      runtime: createRuntime({ session: { model: {}, thinkingLevel: "off" } }),
      message: /runtime session model provider must not be empty/,
    },
    {
      runtime: createRuntime({ session: { model: fakeModel, thinkingLevel: 42 } }),
      message: /runtime session thinkingLevel must be a string/,
    },
    {
      runtime: createRuntime({ services: null }),
      message: /runtime services must be an object/,
    },
    {
      runtime: createRuntime({
        services: {
          agentDir: " ",
          modelRegistry: createRuntime().services.modelRegistry,
        },
      }),
      message: /runtime services agentDir must not be empty/,
    },
    {
      runtime: createRuntime({
        services: {
          agentDir: "/tmp/bad\0agent-dir",
          modelRegistry: createRuntime().services.modelRegistry,
        },
      }),
      message: /runtime services agentDir must not contain NUL bytes/,
    },
    {
      runtime: createRuntime({ services: { modelRegistry: {} } }),
      message: /modelRegistry must provide/,
    },
  ];

  for (const { runtime, message } of cases) {
    assert.throws(
      () =>
        new PiCamlFlowEffectExecutor(runtime, {
          workerSessionFactory: async () => {
            throw new Error("worker should not be created");
          },
        }),
      message,
    );

    assert.throws(
      () =>
        createPiCamlFlowHostSession({
          runtime,
          clientFactory: () => {
            throw new Error("client should not be created");
          },
        }),
      message,
    );

    assert.throws(
      () =>
        createPiCamlFlowHarness({
          runtime,
          workerSessionFactory: async () => {
            throw new Error("worker should not be created");
          },
        }),
      message,
    );
  }
});

test("rejects malformed exported option bags before worker or client creation", async () => {
  assert.throws(
    () => new PiCamlFlowEffectExecutor(createRuntime(), null),
    /effect executor options must be an object/,
  );
  assert.throws(
    () => new PiCamlFlowEffectExecutor(createRuntime(), []),
    /effect executor options must be an object/,
  );
  assert.throws(
    () =>
      new PiCamlFlowEffectExecutor(createRuntime(), {
        workerSessionFactory: {},
      }),
    /workerSessionFactory must be a function/,
  );

  const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
    workerSessionFactory: async () => new FakeWorkerSession("{}"),
  });
  await assert.rejects(
    () => executor.executeEffect(createEffectRequest(), null),
    /effect execution options must be an object/,
  );
  await assert.rejects(
    () => executor.executeEffect(createEffectRequest(), []),
    /effect execution options must be an object/,
  );
  await assert.rejects(
    () =>
      executor.executeEffect(createEffectRequest(), {
        signal: { aborted: false },
      }),
    /effect execution signal must be an AbortSignal/,
  );
  await assert.rejects(
    () =>
      executor.executeEffect(createEffectRequest(), {
        emitOutputChunk: {},
      }),
    /emitOutputChunk must be a function/,
  );

  assert.throws(
    () => createPiCamlFlowHostSession(null),
    /host session options must be an object/,
  );
  assert.throws(
    () => createPiCamlFlowHostSession([]),
    /host session options must be an object/,
  );
  assert.throws(
    () =>
      createPiCamlFlowHostSession({
        runtime: createRuntime(),
        clientFactory: {},
      }),
    /clientFactory must be a function/,
  );
  assert.throws(
    () =>
      createPiCamlFlowHostSession({
        runtime: createRuntime(),
        onTrace: {},
      }),
    /onTrace callback must be a function/,
  );
  assert.throws(
    () =>
      createPiCamlFlowHostSession({
        runtime: createRuntime(),
        autoShutdown: "no",
      }),
    /autoShutdown must be a boolean/,
  );
  const hiddenSpawnEnv = { GOOD: "value" };
  Object.defineProperty(hiddenSpawnEnv, "HIDDEN", {
    enumerable: false,
    value: "secret",
  });
  const symbolSpawnEnv = { GOOD: "value" };
  symbolSpawnEnv[Symbol("SECRET")] = "secret";
  for (const camlflow of [
    { command: " " },
    { command: "bad\0cmd" },
    { args: "serve" },
    { args: ["serve", 42] },
    { args: ["bad\0arg"] },
    { cwd: " " },
    { cwd: "bad\0cwd" },
    { env: [] },
    { env: new Date() },
    { env: hiddenSpawnEnv },
    { env: symbolSpawnEnv },
    { env: { "BAD=NAME": "value" } },
    { env: { BAD: "bad\0value" } },
    { stderr: "ignore" },
    { onNotification: {} },
  ]) {
    assert.throws(
      () =>
        createPiCamlFlowHostSession({
          runtime: createRuntime(),
          camlflow,
        }),
      /camlflow options/,
    );
  }

  assert.throws(
    () => createPiCamlFlowHarness(null),
    /harness options must be an object/,
  );
  assert.throws(
    () => createPiCamlFlowHarness([]),
    /harness options must be an object/,
  );
  assert.throws(
    () =>
      createPiCamlFlowHarness({
        runtime: createRuntime(),
        camlflow: "local",
      }),
    /harness camlflow options must be an object/,
  );
  assert.throws(
    () =>
      createPiCamlFlowHarness({
        runtime: createRuntime(),
        camlflow: { command: "bad\0cmd" },
      }),
    /harness camlflow options command must not contain NUL bytes/,
  );

  const harness = createPiCamlFlowHarness({ runtime: createRuntime() });
  await assert.rejects(
    () => harness.init(null),
    /agent init options must be an object/,
  );
  await assert.rejects(
    () => harness.init([]),
    /agent init options must be an object/,
  );
});

test("rejects malformed injected worker sessions before prompting", async () => {
  const workerSession = {
    messages: [],
    subscribe() {
      throw new Error("subscribe should not be called");
    },
    abort() {
      throw new Error("abort should not be called");
    },
    dispose() {
      throw new Error("dispose should not be called");
    },
  };
  const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
    workerSessionFactory: async () => workerSession,
  });

  await assert.rejects(
    () => executor.executeEffect(createEffectRequest()),
    /effect worker session must provide prompt, subscribe, abort, and dispose/,
  );
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

test("cancellation during worker creation disposes the late worker session", async () => {
  let releaseWorker;
  let signalWorkerStarted;
  let lateSession;
  const workerGate = new Promise((resolve) => {
    releaseWorker = resolve;
  });
  const workerStarted = new Promise((resolve) => {
    signalWorkerStarted = resolve;
  });
  const controller = new AbortController();
  const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
    workerSessionFactory: async () => {
      signalWorkerStarted();
      await workerGate;
      lateSession = new FakeWorkerSession("{}");
      return lateSession;
    },
  });

  const pending = executor.executeEffect(createEffectRequest(), {
    signal: controller.signal,
  });
  await workerStarted;
  controller.abort();
  releaseWorker();

  await assert.rejects(pending, /CamlFlow effect cancelled/);
  assert.equal(lateSession.abortCalled, true);
  assert.equal(lateSession.disposeCalled, true);
  assert.equal(lateSession.promptText, undefined);
});

test("worker subscribe failures still dispose the worker session", async () => {
  const session = new FakeWorkerSession("{}");
  session.subscribe = () => {
    throw new Error("subscribe failed");
  };
  const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
    workerSessionFactory: async () => session,
  });

  await assert.rejects(
    () => executor.executeEffect(createEffectRequest()),
    /subscribe failed/,
  );
  assert.equal(session.disposeCalled, true);
});

test("worker subscribe must return an unsubscribe function", async () => {
  const session = new FakeWorkerSession("{}");
  session.subscribe = () => undefined;
  let promptCalled = false;
  session.prompt = async () => {
    promptCalled = true;
  };
  const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
    workerSessionFactory: async () => session,
  });

  await assert.rejects(
    () => executor.executeEffect(createEffectRequest()),
    /subscribe must return an unsubscribe function/,
  );
  assert.equal(promptCalled, false);
  assert.equal(session.disposeCalled, true);
});

test("final output chunk failures still unsubscribe and dispose the worker session", async () => {
  const session = new FakeWorkerSession('{"answer":"done"}');
  const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
    workerSessionFactory: async () => session,
  });

  await assert.rejects(
    () =>
      executor.executeEffect(createEffectRequest(), {
        emitOutputChunk: (_delta, done) => {
          if (done) {
            throw new Error("done failed");
          }
        },
      }),
    /done failed/,
  );
  assert.equal(session.listeners.length, 0);
  assert.equal(session.disposeCalled, true);
});

test("primary effect failures are preserved when final output chunk cleanup fails", async () => {
  const session = new FakeWorkerSession("not json");
  const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
    workerSessionFactory: async () => session,
  });

  await assert.rejects(
    () =>
      executor.executeEffect(createEffectRequest(), {
        emitOutputChunk: (_delta, done) => {
          if (done) {
            throw new Error("done failed");
          }
        },
      }),
    /CamlFlow effect returned invalid JSON/,
  );
  assert.equal(session.listeners.length, 0);
  assert.equal(session.disposeCalled, true);
});

test("worker cleanup continues when unsubscribe fails", async () => {
  const session = new FakeWorkerSession('{"answer":"done"}');
  session.subscribe = (listener) => {
    session.listeners.push(listener);
    return () => {
      throw new Error("unsubscribe failed");
    };
  };
  const executor = new PiCamlFlowEffectExecutor(createRuntime(), {
    workerSessionFactory: async () => session,
  });

  await assert.rejects(
    () => executor.executeEffect(createEffectRequest()),
    /unsubscribe failed/,
  );
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

test("host session rejects malformed JSON-RPC clients before initialize", async () => {
  let clientCalls = 0;
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('{"answer":"hello Ada"}'),
    clientFactory: (options) => {
      clientCalls += 1;
      return clientCalls === 1
        ? { initialize() {} }
        : new FakeCamlFlowClient(options);
    },
  });

  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
      }),
    /JSON-RPC client must provide initialize, run, and shutdownAndExit/,
  );

  const result = await host.runWorkflow({
    workflowPath: "examples/basic/main.cml",
  });
  assert.equal(result.runId, "run-1");
  assert.equal(clientCalls, 2);
});

test("host session rejects malformed JSON-RPC initialize results before run", async () => {
  const invalidResults = [
    null,
    {
      protocolVersion: "",
      irVersion: "0.1.0",
      capabilities: {},
      effectKinds: [],
    },
    {
      protocolVersion: "0.1.0",
      irVersion: "0.1.0",
      capabilities: null,
      effectKinds: [],
    },
    {
      protocolVersion: "0.1.0",
      irVersion: "0.1.0",
      capabilities: {},
      effectKinds: [],
    },
    {
      protocolVersion: "0.1.0",
      irVersion: "0.1.0",
      capabilities: {
        check: true,
        compile: true,
        run: true,
        executeEffect: "yes",
        trace: true,
        diagnostic: true,
        progress: true,
        streaming: true,
        cancelRequest: true,
        renderedPrompt: true,
        outputSchema: true,
      },
      effectKinds: [],
    },
    {
      protocolVersion: "0.1.0",
      irVersion: "0.1.0",
      capabilities: createCamlFlowCapabilities(),
      effectKinds: ["unknown-effect"],
    },
    {
      protocolVersion: "0.1.0",
      irVersion: "0.1.0",
      capabilities: createCamlFlowCapabilities(),
      effectKinds: [],
      helper: () => undefined,
    },
    (() => {
      const result = {
        protocolVersion: "0.1.0",
        irVersion: "0.1.0",
        capabilities: createCamlFlowCapabilities(),
        effectKinds: [],
      };
      Object.defineProperty(result, "hidden", {
        enumerable: false,
        value: "not JSON-RPC",
      });
      return result;
    })(),
  ];

  for (const initializeResult of invalidResults) {
    let fakeClient;
    const host = createPiCamlFlowHostSession({
      runtime: createRuntime(),
      workerSessionFactory: async () => new FakeWorkerSession('{"answer":"hello Ada"}'),
      clientFactory: (options) => {
        fakeClient = new FakeCamlFlowClient(options);
        fakeClient.initialize = async () => {
          fakeClient.initializeCalled = true;
          return initializeResult;
        };
        return fakeClient;
      },
    });

    await assert.rejects(
      () =>
        host.runWorkflow({
          workflowPath: "examples/basic/main.cml",
        }),
      /JSON-RPC initialize result/,
    );
    assert.equal(fakeClient.initializeCalled, true);
    assert.equal(fakeClient.runCalled, false);
    assert.equal(fakeClient.shutdownCalled, true);
  }
});

test("host session rejects malformed JSON-RPC run results after shutdown", async () => {
  const invalidResults = [
    null,
    {
      runId: "",
      stepsRun: 1,
      output: {},
    },
    {
      runId: "run-1",
      stepsRun: -1,
      output: {},
    },
    {
      runId: "run-1",
      stepsRun: 1,
      output: Number.NaN,
    },
    {
      runId: "run-1",
      stepsRun: 1,
      output: {},
      helper: () => undefined,
    },
    (() => {
      const result = {
        runId: "run-1",
        stepsRun: 1,
        output: {},
      };
      result[Symbol("metadata")] = "not JSON-RPC";
      return result;
    })(),
  ];

  for (const runResult of invalidResults) {
    let fakeClient;
    const host = createPiCamlFlowHostSession({
      runtime: createRuntime(),
      workerSessionFactory: async () => new FakeWorkerSession('{"answer":"hello Ada"}'),
      clientFactory: (options) => {
        fakeClient = new FakeCamlFlowClient(options);
        fakeClient.run = async () => {
          fakeClient.runCalled = true;
          return runResult;
        };
        return fakeClient;
      },
    });

    await assert.rejects(
      () =>
        host.runWorkflow({
          workflowPath: "examples/basic/main.cml",
        }),
      /JSON-RPC run result/,
    );
    assert.equal(fakeClient.initializeCalled, true);
    assert.equal(fakeClient.runCalled, true);
    assert.equal(fakeClient.shutdownCalled, true);
  }
});

test("host session validates JSON-RPC notifications before host callbacks", async () => {
  let spawnOptions;
  let traceCalls = 0;
  let diagnosticCalls = 0;
  let progressCalls = 0;
  let outputChunkCalls = 0;
  let lastTrace;
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('{"answer":"hello Ada"}'),
    onTrace: async (trace) => {
      traceCalls += 1;
      lastTrace = trace;
    },
    onDiagnostic: async () => {
      diagnosticCalls += 1;
    },
    onProgress: async () => {
      progressCalls += 1;
    },
    onOutputChunk: async () => {
      outputChunkCalls += 1;
    },
    clientFactory: (options) => {
      spawnOptions = options;
      return new FakeCamlFlowClient(options);
    },
  });

  await host.runWorkflow({
    workflowPath: "examples/basic/main.cml",
  });
  const validOutputChunkCalls = outputChunkCalls;
  assert.ok(validOutputChunkCalls > 0);

  const trace = createTraceNotification();
  await spawnOptions.onTrace(trace, createJsonRpcNotification("camlflow/trace", trace));
  assert.equal(traceCalls, 1);
  assert.equal(lastTrace.runId, "run-1");

  const envelopeTrace = createTraceNotification({ runId: "envelope-run" });
  await spawnOptions.onTrace(
    createTraceNotification({ runId: "argument-run" }),
    createJsonRpcNotification("camlflow/trace", envelopeTrace),
  );
  assert.equal(traceCalls, 2);
  assert.equal(lastTrace.runId, "envelope-run");

  await assert.rejects(
    () =>
      spawnOptions.onTrace(
        { ...createTraceNotification(), event: "unknown" },
        createJsonRpcNotification("camlflow/trace", createTraceNotification()),
      ),
    /trace params event/,
  );
  await assert.rejects(
    () =>
      spawnOptions.onTrace(
        createTraceNotification(),
        createJsonRpcNotification("wrong/method", createTraceNotification()),
      ),
    /method must be camlflow\/trace/,
  );
  await assert.rejects(
    () =>
      spawnOptions.onTrace(
        createTraceNotification(),
        createJsonRpcNotification("camlflow/trace", {
          ...createTraceNotification(),
          step: -1,
        }),
      ),
    /trace params step/,
  );

  await assert.rejects(
    () =>
      spawnOptions.onDiagnostic(
        { ...createDiagnosticNotification(), severity: "warning" },
        createJsonRpcNotification(
          "camlflow/diagnostic",
          createDiagnosticNotification(),
        ),
      ),
    /diagnostic params severity/,
  );
  await assert.rejects(
    () =>
      spawnOptions.onDiagnostic(createDiagnosticNotification(), {
        jsonrpc: "2.0",
        method: "camlflow/diagnostic",
      }),
    /diagnostic notification params must be present/,
  );
  assert.equal(diagnosticCalls, 0);

  await assert.rejects(
    () =>
      spawnOptions.onProgress(
        { ...createProgressNotification(), cancellable: "yes" },
        createJsonRpcNotification("camlflow/progress", createProgressNotification()),
      ),
    /progress params cancellable/,
  );
  await assert.rejects(
    () =>
      spawnOptions.onProgress(
        createProgressNotification(),
        createJsonRpcNotification("camlflow/progress", {
          ...createProgressNotification(),
          knownSteps: -1,
        }),
      ),
    /progress params knownSteps/,
  );
  assert.equal(progressCalls, 0);

  await assert.rejects(
    () =>
      spawnOptions.onOutputChunk(
        { ...createOutputChunkNotification(), done: "yes" },
        createJsonRpcNotification("camlflow/outputChunk", createOutputChunkNotification()),
    ),
    /outputChunk params done/,
  );
  await assert.rejects(
    () =>
      spawnOptions.onOutputChunk(
        createOutputChunkNotification(),
        createJsonRpcNotification("camlflow/outputChunk", {
          ...createOutputChunkNotification(),
          streamId: "",
        }),
      ),
    /outputChunk params streamId/,
  );
  assert.equal(outputChunkCalls, validOutputChunkCalls);
});

test("host session validates executeEffect params before worker creation", async () => {
  const paramsWithHiddenProperty = createExecuteEffectParams();
  Object.defineProperty(paramsWithHiddenProperty, "hidden", {
    enumerable: false,
    value: "not json-rpc",
  });
  const cases = [
    null,
    {
      runId: "run-1",
      step: 1,
    },
    createExecuteEffectParams({ step: -1 }),
    createExecuteEffectParams({ effect: { kind: "unknown-effect" } }),
    createExecuteEffectParams({ effect: { role: "tool" } }),
    createExecuteEffectParams({ effect: { name: "greeter\0" } }),
    createExecuteEffectParams({ effect: { declaredReturnType: "record\0" } }),
    createExecuteEffectParams({ effect: { kind: "bound-agent", role: "skill" } }),
    createExecuteEffectParams({ effect: { kind: "bound-skill", role: "agent" } }),
    createExecuteEffectParams({
      effect: { kind: "local-prompt-skill", role: "agent" },
    }),
    createExecuteEffectParams({
      effect: {
        kind: "inline-agent",
        role: "skill",
        inlineDefinition: createInlineDefinition(),
      },
    }),
    createExecuteEffectParams({ effect: { runId: "other-run" } }),
    createExecuteEffectParams({ effect: { step: 2 } }),
    createExecuteEffectParams({ effect: { unsupportedSettings: "temperature" } }),
    createExecuteEffectParams({ effect: { unsupportedSettings: [""] } }),
    createExecuteEffectParams({ effect: { inlineDefinition: [] } }),
    createExecuteEffectParams({ effect: { kind: "inline-agent", inlineDefinition: null } }),
    createExecuteEffectParams({
      effect: { kind: "bound-agent", inlineDefinition: createInlineDefinition() },
    }),
    createExecuteEffectParams({
      effect: { inlineDefinition: createInlineDefinition({ model: 42 }) },
    }),
    createExecuteEffectParams({
      effect: { inlineDefinition: createInlineDefinition({ temperature: "warm" }) },
    }),
    createExecuteEffectParams({
      effect: { inlineDefinition: createInlineDefinition({ system_prompt: 42 }) },
    }),
    createExecuteEffectParams({
      effect: { inlineDefinition: createInlineDefinition({ metadata: "tone" }) },
    }),
    createExecuteEffectParams({
      effect: {
        inlineDefinition: createInlineDefinition({
          metadata: [{ name: "", value: { kind: "unit" } }],
        }),
      },
    }),
    createExecuteEffectParams({
      effect: {
        inlineDefinition: createInlineDefinition({
          metadata: [{ name: "tone\0", value: { kind: "unit" } }],
        }),
      },
    }),
    createExecuteEffectParams({
      effect: {
        inlineDefinition: createInlineDefinition({
          metadata: [{ name: "tone", value: { kind: "list", value: [] } }],
        }),
      },
    }),
    createExecuteEffectParams({
      effect: {
        inlineDefinition: createInlineDefinition({
          metadata: [{ name: "tries", value: { kind: "int", value: 1.2 } }],
        }),
      },
    }),
    createExecuteEffectParams({
      effect: {
        inlineDefinition: createInlineDefinition({
          metadata: [{ name: "marker", value: { kind: "unit", value: null } }],
        }),
      },
    }),
    createExecuteEffectParams({
      effect: { inlineDefinition: createInlineDefinition({ loc: { file: "x" } }) },
    }),
    createExecuteEffectParams({
      effect: {
        inlineDefinition: createInlineDefinition({
          loc: createLocation({ start: { line: -1, column: 0, offset: 0 } }),
        }),
      },
    }),
    createExecuteEffectParams({
      effect: {
        inlineDefinition: createInlineDefinition({
          loc: createLocation({ file: "bad\0file.cml" }),
        }),
      },
    }),
    createExecuteEffectParams({ effect: { outputSchema: [] } }),
    createExecuteEffectParams({ effect: { renderedPrompt: "" } }),
    createExecuteEffectParams({ effect: { input: Number.NaN } }),
    paramsWithHiddenProperty,
  ];

  for (const params of cases) {
    let fakeClient;
    let workerCreated = false;
    const host = createPiCamlFlowHostSession({
      runtime: createRuntime(),
      workerSessionFactory: async () => {
        workerCreated = true;
        return new FakeWorkerSession('{"answer":"unreachable"}');
      },
      clientFactory: (options) => {
        fakeClient = new FakeCamlFlowClient(options);
        fakeClient.run = async (_runParams, runOptions) => {
          fakeClient.runCalled = true;
          await fakeClient.options.effectHandler(
            params,
            {
              jsonrpc: "2.0",
              id: 1,
              method: "camlflow/executeEffect",
              params,
            },
            {
              emitOutputChunk: async () => undefined,
            },
          );
          return {
            runId: "run-1",
            stepsRun: 1,
            output: {},
          };
        };
        return fakeClient;
      },
    });

    await assert.rejects(
      () =>
        host.runWorkflow({
          workflowPath: "examples/basic/main.cml",
        }),
      /executeEffect request|executeEffect params|effect name|effect declaredReturnType|effect renderedPrompt|effect input|effect outputSchema|metadata must match|unsupportedSettings/,
    );
    assert.equal(fakeClient.runCalled, true);
    assert.equal(workerCreated, false);
    assert.equal(fakeClient.shutdownCalled, true);
  }
});

test("host session validates executeEffect request ids before worker creation", async () => {
  let fakeClient;
  let workerCreated = false;
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async () => {
      workerCreated = true;
      return new FakeWorkerSession('{"answer":"unreachable"}');
    },
    clientFactory: (options) => {
      fakeClient = new FakeCamlFlowClient(options);
      fakeClient.run = async () => {
        await fakeClient.options.effectHandler(
          createExecuteEffectParams(),
          {
            jsonrpc: "2.0",
            id: 1.5,
            method: "camlflow/executeEffect",
            params: createExecuteEffectParams(),
          },
          {
            emitOutputChunk: async () => undefined,
          },
        );
        return {
          runId: "run-1",
          stepsRun: 1,
          output: {},
        };
      };
      return fakeClient;
    },
  });

  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
      }),
    /executeEffect request id must be a string or integer number/,
  );
  assert.equal(workerCreated, false);
  assert.equal(fakeClient.shutdownCalled, true);
});

test("host session accepts shaped inline executeEffect definitions", async () => {
  let workerCreated = false;
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async () => {
      workerCreated = true;
      return new FakeWorkerSession('{"answer":"inline ok"}');
    },
    clientFactory: (options) => {
      const fakeClient = new FakeCamlFlowClient(options);
      fakeClient.run = async () => {
        const effectResult = await fakeClient.options.effectHandler(
          createExecuteEffectParams({
            effect: {
              kind: "inline-agent",
              inlineDefinition: createInlineDefinition(),
            },
          }),
          {
            jsonrpc: "2.0",
            id: 1,
            method: "camlflow/executeEffect",
            params: createExecuteEffectParams({
              effect: {
                kind: "inline-agent",
                inlineDefinition: createInlineDefinition(),
              },
            }),
          },
          {
            emitOutputChunk: async () => undefined,
          },
        );
        return {
          runId: "run-1",
          stepsRun: 1,
          output: effectResult.output,
        };
      };
      return fakeClient;
    },
  });

  const result = await host.runWorkflow({
    workflowPath: "examples/basic/main.cml",
  });

  assert.equal(workerCreated, true);
  assert.deepEqual(result.output, { answer: "inline ok" });
});

test("host session uses executeEffect request params over injected callback args", async () => {
  let workerInput;
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async (request) => {
      workerInput = request.input;
      return new FakeWorkerSession('{"answer":"from envelope"}');
    },
    clientFactory: (options) => {
      const fakeClient = new FakeCamlFlowClient(options);
      fakeClient.run = async () => {
        const effectResult = await fakeClient.options.effectHandler(
          createExecuteEffectParams({
            effect: {
              input: { source: "argument" },
            },
          }),
          {
            jsonrpc: "2.0",
            id: "run-effect-1",
            method: "camlflow/executeEffect",
            params: createExecuteEffectParams({
              effect: {
                input: { source: "envelope" },
              },
            }),
          },
          {
            emitOutputChunk: async () => undefined,
          },
        );
        return {
          runId: "run-1",
          stepsRun: 1,
          output: effectResult.output,
        };
      };
      return fakeClient;
    },
  });

  const result = await host.runWorkflow({
    workflowPath: "examples/basic/main.cml",
  });

  assert.deepEqual(workerInput, { source: "envelope" });
  assert.deepEqual(result.output, { answer: "from envelope" });
});

test("host session validates executeEffect context before worker creation", async () => {
  for (const context of [null, {}, { emitOutputChunk: {} }]) {
    let fakeClient;
    let workerCreated = false;
    const host = createPiCamlFlowHostSession({
      runtime: createRuntime(),
      workerSessionFactory: async () => {
        workerCreated = true;
        return new FakeWorkerSession('{"answer":"unreachable"}');
      },
      clientFactory: (options) => {
        fakeClient = new FakeCamlFlowClient(options);
        fakeClient.run = async () => {
          await fakeClient.options.effectHandler(
            createExecuteEffectParams(),
            {
              jsonrpc: "2.0",
              id: 1,
              method: "camlflow/executeEffect",
              params: createExecuteEffectParams(),
            },
            context,
          );
          return {
            runId: "run-1",
            stepsRun: 1,
            output: {},
          };
        };
        return fakeClient;
      },
    });

    await assert.rejects(
      () =>
        host.runWorkflow({
          workflowPath: "examples/basic/main.cml",
        }),
      /executeEffect context must provide emitOutputChunk/,
    );
    assert.equal(workerCreated, false);
    assert.equal(fakeClient.shutdownCalled, true);
  }
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

test("host session rejects empty workflow paths before spawning a client", async () => {
  let clientCreated = false;
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("{}"),
    clientFactory: (options) => {
      clientCreated = true;
      return new FakeCamlFlowClient(options);
    },
  });

  await assert.rejects(
    () => host.runWorkflow({ workflowPath: " \n\t " }),
    /workflowPath must not be empty/,
  );
  await assert.rejects(
    () => host.runWorkflow({}),
    /workflowPath must not be empty/,
  );
  assert.equal(clientCreated, false);
});

test("host session rejects empty workflow path options before spawning a client", async () => {
  let clientCreated = false;
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("{}"),
    clientFactory: (options) => {
      clientCreated = true;
      return new FakeCamlFlowClient(options);
    },
  });

  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        entrypoint: "\t",
      }),
    /entrypoint must not be empty/,
  );
  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        entrypoint: 42,
      }),
    /entrypoint must not be empty/,
  );
  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        skillsDir: " ",
      }),
    /skillsDir must not be empty/,
  );
  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        skillsDir: 42,
      }),
    /skillsDir must not be empty/,
  );
  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        includePaths: ["lib", "\n"],
      }),
    /includePaths must not contain empty paths/,
  );
  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        includePaths: "lib",
      }),
    /includePaths must be an array/,
  );
  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        includePaths: ["lib", 42],
      }),
    /includePaths must not contain empty paths/,
  );
  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "bad\0workflow.cml",
      }),
    /workflowPath must not contain NUL bytes/,
  );
  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        entrypoint: "bad\0entry",
      }),
    /entrypoint must not contain NUL bytes/,
  );
  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        skillsDir: "bad\0skills",
      }),
    /skillsDir must not contain NUL bytes/,
  );
  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        includePaths: ["bad\0include"],
      }),
    /includePaths entry must not contain NUL bytes/,
  );
  await assert.rejects(
    () => host.runWorkflow(null),
    /workflow options must be an object/,
  );
  await assert.rejects(
    () => host.runWorkflow([]),
    /workflow options must be an object/,
  );
  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        signal: { aborted: false },
      }),
    /workflow signal must be an AbortSignal/,
  );
  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        input: { value: Number.POSITIVE_INFINITY },
      }),
    /workflow input must be JSON serializable/,
  );
  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        input: new Map(),
      }),
    /workflow input must be JSON serializable/,
  );
  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        input: Object.defineProperty({ visible: true }, "hidden", {
          value: true,
          enumerable: false,
        }),
      }),
    /workflow input must be JSON serializable/,
  );
  assert.equal(clientCreated, false);
});

test("host session rejects pre-aborted workflow signals before spawning a client", async () => {
  let clientCreated = false;
  const controller = new AbortController();
  controller.abort();
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("{}"),
    clientFactory: (options) => {
      clientCreated = true;
      return new FakeCamlFlowClient(options);
    },
  });

  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        signal: controller.signal,
      }),
    /CamlFlow effect cancelled/,
  );
  assert.equal(clientCreated, false);
});

test("host session rejects signals aborted during client creation before initialize", async () => {
  const controller = new AbortController();
  let fakeClient;
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("{}"),
    clientFactory: (options) => {
      fakeClient = new FakeCamlFlowClient(options);
      controller.abort();
      return fakeClient;
    },
  });

  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        signal: controller.signal,
      }),
    /CamlFlow effect cancelled/,
  );
  assert.equal(fakeClient.initializeCalled, false);
  assert.equal(fakeClient.runCalled, false);
  assert.equal(fakeClient.shutdownCalled, true);
});

test("host session removes external abort listeners after workflow completion", async () => {
  const controller = new AbortController();
  const abortListeners = countAbortSignalListeners(controller.signal);
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('{"answer":"hello"}'),
    clientFactory: (options) => new FakeCamlFlowClient(options),
  });

  await host.runWorkflow({
    workflowPath: "examples/basic/main.cml",
    signal: controller.signal,
  });

  assert.equal(abortListeners.added, 1);
  assert.equal(abortListeners.removed, 1);
});

test("host session clears active runs and shuts down when abort listener cleanup fails", async () => {
  const controller = new AbortController();
  controller.signal.removeEventListener = () => {
    throw new Error("remove listener failed");
  };
  const clients = [];
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('{"answer":"hello"}'),
    clientFactory: (options) => {
      const client = new FakeCamlFlowClient(options);
      clients.push(client);
      return client;
    },
  });

  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
        signal: controller.signal,
      }),
    /remove listener failed/,
  );
  assert.equal(clients[0].shutdownCalled, true);

  const result = await host.runWorkflow({
    workflowPath: "examples/basic/main.cml",
  });

  assert.deepEqual(result.output, { answer: "hello" });
  assert.equal(clients.length, 2);
  assert.equal(clients[1].shutdownCalled, true);
});

test("host session reports shutdown failures after successful workflow runs", async () => {
  let fakeClient;
  let clientCalls = 0;
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('{"answer":"hello"}'),
    clientFactory: (options) => {
      clientCalls += 1;
      fakeClient = new FakeCamlFlowClient(options);
      if (clientCalls === 1) {
        fakeClient.shutdownError = new Error("shutdown failed");
      }
      return fakeClient;
    },
  });

  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
      }),
    /shutdown failed/,
  );
  assert.equal(fakeClient.shutdownCalled, true);

  const result = await host.runWorkflow({
    workflowPath: "examples/basic/main.cml",
  });

  assert.deepEqual(result.output, { answer: "hello" });
});

test("host session preserves run failures when shutdown also fails", async () => {
  let fakeClient;
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("not json"),
    clientFactory: (options) => {
      fakeClient = new FakeCamlFlowClient(options);
      fakeClient.shutdownError = new Error("shutdown failed");
      return fakeClient;
    },
  });

  await assert.rejects(
    () =>
      host.runWorkflow({
        workflowPath: "examples/basic/main.cml",
      }),
    /CamlFlow effect returned invalid JSON/,
  );
  assert.equal(fakeClient.shutdownCalled, true);
});

test("host session honors autoShutdown false after successful workflow runs", async () => {
  let fakeClient;
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('{"answer":"hello"}'),
    autoShutdown: false,
    clientFactory: (options) => {
      fakeClient = new FakeCamlFlowClient(options);
      return fakeClient;
    },
  });

  const result = await host.runWorkflow({
    workflowPath: "examples/basic/main.cml",
  });

  assert.deepEqual(result.output, { answer: "hello" });
  assert.equal(fakeClient.shutdownCalled, false);
});

test("host session cancel suppresses shutdown failures while aborting the run", async () => {
  let fakeClient;
  const host = createPiCamlFlowHostSession({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("{}"),
    clientFactory: (options) => {
      fakeClient = new HangingCamlFlowClient(options);
      fakeClient.shutdownError = new Error("shutdown failed");
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

test("host session cancel is idempotent while a run is still settling", async () => {
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
  await host.cancel();

  await assert.rejects(pending, /cancelled/);
  assert.equal(fakeClient.shutdownCalls, 2);
});

test("Flue-style harness prompt returns text or parsed JSON from a Pi session", async () => {
  const prompts = [];
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => {
      const session = new FakeWorkerSession('{"translation":"salut","confidence":"high"}');
      const originalPrompt = session.prompt.bind(session);
      session.prompt = async (text, options) => {
        prompts.push({ text, options });
        await originalPrompt(text, options);
      };
      return session;
    },
  });

  const agent = await harness.init({ id: "hello", sandbox: "local" });
  const session = await agent.session("session-1");
  const result = await session.prompt("Translate hello.", { result: "json" });
  await session.close();

  assert.deepEqual(result, { translation: "salut", confidence: "high" });
  assert.equal(agent.id, "hello");
  assert.equal(session.id, "hello:session-1");
  assert.equal(prompts[0].text, "Translate hello.");
  assert.equal(prompts[0].options.expandPromptTemplates, true);
});

test("Flue-style harness validates init cwd, id, and named model options", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"unreachable"'),
  });

  await assert.rejects(
    () => harness.init({ cwd: " " }),
    /agent cwd must not be empty/,
  );
  await assert.rejects(
    () => harness.init({ cwd: "bad\0cwd" }),
    /agent cwd must not contain NUL bytes/,
  );
  await assert.rejects(
    () => harness.init({ id: "\n" }),
    /agent id must not be empty/,
  );
  await assert.rejects(
    () => harness.init({ id: "bad\0id" }),
    /agent id must not contain NUL bytes/,
  );
  await assert.rejects(
    () => harness.init({ model: " " }),
    /agent model must not be empty/,
  );
  await assert.rejects(
    () => harness.init({ model: "bad\0model" }),
    /agent model must not contain NUL bytes/,
  );
  await assert.rejects(
    () => harness.init({ model: {} }),
    /agent model provider must not be empty/,
  );
  await assert.rejects(
    () => harness.init({ thinkingLevel: 42 }),
    /agent thinkingLevel must be a string/,
  );
  await assert.rejects(
    () => harness.init({ model: "faux/missing" }),
    PiCamlFlowMissingModelError,
  );

  const agent = await harness.init({ model: "faux/model" });
  const session = await agent.session();
  await session.close();
  await agent.close();
});

test("Flue-style harness rejects malformed injected worker sessions", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => ({
      prompt: async () => undefined,
      subscribe: () => () => undefined,
      abort: async () => undefined,
      dispose: () => undefined,
    }),
  });

  const agent = await harness.init();
  await assert.rejects(
    () => agent.session(),
    /harness worker session must provide a messages array/,
  );
  await agent.close();
});

test("Flue-style harness skill call expands to a Pi skill command with JSON args", async () => {
  let promptText = "";
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => {
      const session = new FakeWorkerSession('"done"');
      const originalPrompt = session.prompt.bind(session);
      session.prompt = async (text, options) => {
        promptText = text;
        await originalPrompt(text, options);
      };
      return session;
    },
  });

  const agent = await harness.init();
  const session = await agent.session();
  const result = await session.skill("triage", {
    args: { issueNumber: 42 },
    result: "json",
  });
  await session.close();

  assert.equal(result, "done");
  assert.match(promptText, /^\/skill:triage /);
  assert.match(promptText, /"issueNumber": 42/);
});

test("Flue-style harness rejects non-serializable skill args before prompting", async () => {
  const circularArgs = {};
  circularArgs.self = circularArgs;
  let promptCalled = false;
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => {
      const session = new FakeWorkerSession('"unreachable"');
      session.prompt = async () => {
        promptCalled = true;
      };
      return session;
    },
  });
  const agent = await harness.init();
  const session = await agent.session();

  await assert.rejects(
    () => session.skill("triage", { args: circularArgs }),
    /Pi skill args must be JSON serializable/,
  );
  await assert.rejects(
    () => session.skill("triage", { args: { value: Number.NaN } }),
    /Pi skill args must be JSON serializable/,
  );
  await assert.rejects(
    () => session.skill("triage", { args: { value: () => undefined } }),
    /Pi skill args must be JSON serializable/,
  );
  await assert.rejects(
    () => session.skill("triage", { args: [, "hole"] }),
    /Pi skill args must be JSON serializable/,
  );
  const extraArrayArgs = ["item"];
  extraArrayArgs.extra = "hidden";
  await assert.rejects(
    () => session.skill("triage", { args: extraArrayArgs }),
    /Pi skill args must be JSON serializable/,
  );
  assert.equal(promptCalled, false);
  await agent.close();
});

test("Flue-style harness rejects invalid Pi skill names", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"unreachable"'),
  });
  const agent = await harness.init();
  const session = await agent.session();

  const longName = "a".repeat(65);
  for (const name of [
    "",
    longName,
    "Bad",
    "bad name",
    "bad\n/skill:other",
    "-bad",
    "bad-",
    "bad--name",
    42,
  ]) {
    await assert.rejects(
      () => session.skill(name),
      /Invalid Pi skill name/,
    );
  }
  await agent.close();
});

test("Flue-style harness rejects empty prompt and task text", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"unreachable"'),
  });
  const agent = await harness.init();
  const session = await agent.session();

  await assert.rejects(() => session.prompt(" \n\t "), /prompt text must not be empty/);
  await assert.rejects(() => session.prompt(42), /prompt text must not be empty/);
  await assert.rejects(() => session.task(""), /prompt text must not be empty/);
  await assert.rejects(() => session.task(42), /prompt text must not be empty/);
  await agent.close();
});

test("Flue-style harness rejects malformed prompt, task, skill, and session options", async () => {
  let workerCreated = false;
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => {
      workerCreated = true;
      return new FakeWorkerSession('"unreachable"');
    },
  });
  const agent = await harness.init();

  await assert.rejects(() => agent.session(" "), /session id must not be empty/);
  assert.equal(workerCreated, false);

  const session = await agent.session();
  await assert.rejects(
    () => session.prompt("Hello", null),
    /prompt options must be an object/,
  );
  await assert.rejects(
    () => session.prompt("Hello", []),
    /prompt options must be an object/,
  );
  await assert.rejects(
    () => session.prompt("Hello", { signal: { aborted: false } }),
    /prompt options signal must be an AbortSignal/,
  );
  await assert.rejects(
    () => session.task("Hello", null),
    /task options must be an object/,
  );
  await assert.rejects(
    () => session.task("Hello", []),
    /task options must be an object/,
  );
  await assert.rejects(
    () => session.skill("triage", null),
    /skill options must be an object/,
  );
  await assert.rejects(
    () => session.skill("triage", []),
    /skill options must be an object/,
  );
  await assert.rejects(
    () => session.skill("triage", { signal: { aborted: false } }),
    /skill options signal must be an AbortSignal/,
  );
  await agent.close();
});

test("Flue-style harness accepts parse and safeParse result schemas", async () => {
  let call = 0;
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => {
      const session = new FakeWorkerSession('{"answer":"schema"}');
      const originalPrompt = session.prompt.bind(session);
      session.prompt = async (text, options) => {
        const outputs = [
          '{"answer":"schema"}',
          '{"answer":"zod"}',
          '{"answer":"pi"}',
          '{"answer":"callback"}',
        ];
        session.outputText = outputs[call++];
        await originalPrompt(text, options);
      };
      return session;
    },
  });
  const agent = await harness.init();
  const session = await agent.session();

  const parsed = await session.prompt("Parse this.", {
    result: {
      parse(value) {
        return value.answer.toUpperCase();
      },
    },
  });
  const safeParsed = await session.prompt("Safe parse this.", {
    result: {
      safeParse(value) {
        return { success: true, data: value.answer };
      },
    },
  });
  const outputParsed = await session.prompt("Safe parse this to output.", {
    result: {
      safeParse(value) {
        return { success: true, output: value.answer };
      },
    },
  });
  const callbackParsed = await session.prompt("Callback parse this.", {
    result: (value) => value.answer,
  });
  await session.close();

  assert.equal(parsed, "SCHEMA");
  assert.equal(safeParsed, "zod");
  assert.equal(outputParsed, "pi");
  assert.equal(callbackParsed, "callback");
});

test("Flue-style harness returns raw assistant text by default", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("plain text"),
  });
  const agent = await harness.init();
  const session = await agent.session();

  assert.equal(await session.prompt("Return text."), "plain text");
  await session.close();
});

test("Flue-style harness reports schema validation failures", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('{"answer":"bad"}'),
  });
  const agent = await harness.init();
  const session = await agent.session();

  await assert.rejects(
    () =>
      session.prompt("Validate this.", {
        result: {
          safeParse() {
            return { success: false, error: new Error("answer must be number") };
          },
        },
      }),
    /answer must be number/,
  );
  await session.close();
});

test("Flue-style harness reports invalid JSON result parsing failures", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("not json"),
  });
  const agent = await harness.init();
  const session = await agent.session();

  await assert.rejects(
    () => session.prompt("Return JSON.", { result: "json" }),
    /CamlFlow effect returned invalid JSON/,
  );
  await agent.close();
});

test("Flue-style harness propagates custom parser failures", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('{"answer":"bad"}'),
  });
  const agent = await harness.init();
  const session = await agent.session();

  await assert.rejects(
    () =>
      session.prompt("Parse with callback.", {
        result: () => {
          throw new Error("callback parser failed");
        },
      }),
    /callback parser failed/,
  );
  await agent.close();
});

test("Flue-style harness rejects invalid result parser shapes", async () => {
  const cases = [
    {
      result: "xml",
      message: /result parser must be/,
    },
    {
      result: {},
      message: /result parser must be/,
    },
    {
      result: { parse: true },
      message: /result parser parse must be a function/,
    },
    {
      result: { safeParse: () => ({ success: true }) },
      message: /success must include output or data/,
    },
    {
      result: { safeParse: () => ({ success: "yes" }) },
      message: /safeParse must return a success result/,
    },
  ];

  for (const { result, message } of cases) {
    const harness = createPiCamlFlowHarness({
      runtime: createRuntime(),
      workerSessionFactory: async () => new FakeWorkerSession('{"answer":"ok"}'),
    });
    const agent = await harness.init();
    const session = await agent.session();

    await assert.rejects(
      () => session.prompt("Parse with invalid parser.", { result }),
      message,
    );
    await agent.close();
  }
});

test("Flue-style harness rejects malformed result parser options before prompting", async () => {
  const cases = [
    { result: null, message: /result parser must be/ },
    { result: false, message: /result parser must be/ },
    { result: [], message: /result parser must be/ },
    { result: {}, message: /result parser must be/ },
    { result: { parse: true }, message: /result parser parse must be a function/ },
  ];

  for (const { result, message } of cases) {
    let promptCalled = false;
    const harness = createPiCamlFlowHarness({
      runtime: createRuntime(),
      workerSessionFactory: async () => {
        const session = new FakeWorkerSession('{"answer":"ok"}');
        session.prompt = async () => {
          promptCalled = true;
        };
        return session;
      },
    });
    const agent = await harness.init();
    const session = await agent.session();

    await assert.rejects(
      () => session.prompt("Parse with invalid parser.", { result }),
      message,
    );
    assert.equal(promptCalled, false);
    await agent.close();
  }
});

test("Flue-style harness does not reuse stale assistant output", async () => {
  let promptCount = 0;
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => {
      const session = new FakeWorkerSession('"first"');
      const originalPrompt = session.prompt.bind(session);
      session.prompt = async (text, options) => {
        promptCount += 1;
        if (promptCount === 1) {
          await originalPrompt(text, options);
        }
      };
      return session;
    },
  });
  const agent = await harness.init();
  const session = await agent.session();

  assert.equal(await session.prompt("First prompt.", { result: "json" }), "first");
  await assert.rejects(
    () => session.prompt("Second prompt."),
    /produced no assistant message/,
  );
  await session.close();
});

test("Flue-style harness rejects malformed latest assistant output", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => {
      const session = new FakeWorkerSession('"first"');
      const originalPrompt = session.prompt.bind(session);
      session.prompt = async (text, options) => {
        await originalPrompt(text, options);
        session.messages.push({
          role: "assistant",
          content: "malformed",
          stopReason: "stop",
        });
      };
      return session;
    },
  });
  const agent = await harness.init();
  const session = await agent.session();

  await assert.rejects(
    () => session.prompt("Return text."),
    /assistant message content must be an array/,
  );
  await agent.close();
});

test("Flue-style harness rejects malformed assistant status fields", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => {
      const session = new FakeWorkerSession('"unreachable"');
      session.prompt = async () => {
        session.messages.push({
          role: "assistant",
          content: [{ type: "text", text: '"unreachable"' }],
          stopReason: "error",
          errorMessage: { message: "boom" },
        });
      };
      return session;
    },
  });
  const agent = await harness.init();
  const session = await agent.session();

  await assert.rejects(
    () => session.prompt("Hello."),
    /assistant message errorMessage must be a string/,
  );
  await session.close();
  await agent.close();
});

test("Flue-style harness rejects overlapping prompts in one session", async () => {
  const worker = new FakeWorkerSession('"done"');
  worker.waitForAbort = true;
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => worker,
  });
  const agent = await harness.init();
  const session = await agent.session();

  const pendingPrompt = session.prompt("Slow prompt.");
  await worker.promptStarted;

  await assert.rejects(
    () => session.prompt("Overlapping prompt."),
    /already has an active prompt/,
  );
  await session.abort();
  await assert.rejects(pendingPrompt, /CamlFlow effect cancelled/);
  await agent.close();
});

test("Flue-style harness prompt honors external abort signals", async () => {
  const worker = new FakeWorkerSession('"done"');
  worker.waitForAbort = true;
  const controller = new AbortController();
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => worker,
  });
  const agent = await harness.init();
  const session = await agent.session();

  const pendingPrompt = session.prompt("Abort this prompt.", {
    signal: controller.signal,
  });
  await worker.promptStarted;
  controller.abort();

  await assert.rejects(pendingPrompt, /CamlFlow effect cancelled/);
  assert.equal(worker.abortCalled, true);
  await agent.close();
});

test("Flue-style harness prompt removes external abort listeners after completion", async () => {
  const controller = new AbortController();
  const abortListeners = countAbortSignalListeners(controller.signal);
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"done"'),
  });
  const agent = await harness.init();
  const session = await agent.session();

  assert.equal(
    await session.prompt("Complete this prompt.", {
      result: "json",
      signal: controller.signal,
    }),
    "done",
  );
  assert.equal(abortListeners.added, 1);
  assert.equal(abortListeners.removed, 1);
  await agent.close();
});

test("Flue-style harness prompt removes external abort listeners after failure", async () => {
  const controller = new AbortController();
  const abortListeners = countAbortSignalListeners(controller.signal);
  const worker = new FakeWorkerSession('"unreachable"');
  worker.prompt = async () => {
    throw new Error("prompt failed");
  };
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => worker,
  });
  const agent = await harness.init();
  const session = await agent.session();

  await assert.rejects(
    () => session.prompt("Fail this prompt.", { signal: controller.signal }),
    /prompt failed/,
  );
  assert.equal(abortListeners.added, 1);
  assert.equal(abortListeners.removed, 1);
  await agent.close();
});

test("Flue-style harness prompt preserves primary failures when listener cleanup fails", async () => {
  const controller = new AbortController();
  controller.signal.removeEventListener = () => {
    throw new Error("remove listener failed");
  };
  const worker = new FakeWorkerSession('"unreachable"');
  worker.prompt = async () => {
    throw new Error("prompt failed");
  };
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => worker,
  });
  const agent = await harness.init();
  const session = await agent.session();

  await assert.rejects(
    () => session.prompt("Fail cleanup prompt.", { signal: controller.signal }),
    /prompt failed/,
  );
  await agent.close();
});

test("Flue-style harness prompt reports listener cleanup failures after success", async () => {
  const controller = new AbortController();
  controller.signal.removeEventListener = () => {
    throw new Error("remove listener failed");
  };
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"done"'),
  });
  const agent = await harness.init();
  const session = await agent.session();

  await assert.rejects(
    () =>
      session.prompt("Successful prompt with cleanup failure.", {
        result: "json",
        signal: controller.signal,
      }),
    /remove listener failed/,
  );
  await agent.close();
});

test("session close waits for an active prompt to settle", async () => {
  let promptSettled = false;
  const worker = new FakeWorkerSession('"done"');
  worker.waitForAbort = true;
  const originalPrompt = worker.prompt.bind(worker);
  worker.prompt = async (text, options) => {
    await originalPrompt(text, options);
    promptSettled = true;
  };
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => worker,
  });
  const agent = await harness.init();
  const session = await agent.session();

  const pendingPrompt = session.prompt("Close while this prompt is active.");
  await worker.promptStarted;
  await session.close();

  assert.equal(worker.abortCalled, true);
  assert.equal(promptSettled, true);
  await assert.rejects(pendingPrompt, /CamlFlow effect cancelled/);
  await agent.close();
});

test("Flue-style harness task runs in a detached session sharing the sandbox", async () => {
  const created = [];
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async (_request, options) => {
      const session = new FakeWorkerSession(`"${options.cwd}:${created.length}"`);
      session.cwd = options.cwd;
      created.push(session);
      return session;
    },
  });
  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: "/virtual/tasks",
      tools: [],
    },
  });
  const session = await agent.session("main");

  const result = await session.task("Research independently.", { result: "json" });

  assert.equal(result, "/virtual/tasks:1");
  assert.equal(created.length, 2);
  assert.equal(created[0].disposeCalled, false);
  assert.equal(created[1].disposeCalled, true);
  assert.equal(session.cwd, "/virtual/tasks");
  await agent.close();
  assert.equal(created[0].disposeCalled, true);
});

test("Flue-style harness task reports child close failures after successful prompts", async () => {
  const parent = new FakeWorkerSession('"parent"');
  const child = new FakeWorkerSession('"task"');
  child.disposeError = new Error("task dispose failed");
  const workers = [parent, child];
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => workers.shift(),
  });
  const agent = await harness.init({ sandbox: "local" });
  const session = await agent.session("main");

  await assert.rejects(
    () => session.task("Task with cleanup failure.", { result: "json" }),
    /task dispose failed/,
  );
  assert.equal(child.disposeCalls, 1);

  await agent.close();
});

test("Flue-style harness task preserves prompt failures when child close fails", async () => {
  const parent = new FakeWorkerSession('"parent"');
  const child = new FakeWorkerSession("not json");
  child.disposeError = new Error("task dispose failed");
  const workers = [parent, child];
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => workers.shift(),
  });
  const agent = await harness.init({ sandbox: "local" });
  const session = await agent.session("main");

  await assert.rejects(
    () => session.task("Task with primary failure.", { result: "json" }),
    /CamlFlow effect returned invalid JSON/,
  );
  assert.equal(child.disposeCalls, 1);

  await agent.close();
});

test("local harness sandbox exposes trusted shell execution with stdin and env", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("ok"),
  });
  const agent = await harness.init({ cwd: process.cwd(), sandbox: "local" });
  const session = await agent.session();

  const result = await session.shell(
    "node -e \"process.stdin.pipe(process.stdout); console.error(process.env.CAMLFLOW_TEST)\"",
    {
      stdin: "hello",
      env: { CAMLFLOW_TEST: "sandbox" },
    },
  );
  await session.close();

  assert.equal(result.code, 0);
  assert.equal(result.stdout, "hello");
  assert.match(result.stderr, /sandbox/);
});

test("trusted shell rejects empty commands before invoking executors", async () => {
  let shellCalls = 0;
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("ok"),
  });
  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: process.cwd(),
      tools: [],
      shell: async () => {
        shellCalls += 1;
        return {
          code: 0,
          signal: null,
          stdout: "ran",
          stderr: "",
        };
      },
    },
  });
  const session = await agent.session();

  await assert.rejects(
    () => session.shell(" \n\t "),
    /shell command must not be empty/,
  );
  await assert.rejects(
    () => session.shell(42),
    /shell command must not be empty/,
  );
  assert.equal(shellCalls, 0);
  await agent.close();
});

test("trusted shell rejects invalid timeouts before invoking executors", async () => {
  let shellCalls = 0;
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("ok"),
  });
  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: process.cwd(),
      tools: [],
      shell: async () => {
        shellCalls += 1;
        return {
          code: 0,
          signal: null,
          stdout: "ran",
          stderr: "",
        };
      },
    },
  });
  const session = await agent.session();

  for (const timeoutMs of [-1, Number.POSITIVE_INFINITY, Number.NaN, "50"]) {
    await assert.rejects(
      () => session.shell("echo no", { timeoutMs }),
      /timeoutMs must be a finite non-negative number/,
    );
  }
  assert.equal(shellCalls, 0);
  await agent.close();
});

test("trusted shell rejects malformed option fields before invoking executors", async () => {
  let shellCalls = 0;
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("ok"),
  });
  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: process.cwd(),
      tools: [],
      shell: async () => {
        shellCalls += 1;
        return {
          code: 0,
          signal: null,
          stdout: "ran",
          stderr: "",
        };
      },
    },
  });
  const session = await agent.session();

  const hiddenEnv = { GOOD: "value" };
  Object.defineProperty(hiddenEnv, "HIDDEN", {
    enumerable: false,
    value: "secret",
  });
  const symbolEnv = { GOOD: "value" };
  symbolEnv[Symbol("SECRET")] = "secret";

  await assert.rejects(
    () => session.shell("echo no", null),
    /shell options must be an object/,
  );
  await assert.rejects(
    () => session.shell("echo no", []),
    /shell options must be an object/,
  );
  await assert.rejects(
    () => session.shell("echo no", { cwd: " " }),
    /shell cwd must not be empty/,
  );
  await assert.rejects(
    () => session.shell("echo no", { env: [] }),
    /shell env must be an object/,
  );
  await assert.rejects(
    () => session.shell("echo no", { env: new Date() }),
    /shell env must be a plain object/,
  );
  await assert.rejects(
    () => session.shell("echo no", { env: hiddenEnv }),
    /shell env.HIDDEN must be enumerable/,
  );
  await assert.rejects(
    () => session.shell("echo no", { env: symbolEnv }),
    /shell env must not contain symbol keys/,
  );
  await assert.rejects(
    () => session.shell("echo no", { env: { BAD: 42 } }),
    /shell env value for BAD must be a string or undefined/,
  );
  await assert.rejects(
    () => session.shell("echo no", { stdin: 42 }),
    /shell stdin must be a string/,
  );
  await assert.rejects(
    () => session.shell("echo no", { signal: { aborted: false } }),
    /shell signal must be an AbortSignal/,
  );
  await assert.rejects(
    () => session.shell("echo \0"),
    /shell command must not contain NUL bytes/,
  );
  await assert.rejects(
    () => session.shell("echo no", { cwd: "bad\0cwd" }),
    /shell cwd must not contain NUL bytes/,
  );
  await assert.rejects(
    () => session.shell("echo no", { env: { "BAD=NAME": "value" } }),
    /shell env names must not contain =/,
  );
  await assert.rejects(
    () => session.shell("echo no", { env: { BAD: "bad\0value" } }),
    /shell env value for BAD must not contain NUL bytes/,
  );
  await assert.rejects(
    () => session.shell("echo no", { stdin: "bad\0stdin" }),
    /shell stdin must not contain NUL bytes/,
  );
  assert.equal(shellCalls, 0);
  await agent.close();
});

test("trusted shell cwd cannot escape the sandbox root", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("ok"),
  });
  const agent = await harness.init({ cwd: process.cwd(), sandbox: "local" });
  const session = await agent.session();

  await assert.rejects(
    () => session.shell("pwd", { cwd: ".." }),
    /escapes sandbox root/,
  );
  await assert.rejects(
    () => session.shell("pwd", { cwd: "/tmp" }),
    /escapes sandbox root/,
  );
  await session.close();
  await agent.close();
});

test("local trusted shell blocks symlink cwd escapes", async () => {
  const root = await mkdtemp(join(tmpdir(), "camlflow-shell-root-"));
  const outside = await mkdtemp(join(tmpdir(), "camlflow-shell-outside-"));
  try {
    await symlink(outside, join(root, "escape"), "dir");
    const harness = createPiCamlFlowHarness({
      runtime: createRuntime(),
      workerSessionFactory: async () => new FakeWorkerSession("ok"),
    });
    const agent = await harness.init({ cwd: root, sandbox: "local" });
    const session = await agent.session();

    await assert.rejects(
      () => session.shell("pwd", { cwd: "escape" }),
      /escapes sandbox root/,
    );
    await agent.close();
  } finally {
    await rm(root, { recursive: true, force: true });
    await rm(outside, { recursive: true, force: true });
  }
});

test("local trusted shell reports missing cwd without poisoning the session", async () => {
  const root = await mkdtemp(join(tmpdir(), "camlflow-shell-missing-"));
  try {
    const harness = createPiCamlFlowHarness({
      runtime: createRuntime(),
      workerSessionFactory: async () => new FakeWorkerSession("ok"),
    });
    const agent = await harness.init({ cwd: root, sandbox: "local" });
    const session = await agent.session();

    await assert.rejects(
      () => session.shell("pwd", { cwd: "missing" }),
      /ENOENT|no such file or directory/,
    );
    const result = await session.shell("pwd");

    assert.equal(result.code, 0);
    assert.equal(result.stdout.trim(), root);
    await agent.close();
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("trusted shell timeout terminates the command", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("ok"),
  });
  const agent = await harness.init({ cwd: process.cwd(), sandbox: "local" });
  const session = await agent.session();

  const result = await session.shell("node -e \"setTimeout(() => {}, 5000)\"", {
    timeoutMs: 50,
  });

  assert.equal(result.signal, "SIGTERM");
  await agent.close();
});

test("local trusted shell does not spawn with a pre-aborted signal", async () => {
  const root = await mkdtemp(join(tmpdir(), "camlflow-shell-preabort-"));
  try {
    const controller = new AbortController();
    controller.abort();
    const harness = createPiCamlFlowHarness({
      runtime: createRuntime(),
      workerSessionFactory: async () => new FakeWorkerSession("ok"),
    });
    const agent = await harness.init({ cwd: root, sandbox: "local" });
    const session = await agent.session();

    const result = await session.shell(
      "node -e \"require('node:fs').writeFileSync('marker', 'ran')\"",
      { signal: controller.signal },
    );

    assert.equal(result.signal, "SIGTERM");
    assert.equal(existsSync(join(root, "marker")), false);
    await agent.close();
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("local trusted shell honors external abort signals", async () => {
  const root = await mkdtemp(join(tmpdir(), "camlflow-shell-abort-"));
  try {
    const controller = new AbortController();
    const harness = createPiCamlFlowHarness({
      runtime: createRuntime(),
      workerSessionFactory: async () => new FakeWorkerSession("ok"),
    });
    const agent = await harness.init({ cwd: root, sandbox: "local" });
    const session = await agent.session();

    const pendingShell = session.shell(
      "node -e \"require('node:fs').writeFileSync('started', 'yes'); setTimeout(() => {}, 5000)\"",
      { signal: controller.signal },
    );
    while (!existsSync(join(root, "started"))) {
      await new Promise((resolve) => setTimeout(resolve, 1));
    }
    controller.abort();
    const result = await pendingShell;

    assert.equal(readFileSync(join(root, "started"), "utf8"), "yes");
    assert.equal(result.signal, "SIGTERM");
    await agent.close();
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("read-only harness sandbox disables host shell execution", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("ok"),
  });
  const agent = await harness.init({ sandbox: "read-only" });
  const session = await agent.session();

  await assert.rejects(
    async () => session.shell("echo denied"),
    /does not allow host shell/,
  );
  await session.close();
});

test("harness rejects unknown sandbox kinds before creating a session", async () => {
  let workerCreated = false;
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => {
      workerCreated = true;
      return new FakeWorkerSession("ok");
    },
  });
  const agent = await harness.init({ sandbox: "danger-full-access" });

  await assert.rejects(
    () => agent.session(),
    /Unknown Pi CamlFlow sandbox kind: danger-full-access/,
  );
  assert.equal(workerCreated, false);
  await agent.close();
});

test("harness rejects custom sandboxes without explicit tools", async () => {
  let workerCreated = false;
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => {
      workerCreated = true;
      return new FakeWorkerSession("ok");
    },
  });
  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: "/virtual/custom-without-tools",
    },
  });

  await assert.rejects(
    () => agent.session(),
    /Custom Pi CamlFlow sandboxes must provide tools/,
  );
  assert.equal(workerCreated, false);
  await agent.close();
});

test("harness rejects invalid sandbox config fields before creating a session", async () => {
  const cases = [
    {
      sandbox: null,
      message: /sandbox config must be an object, string, or factory/,
    },
    {
      sandbox: ["local"],
      message: /sandbox config must be an object, string, or factory/,
    },
    {
      sandbox: { kind: "local", cwd: " " },
      message: /sandbox cwd must not be empty/,
    },
    {
      sandbox: { kind: "local", cwd: "bad\0cwd" },
      message: /sandbox cwd must not contain NUL bytes/,
    },
    {
      sandbox: { kind: "custom", cwd: "/virtual", tools: "files" },
      message: /sandbox tools must be an array or factory/,
    },
    {
      sandbox: { kind: "local", tools: () => "files" },
      message: /sandbox tools must be an array or factory/,
    },
    {
      sandbox: { kind: "custom", cwd: "/virtual", tools: [], shell: true },
      message: /sandbox shell must be a function or false/,
    },
    {
      sandbox: { kind: "ephemeral", cleanup: "yes" },
      message: /sandbox cleanup must be a boolean/,
    },
    {
      sandbox: { kind: "local", cleanup: true },
      message: /sandbox cleanup is only supported for ephemeral/,
    },
    {
      sandbox: { kind: "ephemeral", dispose: true },
      message: /sandbox dispose must be a function/,
    },
    {
      sandbox: () => undefined,
      message: /sandbox factory must return a sandbox config/,
    },
    {
      sandbox: () => 42,
      message: /sandbox config must be an object, string, or factory/,
    },
  ];

  for (const { sandbox, message } of cases) {
    let workerCreated = false;
    const harness = createPiCamlFlowHarness({
      runtime: createRuntime(),
      workerSessionFactory: async () => {
        workerCreated = true;
        return new FakeWorkerSession("ok");
      },
    });
    const agent = await harness.init({ sandbox });

    await assert.rejects(() => agent.session(), message);
    assert.equal(workerCreated, false);
    await agent.close();
  }
});

test("agent owns and reuses sandbox state across sessions", async () => {
  const createdSessions = [];
  let disposeCalls = 0;
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async (_request, options) => {
      const session = new FakeWorkerSession('"ok"');
      session.cwd = options.cwd;
      createdSessions.push(session);
      return session;
    },
  });

  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: "/virtual/workspace",
      tools: [],
      dispose: () => {
        disposeCalls += 1;
      },
    },
  });

  const first = await agent.session("first");
  const second = await agent.session("second");
  assert.equal(first.cwd, "/virtual/workspace");
  assert.equal(second.cwd, "/virtual/workspace");
  await first.close();

  assert.equal(disposeCalls, 0);
  assert.equal(createdSessions[0].disposeCalled, true);
  assert.equal(createdSessions[1].disposeCalled, false);

  await agent.close();
  await agent.close();

  assert.equal(createdSessions[1].disposeCalled, true);
  assert.equal(disposeCalls, 1);
  await assert.rejects(async () => agent.session("after-close"), /agent is closed/);
});

test("agent resolves a Flue-style sandbox factory once", async () => {
  let factoryCalls = 0;
  let disposeCalls = 0;
  const workerCwds = [];
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async (_request, options) => {
      workerCwds.push(options.cwd);
      return new FakeWorkerSession('"ok"');
    },
  });
  const agent = await harness.init({
    cwd: "/host/factory",
    sandbox: (cwd) => {
      factoryCalls += 1;
      assert.equal(cwd, "/host/factory");
      return {
        kind: "custom",
        cwd: "/virtual/factory",
        tools: [],
        dispose: () => {
          disposeCalls += 1;
        },
      };
    },
  });

  const first = await agent.session("first");
  const second = await agent.session("second");
  await first.close();
  await second.close();
  await agent.close();

  assert.equal(factoryCalls, 1);
  assert.deepEqual(workerCwds, ["/virtual/factory", "/virtual/factory"]);
  assert.equal(disposeCalls, 1);
});

test("agent close still releases the sandbox when a worker dispose fails", async () => {
  let disposeCalls = 0;
  const worker = new FakeWorkerSession('"ok"');
  worker.disposeError = new Error("worker dispose failed");
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => worker,
  });
  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: "/virtual/dispose-failure",
      tools: [],
      dispose: () => {
        disposeCalls += 1;
      },
    },
  });

  await agent.session("failure");

  await assert.rejects(() => agent.close(), /worker dispose failed/);
  assert.equal(disposeCalls, 1);
  await agent.close();
  assert.equal(disposeCalls, 1);
  await assert.rejects(() => agent.session("after-close"), /agent is closed/);
});

test("closing an agent closes open harness sessions", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"ok"'),
  });
  const agent = await harness.init({ cwd: process.cwd(), sandbox: "local" });
  const session = await agent.session();

  await agent.close();

  await assert.rejects(() => session.prompt("after close"), /session is closed/);
  await assert.rejects(() => session.shell("echo after close"), /session is closed/);
});

test("session close still disposes the worker when abort fails", async () => {
  let sandboxDisposeCalls = 0;
  const worker = new FakeWorkerSession('"ok"');
  worker.abortError = new Error("abort failed");
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => worker,
  });
  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: "/virtual/abort-failure",
      tools: [],
      dispose: () => {
        sandboxDisposeCalls += 1;
      },
    },
  });
  const session = await agent.session("abort-failure");

  await assert.rejects(() => session.close(), /abort failed/);
  assert.equal(worker.abortCalled, true);
  assert.equal(worker.disposeCalled, true);
  assert.equal(sandboxDisposeCalls, 0);

  await agent.close();
  assert.equal(sandboxDisposeCalls, 1);
});

test("closing an agent during session creation disposes the late worker", async () => {
  let releaseWorker;
  let lateWorker;
  let signalWorkerStarted;
  const workerGate = new Promise((resolve) => {
    releaseWorker = resolve;
  });
  const workerStarted = new Promise((resolve) => {
    signalWorkerStarted = resolve;
  });
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => {
      signalWorkerStarted();
      await workerGate;
      lateWorker = new FakeWorkerSession('"late"');
      return lateWorker;
    },
  });
  const agent = await harness.init({ sandbox: "local" });

  const pendingSession = agent.session("slow");
  await workerStarted;
  await agent.close();
  releaseWorker();

  await assert.rejects(pendingSession, /agent is closed/);
  assert.equal(lateWorker.disposeCalled, true);
});

test("closing an agent during session creation preserves the closed error when late worker dispose fails", async () => {
  let releaseWorker;
  let lateWorker;
  let signalWorkerStarted;
  const workerGate = new Promise((resolve) => {
    releaseWorker = resolve;
  });
  const workerStarted = new Promise((resolve) => {
    signalWorkerStarted = resolve;
  });
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => {
      signalWorkerStarted();
      await workerGate;
      lateWorker = new FakeWorkerSession('"late"');
      lateWorker.disposeError = new Error("late dispose failed");
      return lateWorker;
    },
  });
  const agent = await harness.init({ sandbox: "local" });

  const pendingSession = agent.session("slow-dispose");
  await workerStarted;
  await agent.close();
  releaseWorker();

  await assert.rejects(pendingSession, /agent is closed/);
  assert.equal(lateWorker.disposeCalls, 1);
});

test("closing an agent during sandbox creation disposes the late sandbox", async () => {
  let releaseSandbox;
  let signalSandboxStarted;
  let disposeCalls = 0;
  const sandboxGate = new Promise((resolve) => {
    releaseSandbox = resolve;
  });
  const sandboxStarted = new Promise((resolve) => {
    signalSandboxStarted = resolve;
  });
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"late"'),
  });
  const agent = await harness.init({
    sandbox: async () => {
      signalSandboxStarted();
      await sandboxGate;
      return {
        kind: "custom",
        cwd: "/virtual/late-sandbox",
        tools: [],
        dispose: () => {
          disposeCalls += 1;
        },
      };
    },
  });

  const pendingSession = agent.session("slow-sandbox");
  await sandboxStarted;
  const pendingClose = agent.close();
  releaseSandbox();

  await pendingClose;
  await assert.rejects(pendingSession, /agent is closed/);
  assert.equal(disposeCalls, 1);
});

test("closing an agent during workflow sandbox creation rejects the late run", async () => {
  let releaseSandbox;
  let signalSandboxStarted;
  let disposeCalls = 0;
  let clientCreated = false;
  const sandboxGate = new Promise((resolve) => {
    releaseSandbox = resolve;
  });
  const sandboxStarted = new Promise((resolve) => {
    signalSandboxStarted = resolve;
  });
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"late"'),
    clientFactory: (options) => {
      clientCreated = true;
      return new FakeCamlFlowClient(options);
    },
  });
  const agent = await harness.init({
    sandbox: async () => {
      signalSandboxStarted();
      await sandboxGate;
      return {
        kind: "custom",
        cwd: "/virtual/late-workflow-sandbox",
        tools: [],
        dispose: () => {
          disposeCalls += 1;
        },
      };
    },
  });

  const pendingRun = agent.runWorkflow({
    workflowPath: "examples/basic/main.cml",
  });
  await sandboxStarted;
  const pendingClose = agent.close();
  releaseSandbox();

  await pendingClose;
  await assert.rejects(pendingRun, /agent is closed/);
  assert.equal(disposeCalls, 1);
  assert.equal(clientCreated, false);
});

test("ephemeral harness sandbox is removed when the agent closes", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"ok"'),
  });
  const agent = await harness.init({ sandbox: "ephemeral" });
  const session = await agent.session();
  const sandboxCwd = session.cwd;

  assert.equal(existsSync(sandboxCwd), true);
  await session.close();
  assert.equal(existsSync(sandboxCwd), true);

  await agent.close();
  assert.equal(existsSync(sandboxCwd), false);
});

test("non-ephemeral cleanup flag is rejected before touching host-owned cwd", async () => {
  const root = await mkdtemp(join(tmpdir(), "camlflow-local-cleanup-"));
  try {
    let workerCreated = false;
    const harness = createPiCamlFlowHarness({
      runtime: createRuntime(),
      workerSessionFactory: async () => {
        workerCreated = true;
        return new FakeWorkerSession('"ok"');
      },
    });
    const agent = await harness.init({
      sandbox: {
        kind: "local",
        cwd: root,
        cleanup: true,
      },
    });

    await assert.rejects(
      () => agent.session(),
      /sandbox cleanup is only supported for ephemeral/,
    );
    assert.equal(workerCreated, false);
    await agent.close();

    assert.equal(existsSync(root), true);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("ephemeral sandbox cleanup runs even when dispose hook fails", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"ok"'),
  });
  const agent = await harness.init({
    sandbox: {
      kind: "ephemeral",
      dispose: () => {
        throw new Error("dispose hook failed");
      },
    },
  });
  const session = await agent.session();
  const sandboxCwd = session.cwd;

  await assert.rejects(() => agent.close(), /dispose hook failed/);
  assert.equal(existsSync(sandboxCwd), false);
});

test("ephemeral sandbox cleanup runs when tool creation fails", async () => {
  let sandboxCwd;
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"unreachable"'),
  });
  const agent = await harness.init({
    sandbox: {
      kind: "ephemeral",
      tools: (cwd) => {
        sandboxCwd = cwd;
        assert.equal(existsSync(cwd), true);
        throw new Error("tool setup failed");
      },
    },
  });

  await assert.rejects(() => agent.session(), /tool setup failed/);
  assert.equal(typeof sandboxCwd, "string");
  assert.equal(existsSync(sandboxCwd), false);
  await agent.close();
});

test("harness workflow runs reuse the agent-owned sandbox for effects", async () => {
  const workerCwds = [];
  let disposeCalls = 0;
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async (_request, options) => {
      workerCwds.push(options.cwd);
      return new FakeWorkerSession('{"answer":"from workflow"}');
    },
    clientFactory: (options) => new FakeCamlFlowClient(options),
  });
  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: "/virtual/workflow",
      tools: [],
      dispose: () => {
        disposeCalls += 1;
      },
    },
  });

  const result = await agent.runWorkflow({
    workflowPath: "examples/basic/main.cml",
    input: "Ada",
  });

  assert.deepEqual(result.output, { answer: "from workflow" });
  assert.deepEqual(workerCwds, ["/virtual/workflow"]);
  assert.equal(disposeCalls, 0);
  await agent.close();
  assert.equal(disposeCalls, 1);
});

test("closing an agent cancels an active harness workflow run", async () => {
  let fakeClient;
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession("{}"),
    clientFactory: (options) => {
      fakeClient = new HangingCamlFlowClient(options);
      return fakeClient;
    },
  });
  const agent = await harness.init({ sandbox: "local" });

  const pending = agent.runWorkflow({
    workflowPath: "examples/basic/main.cml",
  });
  while (!fakeClient) {
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  await fakeClient.runStarted;
  await agent.close();

  await assert.rejects(pending, /cancelled/);
  assert.equal(fakeClient.runSignal.aborted, true);
  assert.equal(fakeClient.shutdownCalled, true);
});

test("session abort cancels an active trusted shell command", async () => {
  let shellSignal;
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"ok"'),
  });
  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: process.cwd(),
      tools: [],
      shell: (_command, options = {}) =>
        new Promise((_resolve, reject) => {
          shellSignal = options.signal;
          options.signal.addEventListener(
            "abort",
            () => reject(new Error("shell aborted")),
            { once: true },
          );
        }),
    },
  });
  const session = await agent.session();

  const pendingShell = session.shell("sleep 60");
  while (!shellSignal) {
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  await session.abort();

  assert.equal(shellSignal.aborted, true);
  await assert.rejects(pendingShell, /shell aborted/);
  await agent.close();
});

test("pre-aborted trusted shell call does not invoke custom shell executor", async () => {
  let shellCalls = 0;
  const controller = new AbortController();
  controller.abort();
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"ok"'),
  });
  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: process.cwd(),
      tools: [],
      shell: async () => {
        shellCalls += 1;
        return {
          code: 0,
          signal: null,
          stdout: "ran",
          stderr: "",
        };
      },
    },
  });
  const session = await agent.session();

  const result = await session.shell("should not run", {
    signal: controller.signal,
  });

  assert.deepEqual(result, {
    code: null,
    signal: "SIGTERM",
    stdout: "",
    stderr: "",
  });
  assert.equal(shellCalls, 0);
  await agent.close();
});

test("trusted shell removes external abort listeners after completion", async () => {
  const controller = new AbortController();
  const abortListeners = countAbortSignalListeners(controller.signal);
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"ok"'),
  });
  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: process.cwd(),
      tools: [],
      shell: async () => ({
        code: 0,
        signal: null,
        stdout: "done",
        stderr: "",
      }),
    },
  });
  const session = await agent.session();

  assert.deepEqual(await session.shell("echo done", { signal: controller.signal }), {
    code: 0,
    signal: null,
    stdout: "done",
    stderr: "",
  });
  assert.equal(abortListeners.added, 1);
  assert.equal(abortListeners.removed, 1);
  await agent.close();
});

test("trusted shell removes external abort listeners after sync failure", async () => {
  const controller = new AbortController();
  const abortListeners = countAbortSignalListeners(controller.signal);
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"ok"'),
  });
  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: process.cwd(),
      tools: [],
      shell: () => {
        throw new Error("sync shell failed");
      },
    },
  });
  const session = await agent.session();

  await assert.rejects(
    () => session.shell("throw sync", { signal: controller.signal }),
    /sync shell failed/,
  );
  assert.equal(abortListeners.added, 1);
  assert.equal(abortListeners.removed, 1);
  await agent.close();
});

test("trusted shell preserves primary failures when listener cleanup fails", async () => {
  const controller = new AbortController();
  controller.signal.removeEventListener = () => {
    throw new Error("remove listener failed");
  };
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"ok"'),
  });
  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: process.cwd(),
      tools: [],
      shell: () => {
        throw new Error("shell failed");
      },
    },
  });
  const session = await agent.session();

  await assert.rejects(
    () => session.shell("throw sync", { signal: controller.signal }),
    /shell failed/,
  );
  await agent.close();
});

test("trusted shell reports listener cleanup failures after success", async () => {
  const controller = new AbortController();
  controller.signal.removeEventListener = () => {
    throw new Error("remove listener failed");
  };
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"ok"'),
  });
  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: process.cwd(),
      tools: [],
      shell: async () => ({
        code: 0,
        signal: null,
        stdout: "done",
        stderr: "",
      }),
    },
  });
  const session = await agent.session();

  await assert.rejects(
    () => session.shell("echo done", { signal: controller.signal }),
    /remove listener failed/,
  );
  await agent.close();
});

test("trusted shell accepts synchronous executor results", async () => {
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"ok"'),
  });
  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: process.cwd(),
      tools: [],
      shell: () => ({
        code: 0,
        signal: null,
        stdout: "sync",
        stderr: "",
      }),
    },
  });
  const session = await agent.session();

  assert.deepEqual(await session.shell("sync result"), {
    code: 0,
    signal: null,
    stdout: "sync",
    stderr: "",
  });
  await agent.close();
});

test("trusted shell rejects malformed custom executor results", async () => {
  for (const result of [
    {
      code: 0,
      signal: null,
      stdout: 42,
      stderr: "",
    },
    {
      code: Number.NaN,
      signal: null,
      stdout: "",
      stderr: "",
    },
    {
      code: -1,
      signal: null,
      stdout: "",
      stderr: "",
    },
    {
      code: 0,
      signal: "",
      stdout: "",
      stderr: "",
    },
    {
      code: 0,
      signal: "SIG\0TERM",
      stdout: "",
      stderr: "",
    },
  ]) {
    const harness = createPiCamlFlowHarness({
      runtime: createRuntime(),
      workerSessionFactory: async () => new FakeWorkerSession('"ok"'),
    });
    const agent = await harness.init({
      sandbox: {
        kind: "custom",
        cwd: process.cwd(),
        tools: [],
        shell: () => result,
      },
    });
    const session = await agent.session();

    await assert.rejects(
      () => session.shell("bad result"),
      /invalid shell result|shell result signal/,
    );
    await agent.close();
  }
});

test("session close waits for active trusted shell settlement", async () => {
  let shellSignal;
  let settleShell;
  let settled = false;
  const shellSettled = new Promise((resolve) => {
    settleShell = () => {
      settled = true;
      resolve({
        code: null,
        signal: "SIGTERM",
        stdout: "",
        stderr: "",
      });
    };
  });
  const harness = createPiCamlFlowHarness({
    runtime: createRuntime(),
    workerSessionFactory: async () => new FakeWorkerSession('"ok"'),
  });
  const agent = await harness.init({
    sandbox: {
      kind: "custom",
      cwd: process.cwd(),
      tools: [],
      shell: (_command, options = {}) => {
        shellSignal = options.signal;
        options.signal.addEventListener("abort", () => {
          setTimeout(settleShell, 10);
        });
        return shellSettled;
      },
    },
  });
  const session = await agent.session();

  const pendingShell = session.shell("sleep 60");
  while (!shellSignal) {
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  await session.close();

  assert.equal(shellSignal.aborted, true);
  assert.equal(settled, true);
  assert.deepEqual(await pendingShell, {
    code: null,
    signal: "SIGTERM",
    stdout: "",
    stderr: "",
  });
});

test("package exports the public Pi harness surface and no slash-command parser", () => {
  for (const name of [
    "PiCamlFlowEffectCancelledError",
    "PiCamlFlowEffectExecutor",
    "PiCamlFlowMissingModelError",
    "buildPiCamlFlowEffectPrompt",
    "createPiCamlFlowHarness",
    "createPiCamlFlowHostSession",
    "parseCamlFlowJsonOutput",
  ]) {
    assert.equal(typeof sdk[name], "function", `${name} should be exported`);
  }
  assert.equal("parseCamlFlowCommand" in sdk, false);
  assert.equal("parseCamlFlowRunCommand" in sdk, false);
  assert.equal(
    Object.keys(sdk).some((name) => name.toLowerCase().includes("slash")),
    false,
  );
});

function createCamlFlowCapabilities(overrides = {}) {
  return {
    check: true,
    compile: true,
    run: true,
    executeEffect: true,
    trace: true,
    diagnostic: true,
    progress: true,
    streaming: true,
    cancelRequest: true,
    renderedPrompt: true,
    outputSchema: true,
    ...overrides,
  };
}

function createJsonRpcNotification(method, params) {
  return {
    jsonrpc: "2.0",
    method,
    params,
  };
}

function createTraceNotification(overrides = {}) {
  return {
    event: "run-start",
    runId: "run-1",
    step: null,
    effect: null,
    ...overrides,
  };
}

function createDiagnosticNotification(overrides = {}) {
  return {
    severity: "error",
    message: "boom",
    method: "camlflow/run",
    runId: "run-1",
    step: null,
    effect: null,
    ...overrides,
  };
}

function createProgressNotification(overrides = {}) {
  return {
    runId: "run-1",
    stage: "run-start",
    step: null,
    message: null,
    completedSteps: 0,
    knownSteps: null,
    cancellable: true,
    ...overrides,
  };
}

function createOutputChunkNotification(overrides = {}) {
  return {
    runId: "run-1",
    step: 1,
    streamId: "pi:1:bound-agent:greeter",
    format: "text/plain",
    delta: "hello",
    done: false,
    declaredReturnType: "record",
    outputSchema: { type: "object" },
    ...overrides,
  };
}

class FakeCamlFlowClient {
  constructor(options) {
    this.options = options;
    this.shutdownCalled = false;
    this.shutdownCalls = 0;
    this.initializeCalled = false;
    this.runCalled = false;
  }

  async initialize() {
    this.initializeCalled = true;
    return {
      protocolVersion: "0.1.0",
      irVersion: "0.1.0",
      capabilities: createCamlFlowCapabilities(),
      effectKinds: [],
    };
  }

  async run(params, options) {
    this.runCalled = true;
    this.runParams = params;
    this.runOptions = options;
    const effectResult = await this.options.effectHandler(
      createExecuteEffectParams(),
      {
        jsonrpc: "2.0",
        id: 1,
        method: "camlflow/executeEffect",
        params: createExecuteEffectParams(),
      },
      {
        emitOutputChunk: async (chunk) => {
          const notificationChunk = {
            runId: "run-1",
            step: 1,
            declaredReturnType: "record",
            outputSchema: { type: "object" },
            ...chunk,
          };
          await this.options.onOutputChunk?.(
            notificationChunk,
            createJsonRpcNotification("camlflow/outputChunk", notificationChunk),
          );
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
    this.shutdownCalls += 1;
    if (this.shutdownError) {
      const error = this.shutdownError;
      this.shutdownError = undefined;
      throw error;
    }
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
