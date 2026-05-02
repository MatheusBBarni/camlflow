import {
  createAgentSession,
  createCodingTools,
  createExtensionRuntime,
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

export type { JsonObject, JsonValue };

export interface PiCamlFlowRuntime {
  cwd: string;
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
    this.workerSessionFactory = options.workerSessionFactory ?? createDefaultWorkerSession;
  }

  async executeEffect<TOutput extends JsonValue = JsonValue>(
    request: PiCamlFlowEffectRequest,
    options: PiCamlFlowEffectExecutionOptions = {},
  ): Promise<TOutput> {
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

    const unsubscribe = session.subscribe((event) => {
      const delta = extractTextDelta(event);
      if (delta !== undefined) {
        void options.emitOutputChunk?.(delta, false);
      }
    });

    const abortHandler = (): void => {
      void session.abort();
    };
    options.signal?.addEventListener("abort", abortHandler, { once: true });

    try {
      await session.prompt(buildPiCamlFlowEffectPrompt(request), {
        expandPromptTemplates: false,
        source: "extension",
      });

      const assistant = findLastAssistantMessage(session.messages);
      if (!assistant) {
        throw new Error(`CamlFlow effect produced no assistant message: ${request.kind}:${request.name}`);
      }
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
    } finally {
      await options.emitOutputChunk?.("", true);
      options.signal?.removeEventListener("abort", abortHandler);
      unsubscribe();
      session.dispose();
    }
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

    const controller = new AbortController();
    const signal = combineAbortSignals([controller.signal, options.signal]);
    const executor = new PiCamlFlowEffectExecutor(this.options.runtime, {
      workerSessionFactory: this.options.workerSessionFactory,
    });

    const spawnOptions = this.buildSpawnOptions(executor, signal);
    const client = this.options.clientFactory
      ? this.options.clientFactory(spawnOptions)
      : CamlFlowRpc.spawnCamlFlowClient(spawnOptions);

    this.activeRun = { controller, client };

    try {
      const initialize = await client.initialize(
        {
          notifications: {
            trace: true,
            diagnostic: true,
            progress: true,
          },
        },
        { signal },
      );
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
        { signal },
      );

      return {
        ...run,
        protocolVersion: initialize.protocolVersion,
        irVersion: initialize.irVersion,
        workflowPath: options.workflowPath,
        entrypoint,
      };
    } finally {
      this.activeRun = undefined;
      if (this.options.autoShutdown !== false) {
        await client.shutdownAndExit({ timeoutMs: 2000 }).catch(() => undefined);
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
        params: CamlFlowExecuteEffectParams,
        _request: JsonRpcRequest<CamlFlowExecuteEffectParams>,
        context: CamlFlowEffectHandlerContext,
      ) => {
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
      onTrace: this.options.onTrace,
      onDiagnostic: this.options.onDiagnostic,
      onProgress: this.options.onProgress,
      onOutputChunk: this.options.onOutputChunk,
      onTransportError: this.options.onTransportError,
    };
  }
}

export function createPiCamlFlowHostSession(
  options: PiCamlFlowHostSessionOptions,
): PiCamlFlowHostSession {
  return new DefaultPiCamlFlowHostSession(options);
}

export function buildPiCamlFlowEffectPrompt(request: PiCamlFlowEffectRequest): string {
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
    parts.push(JSON.stringify(request.outputSchema, null, 2));
  }

  parts.push("", "Rendered CamlFlow prompt:", request.renderedPrompt);
  return parts.join("\n");
}

export function unwrapJsonCodeFence(text: string): string {
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

async function createDefaultWorkerSession(
  _request: PiCamlFlowEffectRequest,
  options: {
    cwd: string;
    model: PiModel;
    thinkingLevel?: PiThinkingLevel;
    runtime: PiCamlFlowRuntime;
  },
): Promise<PiCamlFlowWorkerSession> {
  const resourceLoader = createWorkerResourceLoader();
  const settingsManager = SettingsManager.inMemory({
    compaction: { enabled: false },
    retry: { enabled: false },
  });

  const result = await createAgentSession({
    cwd: options.cwd,
    agentDir: options.runtime.services.agentDir,
    authStorage: options.runtime.services.authStorage,
    modelRegistry: options.runtime.services.modelRegistry,
    model: options.model,
    thinkingLevel: options.thinkingLevel,
    tools: createCodingTools(options.cwd),
    resourceLoader,
    sessionManager: SessionManager.inMemory(),
    settingsManager,
  });

  return result.session as Pick<
    AgentSession,
    "messages" | "prompt" | "subscribe" | "abort" | "dispose"
  >;
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
    return runtime.session.model;
  }

  const fallback = runtime.services.modelRegistry.getAvailable()[0];
  if (fallback) {
    return fallback;
  }

  throw new PiCamlFlowMissingModelError(request);
}

function resolveRequestedModel(runtime: PiCamlFlowRuntime, requestedModel: string): PiModel | undefined {
  const separatorIndex = requestedModel.indexOf("/");
  if (separatorIndex <= 0 || separatorIndex === requestedModel.length - 1) {
    return undefined;
  }

  const provider = requestedModel.slice(0, separatorIndex);
  const modelId = requestedModel.slice(separatorIndex + 1);
  const model = runtime.services.modelRegistry.find(provider, modelId);
  if (!model || !runtime.services.modelRegistry.hasConfiguredAuth(model)) {
    return undefined;
  }
  return model;
}

type AssistantMessageLike = {
  role: "assistant";
  content: Array<{ type: string; text?: string }>;
  stopReason?: string;
  errorMessage?: string;
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
    (value as { role?: unknown }).role === "assistant" &&
    Array.isArray((value as { content?: unknown }).content)
  );
}

function extractAssistantText(message: AssistantMessageLike): string {
  return message.content
    .filter((content) => content.type === "text" && typeof content.text === "string")
    .map((content) => content.text)
    .join("\n")
    .trim();
}

function extractTextDelta(event: AgentSessionEvent): string | undefined {
  const candidate = event as {
    type?: unknown;
    assistantMessageEvent?: { type?: unknown; delta?: unknown };
  };
  if (
    candidate.type === "message_update" &&
    candidate.assistantMessageEvent?.type === "text_delta" &&
    typeof candidate.assistantMessageEvent.delta === "string"
  ) {
    return candidate.assistantMessageEvent.delta;
  }
  return undefined;
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

function combineAbortSignals(signals: Array<AbortSignal | undefined>): AbortSignal {
  const activeSignals = signals.filter((signal): signal is AbortSignal => signal !== undefined);
  if (activeSignals.length === 0) {
    return new AbortController().signal;
  }
  if (activeSignals.length === 1) {
    return activeSignals[0];
  }

  const controller = new AbortController();
  const abort = (): void => {
    controller.abort();
  };

  for (const signal of activeSignals) {
    if (signal.aborted) {
      controller.abort();
      break;
    }
    signal.addEventListener("abort", abort, { once: true });
  }

  return controller.signal;
}
