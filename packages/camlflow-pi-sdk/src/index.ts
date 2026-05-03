import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { isAbsolute, relative, resolve } from "node:path";

import {
  createAgentSession,
  createCodingTools,
  createExtensionRuntime,
  createReadOnlyTools,
  DefaultResourceLoader,
  SessionManager,
  SettingsManager,
  type AgentSession,
  type AgentSessionEvent,
  type CreateAgentSessionOptions,
  type ResourceLoader,
} from "@mariozechner/pi-coding-agent";
import * as CamlFlowRpc from "camlflow-ts-json-rpc-sdk";
import type {
  CamlFlowDiagnosticNotification,
  CamlFlowEffectHandlerContext,
  CamlFlowExecuteEffectParams,
  CamlFlowOutputChunkNotification,
  CamlFlowProgressNotification,
  CamlFlowRunResult,
  CamlFlowTraceNotification,
  JsonObject,
  JsonRpcNotification,
  JsonRpcRequest,
  JsonValue,
  SpawnCamlFlowClientOptions,
} from "camlflow-ts-json-rpc-sdk";

const DEFAULT_ENTRYPOINT = "main";
const DEFAULT_CAMLFLOW_COMMAND = "camlflow";
const DEFAULT_CAMLFLOW_ARGS = ["serve", "--stdio"];
const SANDBOX_PRESETS = new Set(["local", "workspace-write", "read-only", "ephemeral"]);
const CAMLFLOW_CAPABILITY_NAMES = [
  "check",
  "compile",
  "run",
  "executeEffect",
  "trace",
  "diagnostic",
  "progress",
  "streaming",
  "cancelRequest",
  "renderedPrompt",
  "outputSchema",
] as const;
const WORKER_SYSTEM_PROMPT = [
  "You are executing one CamlFlow effect inside Pi.",
  "Use tools when needed.",
  "The final answer must be JSON only.",
  "Do not wrap the final JSON in commentary.",
].join("\n");

type MaybePromise<T> = T | Promise<T>;
type PiModel = NonNullable<CreateAgentSessionOptions["model"]>;
type PiThinkingLevel = NonNullable<CreateAgentSessionOptions["thinkingLevel"]>;
type PiAuthStorage = NonNullable<CreateAgentSessionOptions["authStorage"]>;
type PiModelRegistry = NonNullable<CreateAgentSessionOptions["modelRegistry"]>;
type PiTool = NonNullable<CreateAgentSessionOptions["tools"]>[number];

export type { JsonObject, JsonValue };

export type PiCamlFlowSandboxPreset =
  | "local"
  | "workspace-write"
  | "read-only"
  | "ephemeral";

export interface PiCamlFlowShellOptions {
  cwd?: string;
  env?: Record<string, string | undefined>;
  stdin?: string;
  timeoutMs?: number;
  signal?: AbortSignal;
}

export interface PiCamlFlowShellResult {
  code: number | null;
  signal: NodeJS.Signals | null;
  stdout: string;
  stderr: string;
}

export type PiCamlFlowShellExecutor = (
  command: string,
  options?: PiCamlFlowShellOptions,
) => MaybePromise<PiCamlFlowShellResult>;

export interface PiCamlFlowSandboxConfig {
  kind?: PiCamlFlowSandboxPreset;
  cwd?: string;
  tools?: PiTool[] | ((cwd: string) => PiTool[]);
  shell?: PiCamlFlowShellExecutor | false;
  cleanup?: boolean;
  dispose?: () => MaybePromise<void>;
}

export interface PiCamlFlowCustomSandbox {
  kind: "custom";
  cwd?: string;
  tools: PiTool[] | ((cwd: string) => PiTool[]);
  shell?: PiCamlFlowShellExecutor;
  dispose?: () => MaybePromise<void>;
}

export type PiCamlFlowSandboxFactory = (
  cwd: string,
) => MaybePromise<
  PiCamlFlowSandboxPreset | PiCamlFlowSandboxConfig | PiCamlFlowCustomSandbox
>;

export type PiCamlFlowSandboxInput =
  | PiCamlFlowSandboxPreset
  | PiCamlFlowSandboxConfig
  | PiCamlFlowCustomSandbox
  | PiCamlFlowSandboxFactory;

export interface PiCamlFlowRuntime {
  cwd: string;
  sandbox?: PiCamlFlowSandboxInput;
  session: {
    model?: PiModel;
    thinkingLevel?: PiThinkingLevel;
  };
  services: {
    agentDir?: string;
    authStorage?: PiAuthStorage;
    modelRegistry: PiModelRegistry;
  };
}

export interface PiCamlFlowEffectRequest<TInput extends JsonValue = JsonValue> {
  kind: string;
  role?: string;
  name: string;
  input: TInput;
  renderedPrompt: string;
  workingDirectory?: string | null;
  skillsDirectory?: string | null;
  skillMarkdown?: string | null;
  requestedModel?: string | null;
  declaredReturnType?: string;
  outputSchema?: JsonObject | null;
  runId?: string | null;
  step?: number | null;
}

export interface PiCamlFlowEffectExecutionOptions {
  signal?: AbortSignal;
  emitOutputChunk?: (delta: string, done: boolean) => MaybePromise<void>;
}

export interface PiCamlFlowWorkerSession {
  readonly messages: readonly unknown[];
  prompt(text: string, options?: { expandPromptTemplates?: boolean; source?: string }): Promise<void>;
  subscribe(listener: (event: AgentSessionEvent) => void): () => void;
  abort(): Promise<void>;
  dispose(): void;
}

export type PiCamlFlowWorkerSessionFactory = (
  request: PiCamlFlowEffectRequest,
  options: {
    cwd: string;
    model: PiModel;
    thinkingLevel?: PiThinkingLevel;
    runtime: PiCamlFlowRuntime;
  },
) => Promise<PiCamlFlowWorkerSession>;

export interface PiCamlFlowEffectExecutorOptions {
  workerSessionFactory?: PiCamlFlowWorkerSessionFactory;
}

export interface PiCamlFlowCallbacks {
  onTrace?: (
    trace: CamlFlowTraceNotification,
    notification: JsonRpcNotification<CamlFlowTraceNotification>,
  ) => MaybePromise<void>;
  onDiagnostic?: (
    diagnostic: CamlFlowDiagnosticNotification,
    notification: JsonRpcNotification<CamlFlowDiagnosticNotification>,
  ) => MaybePromise<void>;
  onProgress?: (
    progress: CamlFlowProgressNotification,
    notification: JsonRpcNotification<CamlFlowProgressNotification>,
  ) => MaybePromise<void>;
  onOutputChunk?: (
    chunk: CamlFlowOutputChunkNotification,
    notification: JsonRpcNotification<CamlFlowOutputChunkNotification>,
  ) => MaybePromise<void>;
  onTransportError?: (error: Error) => void;
}

export interface PiCamlFlowHostSessionOptions extends PiCamlFlowCallbacks {
  runtime: PiCamlFlowRuntime;
  camlflow?: Partial<SpawnCamlFlowClientOptions>;
  clientFactory?: (options: SpawnCamlFlowClientOptions) => CamlFlowClientLike;
  workerSessionFactory?: PiCamlFlowWorkerSessionFactory;
  autoShutdown?: boolean;
}

export interface PiCamlFlowWorkflowRunOptions<TInput extends JsonValue = JsonValue> {
  workflowPath: string;
  entrypoint?: string;
  input?: TInput | null;
  skillsDir?: string | null;
  includePaths?: string[];
  signal?: AbortSignal;
}

export interface PiCamlFlowWorkflowRunResult<TOutput extends JsonValue = JsonValue>
  extends CamlFlowRunResult<TOutput> {
  protocolVersion: string;
  irVersion: string;
  workflowPath: string;
  entrypoint: string;
}

export interface PiCamlFlowHostSession {
  runWorkflow<TOutput extends JsonValue = JsonValue, TInput extends JsonValue = JsonValue>(
    options: PiCamlFlowWorkflowRunOptions<TInput>,
  ): Promise<PiCamlFlowWorkflowRunResult<TOutput>>;
  cancel(): Promise<void>;
  close(): Promise<void>;
}

export type PiCamlFlowResultParser<TOutput> =
  | "json"
  | ((value: JsonValue) => TOutput)
  | {
      parse(value: JsonValue): TOutput;
    }
  | {
      safeParse(value: JsonValue):
        | { success: true; output: TOutput; data?: never }
        | { success: true; data: TOutput; output?: never }
        | { success: false; issues?: unknown; error?: unknown };
    };

export interface PiCamlFlowPromptOptions<TOutput = string> {
  result?: PiCamlFlowResultParser<TOutput>;
  signal?: AbortSignal;
}

export interface PiCamlFlowSkillOptions<TOutput = string>
  extends PiCamlFlowPromptOptions<TOutput> {
  args?: JsonValue;
}

export interface PiCamlFlowHarnessShellOptions extends PiCamlFlowShellOptions {}

export interface PiCamlFlowAgentSession {
  readonly id: string;
  readonly cwd: string;
  prompt<TOutput = string>(
    text: string,
    options?: PiCamlFlowPromptOptions<TOutput>,
  ): Promise<TOutput>;
  skill<TOutput = string>(
    name: string,
    options?: PiCamlFlowSkillOptions<TOutput>,
  ): Promise<TOutput>;
  task<TOutput = string>(
    text: string,
    options?: PiCamlFlowPromptOptions<TOutput>,
  ): Promise<TOutput>;
  shell(
    command: string,
    options?: PiCamlFlowHarnessShellOptions,
  ): Promise<PiCamlFlowShellResult>;
  abort(): Promise<void>;
  close(): Promise<void>;
}

export interface PiCamlFlowAgent {
  readonly id: string;
  readonly cwd: string;
  session(threadId?: string): Promise<PiCamlFlowAgentSession>;
  runWorkflow<TOutput extends JsonValue = JsonValue, TInput extends JsonValue = JsonValue>(
    options: PiCamlFlowWorkflowRunOptions<TInput>,
  ): Promise<PiCamlFlowWorkflowRunResult<TOutput>>;
  close(): Promise<void>;
}

export interface PiCamlFlowAgentInitOptions {
  id?: string;
  cwd?: string;
  model?: PiModel | string;
  thinkingLevel?: PiThinkingLevel;
  sandbox?: PiCamlFlowSandboxInput;
}

export interface PiCamlFlowHarnessOptions extends PiCamlFlowCallbacks {
  runtime: PiCamlFlowRuntime;
  camlflow?: Partial<SpawnCamlFlowClientOptions>;
  clientFactory?: (options: SpawnCamlFlowClientOptions) => CamlFlowClientLike;
  workerSessionFactory?: PiCamlFlowWorkerSessionFactory;
  autoShutdown?: boolean;
}

export interface PiCamlFlowHarness {
  init(options?: PiCamlFlowAgentInitOptions): Promise<PiCamlFlowAgent>;
}

export class PiCamlFlowMissingModelError extends Error {
  constructor(effect: Pick<PiCamlFlowEffectRequest, "kind" | "name">) {
    super(
      `CamlFlow effect needs a configured Pi model: ${effect.kind}:${effect.name}. Select a model in Pi first.`,
    );
    this.name = "PiCamlFlowMissingModelError";
  }
}

export class PiCamlFlowEffectCancelledError extends Error {
  constructor(effect: Pick<PiCamlFlowEffectRequest, "kind" | "name">) {
    super(`CamlFlow effect cancelled: ${effect.kind}:${effect.name}`);
    this.name = "PiCamlFlowEffectCancelledError";
  }
}

export class PiCamlFlowEffectExecutor {
  private readonly workerSessionFactory: PiCamlFlowWorkerSessionFactory;

  constructor(
    private readonly runtime: PiCamlFlowRuntime,
    options: PiCamlFlowEffectExecutorOptions = {},
  ) {
    validateEffectExecutorOptions(options);
    validatePiCamlFlowRuntime(runtime);
    this.workerSessionFactory = options.workerSessionFactory ?? createDefaultWorkerSession;
  }

  async executeEffect<TOutput extends JsonValue = JsonValue>(
    request: PiCamlFlowEffectRequest,
    options: PiCamlFlowEffectExecutionOptions = {},
  ): Promise<TOutput> {
    validateEffectRequest(request);
    validateEffectExecutionOptions(options);
    if (options.signal?.aborted) {
      throw new PiCamlFlowEffectCancelledError(request);
    }

    const workerCwd = request.workingDirectory ?? this.runtime.cwd;
    const model = resolveWorkerModel(this.runtime, request);
    const session = await this.workerSessionFactory(request, {
      cwd: workerCwd,
      model,
      thinkingLevel: this.runtime.session.thinkingLevel,
      runtime: this.runtime,
    });
    validateWorkerSession(session, "Pi CamlFlow effect worker session");

    let unsubscribe = (): void => undefined;
    const abortHandler = (): void => {
      void session.abort();
    };

    let primaryError: unknown;
    try {
      if (options.signal?.aborted) {
        await session.abort();
        throw new PiCamlFlowEffectCancelledError(request);
      }

      const unsubscribeCandidate = session.subscribe((event) => {
        const delta = extractTextDelta(event);
        if (delta !== undefined) {
          emitAdvisoryOutputChunk(options, delta);
        }
      });
      if (typeof unsubscribeCandidate !== "function") {
        throw new Error("Pi CamlFlow effect worker session subscribe must return an unsubscribe function");
      }
      unsubscribe = unsubscribeCandidate;

      options.signal?.addEventListener("abort", abortHandler, { once: true });
      if (options.signal?.aborted) {
        await session.abort();
        throw new PiCamlFlowEffectCancelledError(request);
      }

      await session.prompt(buildPiCamlFlowEffectPrompt(request), {
        expandPromptTemplates: false,
        source: "extension",
      });

      const assistant = findLastAssistantMessage(session.messages);
      if (!assistant) {
        throw new Error(`CamlFlow effect produced no assistant message: ${request.kind}:${request.name}`);
      }
      validateAssistantMessageStatus(assistant);
      if (assistant.stopReason === "aborted") {
        throw new PiCamlFlowEffectCancelledError(request);
      }
      if (assistant.stopReason === "error") {
        throw new Error(
          assistant.errorMessage
            ? `CamlFlow effect failed: ${assistant.errorMessage}`
            : `CamlFlow effect failed: ${request.kind}:${request.name}`,
        );
      }

      const outputText = extractAssistantText(assistant);
      if (outputText.length === 0) {
        throw new Error(`CamlFlow effect returned no text output: ${request.kind}:${request.name}`);
      }

      return parseCamlFlowJsonOutput(outputText) as TOutput;
    } catch (error) {
      primaryError = error;
      throw error;
    } finally {
      let cleanupError: unknown;
      const recordCleanupError = (error: unknown): void => {
        cleanupError ??= error;
      };

      try {
        await options.emitOutputChunk?.("", true);
      } catch (error) {
        recordCleanupError(error);
      }
      try {
        options.signal?.removeEventListener("abort", abortHandler);
      } catch (error) {
        recordCleanupError(error);
      }
      try {
        unsubscribe();
      } catch (error) {
        recordCleanupError(error);
      }
      try {
        session.dispose();
      } catch (error) {
        recordCleanupError(error);
      }

      if (primaryError === undefined && cleanupError !== undefined) {
        throw cleanupError;
      }
    }
  }
}

function emitAdvisoryOutputChunk(
  options: PiCamlFlowEffectExecutionOptions,
  delta: string,
): void {
  try {
    void Promise.resolve(options.emitOutputChunk?.(delta, false)).catch(() => undefined);
  } catch {
    // Streaming chunks are advisory; effect success is determined by the final assistant message.
  }
}

interface CamlFlowClientLike {
  initialize: CamlFlowRpc.CamlFlowJsonRpcClient["initialize"];
  run: CamlFlowRpc.CamlFlowJsonRpcClient["run"];
  shutdownAndExit: CamlFlowRpc.CamlFlowJsonRpcClient["shutdownAndExit"];
}

type ActiveRun = {
  controller: AbortController;
  client: CamlFlowClientLike;
};

class DefaultPiCamlFlowHostSession implements PiCamlFlowHostSession {
  private activeRun: ActiveRun | undefined;

  constructor(private readonly options: PiCamlFlowHostSessionOptions) {}

  async runWorkflow<TOutput extends JsonValue = JsonValue, TInput extends JsonValue = JsonValue>(
    options: PiCamlFlowWorkflowRunOptions<TInput>,
  ): Promise<PiCamlFlowWorkflowRunResult<TOutput>> {
    if (this.activeRun) {
      throw new Error("A CamlFlow workflow is already running in this Pi host session");
    }
    validateWorkflowRunOptions(options);
    if (options.signal?.aborted) {
      throw new PiCamlFlowEffectCancelledError({
        kind: "workflow",
        name: options.workflowPath,
      });
    }

    const controller = new AbortController();
    const abortSignal = combineAbortSignals([controller.signal, options.signal]);
    const executor = new PiCamlFlowEffectExecutor(this.options.runtime, {
      workerSessionFactory: this.options.workerSessionFactory,
    });

    const spawnOptions = this.buildSpawnOptions(executor, abortSignal.signal);
    const client = this.options.clientFactory
      ? this.options.clientFactory(spawnOptions)
      : CamlFlowRpc.spawnCamlFlowClient(spawnOptions);
    validateCamlFlowClient(client);

    this.activeRun = { controller, client };

    let primaryError: unknown;
    try {
      if (abortSignal.signal.aborted) {
        throw new PiCamlFlowEffectCancelledError({
          kind: "workflow",
          name: options.workflowPath,
        });
      }
      const initialize = await client.initialize(
        {
          notifications: {
            trace: true,
            diagnostic: true,
            progress: true,
          },
        },
        { signal: abortSignal.signal },
      );
      validateCamlFlowInitializeResult(initialize);
      const entrypoint = options.entrypoint ?? DEFAULT_ENTRYPOINT;
      const run = await client.run<TOutput, TInput>(
        {
          program: {
            path: options.workflowPath,
            includePaths: options.includePaths ?? [],
            skillsDir: options.skillsDir ?? null,
          },
          entry: entrypoint,
          input: options.input,
        },
        { signal: abortSignal.signal },
      );
      validateCamlFlowRunResult(run);

      return {
        ...run,
        protocolVersion: initialize.protocolVersion,
        irVersion: initialize.irVersion,
        workflowPath: options.workflowPath,
        entrypoint,
      };
    } catch (error) {
      primaryError = error;
      throw error;
    } finally {
      let cleanupError: unknown;
      const rememberCleanupError = (error: unknown): void => {
        cleanupError ??= error;
      };
      try {
        abortSignal.cleanup();
      } catch (error) {
        rememberCleanupError(error);
      }
      this.activeRun = undefined;
      if (this.options.autoShutdown !== false) {
        try {
          await client.shutdownAndExit({ timeoutMs: 2000 });
        } catch (error) {
          rememberCleanupError(error);
        }
      }
      if (primaryError === undefined && cleanupError !== undefined) {
        throw cleanupError;
      }
    }
  }

  async cancel(): Promise<void> {
    const activeRun = this.activeRun;
    if (!activeRun) {
      return;
    }

    activeRun.controller.abort();
    await activeRun.client.shutdownAndExit({ timeoutMs: 2000 }).catch(() => undefined);
  }

  async close(): Promise<void> {
    await this.cancel();
  }

  private buildSpawnOptions(
    executor: PiCamlFlowEffectExecutor,
    signal: AbortSignal,
  ): SpawnCamlFlowClientOptions {
    return {
      command: DEFAULT_CAMLFLOW_COMMAND,
      args: DEFAULT_CAMLFLOW_ARGS,
      cwd: this.options.runtime.cwd,
      stderr: "inherit",
      ...this.options.camlflow,
      effectHandler: async (
        _params: CamlFlowExecuteEffectParams,
        request: JsonRpcRequest<CamlFlowExecuteEffectParams>,
        context: CamlFlowEffectHandlerContext,
      ) => {
        validateEffectHandlerContext(context);
        const params = validateExecuteEffectRequest(request);
        const output = await executor.executeEffect(paramsToEffectRequest(params), {
          signal,
          emitOutputChunk: async (delta, done) => {
            await context.emitOutputChunk({
              streamId: buildEffectStreamId(params),
              format: "text/plain",
              delta,
              done,
            });
          },
        });
        return CamlFlowRpc.effectOutput(output);
      },
      onTrace: wrapTraceCallback(this.options.onTrace),
      onDiagnostic: wrapDiagnosticCallback(this.options.onDiagnostic),
      onProgress: wrapProgressCallback(this.options.onProgress),
      onOutputChunk: wrapOutputChunkCallback(this.options.onOutputChunk),
      onTransportError: this.options.onTransportError,
    };
  }
}

export function createPiCamlFlowHostSession(
  options: PiCamlFlowHostSessionOptions,
): PiCamlFlowHostSession {
  validateHostSessionOptions(options);
  validatePiCamlFlowRuntime(options.runtime);
  return new DefaultPiCamlFlowHostSession(options);
}

export function createPiCamlFlowHarness(options: PiCamlFlowHarnessOptions): PiCamlFlowHarness {
  validateHarnessOptions(options);
  validatePiCamlFlowRuntime(options.runtime);
  return {
    async init(initOptions: PiCamlFlowAgentInitOptions = {}) {
      validateAgentInitOptions(initOptions);
      const cwd = initOptions.cwd ?? options.runtime.cwd;
      const sandboxInput =
        Object.prototype.hasOwnProperty.call(initOptions, "sandbox")
          ? initOptions.sandbox
          : options.runtime.sandbox === undefined
            ? "local"
            : options.runtime.sandbox;
      const model =
        typeof initOptions.model === "string"
          ? resolveNamedModel(options.runtime, initOptions.model)
          : initOptions.model ?? options.runtime.session.model;
      const thinkingLevel = initOptions.thinkingLevel ?? options.runtime.session.thinkingLevel;
      const agentId = initOptions.id ?? "default";
      const agentRuntime: PiCamlFlowRuntime = {
        ...options.runtime,
        cwd,
        sandbox: sandboxInput,
        session: {
          ...options.runtime.session,
          ...(model ? { model } : {}),
          ...(thinkingLevel ? { thinkingLevel } : {}),
        },
      };

      return new DefaultPiCamlFlowAgent(agentId, agentRuntime, {
        camlflow: options.camlflow,
        clientFactory: options.clientFactory,
        workerSessionFactory: options.workerSessionFactory,
        autoShutdown: options.autoShutdown,
        onTrace: options.onTrace,
        onDiagnostic: options.onDiagnostic,
        onProgress: options.onProgress,
        onOutputChunk: options.onOutputChunk,
        onTransportError: options.onTransportError,
      });
    },
  };
}

export function buildPiCamlFlowEffectPrompt(request: PiCamlFlowEffectRequest): string {
  validateEffectRequest(request);
  const parts = [
    `Execute the CamlFlow effect ${request.kind}:${request.name}.`,
    "",
    "Return exactly one JSON value as the final answer.",
    "Do not include markdown commentary before or after the JSON.",
  ];

  if (request.requestedModel) {
    parts.push(`Requested CamlFlow model: ${request.requestedModel}`);
  }

  if (request.declaredReturnType) {
    parts.push(`Declared return type: ${request.declaredReturnType}`);
  }

  if (request.outputSchema) {
    parts.push("Output schema:");
    parts.push(stringifyPromptJson(request.outputSchema, "CamlFlow effect outputSchema"));
  }

  parts.push("", "Rendered CamlFlow prompt:", request.renderedPrompt);
  return parts.join("\n");
}

export function unwrapJsonCodeFence(text: string): string {
  if (typeof text !== "string") {
    throw new Error("CamlFlow JSON output must be a string");
  }
  const trimmed = text.trim();
  const exactFence = trimmed.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/i);
  if (exactFence) {
    return exactFence[1].trim();
  }

  const firstFence = trimmed.match(/```(?:json)?\s*([\s\S]*?)\s*```/i);
  return firstFence ? firstFence[1].trim() : trimmed;
}

export function parseCamlFlowJsonOutput(text: string): JsonValue {
  const candidate = unwrapJsonCodeFence(text);
  try {
    return JSON.parse(candidate) as JsonValue;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const preview = candidate.length > 400 ? `${candidate.slice(0, 400)}...` : candidate;
    throw new Error(`CamlFlow effect returned invalid JSON: ${message}. Output: ${preview}`);
  }
}

class DefaultPiCamlFlowAgent implements PiCamlFlowAgent {
  private sandboxPromise: Promise<ResolvedPiCamlFlowSandbox> | undefined;
  private readonly sessions = new Set<DefaultPiCamlFlowAgentSession>();
  private readonly activeHosts = new Set<PiCamlFlowHostSession>();
  private taskIndex = 0;
  private closed = false;

  constructor(
    readonly id: string,
    private readonly runtime: PiCamlFlowRuntime,
    private readonly options: Omit<PiCamlFlowHarnessOptions, "runtime">,
  ) {}

  get cwd(): string {
    return this.runtime.cwd;
  }

  async session(threadId = "default"): Promise<PiCamlFlowAgentSession> {
    validateNonEmptyString(threadId, "Pi CamlFlow session id");
    const sandbox = await this.getSandbox();
    this.assertOpen();
    const model = resolveWorkerModel(this.runtime, {
      kind: "harness-session",
      name: `${this.id}:${threadId}`,
      requestedModel: null,
    });
    const workerSession = this.options.workerSessionFactory
      ? await this.options.workerSessionFactory(
          {
            kind: "harness-session",
            role: "agent",
            name: `${this.id}:${threadId}`,
            input: {},
            renderedPrompt: "",
            workingDirectory: sandbox.cwd,
            requestedModel: null,
          },
          {
            cwd: sandbox.cwd,
            model,
            thinkingLevel: this.runtime.session.thinkingLevel,
            runtime: this.runtime,
          },
        )
      : await createHarnessWorkerSession(this.runtime, {
          cwd: sandbox.cwd,
          model,
          thinkingLevel: this.runtime.session.thinkingLevel,
          sandbox,
        });
    validateWorkerSession(workerSession, "Pi CamlFlow harness worker session");
    if (this.closed) {
      try {
        workerSession.dispose();
      } catch {
        // The caller needs the lifecycle result; cleanup failures are reported by agent.close().
      }
      throw new Error(`Pi CamlFlow agent is closed: ${this.id}`);
    }

    const session = new DefaultPiCamlFlowAgentSession(
      `${this.id}:${threadId}`,
      sandbox,
      workerSession,
      {
        disposeSandbox: false,
        createTask: (text, taskOptions) => this.runTask(threadId, text, taskOptions),
        onClose: (closedSession) => {
          this.sessions.delete(closedSession);
        },
      },
    );
    this.sessions.add(session);
    return session;
  }

  async runWorkflow<TOutput extends JsonValue = JsonValue, TInput extends JsonValue = JsonValue>(
    runOptions: PiCamlFlowWorkflowRunOptions<TInput>,
  ): Promise<PiCamlFlowWorkflowRunResult<TOutput>> {
    const sandbox = await this.getSandbox();
    this.assertOpen();
    const host = createPiCamlFlowHostSession({
      runtime: {
        ...this.runtime,
        cwd: sandbox.cwd,
        sandbox: {
          kind: "custom",
          cwd: sandbox.cwd,
          tools: sandbox.tools,
          ...(sandbox.shell ? { shell: sandbox.shell } : {}),
        },
      },
      camlflow: this.options.camlflow,
      clientFactory: this.options.clientFactory,
      workerSessionFactory: this.options.workerSessionFactory,
      autoShutdown: this.options.autoShutdown,
      onTrace: this.options.onTrace,
      onDiagnostic: this.options.onDiagnostic,
      onProgress: this.options.onProgress,
      onOutputChunk: this.options.onOutputChunk,
      onTransportError: this.options.onTransportError,
    });
    if (this.closed) {
      await host.close();
      throw new Error(`Pi CamlFlow agent is closed: ${this.id}`);
    }
    this.activeHosts.add(host);
    try {
      return await host.runWorkflow<TOutput, TInput>(runOptions);
    } finally {
      this.activeHosts.delete(host);
    }
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;

    let closeError: unknown;
    const rememberError = (error: unknown): void => {
      closeError ??= error;
    };

    const sessionResults = await Promise.allSettled(
      Array.from(this.sessions, (session) => session.close()),
    );
    for (const result of sessionResults) {
      if (result.status === "rejected") {
        rememberError(result.reason);
      }
    }
    this.sessions.clear();

    const hostResults = await Promise.allSettled(
      Array.from(this.activeHosts, (host) => host.close()),
    );
    for (const result of hostResults) {
      if (result.status === "rejected") {
        rememberError(result.reason);
      }
    }
    this.activeHosts.clear();

    if (this.sandboxPromise) {
      const sandboxResult = await Promise.allSettled([this.sandboxPromise]);
      if (sandboxResult[0].status === "fulfilled") {
        try {
          await sandboxResult[0].value.dispose();
        } catch (error) {
          rememberError(error);
        }
      }
    }

    if (closeError) {
      throw closeError;
    }
  }

  private getSandbox(): Promise<ResolvedPiCamlFlowSandbox> {
    this.assertOpen();
    this.sandboxPromise ??= resolvePiCamlFlowSandbox(
      this.runtime.sandbox === undefined ? "local" : this.runtime.sandbox,
      this.runtime.cwd,
    );
    return this.sandboxPromise;
  }

  private assertOpen(): void {
    if (this.closed) {
      throw new Error(`Pi CamlFlow agent is closed: ${this.id}`);
    }
  }

  private async runTask<TOutput>(
    parentThreadId: string,
    text: string,
    options: PiCamlFlowPromptOptions<TOutput> | undefined,
  ): Promise<TOutput> {
    const taskId = `${parentThreadId}:task-${++this.taskIndex}`;
    const taskSession = await this.session(taskId);
    let primaryError: unknown;
    try {
      return await taskSession.prompt(text, options);
    } catch (error) {
      primaryError = error;
      throw error;
    } finally {
      try {
        await taskSession.close();
      } catch (error) {
        if (primaryError === undefined) {
          throw error;
        }
      }
    }
  }
}

class DefaultPiCamlFlowAgentSession implements PiCamlFlowAgentSession {
  private closed = false;
  private promptActive = false;
  private readonly promptSettlements = new Set<Promise<void>>();
  private readonly shellControllers = new Set<AbortController>();
  private readonly shellSettlements = new Set<Promise<void>>();

  constructor(
    readonly id: string,
    private readonly sandbox: ResolvedPiCamlFlowSandbox,
    private readonly session: PiCamlFlowWorkerSession,
    private readonly lifecycle: {
      disposeSandbox?: boolean;
      createTask?: <TOutput>(
        text: string,
        options: PiCamlFlowPromptOptions<TOutput> | undefined,
      ) => Promise<TOutput>;
      onClose?: (session: DefaultPiCamlFlowAgentSession) => void;
    } = {},
  ) {}

  get cwd(): string {
    return this.sandbox.cwd;
  }

  async prompt<TOutput = string>(
    text: string,
    options: PiCamlFlowPromptOptions<TOutput> = {},
  ): Promise<TOutput> {
    if (this.closed) {
      throw new Error(`Pi CamlFlow session is closed: ${this.id}`);
    }
    validateHarnessPromptText(text);
    validatePromptOptions(options, "Pi harness prompt options");
    if (options.signal?.aborted) {
      throw new PiCamlFlowEffectCancelledError({ kind: "harness-session", name: this.id });
    }
    if (this.promptActive) {
      throw new Error(`Pi CamlFlow session already has an active prompt: ${this.id}`);
    }

    const abortHandler = (): void => {
      void this.session.abort();
    };
    options.signal?.addEventListener("abort", abortHandler, { once: true });
    this.promptActive = true;
    let promptSettlement: Promise<void> | undefined;
    let primaryError: unknown;

    try {
      const messageStart = this.session.messages.length;
      const promptRun = this.session.prompt(text, {
        expandPromptTemplates: true,
        source: "extension",
      });
      const settlement = promptRun.then(
        () => undefined,
        () => undefined,
      );
      promptSettlement = settlement;
      this.promptSettlements.add(settlement);
      settlement.finally(() => {
        this.promptSettlements.delete(settlement);
      });
      await promptRun;

      const assistant = findLastAssistantMessage(this.session.messages.slice(messageStart));
      if (!assistant) {
        throw new Error(`Pi harness session produced no assistant message: ${this.id}`);
      }
      validateAssistantMessageStatus(assistant);
      if (assistant.stopReason === "aborted") {
        throw new PiCamlFlowEffectCancelledError({ kind: "harness-session", name: this.id });
      }
      if (assistant.stopReason === "error") {
        throw new Error(
          assistant.errorMessage
            ? `Pi harness session failed: ${assistant.errorMessage}`
            : `Pi harness session failed: ${this.id}`,
        );
      }

      const outputText = extractAssistantText(assistant);
      return parseHarnessResult(outputText, options.result);
    } catch (error) {
      primaryError = error;
      throw error;
    } finally {
      let cleanupError: unknown;
      this.promptActive = false;
      if (promptSettlement) {
        this.promptSettlements.delete(promptSettlement);
      }
      try {
        options.signal?.removeEventListener("abort", abortHandler);
      } catch (error) {
        cleanupError = error;
      }
      if (primaryError === undefined && cleanupError !== undefined) {
        throw cleanupError;
      }
    }
  }

  async skill<TOutput = string>(
    name: string,
    options: PiCamlFlowSkillOptions<TOutput> = {},
  ): Promise<TOutput> {
    validateSkillOptions(options);
    const prompt = buildSkillPrompt(name, options.args);
    return await this.prompt(prompt, options);
  }

  async task<TOutput = string>(
    text: string,
    options: PiCamlFlowPromptOptions<TOutput> = {},
  ): Promise<TOutput> {
    if (this.closed) {
      throw new Error(`Pi CamlFlow session is closed: ${this.id}`);
    }
    validateHarnessPromptText(text);
    validatePromptOptions(options, "Pi harness task options");
    if (!this.lifecycle.createTask) {
      throw new Error(`Pi CamlFlow session cannot create tasks: ${this.id}`);
    }
    return await this.lifecycle.createTask(text, options);
  }

  async shell(
    command: string,
    options: PiCamlFlowHarnessShellOptions = {},
  ): Promise<PiCamlFlowShellResult> {
    if (this.closed) {
      throw new Error(`Pi CamlFlow session is closed: ${this.id}`);
    }
    validateShellCommand(command);
    validateShellOptions(options);
    if (!this.sandbox.shell) {
      throw new Error(`Sandbox ${this.sandbox.kind} does not allow host shell execution`);
    }
    if (options.signal?.aborted) {
      return cancelledShellResult();
    }

    const controller = new AbortController();
    this.shellControllers.add(controller);
    const abortSignal = combineAbortSignals([options.signal, controller.signal]);
    let primaryError: unknown;
    try {
      const shellRun = Promise.resolve(
        this.sandbox.shell(command, {
          ...options,
          cwd: resolveSandboxCwd(this.sandbox.cwd, options.cwd),
          signal: abortSignal.signal,
        }),
      );
      const settlement = shellRun.then(
        () => undefined,
        () => undefined,
      );
      this.shellSettlements.add(settlement);
      settlement.finally(() => {
        this.shellSettlements.delete(settlement);
      });
      return validateShellResult(await shellRun);
    } catch (error) {
      primaryError = error;
      throw error;
    } finally {
      let cleanupError: unknown;
      try {
        abortSignal.cleanup();
      } catch (error) {
        cleanupError = error;
      }
      this.shellControllers.delete(controller);
      if (primaryError === undefined && cleanupError !== undefined) {
        throw cleanupError;
      }
    }
  }

  async abort(): Promise<void> {
    for (const controller of this.shellControllers) {
      controller.abort();
    }
    await this.session.abort();
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;

    let closeError: unknown;
    const rememberError = (error: unknown): void => {
      closeError ??= error;
    };

    try {
      await this.abort();
    } catch (error) {
      rememberError(error);
    }

    const promptResults = await Promise.allSettled(Array.from(this.promptSettlements));
    for (const result of promptResults) {
      if (result.status === "rejected") {
        rememberError(result.reason);
      }
    }

    const shellResults = await Promise.allSettled(Array.from(this.shellSettlements));
    for (const result of shellResults) {
      if (result.status === "rejected") {
        rememberError(result.reason);
      }
    }

    try {
      this.session.dispose();
    } catch (error) {
      rememberError(error);
    }

    try {
      if (this.lifecycle.disposeSandbox !== false) {
        await this.sandbox.dispose();
      }
    } catch (error) {
      rememberError(error);
    }

    try {
      this.lifecycle.onClose?.(this);
    } catch (error) {
      rememberError(error);
    }
    if (closeError) {
      throw closeError;
    }
  }
}

async function createDefaultWorkerSession(
  _request: PiCamlFlowEffectRequest,
  options: {
    cwd: string;
    model: PiModel;
    thinkingLevel?: PiThinkingLevel;
    runtime: PiCamlFlowRuntime;
  },
): Promise<PiCamlFlowWorkerSession> {
  const sandbox = await resolvePiCamlFlowSandbox(options.runtime.sandbox, options.cwd);
  const resourceLoader = createWorkerResourceLoader();
  const settingsManager = SettingsManager.inMemory({
    compaction: { enabled: false },
    retry: { enabled: false },
  });

  let result: Awaited<ReturnType<typeof createAgentSession>>;
  try {
    result = await createAgentSession({
      cwd: sandbox.cwd,
      agentDir: options.runtime.services.agentDir,
      authStorage: options.runtime.services.authStorage,
      modelRegistry: options.runtime.services.modelRegistry,
      model: options.model,
      thinkingLevel: options.thinkingLevel,
      tools: sandbox.tools,
      resourceLoader,
      sessionManager: SessionManager.inMemory(),
      settingsManager,
    });
  } catch (error) {
    await sandbox.dispose().catch(() => undefined);
    throw error;
  }

  return wrapAgentSession(result.session, sandbox);
}

function createWorkerResourceLoader(): ResourceLoader {
  const runtime = createExtensionRuntime();
  return {
    getExtensions: () => ({ extensions: [], errors: [], runtime }),
    getSkills: () => ({ skills: [], diagnostics: [] }),
    getPrompts: () => ({ prompts: [], diagnostics: [] }),
    getThemes: () => ({ themes: [], diagnostics: [] }),
    getAgentsFiles: () => ({ agentsFiles: [] }),
    getSystemPrompt: () => WORKER_SYSTEM_PROMPT,
    getAppendSystemPrompt: () => [],
    extendResources: () => undefined,
    reload: async () => undefined,
  };
}

function validateWorkflowRunOptions(options: PiCamlFlowWorkflowRunOptions): void {
  if (typeof options !== "object" || options === null || Array.isArray(options)) {
    throw new Error("CamlFlow workflow options must be an object");
  }
  validateNonEmptyString(options.workflowPath, "CamlFlow workflowPath");
  validateNoNulString(options.workflowPath, "CamlFlow workflowPath");
  if (options.entrypoint !== undefined) {
    validateNonEmptyString(options.entrypoint, "CamlFlow entrypoint");
    validateNoNulString(options.entrypoint, "CamlFlow entrypoint");
  }
  if (options.skillsDir !== undefined && options.skillsDir !== null) {
    validateNonEmptyString(options.skillsDir, "CamlFlow skillsDir");
    validateNoNulString(options.skillsDir, "CamlFlow skillsDir");
  }
  if (options.includePaths !== undefined && !Array.isArray(options.includePaths)) {
    throw new Error("CamlFlow includePaths must be an array of non-empty strings");
  }
  for (const includePath of options.includePaths ?? []) {
    if (typeof includePath !== "string" || includePath.trim().length === 0) {
      throw new Error("CamlFlow includePaths must not contain empty paths");
    }
    validateNoNulString(includePath, "CamlFlow includePaths entry");
  }
  if (options.signal !== undefined) {
    validateAbortSignal(options.signal, "CamlFlow workflow signal");
  }
  if (options.input !== undefined) {
    stringifyPromptJson(options.input, "CamlFlow workflow input");
  }
}

interface ResolvedPiCamlFlowSandbox {
  kind: string;
  cwd: string;
  tools: PiTool[];
  shell?: PiCamlFlowShellExecutor;
  dispose(): Promise<void>;
}

type NormalizedPiCamlFlowSandboxConfig = Omit<PiCamlFlowSandboxConfig, "kind"> & {
  kind?: PiCamlFlowSandboxPreset | "custom";
  dispose?: () => MaybePromise<void>;
};

async function resolvePiCamlFlowSandbox(
  input: PiCamlFlowSandboxInput | undefined,
  fallbackCwd: string,
): Promise<ResolvedPiCamlFlowSandbox> {
  const config = await normalizeSandboxInput(input, fallbackCwd);
  validateNormalizedSandboxConfig(config);
  const kind = config.kind ?? "local";
  validateSandboxConfig(config, kind);
  validateSandboxKind(kind);
  if (kind === "custom" && config.tools === undefined) {
    throw new Error("Custom Pi CamlFlow sandboxes must provide tools");
  }
  const cwd =
    kind === "ephemeral"
      ? await mkdtemp(resolve(tmpdir(), "camlflow-pi-"))
      : config.cwd ?? fallbackCwd;
  const cleanup = kind === "ephemeral" && config.cleanup !== false;
  let disposed = false;
  const dispose = async (): Promise<void> => {
    if (disposed) {
      return;
    }
    disposed = true;
    let disposeError: unknown;
    try {
      await config.dispose?.();
    } catch (error) {
      disposeError = error;
    }
    try {
      if (cleanup) {
        await rm(cwd, { recursive: true, force: true });
      }
    } catch (error) {
      disposeError ??= error;
    }
    if (disposeError) {
      throw disposeError;
    }
  };

  let tools: PiTool[];
  try {
    tools = config.tools
      ? typeof config.tools === "function"
        ? config.tools(cwd)
        : config.tools
      : kind === "read-only"
        ? createReadOnlyTools(cwd)
        : createCodingTools(cwd);
    validateSandboxTools(tools);
  } catch (error) {
    await dispose().catch(() => undefined);
    throw error;
  }

  const shell =
    config.shell === false
      ? undefined
      : config.shell ??
        (kind === "read-only" || kind === "custom"
          ? undefined
          : createLocalShellExecutor(cwd));

  return {
    kind,
    cwd,
    tools,
    shell,
    dispose,
  };
}

function validateSandboxKind(kind: string): void {
  if (typeof kind !== "string" || kind.trim().length === 0) {
    throw new Error("Pi CamlFlow sandbox kind must not be empty");
  }
  if (kind !== "custom" && !SANDBOX_PRESETS.has(kind)) {
    throw new Error(`Unknown Pi CamlFlow sandbox kind: ${kind}`);
  }
}

function validateSandboxConfig(
  config: NormalizedPiCamlFlowSandboxConfig,
  kind: string,
): void {
  if (config.cwd !== undefined) {
    validateNonEmptyString(config.cwd, "Pi CamlFlow sandbox cwd");
    validateNoNulString(config.cwd, "Pi CamlFlow sandbox cwd");
  }
  if (
    config.tools !== undefined &&
    !Array.isArray(config.tools) &&
    typeof config.tools !== "function"
  ) {
    throw new Error("Pi CamlFlow sandbox tools must be an array or factory");
  }
  if (
    config.shell !== undefined &&
    config.shell !== false &&
    typeof config.shell !== "function"
  ) {
    throw new Error("Pi CamlFlow sandbox shell must be a function or false");
  }
  if (config.cleanup !== undefined && typeof config.cleanup !== "boolean") {
    throw new Error("Pi CamlFlow sandbox cleanup must be a boolean");
  }
  if (config.dispose !== undefined && typeof config.dispose !== "function") {
    throw new Error("Pi CamlFlow sandbox dispose must be a function");
  }
  if (kind !== "ephemeral" && config.cleanup !== undefined) {
    throw new Error("Pi CamlFlow sandbox cleanup is only supported for ephemeral sandboxes");
  }
}

function validateSandboxTools(tools: unknown): asserts tools is PiTool[] {
  if (!Array.isArray(tools)) {
    throw new Error("Pi CamlFlow sandbox tools must be an array or factory");
  }
}

function normalizeSandboxInput(
  input: PiCamlFlowSandboxInput | undefined,
  fallbackCwd: string,
  options: { allowDefault?: boolean } = { allowDefault: true },
): Promise<NormalizedPiCamlFlowSandboxConfig> | NormalizedPiCamlFlowSandboxConfig {
  if (input === undefined) {
    if (options.allowDefault === false) {
      throw new Error("Pi CamlFlow sandbox factory must return a sandbox config");
    }
    return { kind: "local" };
  }
  if (input === null) {
    throw new Error("Pi CamlFlow sandbox config must be an object, string, or factory");
  }
  if (typeof input === "string") {
    return { kind: input };
  }
  if (typeof input === "function") {
    return Promise.resolve(input(fallbackCwd)).then((resolved) =>
      normalizeSandboxInput(resolved, fallbackCwd, { allowDefault: false }),
    );
  }
  validateNormalizedSandboxConfig(input);
  return input;
}

function validateNormalizedSandboxConfig(
  config: unknown,
): asserts config is NormalizedPiCamlFlowSandboxConfig {
  if (typeof config !== "object" || config === null || Array.isArray(config)) {
    throw new Error("Pi CamlFlow sandbox config must be an object, string, or factory");
  }
}

async function createHarnessWorkerSession(
  runtime: PiCamlFlowRuntime,
  options: {
    cwd: string;
    model: PiModel;
    thinkingLevel?: PiThinkingLevel;
    sandbox: ResolvedPiCamlFlowSandbox;
  },
): Promise<PiCamlFlowWorkerSession> {
  const resourceLoader = new DefaultResourceLoader({
    cwd: options.cwd,
    agentDir: runtime.services.agentDir,
    settingsManager: SettingsManager.inMemory({
      compaction: { enabled: false },
      retry: { enabled: false },
    }),
  });
  await resourceLoader.reload();

  const result = await createAgentSession({
    cwd: options.cwd,
    agentDir: runtime.services.agentDir,
    authStorage: runtime.services.authStorage,
    modelRegistry: runtime.services.modelRegistry,
    model: options.model,
    thinkingLevel: options.thinkingLevel,
    tools: options.sandbox.tools,
    resourceLoader,
    sessionManager: SessionManager.inMemory(),
    settingsManager: SettingsManager.inMemory({
      compaction: { enabled: false },
      retry: { enabled: false },
    }),
  });

  return wrapAgentSession(result.session, options.sandbox, { disposeSandbox: false });
}

function wrapAgentSession(
  session: AgentSession,
  sandbox: ResolvedPiCamlFlowSandbox,
  options: { disposeSandbox?: boolean } = {},
): PiCamlFlowWorkerSession {
  return {
    get messages() {
      return session.messages;
    },
    prompt: session.prompt.bind(session),
    subscribe: session.subscribe.bind(session),
    abort: session.abort.bind(session),
    dispose: () => {
      session.dispose();
      if (options.disposeSandbox !== false) {
        void sandbox.dispose();
      }
    },
  };
}

function createLocalShellExecutor(defaultCwd: string): PiCamlFlowShellExecutor {
  return async (command, options = {}) =>
    executeLocalShell(command, {
      ...options,
      cwd: resolveLocalShellCwd(defaultCwd, options.cwd),
    });
}

function resolveSandboxCwd(baseCwd: string, requestedCwd: string | undefined): string {
  const sandboxRoot = resolve(baseCwd);
  const cwd = requestedCwd ? resolve(sandboxRoot, requestedCwd) : sandboxRoot;
  const relativePath = relative(sandboxRoot, cwd);
  if (relativePath !== "" && (relativePath.startsWith("..") || isAbsolute(relativePath))) {
    throw new Error(`Shell cwd escapes sandbox root: ${requestedCwd}`);
  }
  return cwd;
}

function resolveLocalShellCwd(baseCwd: string, requestedCwd: string | undefined): string {
  const cwd = resolveSandboxCwd(baseCwd, requestedCwd);
  const realSandboxRoot = realpathSync(baseCwd);
  const realCwd = realpathSync(cwd);
  const relativePath = relative(realSandboxRoot, realCwd);
  if (relativePath !== "" && (relativePath.startsWith("..") || isAbsolute(relativePath))) {
    throw new Error(`Shell cwd escapes sandbox root: ${requestedCwd}`);
  }
  return realCwd;
}

function executeLocalShell(
  command: string,
  options: PiCamlFlowShellOptions = {},
): Promise<PiCamlFlowShellResult> {
  if (options.signal?.aborted) {
    return Promise.resolve(cancelledShellResult());
  }

  return new Promise((resolveShell, reject) => {
    const detached = process.platform !== "win32";
    const child = spawn(command, {
      cwd: options.cwd,
      env: { ...process.env, ...options.env },
      detached,
      shell: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let settled = false;
    let timeout: NodeJS.Timeout | undefined;
    const cleanup = (): void => {
      if (timeout) {
        clearTimeout(timeout);
      }
      options.signal?.removeEventListener("abort", abortHandler);
    };
    const terminate = (): void => {
      if (child.exitCode !== null || child.signalCode !== null) {
        return;
      }
      if (detached && child.pid !== undefined) {
        try {
          process.kill(-child.pid, "SIGTERM");
          return;
        } catch {
          child.kill("SIGTERM");
          return;
        }
      }
      child.kill("SIGTERM");
    };
    const abortHandler = (): void => {
      terminate();
    };
    options.signal?.addEventListener("abort", abortHandler, { once: true });
    if (options.signal?.aborted) {
      terminate();
    }
    timeout =
      options.timeoutMs === undefined
        ? undefined
        : setTimeout(() => {
            terminate();
          }, options.timeoutMs);

    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.on("error", (error) => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      reject(error);
    });
    child.on("close", (code, signal) => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      resolveShell({
        code,
        signal,
        stdout: Buffer.concat(stdout).toString("utf8"),
        stderr: Buffer.concat(stderr).toString("utf8"),
      });
    });

    if (options.stdin !== undefined) {
      child.stdin.end(options.stdin);
    } else {
      child.stdin.end();
    }
  });
}

function cancelledShellResult(): PiCamlFlowShellResult {
  return {
    code: null,
    signal: "SIGTERM",
    stdout: "",
    stderr: "",
  };
}

function parseHarnessResult<TOutput>(
  outputText: string,
  parser: PiCamlFlowResultParser<TOutput> | undefined,
): TOutput {
  if (parser === undefined) {
    return outputText as TOutput;
  }

  const json = parseCamlFlowJsonOutput(outputText);
  if (parser === "json") {
    return json as TOutput;
  }
  if (typeof parser === "function") {
    return parser(json);
  }

  if (typeof parser !== "object" || parser === null) {
    throw new Error("Pi harness result parser must be \"json\", a function, parse(value), or safeParse(value)");
  }
  if ("parse" in parser) {
    if (typeof parser.parse !== "function") {
      throw new Error("Pi harness result parser parse must be a function");
    }
    return parser.parse(json);
  }
  if (!("safeParse" in parser) || typeof parser.safeParse !== "function") {
    throw new Error("Pi harness result parser must be \"json\", a function, parse(value), or safeParse(value)");
  }
  const result = parser.safeParse(json);
  if (typeof result !== "object" || result === null || !("success" in result)) {
    throw new Error("Pi harness result safeParse must return a success result");
  }
  if (result.success === true) {
    if (!("output" in result) && !("data" in result)) {
      throw new Error("Pi harness result safeParse success must include output or data");
    }
    return "output" in result
      ? (result as { output: TOutput }).output
      : (result as { data: TOutput }).data;
  }
  if (result.success !== false) {
    throw new Error("Pi harness result safeParse must return a success result");
  }
  throw new Error(
    `Pi harness result failed schema validation: ${formatSchemaIssues(result)}`,
  );
}

function validateResultParserOption(parser: unknown): void {
  if (parser === undefined) {
    return;
  }
  if (parser === "json" || typeof parser === "function") {
    return;
  }
  if (typeof parser !== "object" || parser === null || Array.isArray(parser)) {
    throw new Error("Pi harness result parser must be \"json\", a function, parse(value), or safeParse(value)");
  }
  if ("parse" in parser) {
    if (typeof (parser as { parse?: unknown }).parse !== "function") {
      throw new Error("Pi harness result parser parse must be a function");
    }
    return;
  }
  if (typeof (parser as { safeParse?: unknown }).safeParse !== "function") {
    throw new Error("Pi harness result parser must be \"json\", a function, parse(value), or safeParse(value)");
  }
}

function formatSchemaIssues(result: { issues?: unknown; error?: unknown }): string {
  const details = result.issues ?? result.error ?? [];
  if (details instanceof Error) {
    return details.message;
  }
  return JSON.stringify(details);
}

function buildSkillPrompt(name: string, args: JsonValue | undefined): string {
  validateSkillName(name);
  if (args !== undefined) {
    return `/skill:${name} ${stringifyPromptJson(args, "Pi skill args")}`;
  }
  return `/skill:${name}`;
}

function validateSkillName(name: string): void {
  if (
    typeof name !== "string" ||
    name.length === 0 ||
    name.length > 64 ||
    !/^[a-z0-9-]+$/.test(name) ||
    name.startsWith("-") ||
    name.endsWith("-") ||
    name.includes("--")
  ) {
    throw new Error(
      `Invalid Pi skill name "${name}": use lowercase letters, digits, and single hyphens only`,
    );
  }
}

function validateHarnessPromptText(text: string): void {
  if (typeof text !== "string" || text.trim().length === 0) {
    throw new Error("Pi harness prompt text must not be empty");
  }
}

function validateShellCommand(command: string): void {
  if (typeof command !== "string" || command.trim().length === 0) {
    throw new Error("Pi harness shell command must not be empty");
  }
  validateNoNulString(command, "Pi harness shell command");
}

function validateShellOptions(options: PiCamlFlowShellOptions): void {
  if (typeof options !== "object" || options === null || Array.isArray(options)) {
    throw new Error("Pi harness shell options must be an object");
  }
  if (options.cwd !== undefined) {
    validateNonEmptyString(options.cwd, "Pi harness shell cwd");
    validateNoNulString(options.cwd, "Pi harness shell cwd");
  }
  if (options.env !== undefined) {
    validateShellEnv(options.env, "Pi harness shell env");
  }
  if (options.stdin !== undefined && typeof options.stdin !== "string") {
    throw new Error("Pi harness shell stdin must be a string");
  }
  if (options.stdin !== undefined) {
    validateNoNulString(options.stdin, "Pi harness shell stdin");
  }
  if (
    options.timeoutMs !== undefined &&
    (!Number.isFinite(options.timeoutMs) || options.timeoutMs < 0)
  ) {
    throw new Error("Pi harness shell timeoutMs must be a finite non-negative number");
  }
  if (options.signal !== undefined) {
    validateAbortSignal(options.signal, "Pi harness shell signal");
  }
}

function validateShellResult(result: unknown): PiCamlFlowShellResult {
  if (typeof result !== "object" || result === null || Array.isArray(result)) {
    throw new Error("Pi harness shell executor returned an invalid shell result");
  }
  const candidate = result as PiCamlFlowShellResult;
  if (
    candidate.code !== null &&
    (typeof candidate.code !== "number" ||
      !Number.isInteger(candidate.code) ||
      candidate.code < 0)
  ) {
    throw new Error("Pi harness shell executor returned an invalid shell result");
  }
  if (candidate.signal !== null) {
    validateNonEmptyString(candidate.signal, "Pi harness shell result signal");
    validateNoNulString(candidate.signal, "Pi harness shell result signal");
  }
  if (typeof candidate.stdout !== "string" || typeof candidate.stderr !== "string") {
    throw new Error("Pi harness shell executor returned an invalid shell result");
  }
  return candidate;
}

function validateWorkerSession(
  session: unknown,
  label: string,
): asserts session is PiCamlFlowWorkerSession {
  if (typeof session !== "object" || session === null) {
    throw new Error(`${label} must be an object`);
  }
  const candidate = session as PiCamlFlowWorkerSession;
  if (!Array.isArray(candidate.messages)) {
    throw new Error(`${label} must provide a messages array`);
  }
  if (
    typeof candidate.prompt !== "function" ||
    typeof candidate.subscribe !== "function" ||
    typeof candidate.abort !== "function" ||
    typeof candidate.dispose !== "function"
  ) {
    throw new Error(`${label} must provide prompt, subscribe, abort, and dispose`);
  }
}

function validatePromptOptions(
  options: PiCamlFlowPromptOptions<unknown>,
  label: string,
): void {
  if (typeof options !== "object" || options === null || Array.isArray(options)) {
    throw new Error(`${label} must be an object`);
  }
  if (options.signal !== undefined) {
    validateAbortSignal(options.signal, `${label} signal`);
  }
  validateResultParserOption(options.result);
}

function validateSkillOptions(options: PiCamlFlowSkillOptions<unknown>): void {
  validatePromptOptions(options, "Pi harness skill options");
}

function validateAbortSignal(signal: unknown, label: string): asserts signal is AbortSignal {
  if (
    typeof signal !== "object" ||
    signal === null ||
    typeof (signal as AbortSignal).aborted !== "boolean" ||
    typeof (signal as AbortSignal).addEventListener !== "function" ||
    typeof (signal as AbortSignal).removeEventListener !== "function"
  ) {
    throw new Error(`${label} must be an AbortSignal`);
  }
}

function validateCamlFlowClient(client: unknown): asserts client is CamlFlowClientLike {
  if (typeof client !== "object" || client === null) {
    throw new Error("Pi CamlFlow JSON-RPC client must be an object");
  }
  const candidate = client as CamlFlowClientLike;
  if (
    typeof candidate.initialize !== "function" ||
    typeof candidate.run !== "function" ||
    typeof candidate.shutdownAndExit !== "function"
  ) {
    throw new Error("Pi CamlFlow JSON-RPC client must provide initialize, run, and shutdownAndExit");
  }
}

function validateCamlFlowInitializeResult(
  result: unknown,
): asserts result is { protocolVersion: string; irVersion: string } {
  if (typeof result !== "object" || result === null || Array.isArray(result)) {
    throw new Error("Pi CamlFlow JSON-RPC initialize result must be an object");
  }
  stringifyPromptJson(result, "Pi CamlFlow JSON-RPC initialize result");
  const candidate = result as {
    protocolVersion?: unknown;
    irVersion?: unknown;
    capabilities?: unknown;
    effectKinds?: unknown;
  };
  validateNonEmptyString(
    candidate.protocolVersion,
    "Pi CamlFlow JSON-RPC initialize result protocolVersion",
  );
  validateNoNulString(
    candidate.protocolVersion,
    "Pi CamlFlow JSON-RPC initialize result protocolVersion",
  );
  validateNonEmptyString(
    candidate.irVersion,
    "Pi CamlFlow JSON-RPC initialize result irVersion",
  );
  validateNoNulString(
    candidate.irVersion,
    "Pi CamlFlow JSON-RPC initialize result irVersion",
  );
  if (
    typeof candidate.capabilities !== "object" ||
    candidate.capabilities === null ||
    Array.isArray(candidate.capabilities)
  ) {
    throw new Error(
      "Pi CamlFlow JSON-RPC initialize result capabilities must be an object",
    );
  }
  for (const name of CAMLFLOW_CAPABILITY_NAMES) {
    const capability = (candidate.capabilities as Record<string, unknown>)[name];
    if (capability !== true && capability !== false) {
      throw new Error(
        `Pi CamlFlow JSON-RPC initialize result capabilities.${name} must be a boolean`,
      );
    }
  }
  if (!Array.isArray(candidate.effectKinds)) {
    throw new Error("Pi CamlFlow JSON-RPC initialize result effectKinds must be an array");
  }
  for (const [index, kind] of candidate.effectKinds.entries()) {
    if (
      kind !== "bound-agent" &&
      kind !== "bound-skill" &&
      kind !== "local-prompt-skill" &&
      kind !== "inline-agent"
    ) {
      throw new Error(
        `Pi CamlFlow JSON-RPC initialize result effectKinds[${index}] is invalid`,
      );
    }
  }
}

function validateCamlFlowRunResult<TOutput extends JsonValue>(
  result: unknown,
): asserts result is CamlFlowRunResult<TOutput> {
  if (typeof result !== "object" || result === null || Array.isArray(result)) {
    throw new Error("Pi CamlFlow JSON-RPC run result must be an object");
  }
  stringifyPromptJson(result, "Pi CamlFlow JSON-RPC run result");
  const candidate = result as {
    runId?: unknown;
    stepsRun?: unknown;
    output?: unknown;
  };
  validateNonEmptyString(candidate.runId, "Pi CamlFlow JSON-RPC run result runId");
  validateNoNulString(candidate.runId, "Pi CamlFlow JSON-RPC run result runId");
  if (
    typeof candidate.stepsRun !== "number" ||
    !Number.isInteger(candidate.stepsRun) ||
    candidate.stepsRun < 0
  ) {
    throw new Error(
      "Pi CamlFlow JSON-RPC run result stepsRun must be a non-negative integer",
    );
  }
  stringifyPromptJson(candidate.output, "Pi CamlFlow JSON-RPC run result output");
}

function wrapTraceCallback(
  callback: PiCamlFlowCallbacks["onTrace"],
): PiCamlFlowCallbacks["onTrace"] {
  if (!callback) {
    return undefined;
  }
  return async (trace, notification) => {
    validateCamlFlowTraceNotification(trace);
    const params = validateJsonRpcNotification(
      notification,
      CamlFlowRpc.CAMLFLOW_METHODS.trace,
      "Pi CamlFlow JSON-RPC trace notification",
    );
    validateCamlFlowTraceNotification(params);
    await callback(params as CamlFlowTraceNotification, notification);
  };
}

function wrapDiagnosticCallback(
  callback: PiCamlFlowCallbacks["onDiagnostic"],
): PiCamlFlowCallbacks["onDiagnostic"] {
  if (!callback) {
    return undefined;
  }
  return async (diagnostic, notification) => {
    validateCamlFlowDiagnosticNotification(diagnostic);
    const params = validateJsonRpcNotification(
      notification,
      CamlFlowRpc.CAMLFLOW_METHODS.diagnostic,
      "Pi CamlFlow JSON-RPC diagnostic notification",
    );
    validateCamlFlowDiagnosticNotification(params);
    await callback(params as CamlFlowDiagnosticNotification, notification);
  };
}

function wrapProgressCallback(
  callback: PiCamlFlowCallbacks["onProgress"],
): PiCamlFlowCallbacks["onProgress"] {
  if (!callback) {
    return undefined;
  }
  return async (progress, notification) => {
    validateCamlFlowProgressNotification(progress);
    const params = validateJsonRpcNotification(
      notification,
      CamlFlowRpc.CAMLFLOW_METHODS.progress,
      "Pi CamlFlow JSON-RPC progress notification",
    );
    validateCamlFlowProgressNotification(params);
    await callback(params as CamlFlowProgressNotification, notification);
  };
}

function wrapOutputChunkCallback(
  callback: PiCamlFlowCallbacks["onOutputChunk"],
): PiCamlFlowCallbacks["onOutputChunk"] {
  if (!callback) {
    return undefined;
  }
  return async (chunk, notification) => {
    validateCamlFlowOutputChunkNotification(chunk);
    const params = validateJsonRpcNotification(
      notification,
      CamlFlowRpc.CAMLFLOW_METHODS.outputChunk,
      "Pi CamlFlow JSON-RPC outputChunk notification",
    );
    validateCamlFlowOutputChunkNotification(params);
    await callback(params as CamlFlowOutputChunkNotification, notification);
  };
}

function validateJsonRpcNotification(
  notification: unknown,
  expectedMethod: string,
  label: string,
): unknown {
  if (typeof notification !== "object" || notification === null || Array.isArray(notification)) {
    throw new Error(`${label} must be an object`);
  }
  stringifyPromptJson(notification, label);
  const candidate = notification as {
    jsonrpc?: unknown;
    method?: unknown;
    params?: unknown;
  };
  if (candidate.jsonrpc !== "2.0") {
    throw new Error(`${label} jsonrpc must be 2.0`);
  }
  if (candidate.method !== expectedMethod) {
    throw new Error(`${label} method must be ${expectedMethod}`);
  }
  if (candidate.params === undefined) {
    throw new Error(`${label} params must be present`);
  }
  stringifyPromptJson(candidate.params, `${label} params`);
  return candidate.params;
}

function validateCamlFlowTraceNotification(trace: unknown): void {
  validateJsonObjectPayload(trace, "Pi CamlFlow JSON-RPC trace params");
  const candidate = trace as CamlFlowTraceNotification;
  if (
    candidate.event !== "run-start" &&
    candidate.event !== "effect-request" &&
    candidate.event !== "effect-result" &&
    candidate.event !== "effect-error" &&
    candidate.event !== "run-finish" &&
    candidate.event !== "run-error" &&
    candidate.event !== "run-cancelled"
  ) {
    throw new Error("Pi CamlFlow JSON-RPC trace params event is invalid");
  }
  validateNullableRunId(candidate.runId, "Pi CamlFlow JSON-RPC trace params runId");
  validateNullableStep(candidate.step, "Pi CamlFlow JSON-RPC trace params step");
  validateNullableEffectSummary(
    candidate.effect,
    "Pi CamlFlow JSON-RPC trace params effect",
  );
  if (candidate.details !== undefined) {
    stringifyPromptJson(candidate.details, "Pi CamlFlow JSON-RPC trace params details");
  }
}

function validateCamlFlowDiagnosticNotification(diagnostic: unknown): void {
  validateJsonObjectPayload(diagnostic, "Pi CamlFlow JSON-RPC diagnostic params");
  const candidate = diagnostic as CamlFlowDiagnosticNotification;
  if (candidate.severity !== "error") {
    throw new Error("Pi CamlFlow JSON-RPC diagnostic params severity must be error");
  }
  validateNonEmptyString(candidate.message, "Pi CamlFlow JSON-RPC diagnostic params message");
  validateNullableString(
    candidate.method,
    "Pi CamlFlow JSON-RPC diagnostic params method",
    false,
  );
  validateNullableRunId(
    candidate.runId,
    "Pi CamlFlow JSON-RPC diagnostic params runId",
  );
  validateNullableStep(candidate.step, "Pi CamlFlow JSON-RPC diagnostic params step");
  validateNullableEffectSummary(
    candidate.effect,
    "Pi CamlFlow JSON-RPC diagnostic params effect",
  );
}

function validateCamlFlowProgressNotification(progress: unknown): void {
  validateJsonObjectPayload(progress, "Pi CamlFlow JSON-RPC progress params");
  const candidate = progress as CamlFlowProgressNotification;
  validateNullableRunId(candidate.runId, "Pi CamlFlow JSON-RPC progress params runId");
  validateNonEmptyString(candidate.stage, "Pi CamlFlow JSON-RPC progress params stage");
  validateNullableStep(candidate.step, "Pi CamlFlow JSON-RPC progress params step");
  validateNullableString(
    candidate.message,
    "Pi CamlFlow JSON-RPC progress params message",
    false,
  );
  validateNullableStep(
    candidate.completedSteps,
    "Pi CamlFlow JSON-RPC progress params completedSteps",
  );
  validateNullableStep(
    candidate.knownSteps,
    "Pi CamlFlow JSON-RPC progress params knownSteps",
  );
  if (candidate.cancellable !== null && typeof candidate.cancellable !== "boolean") {
    throw new Error("Pi CamlFlow JSON-RPC progress params cancellable must be boolean or null");
  }
}

function validateCamlFlowOutputChunkNotification(chunk: unknown): void {
  validateJsonObjectPayload(chunk, "Pi CamlFlow JSON-RPC outputChunk params");
  const candidate = chunk as CamlFlowOutputChunkNotification;
  validateNullableRunId(candidate.runId, "Pi CamlFlow JSON-RPC outputChunk params runId");
  validateNullableStep(candidate.step, "Pi CamlFlow JSON-RPC outputChunk params step");
  validateNonEmptyString(
    candidate.streamId,
    "Pi CamlFlow JSON-RPC outputChunk params streamId",
  );
  validateNoNulString(
    candidate.streamId,
    "Pi CamlFlow JSON-RPC outputChunk params streamId",
  );
  validateNonEmptyString(candidate.format, "Pi CamlFlow JSON-RPC outputChunk params format");
  stringifyPromptJson(candidate.delta, "Pi CamlFlow JSON-RPC outputChunk params delta");
  if (typeof candidate.done !== "boolean") {
    throw new Error("Pi CamlFlow JSON-RPC outputChunk params done must be a boolean");
  }
  validateNullableString(
    candidate.declaredReturnType,
    "Pi CamlFlow JSON-RPC outputChunk params declaredReturnType",
    true,
  );
  if (candidate.outputSchema !== null) {
    validateJsonObjectPayload(
      candidate.outputSchema,
      "Pi CamlFlow JSON-RPC outputChunk params outputSchema",
    );
  }
}

function validateExecuteEffectParams(params: unknown): void {
  validateJsonObjectPayload(params, "Pi CamlFlow JSON-RPC executeEffect params");
  const candidate = params as {
    runId?: unknown;
    step?: unknown;
    effect?: unknown;
  };
  validateNullableRunId(
    candidate.runId,
    "Pi CamlFlow JSON-RPC executeEffect params runId",
  );
  validateNullableStep(candidate.step, "Pi CamlFlow JSON-RPC executeEffect params step");
  validateJsonObjectPayload(
    candidate.effect,
    "Pi CamlFlow JSON-RPC executeEffect params effect",
  );
  const effect = candidate.effect as {
    kind?: unknown;
    role?: unknown;
    inlineDefinition?: unknown;
    runId?: unknown;
    step?: unknown;
    unsupportedSettings?: unknown;
  };
  validateCamlFlowEffectKind(
    effect.kind,
    "Pi CamlFlow JSON-RPC executeEffect params effect kind",
  );
  if (effect.role !== "agent" && effect.role !== "skill") {
    throw new Error("Pi CamlFlow JSON-RPC executeEffect params effect role is invalid");
  }
  validateEffectKindRolePair(effect.kind, effect.role);
  validateExecuteEffectMetadataMatch(candidate.runId, effect.runId, "runId");
  validateExecuteEffectMetadataMatch(candidate.step, effect.step, "step");
  validateUnsupportedSettings(effect.unsupportedSettings);
  validateNullableInlineDefinition(effect.inlineDefinition);
  validateInlineDefinitionKindPair(effect.kind, effect.inlineDefinition);
  validateEffectRequest(paramsToEffectRequest(params as CamlFlowExecuteEffectParams));
}

function validateExecuteEffectMetadataMatch(
  paramsValue: unknown,
  effectValue: unknown,
  name: "runId" | "step",
): void {
  const label = `Pi CamlFlow JSON-RPC executeEffect params effect ${name}`;
  if (name === "runId") {
    validateNullableRunId(effectValue, label);
  } else {
    validateNullableStep(effectValue, label);
  }
  if (paramsValue !== effectValue) {
    throw new Error(`Pi CamlFlow JSON-RPC executeEffect params ${name} metadata must match`);
  }
}

function validateEffectKindRolePair(kind: unknown, role: unknown): void {
  const expectedRole =
    kind === "bound-agent" || kind === "inline-agent" ? "agent" : "skill";
  if (role !== expectedRole) {
    throw new Error(
      "Pi CamlFlow JSON-RPC executeEffect params effect kind and role must match",
    );
  }
}

function validateUnsupportedSettings(value: unknown): void {
  if (!Array.isArray(value)) {
    throw new Error(
      "Pi CamlFlow JSON-RPC executeEffect params effect unsupportedSettings must be an array",
    );
  }
  for (const [index, setting] of value.entries()) {
    validateNonEmptyString(
      setting,
      `Pi CamlFlow JSON-RPC executeEffect params effect unsupportedSettings[${index}]`,
    );
    validateNoNulString(
      setting,
      `Pi CamlFlow JSON-RPC executeEffect params effect unsupportedSettings[${index}]`,
    );
  }
}

function validateNullableInlineDefinition(value: unknown): void {
  if (value === null) {
    return;
  }
  const label = "Pi CamlFlow JSON-RPC executeEffect params effect inlineDefinition";
  validateJsonObjectPayload(value, label);
  const candidate = value as {
    model?: unknown;
    temperature?: unknown;
    system_prompt?: unknown;
    metadata?: unknown;
    loc?: unknown;
  };
  validateNullableString(candidate.model, `${label} model`, false);
  if (typeof candidate.model === "string") {
    validateNoNulString(candidate.model, `${label} model`);
  }
  if (candidate.temperature !== null && typeof candidate.temperature !== "number") {
    throw new Error(`${label} temperature must be a number or null`);
  }
  if (typeof candidate.temperature === "number" && !Number.isFinite(candidate.temperature)) {
    throw new Error(`${label} temperature must be finite`);
  }
  validateNullableString(candidate.system_prompt, `${label} system_prompt`, true);
  validateInlineMetadata(candidate.metadata, `${label} metadata`);
  validateLocation(candidate.loc, `${label} loc`);
}

function validateInlineDefinitionKindPair(kind: unknown, inlineDefinition: unknown): void {
  if (kind === "inline-agent" && inlineDefinition === null) {
    throw new Error(
      "Pi CamlFlow JSON-RPC executeEffect params effect inline-agent requires inlineDefinition",
    );
  }
  if (kind !== "inline-agent" && inlineDefinition !== null) {
    throw new Error(
      "Pi CamlFlow JSON-RPC executeEffect params effect inlineDefinition requires inline-agent kind",
    );
  }
}

function validateInlineMetadata(value: unknown, label: string): void {
  if (!Array.isArray(value)) {
    throw new Error(`${label} must be an array`);
  }
  for (const [index, entry] of value.entries()) {
    const entryLabel = `${label}[${index}]`;
    validateJsonObjectPayload(entry, entryLabel);
    const candidate = entry as { name?: unknown; value?: unknown };
    validateNonEmptyString(candidate.name, `${entryLabel} name`);
    validateNoNulString(candidate.name, `${entryLabel} name`);
    validateInlineLiteral(candidate.value, `${entryLabel} value`);
  }
}

function validateInlineLiteral(value: unknown, label: string): void {
  validateJsonObjectPayload(value, label);
  const candidate = value as { kind?: unknown; value?: unknown };
  switch (candidate.kind) {
    case "string":
      if (typeof candidate.value !== "string") {
        throw new Error(`${label} string value must be a string`);
      }
      return;
    case "int":
      if (!Number.isInteger(candidate.value)) {
        throw new Error(`${label} int value must be an integer`);
      }
      return;
    case "bool":
      if (typeof candidate.value !== "boolean") {
        throw new Error(`${label} bool value must be a boolean`);
      }
      return;
    case "float":
      if (typeof candidate.value !== "number" || !Number.isFinite(candidate.value)) {
        throw new Error(`${label} float value must be finite`);
      }
      return;
    case "unit":
      if ("value" in candidate) {
        throw new Error(`${label} unit value must be omitted`);
      }
      return;
    default:
      throw new Error(`${label} kind is invalid`);
  }
}

function validateLocation(value: unknown, label: string): void {
  validateJsonObjectPayload(value, label);
  const candidate = value as { file?: unknown; start?: unknown; end?: unknown };
  if (typeof candidate.file !== "string") {
    throw new Error(`${label} file must be a string`);
  }
  validateNoNulString(candidate.file, `${label} file`);
  validateLocationPosition(candidate.start, `${label} start`);
  validateLocationPosition(candidate.end, `${label} end`);
}

function validateLocationPosition(value: unknown, label: string): void {
  validateJsonObjectPayload(value, label);
  const candidate = value as { line?: unknown; column?: unknown; offset?: unknown };
  for (const name of ["line", "column", "offset"] as const) {
    if (!Number.isInteger(candidate[name]) || (candidate[name] as number) < 0) {
      throw new Error(`${label} ${name} must be a non-negative integer`);
    }
  }
}

function validateExecuteEffectRequest(request: unknown): CamlFlowExecuteEffectParams {
  const params = validateJsonRpcRequest(
    request,
    CamlFlowRpc.CAMLFLOW_METHODS.executeEffect,
    "Pi CamlFlow JSON-RPC executeEffect request",
  );
  validateExecuteEffectParams(params);
  return params as CamlFlowExecuteEffectParams;
}

function validateEffectHandlerContext(context: unknown): void {
  if (
    typeof context !== "object" ||
    context === null ||
    Array.isArray(context) ||
    typeof (context as Partial<CamlFlowEffectHandlerContext>).emitOutputChunk !== "function"
  ) {
    throw new Error(
      "Pi CamlFlow JSON-RPC executeEffect context must provide emitOutputChunk",
    );
  }
}

function validateJsonRpcRequest(
  request: unknown,
  expectedMethod: string,
  label: string,
): unknown {
  if (typeof request !== "object" || request === null || Array.isArray(request)) {
    throw new Error(`${label} must be an object`);
  }
  stringifyPromptJson(request, label);
  const candidate = request as {
    jsonrpc?: unknown;
    id?: unknown;
    method?: unknown;
    params?: unknown;
  };
  if (candidate.jsonrpc !== "2.0") {
    throw new Error(`${label} jsonrpc must be 2.0`);
  }
  if (
    (typeof candidate.id !== "string" && typeof candidate.id !== "number") ||
    (typeof candidate.id === "number" &&
      (!Number.isFinite(candidate.id) || !Number.isInteger(candidate.id)))
  ) {
    throw new Error(`${label} id must be a string or integer number`);
  }
  if (typeof candidate.id === "string") {
    validateNoNulString(candidate.id, `${label} id`);
  }
  if (candidate.method !== expectedMethod) {
    throw new Error(`${label} method must be ${expectedMethod}`);
  }
  if (candidate.params === undefined) {
    throw new Error(`${label} params must be present`);
  }
  stringifyPromptJson(candidate.params, `${label} params`);
  return candidate.params;
}

function validateJsonObjectPayload(value: unknown, label: string): void {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  stringifyPromptJson(value, label);
}

function validateNullableRunId(value: unknown, label: string): void {
  validateNullableString(value, label, true);
  if (typeof value === "string") {
    validateNoNulString(value, label);
  }
}

function validateNullableString(value: unknown, label: string, allowEmpty: boolean): void {
  if (value === null) {
    return;
  }
  if (allowEmpty) {
    if (typeof value !== "string") {
      throw new Error(`${label} must be a string or null`);
    }
    return;
  }
  validateNonEmptyString(value, label);
}

function validateNullableStep(value: unknown, label: string): void {
  if (value !== null && (!Number.isInteger(value) || (value as number) < 0)) {
    throw new Error(`${label} must be a non-negative integer or null`);
  }
}

function validateNullableEffectSummary(value: unknown, label: string): void {
  if (value === null) {
    return;
  }
  validateJsonObjectPayload(value, label);
  const candidate = value as { kind?: unknown; name?: unknown };
  validateCamlFlowEffectKind(candidate.kind, `${label} kind`);
  validateNonEmptyString(candidate.name, `${label} name`);
}

function validateCamlFlowEffectKind(value: unknown, label: string): void {
  if (
    value !== "bound-agent" &&
    value !== "bound-skill" &&
    value !== "local-prompt-skill" &&
    value !== "inline-agent"
  ) {
    throw new Error(`${label} is invalid`);
  }
}

function validateEffectExecutorOptions(options: PiCamlFlowEffectExecutorOptions): void {
  if (typeof options !== "object" || options === null || Array.isArray(options)) {
    throw new Error("Pi CamlFlow effect executor options must be an object");
  }
  validateWorkerSessionFactoryOption(options.workerSessionFactory);
}

function validateEffectExecutionOptions(options: PiCamlFlowEffectExecutionOptions): void {
  if (typeof options !== "object" || options === null || Array.isArray(options)) {
    throw new Error("Pi CamlFlow effect execution options must be an object");
  }
  if (options.signal !== undefined) {
    validateAbortSignal(options.signal, "Pi CamlFlow effect execution signal");
  }
  if (
    options.emitOutputChunk !== undefined &&
    typeof options.emitOutputChunk !== "function"
  ) {
    throw new Error("Pi CamlFlow effect execution emitOutputChunk must be a function");
  }
}

function validateHostSessionOptions(options: PiCamlFlowHostSessionOptions): void {
  if (typeof options !== "object" || options === null || Array.isArray(options)) {
    throw new Error("Pi CamlFlow host session options must be an object");
  }
  validateClientFactoryOption(options.clientFactory);
  validateWorkerSessionFactoryOption(options.workerSessionFactory);
  validateCallbackOptions(options);
  validateCamlFlowSpawnOptions(options.camlflow, "Pi CamlFlow host session camlflow options");
  if (options.autoShutdown !== undefined && typeof options.autoShutdown !== "boolean") {
    throw new Error("Pi CamlFlow host session autoShutdown must be a boolean");
  }
}

function validateHarnessOptions(options: PiCamlFlowHarnessOptions): void {
  if (typeof options !== "object" || options === null || Array.isArray(options)) {
    throw new Error("Pi CamlFlow harness options must be an object");
  }
  validateClientFactoryOption(options.clientFactory);
  validateWorkerSessionFactoryOption(options.workerSessionFactory);
  validateCallbackOptions(options);
  validateCamlFlowSpawnOptions(options.camlflow, "Pi CamlFlow harness camlflow options");
  if (options.autoShutdown !== undefined && typeof options.autoShutdown !== "boolean") {
    throw new Error("Pi CamlFlow harness autoShutdown must be a boolean");
  }
}

function validateClientFactoryOption(
  factory: PiCamlFlowHostSessionOptions["clientFactory"] | undefined,
): void {
  if (factory !== undefined && typeof factory !== "function") {
    throw new Error("Pi CamlFlow clientFactory must be a function");
  }
}

function validateWorkerSessionFactoryOption(
  factory: PiCamlFlowEffectExecutorOptions["workerSessionFactory"] | undefined,
): void {
  if (factory !== undefined && typeof factory !== "function") {
    throw new Error("Pi CamlFlow workerSessionFactory must be a function");
  }
}

function validateCallbackOptions(options: PiCamlFlowCallbacks): void {
  for (const name of [
    "onTrace",
    "onDiagnostic",
    "onProgress",
    "onOutputChunk",
    "onTransportError",
  ] as const) {
    if (options[name] !== undefined && typeof options[name] !== "function") {
      throw new Error(`Pi CamlFlow ${name} callback must be a function`);
    }
  }
}

function validateCamlFlowSpawnOptions(
  options: Partial<SpawnCamlFlowClientOptions> | undefined,
  label: string,
): void {
  if (options === undefined) {
    return;
  }
  if (typeof options !== "object" || options === null || Array.isArray(options)) {
    throw new Error(`${label} must be an object`);
  }
  if (options.command !== undefined) {
    validateNonEmptyString(options.command, `${label} command`);
    validateNoNulString(options.command, `${label} command`);
  }
  if (options.args !== undefined) {
    if (!Array.isArray(options.args)) {
      throw new Error(`${label} args must be an array of strings`);
    }
    for (const arg of options.args) {
      if (typeof arg !== "string") {
        throw new Error(`${label} args must be an array of strings`);
      }
      validateNoNulString(arg, `${label} arg`);
    }
  }
  if (options.cwd !== undefined) {
    validateNonEmptyString(options.cwd, `${label} cwd`);
    validateNoNulString(options.cwd, `${label} cwd`);
  }
  if (options.env !== undefined) {
    validateShellEnv(options.env, `${label} env`);
  }
  if (
    options.stderr !== undefined &&
    options.stderr !== "inherit" &&
    options.stderr !== "pipe"
  ) {
    throw new Error(`${label} stderr must be inherit or pipe`);
  }
  for (const name of [
    "effectHandler",
    "onTrace",
    "onDiagnostic",
    "onProgress",
    "onOutputChunk",
    "onNotification",
    "onTransportError",
  ] as const) {
    if (options[name] !== undefined && typeof options[name] !== "function") {
      throw new Error(`${label} ${name} must be a function`);
    }
  }
}

function validateShellEnv(env: unknown, label: string): void {
  if (typeof env !== "object" || env === null || Array.isArray(env)) {
    throw new Error(`${label} must be an object`);
  }
  validatePlainEnumerableRecord(env, label);
  for (const [name, value] of Object.entries(env)) {
    validateNonEmptyString(name, `${label} name`);
    validateNoNulString(name, `${label} name`);
    if (name.includes("=")) {
      throw new Error(`${label} names must not contain =`);
    }
    if (typeof value !== "string" && value !== undefined) {
      throw new Error(`${label} value for ${name} must be a string or undefined`);
    }
    if (typeof value === "string") {
      validateNoNulString(value, `${label} value for ${name}`);
    }
  }
}

function validatePlainEnumerableRecord(value: object, label: string): void {
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) {
    throw new Error(`${label} must be a plain object`);
  }
  if (Object.getOwnPropertySymbols(value).length > 0) {
    throw new Error(`${label} must not contain symbol keys`);
  }
  for (const key of Object.getOwnPropertyNames(value)) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (descriptor && !descriptor.enumerable) {
      throw new Error(`${label}.${key} must be enumerable`);
    }
  }
}

function validateNonEmptyString(value: unknown, label: string): asserts value is string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${label} must not be empty`);
  }
}

function validateNoNulString(value: string, label: string): void {
  if (value.includes("\0")) {
    throw new Error(`${label} must not contain NUL bytes`);
  }
}

function validateEffectRequest(request: PiCamlFlowEffectRequest): void {
  if (typeof request !== "object" || request === null || Array.isArray(request)) {
    throw new Error("CamlFlow effect request must be an object");
  }
  validateNonEmptyString(request.kind, "CamlFlow effect kind");
  validateNoNulString(request.kind, "CamlFlow effect kind");
  validateNonEmptyString(request.name, "CamlFlow effect name");
  validateNoNulString(request.name, "CamlFlow effect name");
  validateNonEmptyString(request.renderedPrompt, "CamlFlow effect renderedPrompt");
  if (request.workingDirectory !== undefined && request.workingDirectory !== null) {
    validateNonEmptyString(request.workingDirectory, "CamlFlow effect workingDirectory");
    validateNoNulString(request.workingDirectory, "CamlFlow effect workingDirectory");
  }
  if (request.skillsDirectory !== undefined && request.skillsDirectory !== null) {
    validateNonEmptyString(request.skillsDirectory, "CamlFlow effect skillsDirectory");
    validateNoNulString(request.skillsDirectory, "CamlFlow effect skillsDirectory");
  }
  if (request.skillMarkdown !== undefined && request.skillMarkdown !== null) {
    validateNonEmptyString(request.skillMarkdown, "CamlFlow effect skillMarkdown");
  }
  if (request.requestedModel !== undefined && request.requestedModel !== null) {
    validateNonEmptyString(request.requestedModel, "CamlFlow effect requestedModel");
    validateModelReference(request.requestedModel, "CamlFlow effect requestedModel");
  }
  if (request.declaredReturnType !== undefined) {
    validateNonEmptyString(request.declaredReturnType, "CamlFlow effect declaredReturnType");
    validateNoNulString(request.declaredReturnType, "CamlFlow effect declaredReturnType");
  }
  if (request.runId !== undefined && request.runId !== null) {
    validateNonEmptyString(request.runId, "CamlFlow effect runId");
    validateNoNulString(request.runId, "CamlFlow effect runId");
  }
  if (
    request.step !== undefined &&
    request.step !== null &&
    (!Number.isInteger(request.step) || request.step < 0)
  ) {
    throw new Error("CamlFlow effect step must be a non-negative integer");
  }
  if (request.outputSchema !== undefined && request.outputSchema !== null) {
    validateJsonObjectPayload(request.outputSchema, "CamlFlow effect outputSchema");
  }
  stringifyPromptJson(request.input, "CamlFlow effect input");
}

function stringifyPromptJson(value: unknown, label: string): string {
  validateJsonValue(value, label);
  try {
    const encoded = JSON.stringify(value, null, 2);
    if (encoded === undefined) {
      throw new Error("value is not representable as JSON");
    }
    return encoded;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`${label} must be JSON serializable: ${message}`);
  }
}

function validateJsonValue(value: unknown, label: string): void {
  const seen = new WeakSet<object>();
  const visit = (candidate: unknown, path: string): void => {
    if (
      candidate === null ||
      typeof candidate === "string" ||
      typeof candidate === "boolean"
    ) {
      return;
    }
    if (typeof candidate === "number") {
      if (!Number.isFinite(candidate)) {
        throw new Error(`${path} must be a finite number`);
      }
      return;
    }
    if (
      candidate === undefined ||
      typeof candidate === "function" ||
      typeof candidate === "symbol" ||
      typeof candidate === "bigint"
    ) {
      throw new Error(`${path} has unsupported type ${typeof candidate}`);
    }
    if (typeof candidate !== "object") {
      throw new Error(`${path} has unsupported type ${typeof candidate}`);
    }
    if (seen.has(candidate)) {
      throw new Error(`${path} contains a circular reference`);
    }
    seen.add(candidate);
    if (Array.isArray(candidate)) {
      for (let index = 0; index < candidate.length; index += 1) {
        if (!(index in candidate)) {
          throw new Error(`${path}[${index}] is a sparse array hole`);
        }
        visit(candidate[index], `${path}[${index}]`);
      }
      for (const key of Reflect.ownKeys(candidate)) {
        if (key === "length") {
          continue;
        }
        if (typeof key !== "string" || !isArrayIndexKey(key, candidate.length)) {
          throw new Error(`${path} has unsupported array property ${String(key)}`);
        }
      }
    } else {
      const prototype = Object.getPrototypeOf(candidate);
      if (prototype !== Object.prototype && prototype !== null) {
        throw new Error(`${path} must be a plain object`);
      }
      if (Object.getOwnPropertySymbols(candidate).length > 0) {
        throw new Error(`${path} has unsupported symbol keys`);
      }
      for (const key of Object.getOwnPropertyNames(candidate)) {
        const descriptor = Object.getOwnPropertyDescriptor(candidate, key);
        if (descriptor && !descriptor.enumerable) {
          throw new Error(`${path}.${key} must be enumerable`);
        }
        visit((candidate as Record<string, unknown>)[key], `${path}.${key}`);
      }
    }
    seen.delete(candidate);
  };

  try {
    visit(value, label);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`${label} must be JSON serializable: ${message}`);
  }
}

function isArrayIndexKey(key: string, length: number): boolean {
  if (!/^(0|[1-9][0-9]*)$/.test(key)) {
    return false;
  }
  const index = Number(key);
  return Number.isSafeInteger(index) && index >= 0 && index < length;
}

function validatePiCamlFlowRuntime(runtime: PiCamlFlowRuntime): void {
  if (typeof runtime !== "object" || runtime === null) {
    throw new Error("Pi CamlFlow runtime must be an object");
  }
  validateNonEmptyString(runtime.cwd, "Pi CamlFlow runtime cwd");
  validateNoNulString(runtime.cwd, "Pi CamlFlow runtime cwd");
  if (typeof runtime.session !== "object" || runtime.session === null) {
    throw new Error("Pi CamlFlow runtime session must be an object");
  }
  if (runtime.session.thinkingLevel !== undefined && typeof runtime.session.thinkingLevel !== "string") {
    throw new Error("Pi CamlFlow runtime session thinkingLevel must be a string");
  }
  if (typeof runtime.services !== "object" || runtime.services === null) {
    throw new Error("Pi CamlFlow runtime services must be an object");
  }
  if (runtime.services.agentDir !== undefined) {
    validateNonEmptyString(runtime.services.agentDir, "Pi CamlFlow runtime services agentDir");
    validateNoNulString(runtime.services.agentDir, "Pi CamlFlow runtime services agentDir");
  }
  const modelRegistry = runtime.services.modelRegistry;
  if (
    typeof modelRegistry !== "object" ||
    modelRegistry === null ||
    typeof modelRegistry.getAvailable !== "function" ||
    typeof modelRegistry.find !== "function" ||
    typeof modelRegistry.hasConfiguredAuth !== "function"
  ) {
    throw new Error(
      "Pi CamlFlow runtime modelRegistry must provide getAvailable, find, and hasConfiguredAuth",
    );
  }
  if (runtime.session.model) {
    validatePiModel(runtime.session.model, "Pi CamlFlow runtime session model");
  }
}

function validateAgentInitOptions(options: PiCamlFlowAgentInitOptions): void {
  if (typeof options !== "object" || options === null || Array.isArray(options)) {
    throw new Error("Pi CamlFlow agent init options must be an object");
  }
  if (options.cwd !== undefined) {
    validateNonEmptyString(options.cwd, "Pi CamlFlow agent cwd");
    validateNoNulString(options.cwd, "Pi CamlFlow agent cwd");
  }
  if (options.id !== undefined) {
    validateNonEmptyString(options.id, "Pi CamlFlow agent id");
    validateNoNulString(options.id, "Pi CamlFlow agent id");
  }
  if (typeof options.model === "string") {
    validateNonEmptyString(options.model, "Pi CamlFlow agent model");
    validateModelReference(options.model, "Pi CamlFlow agent model");
  } else if (options.model !== undefined) {
    validatePiModel(options.model, "Pi CamlFlow agent model");
  }
  if (options.thinkingLevel !== undefined && typeof options.thinkingLevel !== "string") {
    throw new Error("Pi CamlFlow agent thinkingLevel must be a string");
  }
}

function validatePiModel(model: unknown, label: string): asserts model is PiModel {
  if (typeof model !== "object" || model === null) {
    throw new Error(`${label} must be a Pi model object`);
  }
  const candidate = model as {
    provider?: unknown;
    id?: unknown;
    name?: unknown;
    api?: unknown;
  };
  const provider = candidate.provider;
  const id = candidate.id;
  const name = candidate.name;
  const api = candidate.api;
  validateNonEmptyString(provider, `${label} provider`);
  validateNoNulString(provider, `${label} provider`);
  validateNonEmptyString(id, `${label} id`);
  validateNoNulString(id, `${label} id`);
  validateNonEmptyString(name, `${label} name`);
  validateNoNulString(name, `${label} name`);
  validateNonEmptyString(api, `${label} api`);
  validateNoNulString(api, `${label} api`);
}

function validateModelReference(value: string, label: string): void {
  validateNoNulString(value, label);
  const separatorIndex = value.indexOf("/");
  if (separatorIndex <= 0 || separatorIndex === value.length - 1) {
    return;
  }
  validateNonEmptyString(value.slice(0, separatorIndex), `${label} provider`);
  validateNonEmptyString(value.slice(separatorIndex + 1), `${label} id`);
}

function validateModelAuthResult(value: unknown): asserts value is boolean {
  if (typeof value !== "boolean") {
    throw new Error("Pi CamlFlow runtime modelRegistry.hasConfiguredAuth must return a boolean");
  }
}

function resolveWorkerModel(
  runtime: PiCamlFlowRuntime,
  request: Pick<PiCamlFlowEffectRequest, "kind" | "name" | "requestedModel">,
): PiModel {
  const requestedModel = request.requestedModel
    ? resolveRequestedModel(runtime, request.requestedModel)
    : undefined;
  if (requestedModel) {
    return requestedModel;
  }

  if (runtime.session.model) {
    validatePiModel(runtime.session.model, "Pi CamlFlow runtime session model");
    return runtime.session.model;
  }

  const fallback = getAvailableModels(runtime)[0];
  if (fallback) {
    validatePiModel(fallback, "Pi CamlFlow runtime available model");
    return fallback;
  }

  throw new PiCamlFlowMissingModelError(request);
}

function resolveNamedModel(runtime: PiCamlFlowRuntime, requestedModel: string): PiModel {
  const model = resolveRequestedModel(runtime, requestedModel);
  if (!model) {
    throw new PiCamlFlowMissingModelError({
      kind: "harness-agent",
      name: requestedModel,
    });
  }
  return model;
}

function getAvailableModels(runtime: PiCamlFlowRuntime): PiModel[] {
  const models = runtime.services.modelRegistry.getAvailable();
  if (!Array.isArray(models)) {
    throw new Error("Pi CamlFlow runtime modelRegistry.getAvailable must return an array");
  }
  for (const [index, model] of models.entries()) {
    validatePiModel(model, `Pi CamlFlow runtime available model ${index}`);
  }
  return models;
}

function resolveRequestedModel(runtime: PiCamlFlowRuntime, requestedModel: string): PiModel | undefined {
  validateModelReference(requestedModel, "Pi CamlFlow requested model");
  const separatorIndex = requestedModel.indexOf("/");
  if (separatorIndex <= 0 || separatorIndex === requestedModel.length - 1) {
    return undefined;
  }

  const provider = requestedModel.slice(0, separatorIndex);
  const modelId = requestedModel.slice(separatorIndex + 1);
  const model = runtime.services.modelRegistry.find(provider, modelId);
  if (!model) {
    return undefined;
  }
  validatePiModel(model, "Pi CamlFlow requested model");
  const hasConfiguredAuth = runtime.services.modelRegistry.hasConfiguredAuth(model);
  validateModelAuthResult(hasConfiguredAuth);
  if (!hasConfiguredAuth) {
    return undefined;
  }
  return model;
}

type AssistantMessageLike = {
  role: "assistant";
  content?: unknown;
  stopReason?: unknown;
  errorMessage?: unknown;
};

function findLastAssistantMessage(messages: readonly unknown[]): AssistantMessageLike | undefined {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (isAssistantMessage(message)) {
      return message;
    }
  }
  return undefined;
}

function isAssistantMessage(value: unknown): value is AssistantMessageLike {
  return (
    typeof value === "object" &&
    value !== null &&
    (value as { role?: unknown }).role === "assistant"
  );
}

function validateAssistantMessageStatus(message: AssistantMessageLike): void {
  if (message.stopReason !== undefined && typeof message.stopReason !== "string") {
    throw new Error("Pi assistant message stopReason must be a string");
  }
  if (message.errorMessage !== undefined && typeof message.errorMessage !== "string") {
    throw new Error("Pi assistant message errorMessage must be a string");
  }
}

function extractAssistantText(message: AssistantMessageLike): string {
  if (!Array.isArray(message.content)) {
    throw new Error("Pi assistant message content must be an array");
  }
  const texts: string[] = [];
  for (const [index, content] of message.content.entries()) {
    const label = `Pi assistant message content[${index}]`;
    if (typeof content !== "object" || content === null || Array.isArray(content)) {
      throw new Error(`${label} must be an object`);
    }
    if (typeof content.type !== "string") {
      throw new Error(`${label} type must be a string`);
    }
    if (content.type === "text") {
      if (typeof content.text !== "string") {
        throw new Error(`${label} text must be a string`);
      }
      texts.push(content.text);
    }
  }
  if (texts.length === 0) {
    throw new Error("Pi assistant message must include text content");
  }
  return texts.join("\n").trim();
}

function extractTextDelta(event: AgentSessionEvent): string | undefined {
  const candidate = event as {
    type?: unknown;
    assistantMessageEvent?: { type?: unknown; delta?: unknown };
  };
  if (candidate.type !== "message_update") {
    return undefined;
  }
  if (
    typeof candidate.assistantMessageEvent !== "object" ||
    candidate.assistantMessageEvent === null ||
    candidate.assistantMessageEvent.type !== "text_delta"
  ) {
    return undefined;
  }
  if (typeof candidate.assistantMessageEvent.delta !== "string") {
    throw new Error("Pi assistant text_delta event delta must be a string");
  }
  return candidate.assistantMessageEvent.delta;
}

function paramsToEffectRequest(params: CamlFlowExecuteEffectParams): PiCamlFlowEffectRequest {
  return {
    kind: params.effect.kind,
    role: params.effect.role,
    name: params.effect.name,
    input: params.effect.input,
    renderedPrompt: params.effect.renderedPrompt,
    workingDirectory: params.effect.workingDirectory,
    skillsDirectory: params.effect.skillsDirectory,
    skillMarkdown: params.effect.skillMarkdown,
    requestedModel: params.effect.requestedModel,
    declaredReturnType: params.effect.declaredReturnType,
    outputSchema: params.effect.outputSchema,
    runId: params.runId,
    step: params.step,
  };
}

function buildEffectStreamId(params: CamlFlowExecuteEffectParams): string {
  const step = params.step === null || params.step === undefined ? "unknown" : String(params.step);
  return `pi:${step}:${params.effect.kind}:${params.effect.name}`;
}

function combineAbortSignals(signals: Array<AbortSignal | undefined>): {
  signal: AbortSignal;
  cleanup(): void;
} {
  const activeSignals = signals.filter((signal): signal is AbortSignal => signal !== undefined);
  if (activeSignals.length === 0) {
    return {
      signal: new AbortController().signal,
      cleanup: () => undefined,
    };
  }
  if (activeSignals.length === 1) {
    return {
      signal: activeSignals[0],
      cleanup: () => undefined,
    };
  }

  const controller = new AbortController();
  const abort = (): void => {
    controller.abort();
  };
  const listeningSignals: AbortSignal[] = [];

  for (const signal of activeSignals) {
    if (signal.aborted) {
      controller.abort();
      break;
    }
    signal.addEventListener("abort", abort, { once: true });
    listeningSignals.push(signal);
  }

  return {
    signal: controller.signal,
    cleanup: () => {
      for (const signal of listeningSignals) {
        signal.removeEventListener("abort", abort);
      }
      listeningSignals.length = 0;
    },
  };
}
