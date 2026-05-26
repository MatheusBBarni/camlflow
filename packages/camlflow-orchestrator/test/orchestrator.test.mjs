import assert from "node:assert/strict";
import test from "node:test";

import {
  CamlFlowResultParseError,
  CamlFlowValidationError,
  assertJsonValue,
  assertNonEmptyString,
  composeAbortSignals,
  createMemorySessionStore,
  parseResult,
  relayOutputChunk,
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
