import { spawn } from "node:child_process";
import type { ChildProcess } from "node:child_process";
import { once } from "node:events";
import type { Readable, Writable } from "node:stream";

import {
  CAMLFLOW_ERROR_CODES,
  CAMLFLOW_METHODS,
  isJsonRpcResponse,
  type CamlFlowCheckParams,
  type CamlFlowCheckResult,
  type CamlFlowCompileParams,
  type CamlFlowCompileResult,
  type CamlFlowDiagnosticNotification,
  type CamlFlowExecuteEffectParams,
  type CamlFlowExecuteEffectResult,
  type CamlFlowInitializeResult,
  type CamlFlowRunParams,
  type CamlFlowRunResult,
  type CamlFlowTraceNotification,
  type JsonRpcErrorResponse,
  type JsonObject,
  type JsonRpcErrorObject,
  type JsonRpcId,
  type JsonRpcMessage,
  type JsonRpcNotification,
  type JsonRpcRequest,
  type JsonRpcResponse,
  type JsonValue,
} from "./protocol";
import { ContentLengthMessageParser, writeContentLengthMessage } from "./transport";

type PendingRequest = {
  method: string;
  resolve: (value: JsonValue) => void;
  reject: (error: Error) => void;
};

type MaybePromise<T> = T | Promise<T>;

export type CamlFlowEffectHandler<
  TInput extends JsonValue = JsonValue,
  TOutput extends JsonValue = JsonValue,
> = (
  params: CamlFlowExecuteEffectParams<TInput>,
  request: JsonRpcRequest<CamlFlowExecuteEffectParams<TInput>>,
) => MaybePromise<CamlFlowExecuteEffectResult<TOutput>>;

export interface CamlFlowJsonRpcClientOptions {
  readable: Readable;
  writable: Writable;
  effectHandler?: CamlFlowEffectHandler;
  onTrace?: (
    trace: CamlFlowTraceNotification,
    notification: JsonRpcNotification<CamlFlowTraceNotification>,
  ) => MaybePromise<void>;
  onDiagnostic?: (
    diagnostic: CamlFlowDiagnosticNotification,
    notification: JsonRpcNotification<CamlFlowDiagnosticNotification>,
  ) => MaybePromise<void>;
  onNotification?: (
    notification: JsonRpcNotification,
  ) => MaybePromise<void>;
  onTransportError?: (error: Error) => void;
}

export interface SpawnCamlFlowClientOptions {
  command?: string;
  args?: string[];
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  stderr?: "inherit" | "pipe";
  effectHandler?: CamlFlowEffectHandler;
  onTrace?: CamlFlowJsonRpcClientOptions["onTrace"];
  onDiagnostic?: CamlFlowJsonRpcClientOptions["onDiagnostic"];
  onNotification?: CamlFlowJsonRpcClientOptions["onNotification"];
  onTransportError?: CamlFlowJsonRpcClientOptions["onTransportError"];
}

export interface ShutdownAndExitOptions {
  timeoutMs?: number;
  forceKill?: boolean;
  killSignal?: NodeJS.Signals | number;
}

export class JsonRpcMethodError<
  TData extends JsonValue = JsonValue,
> extends Error {
  readonly code: number;
  readonly data?: TData;

  constructor(code: number, message: string, data?: TData) {
    super(message);
    this.name = "JsonRpcMethodError";
    this.code = code;
    this.data = data;
  }
}

export class JsonRpcResponseError<
  TData extends JsonValue = JsonValue,
> extends Error {
  readonly id: JsonRpcId | null;
  readonly method: string;
  readonly code: number;
  readonly data?: TData;

  constructor(
    method: string,
    id: JsonRpcId | null,
    error: JsonRpcErrorObject<TData>,
  ) {
    super(`${error.code}: ${error.message}`);
    this.name = "JsonRpcResponseError";
    this.method = method;
    this.id = id;
    this.code = error.code;
    this.data = error.data;
  }
}

export class CamlFlowConnectionClosedError extends Error {
  constructor(message = "CamlFlow JSON-RPC connection closed") {
    super(message);
    this.name = "CamlFlowConnectionClosedError";
  }
}

function normalizeError(error: unknown, fallback: string): Error {
  if (error instanceof Error) {
    return error;
  }

  return new Error(typeof error === "string" ? error : fallback);
}

function idKey(id: JsonRpcId | null): string {
  return typeof id === "string" ? `s:${id}` : `n:${id}`;
}

function normalizeProgramRef(program: {
  path: string;
  includePaths?: string[];
  skillsDir?: string | null;
}): JsonObject {
  const normalized: JsonObject = {
    path: program.path,
    includePaths: program.includePaths ?? [],
  };

  if (program.skillsDir !== undefined) {
    normalized.skillsDir = program.skillsDir;
  }

  return normalized;
}

function normalizeCheckOrCompileParams(
  params: CamlFlowCheckParams | CamlFlowCompileParams,
): JsonObject {
  const normalized: JsonObject = {
    program: normalizeProgramRef(params.program),
  };

  if (params.entry !== undefined) {
    normalized.entry = params.entry;
  }

  return normalized;
}

function normalizeRunParams<TInput extends JsonValue>(
  params: CamlFlowRunParams<TInput>,
): JsonObject {
  const normalized: JsonObject = {
    program: normalizeProgramRef(params.program),
  };

  if (params.entry !== undefined) {
    normalized.entry = params.entry;
  }

  if (params.input !== undefined) {
    normalized.input = params.input;
  }

  return normalized;
}

async function endWritable(writable: Writable): Promise<void> {
  if (writable.destroyed || !writable.writable) {
    return;
  }

  await new Promise<void>((resolve, reject) => {
    const onError = (error: Error): void => {
      writable.off("error", onError);
      reject(error);
    };

    writable.once("error", onError);
    writable.end(() => {
      writable.off("error", onError);
      resolve();
    });
  });
}

async function waitForChildClose(
  child: ChildProcess,
  timeoutMs: number,
  forceKill: boolean,
  killSignal: NodeJS.Signals | number,
): Promise<void> {
  if (child.exitCode !== null || child.killed) {
    return;
  }

  const closePromise = once(child, "close").then(() => undefined);
  const timeoutPromise = new Promise<void>((resolve) => {
    const timer = setTimeout(() => {
      if (forceKill && child.exitCode === null && !child.killed) {
        child.kill(killSignal);
      }

      resolve();
    }, timeoutMs);

    closePromise.finally(() => clearTimeout(timer)).catch(() => undefined);
  });

  await Promise.race([closePromise, timeoutPromise]);
}

export class CamlFlowJsonRpcClient {
  readonly child?: ChildProcess;

  effectHandler?: CamlFlowEffectHandler;
  onTrace?: CamlFlowJsonRpcClientOptions["onTrace"];
  onDiagnostic?: CamlFlowJsonRpcClientOptions["onDiagnostic"];
  onNotification?: CamlFlowJsonRpcClientOptions["onNotification"];
  onTransportError?: CamlFlowJsonRpcClientOptions["onTransportError"];

  private readonly readable: Readable;
  private readonly writable: Writable;
  private readonly parser = new ContentLengthMessageParser();
  private readonly pending = new Map<string, PendingRequest>();
  private readonly closePromise: Promise<void>;
  private resolveClosed!: () => void;
  private nextId = 0;
  private closed = false;

  constructor(
    options: CamlFlowJsonRpcClientOptions,
    context?: { child?: ChildProcess },
  ) {
    this.readable = options.readable;
    this.writable = options.writable;
    this.child = context?.child;
    this.effectHandler = options.effectHandler;
    this.onTrace = options.onTrace;
    this.onDiagnostic = options.onDiagnostic;
    this.onNotification = options.onNotification;
    this.onTransportError = options.onTransportError;

    this.closePromise = new Promise<void>((resolve) => {
      this.resolveClosed = resolve;
    });

    this.readable.on("data", this.handleData);
    this.readable.on("end", this.handleStreamEnd);
    this.readable.on("close", this.handleStreamClose);
    this.readable.on("error", this.handleStreamError);
    this.writable.on("error", this.handleStreamError);

    if (this.child) {
      this.child.on("error", this.handleChildError);
      this.child.on("exit", this.handleChildExit);
    }
  }

  static spawn(options: SpawnCamlFlowClientOptions = {}): CamlFlowJsonRpcClient {
    return spawnCamlFlowClient(options);
  }

  async initialize(params: JsonObject = {}): Promise<CamlFlowInitializeResult> {
    return this.request(CAMLFLOW_METHODS.initialize, params);
  }

  async check(params: CamlFlowCheckParams): Promise<CamlFlowCheckResult> {
    return this.request(
      CAMLFLOW_METHODS.check,
      normalizeCheckOrCompileParams(params),
    );
  }

  async compile<TArtifact extends JsonValue = JsonValue>(
    params: CamlFlowCompileParams,
  ): Promise<CamlFlowCompileResult<TArtifact>> {
    return this.request(
      CAMLFLOW_METHODS.compile,
      normalizeCheckOrCompileParams(params),
    );
  }

  async run<TOutput extends JsonValue = JsonValue, TInput extends JsonValue = JsonValue>(
    params: CamlFlowRunParams<TInput>,
  ): Promise<CamlFlowRunResult<TOutput>> {
    return this.request(CAMLFLOW_METHODS.run, normalizeRunParams(params));
  }

  async shutdown(): Promise<null> {
    return this.request(CAMLFLOW_METHODS.shutdown, {});
  }

  async exit(): Promise<void> {
    await this.notify(CAMLFLOW_METHODS.exit);
  }

  async request<
    TResult extends JsonValue = JsonValue,
    TParams extends JsonValue = JsonValue,
  >(method: string, params?: TParams): Promise<TResult> {
    if (this.closed) {
      throw new CamlFlowConnectionClosedError();
    }

    const id = ++this.nextId;
    const key = idKey(id);
    const message: JsonRpcRequest<TParams> = {
      jsonrpc: "2.0",
      id,
      method,
    };

    if (params !== undefined) {
      message.params = params;
    }

    const responsePromise = new Promise<TResult>((resolve, reject) => {
      this.pending.set(key, {
        method,
        resolve: (value) => resolve(value as TResult),
        reject,
      });
    });

    try {
      await this.sendMessage(message);
    } catch (error) {
      this.pending.delete(key);
      throw error;
    }

    return responsePromise;
  }

  async notify<TParams extends JsonValue = JsonValue>(
    method: string,
    params?: TParams,
  ): Promise<void> {
    if (this.closed) {
      throw new CamlFlowConnectionClosedError();
    }

    const message: JsonRpcNotification<TParams> = {
      jsonrpc: "2.0",
      method,
    };

    if (params !== undefined) {
      message.params = params;
    }

    await this.sendMessage(message);
  }

  async shutdownAndExit(options: ShutdownAndExitOptions = {}): Promise<void> {
    const timeoutMs = options.timeoutMs ?? 1000;
    const forceKill = options.forceKill ?? true;
    const killSignal = options.killSignal ?? "SIGKILL";

    let shutdownError: Error | undefined;
    if (!this.closed) {
      try {
        await this.shutdown();
      } catch (error) {
        shutdownError = normalizeError(error, "shutdown failed");
      }

      try {
        await this.exit();
      } catch (error) {
        shutdownError ??= normalizeError(error, "exit failed");
      }

      try {
        await endWritable(this.writable);
      } catch (error) {
        shutdownError ??= normalizeError(error, "failed to close writable stream");
      }
    }

    if (this.child) {
      await waitForChildClose(this.child, timeoutMs, forceKill, killSignal);
    } else {
      await Promise.race([
        this.waitForClose(),
        new Promise<void>((resolve) => setTimeout(resolve, timeoutMs)),
      ]);
    }

    if (shutdownError) {
      throw shutdownError;
    }
  }

  async waitForClose(): Promise<void> {
    await this.closePromise;
  }

  private readonly handleData = (chunk: Buffer | string): void => {
    try {
      const messages = this.parser.append(chunk);
      for (const message of messages) {
        void this.handleMessage(message).catch((error) => {
          this.failConnection(normalizeError(error, "failed to handle JSON-RPC message"));
        });
      }
    } catch (error) {
      this.failConnection(normalizeError(error, "failed to parse JSON-RPC stream"));
    }
  };

  private readonly handleStreamEnd = (): void => {
    this.finishConnection();
  };

  private readonly handleStreamClose = (): void => {
    this.finishConnection();
  };

  private readonly handleStreamError = (error: Error): void => {
    this.failConnection(error);
  };

  private readonly handleChildError = (error: Error): void => {
    this.failConnection(error);
  };

  private readonly handleChildExit = (
    code: number | null,
    signal: NodeJS.Signals | null,
  ): void => {
    if (this.closed) {
      return;
    }

    if (code === 0 || (code === null && signal === null)) {
      this.finishConnection();
      return;
    }

    const detail =
      code !== null
        ? `process exited with code ${code}`
        : `process exited from signal ${signal ?? "unknown"}`;
    this.failConnection(new Error(`CamlFlow JSON-RPC server ${detail}`));
  };

  private async handleMessage(message: JsonRpcMessage): Promise<void> {
    if (isJsonRpcResponse(message)) {
      this.handleResponse(message);
      return;
    }

    if ("id" in message) {
      await this.handleServerRequest(message);
      return;
    }

    await this.handleNotification(message);
  }

  private handleResponse(response: JsonRpcResponse): void {
    const key = idKey(response.id);
    const pending = this.pending.get(key);
    if (!pending) {
      return;
    }

    this.pending.delete(key);

    if ("error" in response) {
      pending.reject(
        new JsonRpcResponseError(pending.method, response.id, response.error),
      );
      return;
    }

    pending.resolve(response.result);
  }

  private async handleServerRequest(
    request: JsonRpcRequest,
  ): Promise<void> {
    if (request.method !== CAMLFLOW_METHODS.executeEffect || !this.effectHandler) {
      await this.sendError(
        request.id,
        CAMLFLOW_ERROR_CODES.methodNotFound,
        "method not found",
      );
      return;
    }

    try {
      const result = await this.effectHandler(
        request.params as CamlFlowExecuteEffectParams,
        request as JsonRpcRequest<CamlFlowExecuteEffectParams>,
      );
      await this.sendResponse(request.id, result);
    } catch (error) {
      const methodError =
        error instanceof JsonRpcMethodError
          ? error
          : new JsonRpcMethodError(
              CAMLFLOW_ERROR_CODES.internalError,
              normalizeError(error, "effect handler failed").message,
            );
      await this.sendError(
        request.id,
        methodError.code,
        methodError.message,
        methodError.data,
      );
    }
  }

  private async handleNotification(
    notification: JsonRpcNotification,
  ): Promise<void> {
    try {
      if (notification.method === CAMLFLOW_METHODS.trace && this.onTrace) {
        await this.onTrace(
          (notification.params ?? {}) as CamlFlowTraceNotification,
          notification as JsonRpcNotification<CamlFlowTraceNotification>,
        );
      }

      if (
        notification.method === CAMLFLOW_METHODS.diagnostic &&
        this.onDiagnostic
      ) {
        await this.onDiagnostic(
          notification.params as CamlFlowDiagnosticNotification,
          notification as JsonRpcNotification<CamlFlowDiagnosticNotification>,
        );
      }

      if (this.onNotification) {
        await this.onNotification(notification);
      }
    } catch (error) {
      const normalized = normalizeError(
        error,
        "notification handler failed",
      );
      this.onTransportError?.(normalized);
    }
  }

  private async sendResponse(
    id: JsonRpcId,
    result: JsonValue,
  ): Promise<void> {
    await this.sendMessage({
      jsonrpc: "2.0",
      id,
      result,
    });
  }

  private async sendError(
    id: JsonRpcId | null,
    code: number,
    message: string,
    data?: JsonValue,
  ): Promise<void> {
    const payload: JsonRpcErrorResponse = {
      jsonrpc: "2.0",
      id,
      error: {
        code,
        message,
      },
    };

    if (data !== undefined) {
      payload.error.data = data;
    }

    await this.sendMessage(payload);
  }

  private async sendMessage(message: JsonRpcMessage): Promise<void> {
    await writeContentLengthMessage(this.writable, message);
  }

  private failConnection(error: Error): void {
    if (this.closed) {
      return;
    }

    this.onTransportError?.(error);
    this.closeWithReason(error);
  }

  private finishConnection(): void {
    if (this.closed) {
      return;
    }

    this.closeWithReason(new CamlFlowConnectionClosedError());
  }

  private closeWithReason(error: Error): void {
    if (this.closed) {
      return;
    }

    this.closed = true;
    this.parser.reset();

    for (const pending of this.pending.values()) {
      pending.reject(error);
    }
    this.pending.clear();

    this.readable.off("data", this.handleData);
    this.readable.off("end", this.handleStreamEnd);
    this.readable.off("close", this.handleStreamClose);
    this.readable.off("error", this.handleStreamError);
    this.writable.off("error", this.handleStreamError);

    if (this.child) {
      this.child.off("error", this.handleChildError);
      this.child.off("exit", this.handleChildExit);
    }

    this.resolveClosed();
  }
}

export function spawnCamlFlowClient(
  options: SpawnCamlFlowClientOptions = {},
): CamlFlowJsonRpcClient {
  const command = options.command ?? "camlflow";
  const args = options.args ?? ["serve", "--stdio"];
  const child = spawn(command, args, {
    cwd: options.cwd,
    env: options.env,
    stdio: ["pipe", "pipe", options.stderr ?? "inherit"],
  });

  if (child.stdin === null || child.stdout === null) {
    throw new Error("Failed to create stdio pipes for CamlFlow child process");
  }

  return new CamlFlowJsonRpcClient(
    {
      readable: child.stdout,
      writable: child.stdin,
      effectHandler: options.effectHandler,
      onTrace: options.onTrace,
      onDiagnostic: options.onDiagnostic,
      onNotification: options.onNotification,
      onTransportError: options.onTransportError,
    },
    { child },
  );
}
