import { once } from "node:events";
import type { Writable } from "node:stream";

import type { JsonRpcMessage } from "./protocol";

const HEADER_SEPARATOR = "\r\n\r\n";

function parseContentLength(headerBlock: string): number {
  const headers = headerBlock.split("\r\n");
  for (const header of headers) {
    if (!header.toLowerCase().startsWith("content-length:")) {
      continue;
    }

    const rawValue = header.slice("content-length:".length).trim();
    const contentLength = Number(rawValue);
    if (!Number.isInteger(contentLength) || contentLength < 0) {
      throw new Error(`Invalid Content-Length header: ${header}`);
    }

    return contentLength;
  }

  throw new Error(`Missing Content-Length header: ${headerBlock}`);
}

export function encodeContentLengthMessage(message: JsonRpcMessage): Buffer {
  const payload = Buffer.from(JSON.stringify(message), "utf8");
  const header = Buffer.from(
    `Content-Length: ${payload.length}\r\n\r\n`,
    "utf8",
  );

  return Buffer.concat([header, payload]);
}

export class ContentLengthMessageParser {
  private buffer = Buffer.alloc(0);

  append(chunk: Buffer | string): JsonRpcMessage[] {
    const nextChunk =
      typeof chunk === "string" ? Buffer.from(chunk, "utf8") : chunk;
    this.buffer = Buffer.concat([this.buffer, nextChunk]);

    const messages: JsonRpcMessage[] = [];
    while (true) {
      const marker = this.buffer.indexOf(HEADER_SEPARATOR);
      if (marker === -1) {
        return messages;
      }

      const headerBlock = this.buffer.subarray(0, marker).toString("utf8");
      const contentLength = parseContentLength(headerBlock);
      const payloadStart = marker + HEADER_SEPARATOR.length;
      const payloadEnd = payloadStart + contentLength;
      if (this.buffer.length < payloadEnd) {
        return messages;
      }

      const payload = this.buffer.subarray(payloadStart, payloadEnd);
      this.buffer = this.buffer.subarray(payloadEnd);

      let parsed: unknown;
      try {
        parsed = JSON.parse(payload.toString("utf8"));
      } catch (error) {
        const message =
          error instanceof Error ? error.message : "unknown JSON parse error";
        throw new Error(`Invalid JSON-RPC payload: ${message}`);
      }

      if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
        throw new Error("JSON-RPC payload must decode to an object");
      }

      messages.push(parsed as JsonRpcMessage);
    }
  }

  reset(): void {
    this.buffer = Buffer.alloc(0);
  }
}

export async function writeContentLengthMessage(
  writable: Writable,
  message: JsonRpcMessage,
): Promise<void> {
  if (writable.destroyed) {
    throw new Error("Cannot write JSON-RPC message: writable stream is destroyed");
  }

  const frame = encodeContentLengthMessage(message);
  const writePromise = new Promise<void>((resolve, reject) => {
    writable.write(frame, (error) => {
      if (error) {
        reject(error);
        return;
      }

      resolve();
    });
  });

  if (!writable.writableNeedDrain) {
    await writePromise;
    return;
  }

  await Promise.all([writePromise, once(writable, "drain")]);
}
