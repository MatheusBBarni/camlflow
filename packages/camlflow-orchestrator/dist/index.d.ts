export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonValue[] | JsonObject;
export interface JsonObject {
    [key: string]: JsonValue;
}
export type MaybePromise<T> = T | Promise<T>;
export declare class CamlFlowOrchestratorError extends Error {
    constructor(message: string, options?: ErrorOptions);
}
export declare class CamlFlowValidationError extends CamlFlowOrchestratorError {
    constructor(message: string, options?: ErrorOptions);
}
export declare class CamlFlowResultParseError extends CamlFlowOrchestratorError {
    readonly metadata?: unknown;
    constructor(message: string, metadata?: unknown, options?: ErrorOptions);
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
export type SandboxShellExecutor = (command: string, options?: SandboxShellOptions) => MaybePromise<SandboxShellResult>;
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
export type ResultParser<TOutput = JsonValue> = "json" | ((value: JsonValue) => TOutput) | {
    parse(value: JsonValue): TOutput;
} | {
    safeParse(value: JsonValue): {
        success: true;
        output: TOutput;
        data?: never;
    } | {
        success: true;
        data: TOutput;
        output?: never;
    } | {
        success: false;
        issues?: unknown;
        error?: unknown;
    };
};
export declare function assertNonEmptyString(value: unknown, label: string): string;
export declare function assertPlainObject(value: unknown, label: string): Record<string, unknown>;
export declare function assertJsonValue(value: unknown, label?: string): JsonValue;
export declare function parseResult<TOutput = JsonValue>(value: unknown, parser?: ResultParser<TOutput>): TOutput;
export declare function composeAbortSignals(signals: readonly (AbortSignal | undefined)[]): AbortSignal | undefined;
export declare function relayOutputChunk(chunk: OutputChunk, listener?: (chunk: OutputChunk) => MaybePromise<void>): Promise<void>;
export declare function createMemorySessionStore<TData extends JsonObject = JsonObject>(): SessionStore<TData>;
