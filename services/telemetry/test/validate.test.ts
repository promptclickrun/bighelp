import { describe, expect, it } from "vitest";
import { SCHEMA } from "../src/schema.js";
import { checkValue, sanitizeEvents, validateBatch } from "../src/validate.js";
import { INSTALL_ID, SESSION_ID, appBatch } from "./helpers.js";

const NOW = Date.UTC(2026, 9, 24, 12, 0, 0);
const DAY = 86_400_000;
const FRAME_UUID = "0123456789abcdef0123456789ABCDEF";

const event = (name: string, p?: unknown, t: number = NOW) => ({ name, t, ...(p === undefined ? {} : { p }) });

function run(source: "app" | "nse" | "host" | "relay", events: unknown[]) {
  return sanitizeEvents(source, events, NOW);
}

describe("envelope", () => {
  const accept = (value: unknown) => validateBatch(value, NOW);

  it("accepts a complete app batch and lowercases nothing it should keep", () => {
    const result = accept(appBatch({ events: [event("app.opened", { coldStart: false })] }));
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.batch).toMatchObject({ source: "app", id: INSTALL_ID, session: SESSION_ID, dropped: 0 });
    expect(result.batch.events[0]).toMatchObject({ name: "app.opened", properties: { coldStart: "false" } });
  });

  it.each([
    ["not an object", "text"],
    ["an array", []],
    ["wrong version", appBatch({ version: 2 })],
    ["missing version", appBatch({ version: undefined })],
    ["source relay", appBatch({ source: "relay" })],
    ["unknown source", appBatch({ source: "web" })],
    ["numeric source", appBatch({ source: 1 })],
    ["uppercase id", appBatch({ id: INSTALL_ID.toUpperCase() })],
    ["version 1 uuid", appBatch({ id: "3f2b8c1e-9d4a-1e6b-8a1c-5d7e9f0a1b2c" })],
    ["missing id", appBatch({ id: undefined })],
    ["bad session", appBatch({ session: "not-a-uuid" })],
    ["no events", appBatch({ events: [] })],
    ["events not an array", appBatch({ events: {} })],
    ["51 events", appBatch({ events: Array.from({ length: 51 }, () => event("app.opened")) })],
    ["context not an object", appBatch({ context: "iOS" })],
    ["context is an array", appBatch({ context: [] })],
  ])("rejects %s", (_name, value) => {
    expect(accept(value).ok).toBe(false);
  });

  it("accepts exactly 1 and exactly 50 events", () => {
    expect(accept(appBatch({ events: [event("app.opened")] })).ok).toBe(true);
    expect(accept(appBatch({ events: Array.from({ length: 50 }, () => event("app.opened")) })).ok).toBe(true);
  });

  it("allows a missing session and a missing context", () => {
    const result = accept(appBatch({ session: undefined, context: undefined }));
    expect(result.ok && result.batch.context).toEqual({});
    expect(result.ok && result.batch.session).toBeUndefined();
  });

  it("drops unknown context keys and bad context values, and counts them", () => {
    const result = accept(
      appBatch({
        // JSON.parse makes a real own "__proto__" key. An object literal would set the prototype instead.
        context: JSON.parse(
          '{"appVersion":"2.7.0","os":"Android","hostname":"my-laptop","deviceClass":"iPhone","__proto__":"x"}',
        ),
        events: [event("app.opened")],
      }),
    );
    expect(result.ok && result.batch.context).toEqual({ appVersion: "2.7.0", deviceClass: "iPhone" });
    expect(result.ok && result.batch.dropped).toBe(3);
  });

  it("uses the context list of the batch's own source", () => {
    const result = accept(
      appBatch({ source: "host", context: { pluginVersion: "3.30.0", appVersion: "2.7.0" }, events: [event("host.started")] }),
    );
    expect(result.ok && result.batch.context).toEqual({ pluginVersion: "3.30.0" });
  });
});

describe("events", () => {
  it("drops unknown event names and counts them", () => {
    const result = run("app", [event("app.opened"), event("app.exploded"), event("push.sent"), event("host.started")]);
    expect(result.events.map((e) => e.name)).toEqual(["app.opened"]);
    expect(result.dropped).toBe(3);
  });

  it("only lets a source use its own events", () => {
    expect(run("nse", [event("app.opened")]).events).toEqual([]);
    expect(run("host", [event("crash")]).events).toEqual([]);
    expect(run("relay", [event("push.dlq", { reason: "queue_full" })]).events).toHaveLength(1);
  });

  it.each(["__proto__", "constructor", "toString", "hasOwnProperty"])("never treats %s as an event name", (name) => {
    expect(run("app", [event(name)]).events).toEqual([]);
  });

  it("drops events that are not objects or have no usable name", () => {
    const result = run("app", [null, 5, "app.opened", [], { t: NOW }, { name: 4, t: NOW }]);
    expect(result).toEqual({ events: [], dropped: 6 });
  });

  it("drops unknown props and prototype keys, keeps the event, and counts each", () => {
    const props = JSON.parse('{"coldStart":true,"email":"a@b.example","__proto__":{"x":1},"constructor":"y"}');
    const result = run("app", [event("app.opened", props)]);
    expect(result.events).toHaveLength(1);
    expect(result.events[0]!.properties).toEqual({ coldStart: "true" });
    expect(result.dropped).toBe(3);
  });

  it("drops an event whose props are not an object", () => {
    expect(run("app", [event("app.opened", "x"), event("app.opened", [1]), event("app.opened", null)]).events).toEqual([]);
  });

  it("drops an event that misses a required prop", () => {
    const result = run("app", [event("feature.used"), event("feature.used", { feature: "nope" }), event("perf.first_token_ms", {})]);
    expect(result).toEqual({ events: [], dropped: 3 });
  });

  it("splits numbers into measurements and everything else into properties", () => {
    const result = run("app", [event("perf.launch", { kind: "resume", medianMs: 420, samples: 12 })]);
    expect(result.events[0]).toMatchObject({
      properties: { kind: "resume" },
      measurements: { medianMs: 420, samples: 12 },
    });
  });

  it("sends a numeric enum as a measurement", () => {
    const result = run("relay", [event("push.sent", { priority: 10, result: "ok", status: 200 })]);
    expect(result.events[0]!.measurements).toEqual({ priority: 10, status: 200 });
    expect(run("relay", [event("push.sent", { priority: 7 })]).events[0]!.measurements).toEqual({});
    expect(run("relay", [event("push.sent", { priority: "10" })]).dropped).toBe(1);
  });
});

describe("time window", () => {
  it.each([
    ["now", NOW, true],
    ["exactly 7 days old", NOW - 7 * DAY, true],
    ["7 days and 1 ms old", NOW - 7 * DAY - 1, false],
    ["1 hour ahead", NOW + 3_600_000, true],
    ["1 hour and 1 ms ahead", NOW + 3_600_001, false],
    ["epoch", 0, false],
    ["a fraction", NOW + 0.5, false],
  ])("%s", (_name, t, ok) => {
    expect(run("app", [event("app.opened", undefined, t)]).events).toHaveLength(ok ? 1 : 0);
  });

  it.each([["a string", String(NOW)], ["null", null], ["NaN", Number.NaN], ["Infinity", Number.POSITIVE_INFINITY]])(
    "drops t as %s",
    (_name, t) => {
      expect(run("app", [{ name: "app.opened", t }]).events).toEqual([]);
    },
  );
});

describe("numbers", () => {
  it.each([
    ["ms 0", "perf.first_token_ms", { ms: 0 }, true],
    ["ms max", "perf.first_token_ms", { ms: 86_400_000 }, true],
    ["ms over", "perf.first_token_ms", { ms: 86_400_001 }, false],
    ["ms negative", "perf.first_token_ms", { ms: -1 }, false],
    ["ms fraction", "perf.first_token_ms", { ms: 1.5 }, false],
    ["ms string", "perf.first_token_ms", { ms: "5" }, false],
    ["ms NaN", "perf.first_token_ms", { ms: Number.NaN }, false],
    ["count max", "perf.reconnect", { attempts: 100_000 }, true],
    ["count over", "perf.reconnect", { attempts: 100_001 }, false],
    ["count negative", "perf.reconnect", { attempts: -1 }, false],
  ])("%s", (_name, name, p, ok) => {
    const result = run("app", [event(name, p)]);
    // A bad optional number drops the prop. A bad required one drops the event.
    if (ok) expect(result.dropped).toBe(0);
    else expect(result.dropped).toBe(1);
  });

  it("does not turn booleans or strings into numbers", () => {
    expect(run("app", [event("app.backgrounded", { foregroundMs: true })]).events[0]!.measurements).toEqual({});
    expect(run("app", [event("app.opened", { coldStart: 1 })]).events[0]!.properties).toEqual({});
  });
});

describe("string types", () => {
  const pass = (type: Parameters<typeof checkValue>[0], value: unknown) => checkValue(type, value).ok;

  it.each([
    ["2.7.0", true],
    ["2", true],
    ["1.2.3.4", true],
    ["12345.1", false],
    ["1.2.3.4.5", false],
    ["2.7.0-beta", false],
    ["", false],
    ["2.7.0\n", false],
    ["v2.7", false],
  ])("version %j", (value, ok) => expect(pass({ type: "version" }, value)).toBe(ok));

  it.each([
    ["ok", true],
    ["timeout_5s", true],
    ["a".repeat(64), true],
    ["a".repeat(65), false],
    ["Upper", false],
    ["has space", false],
    ["dash-ed", false],
    ["", false],
    ["path/to", false],
  ])("code %j", (value, ok) => expect(pass({ type: "code" }, value)).toBe(ok));

  it.each([
    [INSTALL_ID, true],
    [INSTALL_ID.toUpperCase(), false],
    ["3f2b8c1e-9d4a-5e6b-8a1c-5d7e9f0a1b2c", false],
    ["3f2b8c1e-9d4a-4e6b-7a1c-5d7e9f0a1b2c", false],
    ["3f2b8c1e9d4a4e6b8a1c5d7e9f0a1b2c", false],
    ["", false],
  ])("uuid %j", (value, ok) => expect(pass({ type: "uuid" }, value)).toBe(ok));

  it.each([
    [FRAME_UUID, true],
    ["0123456789abcdef0123456789abcdef", true],
    ["01234567-89ab-cdef-0123-456789abcdef", true],
    ["0123456789abcdef0123456789abcde", false],
    ["0123456789abcdef0123456789abcdef01234", false],
    ["0123456789abcdeg0123456789abcdef", false],
  ])("hexuuid %j", (value, ok) => expect(pass({ type: "hexuuid" }, value)).toBe(ok));

  it("normalizes hexuuid to lowercase", () => {
    expect(checkValue({ type: "hexuuid" }, FRAME_UUID)).toEqual({ ok: true, kind: "property", value: FRAME_UUID.toLowerCase() });
  });

  it("enforces enums as exact, case-sensitive matches", () => {
    const spec = { type: "enum", values: ["iOS", "iPadOS"] } as const;
    expect(pass(spec, "iOS")).toBe(true);
    expect(pass(spec, "ios")).toBe(false);
    expect(pass(spec, "iOS ")).toBe(false);
    expect(pass(spec, 1)).toBe(false);
  });

  const context = (source: "app" | "host", key: string, value: unknown) => {
    const result = validateBatch(
      { version: 1, source, id: INSTALL_ID, context: { [key]: value }, events: [event(source === "app" ? "app.opened" : "host.started")] },
      NOW,
    );
    return result.ok ? Object.keys(result.batch.context).includes(key) : false;
  };

  it.each([
    ["build", "160", true],
    ["build", "12345678", false],
    ["build", "16a", false],
    ["channel", "appstore", true],
    ["channel", "beta", false],
    ["deviceClass", "iPhone", true],
    ["deviceClass", "iPhone 17", false],
    ["osVersion", "27.1", true],
    ["osVersion", "27.1 (beta)", false],
  ])("app context %s=%j", (key, value, ok) => expect(context("app", key, value)).toBe(ok));

  it.each([
    ["hermesVersion", "0.22.1", true],
    ["hermesVersion", "0.22.1+g1a2b3c", true],
    ["hermesVersion", "0.22.1-rc1", true],
    ["hermesVersion", "0.22.1+" + "a".repeat(17), false],
    ["hermesVersion", "0.22.1 extra", false],
    ["python", "3.11", true],
    ["python", "3.11.4", false],
    ["python", "2.7", false],
    ["osFamily", "linux", true],
    ["osFamily", "Darwin", false],
    ["agentCount", "2-5", true],
    ["agentCount", "21+", true],
    ["agentCount", "7", false],
    ["pluginVersion", "3.30.0", true],
    ["pluginVersion", "3.30.0-dev", false],
  ])("host context %s=%j", (key, value, ok) => expect(context("host", key, value)).toBe(ok));

  const prop = (source: "host" | "relay", name: string, key: string, value: unknown) => {
    const result = run(source, [event(name, { [key]: value })]);
    return result.events.length === 1 && key in result.events[0]!.properties;
  };

  it.each([
    ["provider", "openai", true],
    ["provider", "my-provider_2", true],
    ["provider", "-bad", false],
    ["provider", "A", false],
    ["provider", "a".repeat(33), false],
    ["model", "gpt-5.1", true],
    ["model", "org/model:latest", true],
    ["model", "a".repeat(65), false],
    ["model", "Model With Spaces", false],
    ["model", "/etc/passwd", false],
    ["sessionSource", "telegram", true],
    ["sessionSource", "irc", false],
    ["outcome", "cancelled", true],
    ["outcome", "ok ", false],
  ])("turn.completed %s=%j", (key, value, ok) => expect(prop("host", "turn.completed", key, value)).toBe(ok));

  it.each([
    ["bighelp_render_card", true],
    ["mcp", true],
    ["custom", true],
    ["Terminal", false],
    ["../secrets", false],
    ["1tool", false],
    ["a".repeat(65), false],
  ])("tool.completed tool=%j", (value, ok) => expect(prop("host", "tool.completed", "tool", value)).toBe(ok));

  it.each([
    ["session.completed", true],
    ["wake", true],
    ["liveactivity", true],
    ["test", false],
    ["session.unknown", false],
  ])("alert.queued eventType=%j", (value, ok) => expect(prop("host", "alert.queued", "eventType", value)).toBe(ok));

  it("allows test only on push.sent", () => {
    expect(prop("relay", "push.sent", "eventType", "test")).toBe(true);
  });
});

describe("frames", () => {
  const frame = (over: Record<string, unknown> = {}) => ({ b: FRAME_UUID, o: 4096, n: "Bighelp", ...over });
  const crash = (frames: unknown) => run("app", [event("crash", { signal: 11, frames })]);

  it("accepts up to 64 frames and normalizes them to compact JSON", () => {
    const result = crash(Array.from({ length: 64 }, (_, i) => frame({ o: i })));
    expect(result.dropped).toBe(0);
    const json = result.events[0]!.properties.frames!;
    expect(JSON.parse(json)).toHaveLength(64);
    expect(json).not.toContain(" ");
    expect(JSON.parse(json)[0].b).toBe(FRAME_UUID.toLowerCase());
  });

  it("accepts an empty list", () => {
    expect(crash([]).events[0]!.properties.frames).toBe("[]");
  });

  it.each([
    ["65 frames", Array.from({ length: 65 }, () => frame())],
    ["not an array", { b: FRAME_UUID }],
    ["a string entry", ["frame"]],
    ["negative offset", [frame({ o: -1 })]],
    ["fractional offset", [frame({ o: 1.5 })]],
    ["huge offset", [frame({ o: 2 ** 60 })]],
    ["string offset", [frame({ o: "4" })]],
    ["bad binary uuid", [frame({ b: "xyz" })]],
    ["empty name", [frame({ n: "" })]],
    ["name too long", [frame({ n: "a".repeat(65) })]],
    ["name with a path", [frame({ n: "/Users/me/App" })]],
    ["name with a space", [frame({ n: "My App" })]],
    ["extra key", [frame({ symbol: "main" })]],
    ["missing key", [{ b: FRAME_UUID, o: 1 }]],
  ])("drops the whole frames prop for %s", (_name, frames) => {
    const result = crash(frames);
    expect(result.events).toHaveLength(1);
    expect(result.events[0]!.properties.frames).toBeUndefined();
    expect(result.events[0]!.measurements).toEqual({ signal: 11 });
    expect(result.dropped).toBe(1);
  });

  it("drops frames whose compact JSON is over 8,192 characters", () => {
    // 64 entries of about 140 characters each is more than 8,192.
    const frames = Array.from({ length: 64 }, (_, i) => frame({ o: 1_000_000_000_000 + i, n: "N".repeat(64) }));
    const result = crash(frames);
    expect(result.events[0]!.properties.frames).toBeUndefined();
    expect(result.dropped).toBe(1);
    // The same list with short names fits.
    expect(crash(frames.map((f) => ({ ...f, n: "N" }))).events[0]!.properties.frames).toBeDefined();
  });

  it("is only allowed on hang and crash", () => {
    expect(run("app", [event("app.opened", { frames: [] })]).dropped).toBe(1);
    expect(run("app", [event("hang", { durationMs: 3000, frames: [frame()] })]).dropped).toBe(0);
  });
});

describe("contract limits", () => {
  it("keeps the numbers the other repos rely on", () => {
    expect(SCHEMA.limits).toMatchObject({ maxEvents: 50, maxWireBytes: 65_536, maxDecompressedBytes: 262_144, maxFrames: 64 });
  });
});
