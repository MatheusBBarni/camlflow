import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { isAbsolute, relative, resolve } from "node:path";

export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonValue[] | JsonObject;
export interface JsonObject {
  [key: string]: JsonValue;
}

export type MaybePromise<T> = T | Promise<T>;

export class CamlFlowOrchestratorError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "CamlFlowOrchestratorError";
  }
}

export class CamlFlowValidationError extends CamlFlowOrchestratorError {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "CamlFlowValidationError";
  }
}

export class CamlFlowResultParseError extends CamlFlowOrchestratorError {
  readonly metadata?: unknown;

  constructor(message: string, metadata?: unknown, options?: ErrorOptions) {
    super(message, options);
    this.name = "CamlFlowResultParseError";
    this.metadata = metadata;
  }
}

export type SandboxKind = "local" | "workspace-write" | "read-only" | "ephemeral" | string;

export interface SandboxShellOptions {
  cwd?: string;
  env?: Record<string, string | undefined>;
  stdin?: string;
  timeoutMs?: number;
  signal?: AbortSignal;
}

export interface SandboxShellResult {
  code: number | null;
  signal: string | null;
  stdout: string;
  stderr: string;
}

export type SandboxShellExecutor = (
  command: string,
  options?: SandboxShellOptions,
) => MaybePromise<SandboxShellResult>;

export interface SandboxCloseResult {
  kind: SandboxKind;
  cwd: string;
  cleaned: boolean;
  preservedPath?: string;
  reason?: string;
}

export interface SandboxHandle<TTool = unknown> {
  readonly kind: SandboxKind;
  readonly cwd: string;
  readonly tools: readonly TTool[];
  resolvePath(path: string): string;
  shell?: SandboxShellExecutor;
  close(): MaybePromise<SandboxCloseResult>;
}

export interface SandboxProvider<TConfig = unknown, TTool = unknown> {
  readonly name: string;
  create(config: TConfig, context: SandboxCreateContext): MaybePromise<SandboxHandle<TTool>>;
}

export interface SandboxCreateContext {
  workflowPath?: string;
  runId?: string;
  signal?: AbortSignal;
}

export type WorktreeStrategy =
  | { kind: "direct" }
  | { kind: "head" }
  | { kind: "branch"; branch: string }
  | { kind: "merge-to-head"; branch: string };

export interface LocalSandboxConfig<TTool = unknown> {
  kind?: "local" | "workspace-write" | "read-only" | "ephemeral";
  cwd?: string;
  env?: Record<string, string | undefined>;
  tools?: readonly TTool[];
  shell?: SandboxShellExecutor | false;
  cleanup?: boolean;
  preserveOnDirtyWorktree?: boolean;
  isDirty?: () => MaybePromise<boolean>;
  worktree?: WorktreeStrategy;
  dispose?: () => MaybePromise<void>;
}

export interface AgentProvider<TSession = unknown, TMessage = unknown> {
  readonly name: string;
  createSession(options: AgentSessionCreateOptions): MaybePromise<TSession>;
  prompt(session: TSession, prompt: string, options?: AgentPromptOptions): MaybePromise<TMessage>;
  closeSession(session: TSession): MaybePromise<void>;
}

export interface AgentSessionCreateOptions {
  sandbox: SandboxHandle;
  role?: string;
  model?: string;
  signal?: AbortSignal;
}

export interface AgentPromptOptions {
  signal?: AbortSignal;
  onChunk?: (chunk: OutputChunk) => MaybePromise<void>;
}

export interface SessionRecord<TData extends JsonObject = JsonObject> {
  id: string;
  runId?: string;
  sandboxCwd: string;
  data: TData;
}

export interface SessionStore<TData extends JsonObject = JsonObject> {
  load(id: string): MaybePromise<SessionRecord<TData> | undefined>;
  save(record: SessionRecord<TData>): MaybePromise<void>;
  delete(id: string): MaybePromise<void>;
}

export interface ToolProvider<TTool = unknown> {
  readonly name: string;
  toolsForSandbox(sandbox: SandboxHandle): MaybePromise<readonly TTool[]>;
}

export interface PromptResolver {
  resolve(prompt: PromptReference, context: PromptContext): MaybePromise<string>;
}

export interface PromptReference {
  name?: string;
  file?: string;
  text?: string;
}

export interface PromptContext {
  workflowPath?: string;
  args?: JsonObject;
  sandbox: SandboxHandle;
}

export interface LifecycleHooks {
  beforeSandboxCreate?: (context: SandboxCreateContext) => MaybePromise<void>;
  afterSandboxReady?: (sandbox: SandboxHandle) => MaybePromise<void>;
  beforeRun?: (run: WorkflowRunContext) => MaybePromise<void>;
  afterRun?: (run: WorkflowRunContext, result: WorkflowRunResult) => MaybePromise<void>;
  beforeClose?: (sandbox: SandboxHandle) => MaybePromise<void>;
}

export interface WorkflowRunContext {
  runId: string;
  workflowPath: string;
  entrypoint: string;
  input: JsonValue;
  sandbox: SandboxHandle;
  signal?: AbortSignal;
}

export interface WorkflowRunResult<TOutput extends JsonValue = JsonValue> {
  runId: string;
  output: TOutput;
  diagnostics: readonly JsonObject[];
  metadata: JsonObject;
}

export interface OutputChunk {
  delta: string;
  done: boolean;
}

export type ResultParser<TOutput = JsonValue> =
  | "json"
  | ((value: JsonValue) => TOutput)
  | { parse(value: JsonValue): TOutput }
  | {
      safeParse(value: JsonValue):
        | { success: true; output: TOutput; data?: never }
        | { success: true; data: TOutput; output?: never }
        | { success: false; issues?: unknown; error?: unknown };
    };

export function assertNonEmptyString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.trim() === "") {
    throw new CamlFlowValidationError(`${label} must be a non-empty string`);
  }
  if (value.includes("\0")) {
    throw new CamlFlowValidationError(`${label} must not contain NUL bytes`);
  }
  return value;
}

export function assertPlainObject(value: unknown, label: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new CamlFlowValidationError(`${label} must be an object`);
  }
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) {
    throw new CamlFlowValidationError(`${label} must be a plain object`);
  }
  if (Object.getOwnPropertySymbols(value).length > 0) {
    throw new CamlFlowValidationError(`${label} must not contain symbol keys`);
  }
  return value as Record<string, unknown>;
}

export function assertJsonValue(value: unknown, label = "value"): JsonValue {
  const seen = new WeakSet<object>();
  return assertJsonValueInner(value, label, seen);
}

function assertJsonValueInner(value: unknown, label: string, seen: WeakSet<object>): JsonValue {
  if (value === null || typeof value === "string" || typeof value === "boolean") {
    return value;
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new CamlFlowValidationError(`${label} must be a finite number`);
    }
    return value;
  }
  if (Array.isArray(value)) {
    if (seen.has(value)) {
      throw new CamlFlowValidationError(`${label} must not contain circular references`);
    }
    seen.add(value);
    const output = value.map((entry, index) => {
      if (!(index in value)) {
        throw new CamlFlowValidationError(`${label} must not contain sparse arrays`);
      }
      return assertJsonValueInner(entry, `${label}[${index}]`, seen);
    });
    seen.delete(value);
    return output;
  }
  if (value !== null && typeof value === "object") {
    const object = assertPlainObject(value, label);
    if (seen.has(object)) {
      throw new CamlFlowValidationError(`${label} must not contain circular references`);
    }
    seen.add(object);
    const output: JsonObject = {};
    for (const [key, entry] of Object.entries(object)) {
      const descriptor = Object.getOwnPropertyDescriptor(object, key);
      if (descriptor && !descriptor.enumerable) {
        throw new CamlFlowValidationError(`${label}.${key} must be enumerable`);
      }
      output[key] = assertJsonValueInner(entry, `${label}.${key}`, seen);
    }
    seen.delete(object);
    return output;
  }
  throw new CamlFlowValidationError(`${label} must be JSON-serializable`);
}

export function parseResult<TOutput = JsonValue>(value: unknown, parser: ResultParser<TOutput> = "json"): TOutput {
  const json = assertJsonValue(value, "result");
  if (parser === "json") {
    return json as TOutput;
  }
  if (typeof parser === "function") {
    return parser(json);
  }
  if (parser && typeof parser === "object" && "parse" in parser && typeof parser.parse === "function") {
    return parser.parse(json);
  }
  if (
    parser &&
    typeof parser === "object" &&
    "safeParse" in parser &&
    typeof parser.safeParse === "function"
  ) {
    const parsed = parser.safeParse(json);
    if (!parsed.success) {
      throw new CamlFlowResultParseError("result parser rejected output", {
        issues: parsed.issues,
        error: parsed.error,
      });
    }
    return ("output" in parsed ? parsed.output : parsed.data) as TOutput;
  }
  throw new CamlFlowValidationError("result parser must be json, a function, parse, or safeParse object");
}

export function composeAbortSignals(signals: readonly (AbortSignal | undefined)[]): AbortSignal | undefined {
  const activeSignals = signals.filter((signal): signal is AbortSignal => signal !== undefined);
  if (activeSignals.length === 0) {
    return undefined;
  }
  if (activeSignals.length === 1) {
    return activeSignals[0];
  }
  const controller = new AbortController();
  const abort = () => controller.abort();
  for (const signal of activeSignals) {
    if (signal.aborted) {
      controller.abort();
      break;
    }
    signal.addEventListener("abort", abort, { once: true });
  }
  if (!controller.signal.aborted) {
    controller.signal.addEventListener(
      "abort",
      () => {
        for (const signal of activeSignals) {
          signal.removeEventListener("abort", abort);
        }
      },
      { once: true },
    );
  }
  return controller.signal;
}

export async function relayOutputChunk(
  chunk: OutputChunk,
  listener?: (chunk: OutputChunk) => MaybePromise<void>,
): Promise<void> {
  if (typeof chunk.delta !== "string") {
    throw new CamlFlowValidationError("output chunk delta must be a string");
  }
  if (typeof chunk.done !== "boolean") {
    throw new CamlFlowValidationError("output chunk done must be a boolean");
  }
  if (listener) {
    await listener(chunk);
  }
}

export function createMemorySessionStore<TData extends JsonObject = JsonObject>(): SessionStore<TData> {
  const records = new Map<string, SessionRecord<TData>>();
  return {
    async load(id) {
      assertNonEmptyString(id, "session id");
      return records.get(id);
    },
    async save(record) {
      assertNonEmptyString(record.id, "session id");
      assertNonEmptyString(record.sandboxCwd, "session sandbox cwd");
      assertJsonValue(record.data, "session data");
      records.set(record.id, { ...record, data: assertJsonValue(record.data, "session data") as TData });
    },
    async delete(id) {
      assertNonEmptyString(id, "session id");
      records.delete(id);
    },
  };
}

export function createLocalSandboxProvider<TTool = unknown>(): SandboxProvider<LocalSandboxConfig<TTool>, TTool> {
  return {
    name: "local",
    async create(config, context) {
      return createFilesystemSandbox("local", config, context, { allowShell: true, ephemeral: false });
    },
  };
}

export function createReadOnlySandboxProvider<TTool = unknown>(): SandboxProvider<LocalSandboxConfig<TTool>, TTool> {
  return {
    name: "read-only",
    async create(config, context) {
      return createFilesystemSandbox("read-only", { ...config, kind: "read-only", shell: false }, context, {
        allowShell: false,
        ephemeral: false,
      });
    },
  };
}

export function createEphemeralSandboxProvider<TTool = unknown>(): SandboxProvider<LocalSandboxConfig<TTool>, TTool> {
  return {
    name: "ephemeral",
    async create(config, context) {
      return createFilesystemSandbox("ephemeral", { ...config, kind: "ephemeral", cleanup: true }, context, {
        allowShell: true,
        ephemeral: true,
      });
    },
  };
}

async function createFilesystemSandbox<TTool>(
  fallbackKind: "local" | "read-only" | "ephemeral",
  config: LocalSandboxConfig<TTool>,
  context: SandboxCreateContext,
  defaults: { allowShell: boolean; ephemeral: boolean },
): Promise<SandboxHandle<TTool>> {
  if (context.signal?.aborted) {
    throw new CamlFlowOrchestratorError("sandbox creation aborted");
  }
  const kind = config.kind ?? fallbackKind;
  const cwd = defaults.ephemeral
    ? await mkdtemp(resolve(tmpdir(), "camlflow-orchestrator-"))
    : realpathSync(resolve(config.cwd ?? process.cwd()));
  const root = realpathSync(cwd);
  const cleanup = config.cleanup ?? defaults.ephemeral;
  if (cleanup && !defaults.ephemeral) {
    throw new CamlFlowValidationError("cleanup is only supported for ephemeral sandboxes");
  }
  const shell = config.shell === false || !defaults.allowShell ? undefined : config.shell ?? createBoundShell(root, config.env);

  let closed = false;
  const handle: SandboxHandle<TTool> = {
    kind,
    cwd: root,
    tools: config.tools ?? [],
    resolvePath(path) {
      return resolveSandboxPath(root, path);
    },
    shell,
    async close() {
      if (closed) {
        return { kind, cwd: root, cleaned: false, reason: "already-closed" };
      }
      closed = true;
      await config.dispose?.();
      if (config.preserveOnDirtyWorktree && (await config.isDirty?.())) {
        return {
          kind,
          cwd: root,
          cleaned: false,
          preservedPath: root,
          reason: "dirty-worktree",
        };
      }
      if (cleanup) {
        await rm(root, { force: true, recursive: true });
        return { kind, cwd: root, cleaned: true };
      }
      return { kind, cwd: root, cleaned: false };
    },
  };
  return handle;
}

export function resolveSandboxPath(root: string, path: string): string {
  const cleanRoot = realpathSync(resolve(assertNonEmptyString(root, "sandbox root")));
  const cleanPath = assertNonEmptyString(path, "sandbox path");
  const target = isAbsolute(cleanPath) ? cleanPath : resolve(cleanRoot, cleanPath);
  let normalized = resolve(target);
  try {
    normalized = realpathSync(normalized);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
      throw error;
    }
  }
  const rel = relative(cleanRoot, normalized);
  if (rel === "" || (!rel.startsWith("..") && !isAbsolute(rel))) {
    return normalized;
  }
  throw new CamlFlowValidationError(`sandbox path escapes sandbox root: ${path}`);
}

function createBoundShell(root: string, baseEnv?: Record<string, string | undefined>): SandboxShellExecutor {
  return async (command, options = {}) => {
    const shellCommand = assertNonEmptyString(command, "shell command");
    const cwd = options.cwd ? resolveSandboxPath(root, options.cwd) : root;
    validateShellOptions(options);
    const signal = composeAbortSignals([options.signal]);
    if (signal?.aborted) {
      throw new CamlFlowOrchestratorError("shell command aborted before start");
    }
    return runShell(shellCommand, {
      ...options,
      cwd,
      env: { ...baseEnv, ...options.env },
      signal,
    });
  };
}

function validateShellOptions(options: SandboxShellOptions): void {
  if (options.timeoutMs !== undefined && (!Number.isFinite(options.timeoutMs) || options.timeoutMs < 0)) {
    throw new CamlFlowValidationError("shell timeoutMs must be a finite non-negative number");
  }
  if (options.stdin !== undefined) {
    assertNonEmptyNulFree(options.stdin, "shell stdin", { allowEmpty: true });
  }
  if (options.env !== undefined) {
    const env = assertPlainObject(options.env, "shell env");
    for (const [name, value] of Object.entries(env)) {
      assertNonEmptyString(name, "shell env name");
      if (name.includes("=")) {
        throw new CamlFlowValidationError("shell env names must not contain =");
      }
      if (value !== undefined && typeof value !== "string") {
        throw new CamlFlowValidationError(`shell env value for ${name} must be a string or undefined`);
      }
      if (typeof value === "string") {
        assertNonEmptyNulFree(value, `shell env value for ${name}`, { allowEmpty: true });
      }
    }
  }
}

function assertNonEmptyNulFree(value: string, label: string, options?: { allowEmpty?: boolean }): string {
  if (!options?.allowEmpty && value.trim() === "") {
    throw new CamlFlowValidationError(`${label} must be a non-empty string`);
  }
  if (value.includes("\0")) {
    throw new CamlFlowValidationError(`${label} must not contain NUL bytes`);
  }
  return value;
}

function runShell(command: string, options: SandboxShellOptions): Promise<SandboxShellResult> {
  return new Promise((resolveResult, reject) => {
    const child = spawn(command, {
      cwd: options.cwd,
      env: { ...process.env, ...options.env },
      shell: true,
      signal: options.signal,
    });
    let stdout = "";
    let stderr = "";
    let timer: NodeJS.Timeout | undefined;
    if (options.timeoutMs !== undefined) {
      timer = setTimeout(() => child.kill(), options.timeoutMs);
    }
    child.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8");
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", (error) => {
      if (timer) {
        clearTimeout(timer);
      }
      reject(error);
    });
    child.on("close", (code, signal) => {
      if (timer) {
        clearTimeout(timer);
      }
      resolveResult({ code, signal, stdout, stderr });
    });
    if (options.stdin !== undefined) {
      child.stdin?.end(options.stdin);
    }
  });
}
