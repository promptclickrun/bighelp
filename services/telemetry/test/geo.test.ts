import { afterEach, describe, expect, it, vi } from "vitest";
import { hostLocation } from "../src/geo.js";
import { appBatch, CLIENT_IP, INSTALL_ID, call, captureForwards } from "./helpers.js";

describe("hostLocation", () => {
  it("keeps the country and, in the US, the state", () => {
    expect(hostLocation({ country: "US", regionCode: "TX" })).toEqual({ country: "US", usState: "TX" });
    expect(hostLocation({ country: "us", regionCode: " dc " })).toEqual({ country: "US", usState: "DC" });
  });

  it("keeps only the country outside the US", () => {
    expect(hostLocation({ country: "DE", regionCode: "BE" })).toEqual({ country: "DE" });
    expect(hostLocation({ country: "PR", regionCode: "SJ" })).toEqual({ country: "PR" });
  });

  it("drops a US region that is not a state or DC", () => {
    expect(hostLocation({ country: "US", regionCode: "ZZ" })).toEqual({ country: "US" });
    expect(hostLocation({ country: "US", regionCode: "Texas" })).toEqual({ country: "US" });
    expect(hostLocation({ country: "US" })).toEqual({ country: "US" });
  });

  it.each([
    ["unknown", { country: "XX" }],
    ["Tor", { country: "T1", regionCode: "TX" }],
    ["not a code", { country: "USA" }],
    ["not a string", { country: 840 }],
    ["missing", {}],
  ])("returns nothing for a %s country", (_name, cf) => {
    expect(hostLocation(cf)).toEqual({});
  });

  it("returns nothing without Cloudflare properties", () => {
    expect(hostLocation(undefined)).toEqual({});
    expect(hostLocation(null)).toEqual({});
  });
});

describe("location on forwarded reports", () => {
  const hostBatch = (context: Record<string, string> = {}) => ({
    version: 1,
    source: "host",
    id: INSTALL_ID,
    context: { pluginVersion: "3.31.0", hermesVersion: "0.22.1", osFamily: "linux", python: "3.11", agentCount: "2-5", ...context },
    events: [
      { name: "turn.completed", t: Date.now(), p: { durationMs: 5200, outcome: "ok", provider: "example", model: "custom" } },
      { name: "host.started", t: Date.now() },
    ],
  });

  function request(batch: unknown, cf?: Record<string, unknown>): Request {
    return new Request("https://telemetry.example/v1/batch", {
      method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": CLIENT_IP },
      body: JSON.stringify(batch),
      ...(cf ? { cf } : {}),
    } as RequestInit);
  }

  async function forwarded(batch: unknown, cf?: Record<string, unknown>) {
    const { sent } = captureForwards();
    const response = await call(request(batch, cf));
    expect(response.status).toBe(202);
    return sent;
  }

  afterEach(() => vi.restoreAllMocks());

  it("adds the country and state to every host event", async () => {
    const sent = await forwarded(hostBatch(), { country: "US", regionCode: "TX", city: "Austin", postalCode: "78701", latitude: "30.27" });
    const envelopes = sent[0]!.body as any[];
    expect(envelopes).toHaveLength(2);
    for (const envelope of envelopes) {
      expect(envelope.data.baseData.properties.country).toBe("US");
      expect(envelope.data.baseData.properties.usState).toBe("TX");
      expect(envelope.tags["ai.location.ip"]).toBe("0.0.0.0");
    }
    for (const leaked of [CLIENT_IP, "Austin", "78701", "30.27"]) expect(sent[0]!.raw).not.toContain(leaked);
  });

  it("adds only the country for a host outside the US", async () => {
    const sent = await forwarded(hostBatch(), { country: "DE", regionCode: "BE" });
    const [envelope] = sent[0]!.body as any[];
    expect(envelope.data.baseData.properties.country).toBe("DE");
    expect(envelope.data.baseData.properties).not.toHaveProperty("usState");
  });

  it("adds nothing when the country is unknown", async () => {
    const sent = await forwarded(hostBatch(), { country: "XX" });
    const [envelope] = sent[0]!.body as any[];
    expect(envelope.data.baseData.properties).not.toHaveProperty("country");
    expect(envelope.data.baseData.properties).not.toHaveProperty("usState");
  });

  it("never adds a location to app reports", async () => {
    const sent = await forwarded(appBatch(), { country: "US", regionCode: "TX" });
    const raw = sent[0]!.raw;
    expect(raw).not.toContain('"country"');
    expect(raw).not.toContain('"usState"');
  });

  it("can't be set or overridden by the host", async () => {
    const sent = await forwarded(hostBatch({ country: "FR", usState: "CA" }), { country: "US", regionCode: "TX" });
    const [envelope] = sent[0]!.body as any[];
    expect(envelope.data.baseData.properties.country).toBe("US");
    expect(envelope.data.baseData.properties.usState).toBe("TX");

    const spoofOnly = await forwarded(hostBatch({ country: "FR", usState: "CA" }));
    const [plain] = spoofOnly[0]!.body as any[];
    expect(plain.data.baseData.properties).not.toHaveProperty("country");
    expect(plain.data.baseData.properties).not.toHaveProperty("usState");
  });
});
