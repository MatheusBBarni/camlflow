export type JsonPrimitive = string | number | boolean | null;

export interface JsonObject {
  [key: string]: JsonValue | undefined;
}

export type JsonArray = JsonValue[];
export type JsonValue = JsonPrimitive | JsonObject | JsonArray;
export type JsonRpcId = number | string;

export interface JsonRpcRequest<TParams extends JsonValue = JsonValue> {
  jsonrpc: "2.0";
  id: JsonRpcId;
  method: string;
  params?: TParams;
}

export interface JsonRpcNotification<TParams extends JsonValue = JsonValue> {
  jsonrpc: "2.0";
  method: string;
  params?: TParams;
}

export interface JsonRpcCancelRequestParams extends JsonObject {
  id: JsonRpcId;
}

export interface JsonRpcErrorObject<TData extends JsonValue = JsonValue> {
  code: number;
  message: string;
  data?: TData;
}

export interface JsonRpcSuccessResponse<TResult extends JsonValue = JsonValue> {
  jsonrpc: "2.0";
  id: JsonRpcId | null;
  result: TResult;
}

export interface JsonRpcErrorResponse<TData extends JsonValue = JsonValue> {
  jsonrpc: "2.0";
  id: JsonRpcId | null;
  error: JsonRpcErrorObject<TData>;
}

export type JsonRpcResponse<
  TResult extends JsonValue = JsonValue,
  TData extends JsonValue = JsonValue,
> = JsonRpcSuccessResponse<TResult> | JsonRpcErrorResponse<TData>;

export type JsonRpcMessage =
  | JsonRpcRequest
  | JsonRpcNotification
  | JsonRpcResponse;

export function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isJsonRpcResponse(
  message: JsonRpcMessage,
): message is JsonRpcResponse {
  return "result" in message || "error" in message;
}

export function isJsonRpcRequest(
  message: JsonRpcMessage,
): message is JsonRpcRequest | JsonRpcNotification {
  return "method" in message;
}

export function isJsonRpcNotification(
  message: JsonRpcMessage,
): message is JsonRpcNotification {
  return isJsonRpcRequest(message) && !("id" in message);
}

export const CAMLFLOW_PROTOCOL_VERSION = "0.1.0";

export const CAMLFLOW_METHODS = {
  initialize: "initialize",
  check: "camlflow/check",
  compile: "camlflow/compile",
  run: "camlflow/run",
  shutdown: "shutdown",
  exit: "exit",
  cancelRequest: "$/cancelRequest",
  executeEffect: "camlflow/executeEffect",
  trace: "camlflow/trace",
  diagnostic: "camlflow/diagnostic",
} as const;

export const CAMLFLOW_ERROR_CODES = {
  invalidRequest: -32600,
  methodNotFound: -32601,
  requestCancelled: -32800,
  serverNotInitialized: -32002,
  checkFailed: -32010,
  compileFailed: -32011,
  runFailed: -32012,
  internalError: -32000,
} as const;

export type CamlFlowEffectKind =
  | "bound-agent"
  | "bound-skill"
  | "local-prompt-skill"
  | "inline-agent";

export type CamlFlowEffectRole = "agent" | "skill";

export type CamlFlowTraceEvent =
  | "run-start"
  | "effect-request"
  | "effect-result"
  | "effect-error"
  | "run-finish"
  | "run-error"
  | "run-cancelled";

export interface CamlFlowCapabilities extends JsonObject {
  check: boolean;
  compile: boolean;
  run: boolean;
  executeEffect: boolean;
  trace: boolean;
  diagnostic: boolean;
  cancelRequest: boolean;
  renderedPrompt: boolean;
  outputSchema: boolean;
}

export interface CamlFlowInitializeResult extends JsonObject {
  protocolVersion: string;
  irVersion: string;
  capabilities: CamlFlowCapabilities;
  effectKinds: CamlFlowEffectKind[];
}

export interface CamlFlowProgramRef extends JsonObject {
  path: string;
  includePaths?: string[];
  skillsDir?: string | null;
}

export interface CamlFlowCheckParams extends JsonObject {
  program: CamlFlowProgramRef;
  entry?: string;
}

export interface CamlFlowCompileParams extends JsonObject {
  program: CamlFlowProgramRef;
  entry?: string;
}

export interface CamlFlowRunParams<TInput extends JsonValue = JsonValue>
  extends JsonObject {
  program: CamlFlowProgramRef;
  entry?: string;
  input?: TInput | null;
}

export interface CamlFlowCheckResult extends JsonObject {
  modules: number;
  rootModule: string;
}

export interface CamlFlowCompileResult<
  TArtifact extends JsonValue = JsonValue,
> extends JsonObject {
  irVersion: string;
  artifact: TArtifact;
}

export interface CamlFlowRunResult<TOutput extends JsonValue = JsonValue>
  extends JsonObject {
  runId: string;
  stepsRun: number;
  output: TOutput | null;
}

export interface CamlFlowPosition extends JsonObject {
  line: number;
  column: number;
  offset: number;
}

export interface CamlFlowLocation extends JsonObject {
  file: string;
  start: CamlFlowPosition;
  end: CamlFlowPosition;
}

export interface CamlFlowStringLiteral extends JsonObject {
  kind: "string";
  value: string;
}

export interface CamlFlowIntLiteral extends JsonObject {
  kind: "int";
  value: number;
}

export interface CamlFlowBoolLiteral extends JsonObject {
  kind: "bool";
  value: boolean;
}

export interface CamlFlowFloatLiteral extends JsonObject {
  kind: "float";
  value: number;
}

export interface CamlFlowUnitLiteral extends JsonObject {
  kind: "unit";
}

export type CamlFlowLiteral =
  | CamlFlowStringLiteral
  | CamlFlowIntLiteral
  | CamlFlowBoolLiteral
  | CamlFlowFloatLiteral
  | CamlFlowUnitLiteral;

export interface CamlFlowInlineMetadataEntry extends JsonObject {
  name: string;
  value: CamlFlowLiteral;
}

export interface CamlFlowInlineAgentDefinition extends JsonObject {
  model: string | null;
  temperature: number | null;
  system_prompt: string | null;
  metadata: CamlFlowInlineMetadataEntry[];
  loc: CamlFlowLocation;
}

export interface CamlFlowEffectRequest<TInput extends JsonValue = JsonValue>
  extends JsonObject {
  kind: CamlFlowEffectKind;
  role: CamlFlowEffectRole;
  name: string;
  input: TInput;
  declaredReturnType: string;
  outputSchema: JsonObject;
  workingDirectory: string | null;
  skillsDirectory: string | null;
  skillMarkdown: string | null;
  inlineDefinition: CamlFlowInlineAgentDefinition | null;
  renderedPrompt: string;
  requestedModel: string | null;
  unsupportedSettings: string[];
  step: number | null;
  runId: string | null;
}

export interface CamlFlowExecuteEffectParams<
  TInput extends JsonValue = JsonValue,
> extends JsonObject {
  runId: string | null;
  step: number | null;
  effect: CamlFlowEffectRequest<TInput>;
}

export interface CamlFlowExecuteEffectResult<
  TOutput extends JsonValue = JsonValue,
> extends JsonObject {
  output: TOutput;
}

export interface CamlFlowEffectSummary extends JsonObject {
  kind: CamlFlowEffectKind;
  name: string;
}

export interface CamlFlowTraceNotification extends JsonObject {
  event: CamlFlowTraceEvent;
  runId: string | null;
  step: number | null;
  effect: CamlFlowEffectSummary | null;
  details?: JsonValue;
}

export interface CamlFlowDiagnosticNotification extends JsonObject {
  severity: "error";
  message: string;
  method: string | null;
  runId: string | null;
  step: number | null;
  effect: CamlFlowEffectSummary | null;
}

export function effectOutput<TOutput extends JsonValue>(
  output: TOutput,
): CamlFlowExecuteEffectResult<TOutput> {
  return { output };
}
