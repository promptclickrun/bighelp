import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import worker, { TelemetryIngest, type RateLimiter } from "../src/index.js";
import { SCHEMA } from "../src/schema.js";
import {
  CLIENT_IP,
  CONNECTION_STRING,
  HASH_KEY,
  INSTALL_ID,
  SESSION_ID,
  TRACK_URL,
  appBatch,
  baseEnv,
  call,
  captureForwards,
  gzip,
  post,
  postJson,
} from "./helpers.js";

afterEach(() => {
  vi.restoreAllMocks();
});

const errorCode = async (response: Response) => ((await response.json()) as { error: string }).error;

function recordingLimiter(allow = true) {
  const keys: string[] = [];
  const limiter: RateLimiter = {
    async limit({ key }) {
      keys.push(key);
      return { success: allow };
    },
  };
  return { keys, limiter };
}

describe("POST /v1/batch", () => {
  it("answers 202 with counts and no store", async () => {
    captureForwards();
    const response = await call(
      postJson(
        appBatch({
          events: [
            { name: "app.opened", t: Date.now(), p: { coldStart: true } },
            { name: "mystery", t: Date.now() },
            { name: "app.backgrounded", t: Date.now(), p: { foregroundMs: 1200, secret: "x" } },
          ],
        }),
      ),
    );
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({ accepted: 2, dropped: 2 });
    expect(response.headers.get("cache-control")).toBe("no-store");
  });

  it("sets no CORS headers", async () => {
    captureForwards();
    const response = await call(postJson(appBatch(), { origin: "https://example.test" }));
    expect([...response.headers.keys()].filter((name) => name.startsWith("access-control-"))).toEqual([]);
    const preflight = await call(
      new Request("https://telemetry.example/v1/batch", { method: "OPTIONS", headers: { origin: "https://example.test" } }),
    );
    expect(preflight.status).toBe(404);
  });

  it.each([
    ["GET /v1/batch", () => new Request("https://telemetry.example/v1/batch")],
    ["POST /", () => post("{}", {}, "/")],
    ["POST /v1/batch/", () => post("{}", {}, "/v1/batch/")],
    ["POST /v2/batch", () => post("{}", {}, "/v2/batch")],
    ["PUT /v1/batch", () => new Request("https://telemetry.example/v1/batch", { method: "PUT", body: "{}" })],
  ])("answers 404 for %s", async (_name, make) => {
    const response = await call(make());
    expect(response.status).toBe(404);
  });

  it("answers 202 for an accepted batch even when everything is dropped", async () => {
    captureForwards();
    const { sent } = captureForwards();
    const response = await call(postJson(appBatch({ events: [{ name: "nope", t: Date.now() }] })));
    expect(await response.json()).toEqual({ accepted: 0, dropped: 1 });
    expect(sent).toEqual([]);
  });

  describe("content type and encoding", () => {
    it.each(["text/plain", "application/x-www-form-urlencoded", "application/jsonp", ""])("415 for %j", async (type) => {
      const response = await call(post(JSON.stringify(appBatch()), { "content-type": type }));
      expect(response.status).toBe(415);
      expect(await errorCode(response)).toBe("telemetry_content_type_invalid");
    });

    it("accepts a charset parameter and any letter case", async () => {
      captureForwards();
      const response = await call(
        post(JSON.stringify(appBatch()), { "content-type": "Application/JSON; charset=utf-8" }),
      );
      expect(response.status).toBe(202);
    });

    it("415 for an encoding other than gzip", async () => {
      const response = await call(post(JSON.stringify(appBatch()), { "content-encoding": "br" }));
      expect(response.status).toBe(415);
    });

    it("accepts a gzip body", async () => {
      captureForwards();
      const body = await gzip(JSON.stringify(appBatch()));
      const response = await call(post(body, { "content-encoding": "gzip" }));
      expect(response.status).toBe(202);
      expect(await response.json()).toEqual({ accepted: 1, dropped: 0 });
    });

    it("400 for a corrupt gzip body", async () => {
      const response = await call(post(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]), { "content-encoding": "gzip" }));
      expect(response.status).toBe(400);
      expect(await errorCode(response)).toBe("telemetry_batch_invalid");
    });

    it("400 for JSON that gzip header lies about", async () => {
      const response = await call(post(JSON.stringify(appBatch()), { "content-encoding": "gzip" }));
      expect(response.status).toBe(400);
    });
  });

  describe("size limits", () => {
    it("413 when the wire body is over 64 KiB (declared length)", async () => {
      const body = "x".repeat(SCHEMA.limits.maxWireBytes + 1);
      const response = await call(post(body));
      expect(response.status).toBe(413);
      expect(await errorCode(response)).toBe("telemetry_batch_too_large");
    });

    it("413 when a streamed body without a length passes 64 KiB", async () => {
      const chunk = new TextEncoder().encode("x".repeat(16_384));
      let sent = 0;
      const stream = new ReadableStream<Uint8Array>({
        pull(controller) {
          if (sent >= 6) return controller.close();
          sent += 1;
          controller.enqueue(chunk);
        },
      });
      const request = new Request("https://telemetry.example/v1/batch", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: stream,
        // @ts-expect-error Workers need duplex for streamed request bodies.
        duplex: "half",
      });
      const response = await call(request);
      expect(response.status).toBe(413);
      expect(sent).toBeLessThan(6);
    });

    it("accepts a body of exactly 64 KiB", async () => {
      captureForwards();
      const filler = " ".repeat(SCHEMA.limits.maxWireBytes);
      const json = JSON.stringify(appBatch());
      const body = json + filler.slice(json.length);
      expect(new TextEncoder().encode(body).byteLength).toBe(SCHEMA.limits.maxWireBytes);
      expect((await call(post(body))).status).toBe(202);
    });

    it("413 for a gzip bomb that is small on the wire", async () => {
      const bomb = await gzip(new Uint8Array(32 * 1024 * 1024));
      expect(bomb.byteLength).toBeLessThan(SCHEMA.limits.maxWireBytes);
      const response = await call(post(bomb, { "content-encoding": "gzip" }));
      expect(response.status).toBe(413);
      expect(await errorCode(response)).toBe("telemetry_batch_too_large");
    });

    it("413 when the inflated body is just over 256 KiB, and accepts it just under", async () => {
      const pad = (size: number) => {
        const json = JSON.stringify(appBatch());
        return json + " ".repeat(size - json.length);
      };
      captureForwards();
      const over = await gzip(pad(SCHEMA.limits.maxDecompressedBytes + 1));
      expect((await call(post(over, { "content-encoding": "gzip" }))).status).toBe(413);
      const exact = await gzip(pad(SCHEMA.limits.maxDecompressedBytes));
      expect((await call(post(exact, { "content-encoding": "gzip" }))).status).toBe(202);
    });
  });

  describe("envelope", () => {
    it("400 for invalid JSON and invalid UTF-8", async () => {
      expect((await call(post("{not json"))).status).toBe(400);
      expect((await call(post(""))).status).toBe(400);
      expect((await call(post(new Uint8Array([0x7b, 0xff, 0xfe, 0x7d])))).status).toBe(400);
    });

    it("400 for zero events and for 51 events", async () => {
      const zero = await call(postJson(appBatch({ events: [] })));
      expect(zero.status).toBe(400);
      expect(await errorCode(zero)).toBe("telemetry_batch_invalid");
      const many = Array.from({ length: 51 }, () => ({ name: "app.opened", t: Date.now() }));
      expect((await call(postJson(appBatch({ events: many })))).status).toBe(400);
    });

    it("rejects source relay on the public route", async () => {
      const response = await call(
        postJson({
          version: 1,
          source: "relay",
          id: INSTALL_ID,
          events: [{ name: "push.dlq", t: Date.now(), p: { reason: "queue_full" } }],
        }),
      );
      expect(response.status).toBe(400);
      expect(await errorCode(response)).toBe("telemetry_batch_invalid");
    });

    it("does not let a public source send relay events", async () => {
      const { sent } = captureForwards();
      const response = await call(postJson(appBatch({ events: [{ name: "push.dlq", t: Date.now() }] })));
      expect(await response.json()).toEqual({ accepted: 0, dropped: 1 });
      expect(sent).toEqual([]);
    });

    it("drops events outside the time window", async () => {
      captureForwards();
      const day = 86_400_000;
      const response = await call(
        postJson(
          appBatch({
            events: [
              { name: "app.opened", t: Date.now() - 8 * day },
              { name: "app.opened", t: Date.now() + 2 * 3_600_000 },
              { name: "app.opened", t: Date.now() - day },
            ],
          }),
        ),
      );
      expect(await response.json()).toEqual({ accepted: 1, dropped: 2 });
    });
  });
});

describe("TelemetryIngest.relay", () => {
  async function relay(events: unknown, envOverrides: Partial<ReturnType<typeof baseEnv>> = {}) {
    const ctx = createExecutionContext();
    const entrypoint = new TelemetryIngest(ctx, { ...baseEnv(), ...envOverrides });
    await entrypoint.relay(events);
    await waitOnExecutionContext(ctx);
  }

  it("accepts relay events over RPC and forwards them", async () => {
    const { sent } = captureForwards();
    await relay([
      { name: "push.sent", t: Date.now(), p: { eventType: "session.completed", path: "direct", priority: 10, result: "ok", status: 200, hostToWorkerMs: 420, providerMs: 80, attempt: 1, environment: "production" } },
      { name: "push.dlq", t: Date.now(), p: { reason: "retries_exhausted" } },
    ]);
    expect(sent).toHaveLength(1);
    const envelopes = sent[0]!.body as { data: { baseData: { name: string; measurements: Record<string, number> } }; tags: Record<string, string> }[];
    expect(envelopes.map((e) => e.data.baseData.name)).toEqual(["push.sent", "push.dlq"]);
    expect(envelopes[0]!.data.baseData.measurements).toEqual({ priority: 10, status: 200, hostToWorkerMs: 420, providerMs: 80, attempt: 1 });
    expect(envelopes[0]!.tags["ai.cloud.role"]).toBe("bighelp-relay");
    expect(envelopes[0]!.tags["ai.user.id"]).toBeUndefined();
  });

  it("validates relay events against the relay allowlist", async () => {
    const { sent } = captureForwards();
    await relay([
      { name: "app.opened", t: Date.now() },
      { name: "push.dlq", t: Date.now(), p: { reason: "Has Spaces And Text", extra: 1 } },
      { name: "push.token_invalid", t: Date.now(), p: { kind: "alert", token: "deadbeef", reason: "bad_token" } },
    ]);
    const envelopes = sent[0]!.body as { data: { baseData: { name: string; properties: Record<string, string> } } }[];
    expect(envelopes.map((e) => e.data.baseData.name)).toEqual(["push.dlq", "push.token_invalid"]);
    expect(envelopes[0]!.data.baseData.properties).toEqual({});
    expect(envelopes[1]!.data.baseData.properties).toEqual({ kind: "alert", reason: "bad_token" });
    expect(sent[0]!.raw).not.toContain("deadbeef");
  });

  it("ignores input that is not a list and sends nothing when nothing is valid", async () => {
    const { sent } = captureForwards();
    await relay("nope");
    await relay({ name: "push.dlq" });
    await relay([{ name: "bogus", t: Date.now() }]);
    await relay([]);
    expect(sent).toEqual([]);
  });

  it("takes at most 50 events per call", async () => {
    const { sent } = captureForwards();
    await relay(Array.from({ length: 80 }, () => ({ name: "push.dlq", t: Date.now() })));
    expect((sent[0]!.body as unknown[]).length).toBe(50);
  });

  it("does nothing when the connection string is missing", async () => {
    const { sent } = captureForwards();
    await relay([{ name: "push.dlq", t: Date.now() }], { APPINSIGHTS_CONNECTION_STRING: undefined });
    expect(sent).toEqual([]);
  });

  it("is not reachable through fetch", async () => {
    const { sent } = captureForwards();
    for (const path of ["/relay", "/v1/relay", "/rpc/relay"]) {
      expect((await call(post(JSON.stringify([{ name: "push.dlq", t: Date.now() }]), {}, path))).status).toBe(404);
    }
    expect(sent).toEqual([]);
  });
});

describe("rate limits", () => {
  it("limits one id to 60 batches a minute with the real binding", async () => {
    captureForwards();
    const id = "9c1e2d3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f";
    const noNetwork = { ...baseEnv(), RL_NET: undefined };
    const statuses: number[] = [];
    for (let i = 0; i < 62; i += 1) {
      statuses.push((await call(postJson(appBatch({ id })), noNetwork)).status);
    }
    expect(statuses.slice(0, 60).every((status) => status === 202)).toBe(true);
    expect(statuses.slice(60)).toEqual([429, 429]);
    // Another id is not affected.
    expect((await call(postJson(appBatch()), noNetwork)).status).toBe(202);
  });

  it("answers 429 with the contract code", async () => {
    const { limiter } = recordingLimiter(false);
    const response = await call(postJson(appBatch()), { ...baseEnv(), RL_ID: limiter });
    expect(response.status).toBe(429);
    expect(await errorCode(response)).toBe("telemetry_rate_limited");
  });

  it("limits a network by an HMAC of its address, never the address", async () => {
    captureForwards();
    const net = recordingLimiter(true);
    const id = recordingLimiter(true);
    await call(postJson(appBatch()), { ...baseEnv(), RL_NET: net.limiter, RL_ID: id.limiter });
    expect(net.keys).toHaveLength(1);
    expect(id.keys).toEqual([`id:${INSTALL_ID}`]);

    const key = net.keys[0]!;
    expect(key).toMatch(/^net:[0-9a-f]{32}$/);
    expect(key).not.toContain(CLIENT_IP);

    const hmac = await crypto.subtle.importKey("raw", new TextEncoder().encode(HASH_KEY), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const expected = new Uint8Array(await crypto.subtle.sign("HMAC", hmac, new TextEncoder().encode(CLIENT_IP)));
    expect(key).toBe(`net:${Array.from(expected.slice(0, 16), (b) => b.toString(16).padStart(2, "0")).join("")}`);
  });

  it("gives different networks different keys and one network one key", async () => {
    captureForwards();
    const net = recordingLimiter(true);
    const env = { ...baseEnv(), RL_NET: net.limiter };
    await call(postJson(appBatch(), { "cf-connecting-ip": "203.0.113.1" }), env);
    await call(postJson(appBatch(), { "cf-connecting-ip": "203.0.113.1" }), env);
    await call(postJson(appBatch(), { "cf-connecting-ip": "203.0.113.2" }), env);
    expect(net.keys[0]).toBe(net.keys[1]);
    expect(net.keys[0]).not.toBe(net.keys[2]);
  });

  it("answers 429 when the network is over its limit, before reading the body", async () => {
    const net = recordingLimiter(false);
    const id = recordingLimiter(true);
    const response = await call(postJson(appBatch()), { ...baseEnv(), RL_NET: net.limiter, RL_ID: id.limiter });
    expect(response.status).toBe(429);
    expect(await errorCode(response)).toBe("telemetry_rate_limited");
    expect(id.keys).toEqual([]);
  });

  it("uses the 60 and 600 a minute budgets from the contract", async () => {
    const wrangler = await import("../wrangler.jsonc?raw").then((m) => m.default);
    const limits = [...wrangler.matchAll(/"name": "(RL_ID|RL_NET)".*?"limit": (\d+), "period": (\d+)/g)].map((m) => [m[1], Number(m[2]), Number(m[3])]);
    expect(limits).toEqual([
      ["RL_ID", 60, 60],
      ["RL_NET", 600, 60],
    ]);
  });

  it("skips the per-network limit without IP_HASH_KEY and never falls back to the raw address", async () => {
    captureForwards();
    const net = recordingLimiter(true);
    const response = await call(postJson(appBatch()), { ...baseEnv(), RL_NET: net.limiter, IP_HASH_KEY: undefined });
    expect(response.status).toBe(202);
    expect(net.keys).toEqual([]);
  });

  it("skips the per-network limit when the address header is missing", async () => {
    captureForwards();
    const net = recordingLimiter(false);
    const request = post(JSON.stringify(appBatch()));
    request.headers.delete("cf-connecting-ip");
    expect((await call(request, { ...baseEnv(), RL_NET: net.limiter })).status).toBe(202);
    expect(net.keys).toEqual([]);
  });

  it("lets a batch through if the limiter itself fails", async () => {
    captureForwards();
    const broken: RateLimiter = {
      async limit() {
        throw new Error("limiter down: do not log this");
      },
    };
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const response = await call(postJson(appBatch()), { ...baseEnv(), RL_ID: broken, RL_NET: broken });
    expect(response.status).toBe(202);
    expect(JSON.stringify(warn.mock.calls)).not.toContain("do not log this");
  });
});

describe("forwarding to Application Insights", () => {
  const fullBatch = () =>
    appBatch({
      events: [
        { name: "app.opened", t: 1_800_000_000_000, p: { coldStart: true } },
        { name: "perf.launch", t: 1_800_000_000_500, p: { kind: "first_draw", medianMs: 640, samples: 9 } },
        { name: "crash", t: 1_800_000_001_000, p: { signal: 11, frames: [{ b: "0123456789ABCDEF0123456789ABCDEF", o: 12, n: "Bighelp" }] } },
      ],
    });

  async function forwarded(batch: unknown = fullBatch(), headers: Record<string, string> = {}) {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(1_800_000_100_000);
    const { sent } = captureForwards();
    const response = await call(postJson(batch, headers));
    vi.useRealTimers();
    return { sent, response };
  }

  afterEach(() => vi.useRealTimers());

  it("posts a JSON array of envelopes to <endpoint>/v2.1/track", async () => {
    const { sent, response } = await forwarded();
    expect(response.status).toBe(202);
    expect(sent).toHaveLength(1);
    expect(sent[0]!.url).toBe(TRACK_URL);
    expect(sent[0]!.init.method).toBe("POST");
    expect(new Headers(sent[0]!.init.headers).get("content-type")).toBe("application/json");
    expect(sent[0]!.init.signal).toBeInstanceOf(AbortSignal);
    expect(Array.isArray(sent[0]!.body)).toBe(true);
  });

  it("builds the envelope shape from the contract", async () => {
    const { sent } = await forwarded();
    const envelopes = sent[0]!.body as any[];
    expect(envelopes).toHaveLength(3);
    expect(envelopes[1]).toEqual({
      name: "Microsoft.ApplicationInsights.Event",
      time: new Date(1_800_000_000_500).toISOString(),
      iKey: "00000000-0000-4000-8000-000000000001",
      tags: {
        "ai.cloud.role": "bighelp-app",
        "ai.user.id": INSTALL_ID,
        "ai.session.id": SESSION_ID,
        "ai.application.ver": "2.7.0",
        "ai.device.type": "iPhone",
        "ai.device.osVersion": "27.1",
        "ai.location.ip": "0.0.0.0",
        "ai.internal.sdkVersion": "bighelp-telemetry:1",
      },
      data: {
        baseType: "EventData",
        baseData: {
          ver: 2,
          name: "perf.launch",
          properties: {
            appVersion: "2.7.0",
            build: "160",
            os: "iOS",
            osVersion: "27.1",
            deviceClass: "iPhone",
            channel: "testflight",
            kind: "first_draw",
          },
          measurements: { medianMs: 640, samples: 9 },
        },
      },
    });
  });

  it("puts booleans and frames in properties as strings", async () => {
    const { sent } = await forwarded();
    const envelopes = sent[0]!.body as any[];
    expect(envelopes[0].data.baseData.properties.coldStart).toBe("true");
    expect(envelopes[2].data.baseData.measurements).toEqual({ signal: 11 });
    expect(envelopes[2].data.baseData.properties.frames).toBe('[{"b":"0123456789abcdef0123456789abcdef","o":12,"n":"Bighelp"}]');
  });

  it("uses the host plugin version and role for host batches", async () => {
    const { sent } = await forwarded({
      version: 1,
      source: "host",
      id: INSTALL_ID,
      context: { pluginVersion: "3.31.0", hermesVersion: "0.22.1", osFamily: "linux", python: "3.11", agentCount: "2-5" },
      events: [{ name: "turn.completed", t: 1_800_000_050_000, p: { durationMs: 5200, firstTokenMs: 900, toolCalls: 2, outcome: "ok", provider: "example", model: "custom", sessionSource: "bighelp" } }],
    });
    const [envelope] = sent[0]!.body as any[];
    expect(envelope.tags["ai.cloud.role"]).toBe("bighelp-host");
    expect(envelope.tags["ai.application.ver"]).toBe("3.31.0");
    expect(envelope.tags["ai.device.type"]).toBeUndefined();
    expect(envelope.data.baseData.measurements).toEqual({ durationMs: 5200, firstTokenMs: 900, toolCalls: 2 });
  });

  it("never contains the client address, the network hash or the request headers", async () => {
    const { sent } = await forwarded(fullBatch(), {
      "user-agent": "Bighelp/2.7 CFNetwork",
      "x-forwarded-for": "198.51.100.9",
      "x-real-ip": "198.51.100.10",
    });
    const raw = sent[0]!.raw;
    for (const secret of [CLIENT_IP, "198.51.100", HASH_KEY, "CFNetwork", "x-forwarded"]) {
      expect(raw).not.toContain(secret);
    }
    expect(raw).not.toMatch(/net:[0-9a-f]{32}/);
    expect(Object.keys(sent[0]!.init.headers as Record<string, string>)).toEqual(["content-type"]);
    expect(raw).toContain('"ai.location.ip":"0.0.0.0"');
  });

  it("forwards only allowlisted names, keys and tags", async () => {
    const hostile = appBatch({
      context: { appVersion: "2.7.0", email: "someone@example.test", hostname: "laptop", os: "iOS" },
      events: [
        { name: "app.opened", t: Date.now(), p: { coldStart: true, path: "/Users/someone/Secret.txt", text: "hello", ip: CLIENT_IP } },
        { name: "chat.message", t: Date.now(), p: { text: "private words" } },
        { name: "feature.used", t: Date.now(), p: { feature: "chat_sent", prompt: "tell me a secret" } },
      ],
    });
    vi.useFakeTimers({ toFake: ["Date"] });
    const { sent } = captureForwards();
    await call(postJson(hostile));
    vi.useRealTimers();
    const envelopes = sent[0]!.body as any[];
    expect(envelopes.map((e) => e.data.baseData.name)).toEqual(["app.opened", "feature.used"]);

    const allowedContext = new Set(Object.keys(SCHEMA.context.app));
    const allowedKeys = (name: string) =>
      new Set([...allowedContext, ...Object.keys((SCHEMA.events.app as Record<string, { props: object }>)[name]!.props)]);
    for (const envelope of envelopes) {
      const { name, properties, measurements } = envelope.data.baseData;
      const allowed = allowedKeys(name);
      for (const key of [...Object.keys(properties), ...Object.keys(measurements)]) expect(allowed.has(key), key).toBe(true);
      expect(Object.keys(envelope).sort()).toEqual(["data", "iKey", "name", "tags", "time"]);
    }
    for (const leaked of ["someone", "Secret.txt", "hello", CLIENT_IP, "private words", "tell me a secret", "laptop"]) {
      expect(sent[0]!.raw).not.toContain(leaked);
    }
  });

  it("answers 202 and logs a fixed code when Azure fails", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("secret exception text: InstrumentationKey=abc"));
    const response = await call(postJson(appBatch()));
    expect(response.status).toBe(202);
    expect(warn.mock.calls).toEqual([["telemetry_forward_failed"]]);
  });

  it("answers 202 and logs a fixed code when Azure refuses", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    captureForwards(403);
    const response = await call(postJson(appBatch()));
    expect(response.status).toBe(202);
    expect(warn.mock.calls).toEqual([["telemetry_forward_rejected", 403]]);
  });

  it.each([
    ["missing", undefined],
    ["empty", ""],
    ["no key", "IngestionEndpoint=https://region-0.in.applicationinsights.example/"],
    ["not https", "InstrumentationKey=00000000-0000-4000-8000-000000000001;IngestionEndpoint=http://example.test/"],
    ["bad key", "InstrumentationKey=hello;IngestionEndpoint=https://example.test/"],
    ["garbage", "%%%"],
  ])("accepts and drops when the connection string is %s", async (_name, connection) => {
    const { sent } = captureForwards();
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const response = await call(postJson(appBatch()), { ...baseEnv(), APPINSIGHTS_CONNECTION_STRING: connection });
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({ accepted: 1, dropped: 0 });
    expect(sent).toEqual([]);
  });

  it("falls back to the public ingestion endpoint when the string names none", async () => {
    const { sent } = captureForwards();
    await call(postJson(appBatch()), {
      ...baseEnv(),
      APPINSIGHTS_CONNECTION_STRING: "InstrumentationKey=00000000-0000-4000-8000-000000000001",
    });
    expect(sent[0]!.url).toBe("https://dc.services.visualstudio.com/v2.1/track");
  });

  it("keeps the configured string out of every response", async () => {
    captureForwards();
    const response = await call(postJson(appBatch()));
    expect(await response.text()).not.toContain("InstrumentationKey");
    expect(CONNECTION_STRING).toContain("InstrumentationKey");
  });
});
