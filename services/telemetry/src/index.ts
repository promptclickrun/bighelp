import { WorkerEntrypoint } from "cloudflare:workers";
import { forwardEvents } from "./appinsights.js";
import { networkKey } from "./network.js";
import { SCHEMA } from "./schema.js";
import { sanitizeEvents, validateBatch } from "./validate.js";

export interface RateLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface TelemetryEnv {
  // Workers Rate Limiting bindings. Missing in a bare test setup, so a missing one skips that limit.
  RL_ID?: RateLimiter;
  RL_NET?: RateLimiter;
  // Secrets. Both are optional on purpose: without them the Worker degrades instead of failing.
  APPINSIGHTS_CONNECTION_STRING?: string;
  IP_HASH_KEY?: string;
}

const { limits } = SCHEMA;

class Rejection extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code);
  }
}

function reply(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

function reject(status: number, code: string): Rejection {
  return new Rejection(status, code);
}

// Reads at most `cap` bytes. Anything longer is refused without being read to the end.
async function readCapped(stream: ReadableStream<Uint8Array> | null, cap: number): Promise<Uint8Array> {
  if (!stream) return new Uint8Array(0);
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > cap) {
      await reader.cancel().catch(() => undefined);
      throw reject(413, "telemetry_batch_too_large");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

async function readBody(request: Request): Promise<unknown> {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > limits.maxWireBytes) {
    throw reject(413, "telemetry_batch_too_large");
  }
  const wire = await readCapped(request.body, limits.maxWireBytes);

  const encoding = (request.headers.get("content-encoding") ?? "identity").trim().toLowerCase();
  let bytes = wire;
  if (encoding === "gzip") {
    try {
      const inflated = new Response(wire).body!.pipeThrough(new DecompressionStream("gzip"));
      bytes = await readCapped(inflated, limits.maxDecompressedBytes);
    } catch (error) {
      if (error instanceof Rejection) throw error;
      throw reject(400, "telemetry_batch_invalid");
    }
  } else if (encoding !== "identity") {
    throw reject(415, "telemetry_content_type_invalid");
  }
  if (bytes.byteLength > limits.maxDecompressedBytes) throw reject(413, "telemetry_batch_too_large");

  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
  } catch {
    throw reject(400, "telemetry_batch_invalid");
  }
}

async function allowed(limiter: RateLimiter | undefined, key: string): Promise<boolean> {
  if (!limiter) return true;
  try {
    return (await limiter.limit({ key })).success;
  } catch {
    // A broken limiter must not turn into lost telemetry or an open door for errors.
    console.warn("telemetry_rate_limiter_unavailable");
    return true;
  }
}

async function handleBatch(request: Request, env: TelemetryEnv, ctx: ExecutionContext): Promise<Response> {
  const mediaType = (request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
  if (mediaType !== "application/json") throw reject(415, "telemetry_content_type_invalid");

  // The network key is a keyed hash of the address. The address itself goes no further than this line.
  const network = await networkKey(env.IP_HASH_KEY, request.headers.get("cf-connecting-ip"));
  if (network && !(await allowed(env.RL_NET, `net:${network}`))) {
    throw reject(429, "telemetry_rate_limited");
  }

  const parsed = validateBatch(await readBody(request), Date.now());
  if (!parsed.ok) throw reject(400, "telemetry_batch_invalid");
  const { batch } = parsed;
  if (!(await allowed(env.RL_ID, `id:${batch.id}`))) throw reject(429, "telemetry_rate_limited");

  if (batch.events.length > 0) {
    ctx.waitUntil(forwardEvents(env.APPINSIGHTS_CONNECTION_STRING, batch, batch.events));
  }
  return reply({ accepted: batch.events.length, dropped: batch.dropped }, 202);
}

export default {
  async fetch(request: Request, env: TelemetryEnv, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/v1/batch") {
      return reply({ version: 1, error: "not_found" }, 404);
    }
    try {
      return await handleBatch(request, env, ctx);
    } catch (error) {
      if (error instanceof Rejection) return reply({ version: 1, error: error.code }, error.status);
      console.error("telemetry_internal_error");
      return reply({ version: 1, error: "telemetry_unavailable" }, 503);
    }
  },
} satisfies ExportedHandler<TelemetryEnv>;

// The only way `relay` events get in. Service bindings can call it; the public internet can't.
export class TelemetryIngest extends WorkerEntrypoint<TelemetryEnv> {
  async relay(events: unknown): Promise<void> {
    if (!Array.isArray(events)) return;
    const clean = sanitizeEvents("relay", events.slice(0, limits.maxEvents), Date.now());
    if (clean.events.length === 0) return;
    this.ctx.waitUntil(forwardEvents(this.env.APPINSIGHTS_CONNECTION_STRING, { source: "relay" }, clean.events));
  }
}
