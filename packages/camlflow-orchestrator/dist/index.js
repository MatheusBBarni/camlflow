export class CamlFlowOrchestratorError extends Error {
    constructor(message, options) {
        super(message, options);
        this.name = "CamlFlowOrchestratorError";
    }
}
export class CamlFlowValidationError extends CamlFlowOrchestratorError {
    constructor(message, options) {
        super(message, options);
        this.name = "CamlFlowValidationError";
    }
}
export class CamlFlowResultParseError extends CamlFlowOrchestratorError {
    metadata;
    constructor(message, metadata, options) {
        super(message, options);
        this.name = "CamlFlowResultParseError";
        this.metadata = metadata;
    }
}
export function assertNonEmptyString(value, label) {
    if (typeof value !== "string" || value.trim() === "") {
        throw new CamlFlowValidationError(`${label} must be a non-empty string`);
    }
    if (value.includes("\0")) {
        throw new CamlFlowValidationError(`${label} must not contain NUL bytes`);
    }
    return value;
}
export function assertPlainObject(value, label) {
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
    return value;
}
export function assertJsonValue(value, label = "value") {
    const seen = new WeakSet();
    return assertJsonValueInner(value, label, seen);
}
function assertJsonValueInner(value, label, seen) {
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
        const output = {};
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
export function parseResult(value, parser = "json") {
    const json = assertJsonValue(value, "result");
    if (parser === "json") {
        return json;
    }
    if (typeof parser === "function") {
        return parser(json);
    }
    if (parser && typeof parser === "object" && "parse" in parser && typeof parser.parse === "function") {
        return parser.parse(json);
    }
    if (parser &&
        typeof parser === "object" &&
        "safeParse" in parser &&
        typeof parser.safeParse === "function") {
        const parsed = parser.safeParse(json);
        if (!parsed.success) {
            throw new CamlFlowResultParseError("result parser rejected output", {
                issues: parsed.issues,
                error: parsed.error,
            });
        }
        return ("output" in parsed ? parsed.output : parsed.data);
    }
    throw new CamlFlowValidationError("result parser must be json, a function, parse, or safeParse object");
}
export function composeAbortSignals(signals) {
    const activeSignals = signals.filter((signal) => signal !== undefined);
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
        controller.signal.addEventListener("abort", () => {
            for (const signal of activeSignals) {
                signal.removeEventListener("abort", abort);
            }
        }, { once: true });
    }
    return controller.signal;
}
export async function relayOutputChunk(chunk, listener) {
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
export function createMemorySessionStore() {
    const records = new Map();
    return {
        async load(id) {
            assertNonEmptyString(id, "session id");
            return records.get(id);
        },
        async save(record) {
            assertNonEmptyString(record.id, "session id");
            assertNonEmptyString(record.sandboxCwd, "session sandbox cwd");
            assertJsonValue(record.data, "session data");
            records.set(record.id, { ...record, data: assertJsonValue(record.data, "session data") });
        },
        async delete(id) {
            assertNonEmptyString(id, "session id");
            records.delete(id);
        },
    };
}
