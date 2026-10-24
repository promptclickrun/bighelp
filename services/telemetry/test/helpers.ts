import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test";
import { vi } from "vitest";
import worker, { type RateLimiter, type TelemetryEnv } from "../src/index.js";

export const INSTALL_ID = "3f2b8c1e-9d4a-4e6b-8a1c-5d7e9f0a1b2c";
export const SESSION_ID = "7a1d5c2e-0b3f-4c8d-9e6a-2f4b6d8a0c1e";
export const CONNECTION_STRING =
  "InstrumentationKey=00000000-0000-4000-8000-000000000001;IngestionEndpoint=https://region-0.in.applicationinsights.example/;LiveEndpoint=https://region.livediagnostics.example/";
export const TRACK_URL = "https://region-0.in.applicationinsights.example/v2.1/track";
export const HASH_KEY = "test-only-hash-key-not-a-secret";
// A documentation address (RFC 5737). Tests check that it never leaves the Worker.
export const CLIENT_IP = "203.0.113.77";

export const baseEnv = (): TelemetryEnv => ({
  RL_ID: (env as unknown as Record<string, RateLimiter>).RL_ID,
  RL_NET: (env as unknown as Record<string, RateLimiter>).RL_NET,
  APPINSIGHTS_CONNECTION_STRING: CONNECTION_STRING,
  IP_HASH_KEY: HASH_KEY,
});

export function appBatch(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    version: 1,
    source: "app",
    id: INSTALL_ID,
    session: SESSION_ID,
    context: {
      appVersion: "2.7.0",
      build: "160",
      os: "iOS",
      osVersion: "27.1",
      deviceClass: "iPhone",
      channel: "testflight",
    },
    events: [{ name: "app.opened", t: Date.now(), p: { coldStart: true } }],
    ...overrides,
  };
}

export function post(
  body: BodyInit | null,
  headers: Record<string, string> = {},
  path = "/v1/batch",
): Request {
  return new Request(`https://telemetry.example${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "cf-connecting-ip": CLIENT_IP,
      ...headers,
    },
    body,
  });
}

export const postJson = (value: unknown, headers: Record<string, string> = {}) =>
  post(JSON.stringify(value), headers);

export async function gzip(text: string | Uint8Array): Promise<Uint8Array> {
  const bytes = typeof text === "string" ? new TextEncoder().encode(text) : text;
  const stream = new Response(bytes).body!.pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

export async function call(request: Request, workerEnv: TelemetryEnv = baseEnv()) {
  const ctx = createExecutionContext();
  const response = await worker.fetch(request, workerEnv, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

// Replaces the outbound fetch so tests can read exactly what would reach Azure.
export function captureForwards(status = 200) {
  const sent: { url: string; body: unknown; raw: string; init: RequestInit }[] = [];
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const raw = String(init?.body ?? "");
    sent.push({ url: String(input instanceof Request ? input.url : input), body: JSON.parse(raw), raw, init: init ?? {} });
    return new Response("{}", { status });
  });
  return { sent, spy };
}
