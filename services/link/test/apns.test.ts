import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  apnsCollapseIdFor,
  apnsConfig,
  apnsIdFor,
  apnsProviderToken,
  apnsReasonCode,
  classifyApnsResponse,
  resetApnsTokenCache,
  sendApns,
  type ApnsConfig,
} from "../src/apns.js";
import { canonicalDeviceRequest } from "../src/device-auth.js";
import { handleLoopdyLinkRequest } from "../src/http.js";
import { canonicalNotificationHostRequest } from "../src/notification-grants.js";
import { liveActivitySpec, messageSpec } from "../src/push-delivery.js";
import { handleApnsRetryBatch, parseRetryMessage } from "../src/push-retry.js";
import { openPushToken, putPushTarget, purgeExpiredPushState } from "../src/push-targets.js";
import { LoopdyLinkError } from "../src/contracts.js";
import { sealedMessage } from "../src/buzzkit.js";
import pushTargetsMigrationSql from "../migrations/0010_push_targets.sql?raw";
import type { LinkEnv } from "../src/user-link.js";

const NOW = Math.floor(Date.now() / 1_000);
const ACCOUNT = "direct-apns-account-coordinate";
const DEVICE = "direct-apns-mobile-device";
const TOKEN = "ab".repeat(32);
const OTHER_TOKEN = "cd".repeat(32);

type KeyPair = CryptoKeyPair & { publicKeySPKI: string };

function encoded(value: ArrayBuffer | Uint8Array): string {
  return btoa(String.fromCharCode(...new Uint8Array(value)))
    .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function keys(): Promise<KeyPair> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"],
  ) as CryptoKeyPair;
  return Object.assign(pair, {
    publicKeySPKI: encoded(await crypto.subtle.exportKey("spki", pair.publicKey) as ArrayBuffer),
  });
}

/** A throwaway provider key. Real keys never go in the repo. */
async function throwawayP8(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"],
  ) as CryptoKeyPair;
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey) as ArrayBuffer);
  const body = btoa(String.fromCharCode(...der)).match(/.{1,64}/g)!.join("\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----`, publicKey: pair.publicKey };
}

function randomKey(): string {
  return btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))));
}

let providerKey: Awaited<ReturnType<typeof throwawayP8>>;
let log: string[];
let telemetry: ReturnType<typeof vi.fn>;
let retryQueue: { send: ReturnType<typeof vi.fn> };

interface ApnsCall { url: string; headers: Headers; payload: Record<string, unknown> }
interface BuzzKitCall { method: string; path: string; body: Record<string, unknown> | null }
let apnsCalls: ApnsCall[];
let buzzKitCalls: BuzzKitCall[];
let apnsAnswers: Array<{ status: number; reason?: string } | "timeout">;

/** Answers APNs from `apnsAnswers` (200 when it runs out) and BuzzKit the way it does today. */
function installFakeProviders(): void {
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const url = new URL(String(input instanceof Request ? input.url : input));
    if (url.hostname.endsWith("push.apple.com")) {
      log.push("apns");
      apnsCalls.push({
        url: url.toString(), headers: new Headers(init?.headers),
        payload: JSON.parse(String(init?.body)) as Record<string, unknown>,
      });
      const answer = apnsAnswers.shift() ?? { status: 200 };
      if (answer === "timeout") throw new DOMException("timed out", "TimeoutError");
      return new Response(answer.reason ? JSON.stringify({ reason: answer.reason }) : null, {
        status: answer.status,
      });
    }
    log.push("buzzkit");
    const method = init?.method ?? "GET";
    buzzKitCalls.push({
      method, path: url.pathname, body: init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : null,
    });
    if (method === "DELETE") return Response.json({ success: true, data: {} });
    if (url.pathname.includes("/v1/subscribers/")) {
      return Response.json({ success: false, error: { code: "not_found" } }, { status: 404 });
    }
    if (url.pathname === "/v1/live-activities/send") {
      return Response.json({ success: true, data: { results: [{ ok: true, id: "live_buzzkit_1" }] } });
    }
    return Response.json({ success: true, data: { id: "msg_buzzkit_1", status: "queued", counts: { total: 1 } } });
  });
}

function targetEnvironment(
  overrides: Record<string, unknown> = {},
  state: Record<string, unknown> = {},
): LinkEnv {
  return {
    ...env,
    USER_LINKS: {
      getByName: () => ({
        listDevices: async () => ({ devices: [{ deviceId: DEVICE, role: "mobile", lifecycle: "active" }] }),
        authorizeNotificationEgress: async (input: {
          activity?: { activityId: string; sessionReference: string; leaseExpires: number };
          grant?: { grantId: string };
          now: number;
        }) => {
          log.push("authorize");
          if (!input.activity || typeof state.notificationActivity !== "function") return;
          const activity = await (state.notificationActivity as (input: object) => Promise<{
            status: string; sessionReference: string; leaseExpires: number;
          }>)({ grantId: input.grant?.grantId, activityId: input.activity.activityId, now: input.now });
          if (activity.status !== "active" || activity.leaseExpires <= Math.floor(Date.now() / 1_000)) {
            throw new LoopdyLinkError("notification_activity_inactive", "Notification activity is inactive");
          }
        },
        revokeNotificationCredential: async () => {},
        revokeNotificationGrantAuthority: async () => {},
        retireNotificationScope: async () => {},
        putNotificationAsset: async (asset: object) => asset,
        ...state,
      }),
    } as never,
    BUZZKIT_API_KEY: `bk_tn_${crypto.randomUUID()}`,
    BUZZKIT_IDENTITY_SECRET: crypto.randomUUID(),
    BUZZKIT_IDENTITY_SECRET_GENERATION: "notification-instance-v2",
    APNS_KEY_P8: providerKey.pem,
    APNS_KEY_ID: "ABC123DEFG",
    APNS_TEAM_ID: "TEAM123456",
    PUSH_TOKEN_KEY: randomKey(),
    APNS_TOPIC: "app.loopdy.mobile",
    DIRECT_APNS: "on",
    DIRECT_APNS_CANARY: "",
    TELEMETRY: { relay: telemetry },
    APNS_RETRY: retryQueue,
    ...overrides,
  } as unknown as LinkEnv;
}

async function insertInstallation(installationKeys: KeyPair, hostKeys: KeyPair, eventTypes = ["session.completed"]) {
  const installationId = crypto.randomUUID();
  const grantId = crypto.randomUUID();
  const coordinate = `notify_${crypto.randomUUID().replaceAll("-", "")}`;
  const hostRaw = new Uint8Array(await crypto.subtle.exportKey("raw", hostKeys.publicKey) as ArrayBuffer);
  const hostKeyId = encoded(await crypto.subtle.digest("SHA-256", hostRaw));
  const grant = {
    grantId, instanceId: crypto.randomUUID(), hostKeyId, hostPublicKey: encoded(hostRaw),
    authorizationEpoch: 1, profile: "default", eventTypes, createdAt: NOW, expiresAt: NOW + 1_800,
    revision: 1, provider: "buzzkit", subscriberScope: "notification-instance", state: "active",
  };
  await env.ACCOUNTS.batch([
    env.ACCOUNTS.prepare(`INSERT INTO notification_installations(
      installation_id,notification_coordinate,public_key_spki,authorization_epoch,
      bootstrap_request_id,bootstrap_request_digest,state,created_at)
      VALUES(?,?,?,1,?,?,'active',?)`)
      .bind(installationId, coordinate, installationKeys.publicKeySPKI, crypto.randomUUID(), "digest", NOW),
    env.ACCOUNTS.prepare(`INSERT INTO notification_instance_grants(
      grant_id,notification_coordinate,installation_id,authorization_epoch,idempotency_key,
      request_digest,public_json,state,revision,created_at,expires_at)
      VALUES(?,?,?,1,?,?,?,'active',1,?,?)`)
      .bind(grantId, coordinate, installationId, crypto.randomUUID(), "digest", JSON.stringify(grant), NOW, NOW + 1_800),
  ]);
  return { installationId, grantId, hostKeyId, coordinate };
}

type Installation = Awaited<ReturnType<typeof insertInstallation>>;

async function hostRequest(
  hostKeys: KeyPair, grantId: string, suffix: string, body: object,
): Promise<Request> {
  const path = `/v1/notifications/host-grants/${grantId}${suffix}`;
  const raw = JSON.stringify(body);
  const nonce = encoded(crypto.getRandomValues(new Uint8Array(32)));
  const transcript = await canonicalNotificationHostRequest(
    "POST", path, grantId, NOW, nonce, new TextEncoder().encode(raw),
  );
  const hostRaw = new Uint8Array(await crypto.subtle.exportKey("raw", hostKeys.publicKey) as ArrayBuffer);
  return new Request(`https://link.loopdy.example${path}`, {
    method: "POST", body: raw,
    headers: {
      "content-type": "application/json",
      "x-loopdy-host-key-id": encoded(await crypto.subtle.digest("SHA-256", hostRaw)),
      "x-loopdy-timestamp": String(NOW),
      "x-loopdy-nonce": nonce,
      "x-loopdy-signature": encoded(await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" }, hostKeys.privateKey, new TextEncoder().encode(transcript),
      )),
    },
  });
}

function sealedEvent(installation: Installation, hex = "c") {
  const eventId = `${installation.grantId}:${hex.repeat(64)}`;
  const blob = new Uint8Array([9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6, 7]);
  return {
    version: 3, eventId, eventType: "session.completed", sessionReference: "a".repeat(43),
    turnId: "turn-direct", occurredAt: NOW,
    sealed: {
      v: 2, grantId: installation.grantId, eventId, recipientKeyId: "r".repeat(43),
      senderKeyId: installation.hostKeyId, issued: NOW, ephemeralPublicKey: "e".repeat(87),
      salt: "s".repeat(43), nonce: "n".repeat(16), ciphertext: "opaque-ciphertext",
      tag: "t".repeat(22), signature: "g".repeat(86),
    },
    avatar: {
      sha256: "", data: `data:application/octet-stream;base64,${btoa(String.fromCharCode(...blob))}`,
    },
    sound: true,
    blob,
  };
}

async function sealedBody(installation: Installation, hex = "c") {
  const { blob, ...event } = sealedEvent(installation, hex);
  event.avatar.sha256 = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", blob)),
    (byte) => byte.toString(16).padStart(2, "0")).join("");
  return event;
}

async function sendSealed(
  hostKeys: KeyPair, installation: Installation, targetEnv: LinkEnv, hex = "c", ctx?: ExecutionContext,
): Promise<Response> {
  return handleLoopdyLinkRequest(
    await hostRequest(hostKeys, installation.grantId, "/events", await sealedBody(installation, hex)),
    targetEnv, ctx,
  );
}

async function addTarget(
  targetEnv: LinkEnv, installation: Installation,
  overrides: Partial<{ kind: "alert" | "liveactivity" | "pts"; activityId: string; token: string; environment: "sandbox" | "production" }> = {},
) {
  await putPushTarget(targetEnv, {
    installationId: installation.installationId, ownerCoordinate: installation.coordinate, authorizationEpoch: 1,
  }, {
    kind: "alert", activityId: "", token: TOKEN, environment: "production", appVersion: "2.7.0(160)", ...overrides,
  }, NOW);
}

async function installationRequest(
  installationKeys: KeyPair, installationId: string, method: "PUT" | "DELETE" | "POST", path: string, body: object | null,
): Promise<Request> {
  const raw = body === null ? "" : JSON.stringify(body);
  const nonce = encoded(crypto.getRandomValues(new Uint8Array(24)));
  const canonical = [
    "loopdy-notification-device-v1", method, path, installationId, String(NOW), nonce, "1",
    encoded(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw))),
  ].join("\n");
  return new Request(`https://link.loopdy.example${path}`, {
    method, ...(raw ? { body: raw } : {}),
    headers: {
      "content-type": "application/json",
      "x-loopdy-notification-installation": installationId,
      "x-loopdy-timestamp": String(NOW),
      "x-loopdy-nonce": nonce,
      "x-loopdy-authorization-epoch": "1",
      "x-loopdy-signature": encoded(await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" }, installationKeys.privateKey, new TextEncoder().encode(canonical),
      )),
    },
  });
}

function relayedEvents(): Array<{ name: string; t: number; p: Record<string, unknown> }> {
  return telemetry.mock.calls.flatMap((call) => call[0] as never);
}

beforeEach(async () => {
  providerKey = providerKey ?? await throwawayP8();
  log = [];
  apnsCalls = [];
  buzzKitCalls = [];
  apnsAnswers = [];
  telemetry = vi.fn(async () => {});
  retryQueue = { send: vi.fn(async () => {}) };
  resetApnsTokenCache();
  await env.ACCOUNTS.batch([
    env.ACCOUNTS.prepare("DELETE FROM push_sends"),
    env.ACCOUNTS.prepare("DELETE FROM notification_installation_revocation_cleanup"),
    env.ACCOUNTS.prepare("DELETE FROM notification_device_revocations"),
    env.ACCOUNTS.prepare("DELETE FROM notification_instance_host_nonces"),
    env.ACCOUNTS.prepare("DELETE FROM notification_instance_grants"),
    env.ACCOUNTS.prepare("DELETE FROM notification_installations"),
    env.ACCOUNTS.prepare("DELETE FROM notification_account_installations"),
    env.ACCOUNTS.prepare("DELETE FROM device_directory"),
    env.ACCOUNTS.prepare("DELETE FROM accounts"),
    env.ACCOUNTS.prepare(
      "INSERT INTO accounts(account_coordinate,status,authorization_epoch,created_at) VALUES(?,'active',1,?)",
    ).bind(ACCOUNT, NOW),
    env.ACCOUNTS.prepare(`INSERT INTO device_directory(
      device_id,account_coordinate,public_key_spki,status,authorization_epoch,created_at)
      VALUES(?,?,?,'active',1,?)`).bind(DEVICE, ACCOUNT, "public-key-fixture", NOW),
  ]);
  installFakeProviders();
});

afterEach(() => vi.restoreAllMocks());

// MARK: APNs client

describe("APNs provider token", () => {
  async function config(): Promise<ApnsConfig> {
    return apnsConfig({
      APNS_KEY_P8: providerKey.pem, APNS_KEY_ID: "ABC123DEFG", APNS_TEAM_ID: "TEAM123456",
    })!;
  }

  it("is a valid ES256 JWT, cached for 40 minutes and then minted again", async () => {
    const now = vi.spyOn(Date, "now");
    now.mockReturnValue(1_700_000_000_000);
    const first = await apnsProviderToken(await config());
    const [header, claims, signature] = first.split(".") as [string, string, string];
    const decode = (value: string) => JSON.parse(atob(value.replaceAll("-", "+").replaceAll("_", "/")));
    expect(decode(header)).toEqual({ alg: "ES256", kid: "ABC123DEFG" });
    expect(decode(claims)).toEqual({ iss: "TEAM123456", iat: 1_700_000_000 });
    const raw = Uint8Array.from(atob(signature.replaceAll("-", "+").replaceAll("_", "/")), (c) => c.charCodeAt(0));
    expect(raw.length).toBe(64);
    expect(await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" }, providerKey.publicKey, raw, new TextEncoder().encode(`${header}.${claims}`),
    )).toBe(true);

    now.mockReturnValue(1_700_000_000_000 + 39 * 60_000);
    expect(await apnsProviderToken(await config())).toBe(first);
    now.mockReturnValue(1_700_000_000_000 + 41 * 60_000);
    const refreshed = await apnsProviderToken(await config());
    expect(refreshed).not.toBe(first);
    expect(JSON.parse(atob(refreshed.split(".")[1]!.replaceAll("-", "+").replaceAll("_", "/"))).iat)
      .toBe(1_700_000_000 + 41 * 60);
  });

  it("is not built from missing or malformed settings", () => {
    expect(apnsConfig({})).toBeNull();
    expect(apnsConfig({ APNS_KEY_P8: "not a key", APNS_KEY_ID: "ABC123DEFG", APNS_TEAM_ID: "TEAM123456" })).toBeNull();
    expect(apnsConfig({ APNS_KEY_P8: providerKey.pem, APNS_KEY_ID: "bad id!", APNS_TEAM_ID: "TEAM123456" })).toBeNull();
    // A secret pasted with literal \n pairs still reads.
    expect(apnsConfig({
      APNS_KEY_P8: providerKey.pem.replaceAll("\n", "\\n"), APNS_KEY_ID: "ABC123DEFG", APNS_TEAM_ID: "TEAM123456",
    })).not.toBeNull();
  });
});

describe("APNs request", () => {
  const base = async () => ({
    config: apnsConfig({
      APNS_KEY_P8: providerKey.pem, APNS_KEY_ID: "ABC123DEFG", APNS_TEAM_ID: "TEAM123456",
    })!,
    environment: "production" as const,
    tokenHex: TOKEN,
    pushType: "alert" as const,
    priority: 10 as const,
    expiration: NOW + 900,
    apnsId: await apnsIdFor("key"),
    payload: { aps: { alert: "hi" } },
    authorize: async () => { log.push("authorize"); },
  });

  it("sends the headers APNs needs, to the host for the token's environment", async () => {
    const input = await base();
    expect((await sendApns({ ...input, collapseId: "collapse-1" })).outcome).toBe("sent");
    expect((await sendApns({ ...input, environment: "sandbox", pushType: "background", priority: 5 })).outcome).toBe("sent");
    expect((await sendApns({ ...input, pushType: "liveactivity" })).outcome).toBe("sent");
    expect(apnsCalls.map((call) => new URL(call.url).host)).toEqual([
      "api.push.apple.com", "api.sandbox.push.apple.com", "api.push.apple.com",
    ]);
    expect(apnsCalls[0]!.url).toBe(`https://api.push.apple.com/3/device/${TOKEN}`);
    const alert = apnsCalls[0]!.headers;
    expect(alert.get("apns-topic")).toBe("app.loopdy.mobile");
    expect(alert.get("apns-push-type")).toBe("alert");
    expect(alert.get("apns-priority")).toBe("10");
    expect(alert.get("apns-expiration")).toBe(String(NOW + 900));
    expect(alert.get("apns-id")).toBe(input.apnsId);
    expect(alert.get("apns-collapse-id")).toBe("collapse-1");
    expect(alert.get("authorization")).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    expect(apnsCalls[1]!.headers.get("apns-push-type")).toBe("background");
    expect(apnsCalls[1]!.headers.get("apns-priority")).toBe("5");
    expect(apnsCalls[1]!.headers.has("apns-collapse-id")).toBe(false);
    expect(apnsCalls[2]!.headers.get("apns-topic")).toBe("app.loopdy.mobile.push-type.liveactivity");
    expect(apnsCalls[2]!.headers.get("apns-push-type")).toBe("liveactivity");
  });

  it("derives a stable version 8 UUID and a collapse ID that fits APNs' 64 bytes", async () => {
    const first = await apnsIdFor("install|alert|event-1");
    expect(first).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(await apnsIdFor("install|alert|event-1")).toBe(first);
    expect(await apnsIdFor("install|alert|event-2")).not.toBe(first);
    const collapse = await apnsCollapseIdFor(`${crypto.randomUUID()}:${"a".repeat(64)}`);
    expect(new TextEncoder().encode(collapse).length).toBeLessThanOrEqual(64);
    expect(await apnsCollapseIdFor("x")).toBe(await apnsCollapseIdFor("x"));
  });

  it("asks for egress authority right before the request, with the token already minted", async () => {
    const importKey = vi.spyOn(crypto.subtle, "importKey");
    const sign = vi.spyOn(crypto.subtle, "sign");
    const input = await base();
    await sendApns({
      ...input,
      authorize: async () => {
        log.push(`authorize:minted=${importKey.mock.calls.length > 0 && sign.mock.calls.length > 0}`);
      },
    });
    expect(log).toEqual(["authorize:minted=true", "apns"]);
  });

  it("replaces a refused provider token once and asks for authority again", async () => {
    apnsAnswers.push({ status: 403, reason: "ExpiredProviderToken" }, { status: 200 });
    const input = await base();
    const result = await sendApns(input);
    expect(result.outcome).toBe("sent");
    expect(log).toEqual(["authorize", "apns", "authorize", "apns"]);
    expect(apnsCalls[1]!.headers.get("authorization")).not.toBe(apnsCalls[0]!.headers.get("authorization"));
  });

  it("gives up when the new provider token is refused too", async () => {
    apnsAnswers.push({ status: 403, reason: "InvalidProviderToken" }, { status: 403, reason: "InvalidProviderToken" });
    const result = await sendApns(await base());
    expect(result).toMatchObject({ outcome: "provider_token", status: 403, reason: "invalid_provider_token" });
    expect(apnsCalls).toHaveLength(2);
  });

  it.each([
    [200, undefined, "sent"],
    [410, "Unregistered", "token_invalid"],
    [400, "BadDeviceToken", "token_invalid"],
    [400, "DeviceTokenNotForTopic", "token_invalid"],
    [400, "BadTopic", "rejected"],
    [400, "PayloadEmpty", "rejected"],
    [403, "Forbidden", "rejected"],
    [413, "PayloadTooLarge", "rejected"],
    [429, "TooManyRequests", "retryable"],
    [500, "InternalServerError", "retryable"],
    [503, "ServiceUnavailable", "retryable"],
  ] as const)("classifies %s %s as %s", (status, reason, expected) => {
    expect(classifyApnsResponse(status, reason)).toBe(expected);
  });

  it("maps reasons to fixed codes", () => {
    expect(apnsReasonCode("BadDeviceToken")).toBe("bad_device_token");
    expect(apnsReasonCode("SomethingNew-with=odd/chars")).toBe("other");
    expect(apnsReasonCode(undefined)).toBe("none");
  });

  it("treats a timeout or a dropped connection as retryable", async () => {
    apnsAnswers.push("timeout");
    expect(await sendApns(await base())).toMatchObject({ outcome: "retryable", status: 0, reason: "timeout" });
    vi.mocked(globalThis.fetch).mockRejectedValueOnce(new TypeError("network"));
    expect(await sendApns(await base())).toMatchObject({ outcome: "retryable", reason: "transport_error" });
  });

  it("reads at most 4 KiB of an answer", async () => {
    vi.mocked(globalThis.fetch).mockResolvedValueOnce(new Response(
      JSON.stringify({ reason: "BadTopic", padding: "x".repeat(10_000) }), { status: 400 },
    ));
    expect(await sendApns(await base())).toMatchObject({ outcome: "rejected", reason: "none" });
  });
});

// MARK: Device routes

describe("push target routes", () => {
  let installationKeys: KeyPair;
  let hostKeys: KeyPair;
  let installation: Installation;
  let targetEnv: LinkEnv;

  beforeEach(async () => {
    installationKeys = await keys();
    hostKeys = await keys();
    installation = await insertInstallation(installationKeys, hostKeys);
    targetEnv = targetEnvironment();
  });

  const put = (body: object, path = "/v1/notifications/push-target") =>
    installationRequest(installationKeys, installation.installationId, "PUT", path, body)
      .then((request) => handleLoopdyLinkRequest(request, targetEnv));

  it("stores the token sealed and answers with the target", async () => {
    const response = await put({ version: 1, token: TOKEN, environment: "production", appVersion: "2.7.0(160)" });
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      version: 1, target: { kind: "alert", environment: "production", updatedAt: expect.any(Number) },
    });
    const row = await env.ACCOUNTS.prepare("SELECT * FROM push_targets WHERE installation_id=?")
      .bind(installation.installationId).first<Record<string, unknown>>();
    expect(row).toMatchObject({ kind: "alert", activity_id: "", environment: "production", app_version: "2.7.0(160)" });
    expect(String(row!.token_ciphertext)).not.toContain(TOKEN);
    expect(JSON.stringify(row)).not.toContain(TOKEN);
    expect(Number(row!.expires_at) - Number(row!.updated_at)).toBe(60 * 86_400);
    expect(row!.invalid_at).toBeNull();
    // Opens only for the installation, kind and activity it was sealed for.
    const ciphertext = String(row!.token_ciphertext);
    expect(await openPushToken(targetEnv, installation.installationId, "alert", "", ciphertext)).toBe(TOKEN);
    expect(await openPushToken(targetEnv, crypto.randomUUID(), "alert", "", ciphertext)).toBeNull();
    expect(await openPushToken(targetEnv, installation.installationId, "pts", "", ciphertext)).toBeNull();
    expect(await openPushToken({ PUSH_TOKEN_KEY: randomKey() }, installation.installationId, "alert", "", ciphertext)).toBeNull();
  });

  it("replaces the token on a second PUT and clears an invalid mark", async () => {
    await put({ version: 1, token: TOKEN, environment: "production", appVersion: "2.7.0(160)" });
    await env.ACCOUNTS.prepare("UPDATE push_targets SET invalid_at=?").bind(NOW).run();
    await put({ version: 1, token: OTHER_TOKEN, environment: "sandbox", appVersion: "2.7.0(161)" });
    const rows = await env.ACCOUNTS.prepare("SELECT environment,invalid_at,app_version FROM push_targets WHERE installation_id=?")
      .bind(installation.installationId).all();
    expect(rows.results).toEqual([{ environment: "sandbox", invalid_at: null, app_version: "2.7.0(161)" }]);
  });

  it.each([
    ["upper-case hex", { token: "AB".repeat(32) }],
    ["odd length", { token: `${TOKEN}a` }],
    ["too short", { token: "ab".repeat(31) }],
    ["too long", { token: "ab".repeat(101) }],
    ["not hex", { token: "zz".repeat(32) }],
    ["unknown environment", { environment: "staging" }],
    ["bad app version", { appVersion: "2.7.0" }],
    ["extra key", { extra: true }],
    ["wrong version", { version: 2 }],
  ])("refuses %s", async (_name, change) => {
    const response = await put({
      version: 1, token: TOKEN, environment: "production", appVersion: "2.7.0(160)", ...change,
    });
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: { code: "notification_push_target_invalid" } });
    expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS n FROM push_targets").first()).toEqual({ n: 0 });
  });

  it("deletes the target, and deleting again is fine", async () => {
    await put({ version: 1, token: TOKEN, environment: "production", appVersion: "2.7.0(160)" });
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const response = await installationRequest(
        installationKeys, installation.installationId, "DELETE", "/v1/notifications/push-target", { version: 1 },
      ).then((request) => handleLoopdyLinkRequest(request, targetEnv));
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ version: 1, target: null });
    }
    expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS n FROM push_targets").first()).toEqual({ n: 0 });
  });

  it("keeps Live Activity and push-to-start tokens apart, with their own lifetimes", async () => {
    const live = await put({
      version: 1, kind: "liveactivity", activityId: "activity-1", token: TOKEN, environment: "sandbox",
    }, "/v1/notifications/live-activity-target");
    expect(live.status).toBe(200);
    expect(await live.json()).toEqual({
      version: 1,
      target: { kind: "liveactivity", activityId: "activity-1", environment: "sandbox", updatedAt: expect.any(Number) },
    });
    const pts = await put({
      version: 1, kind: "pts", token: OTHER_TOKEN, environment: "production",
    }, "/v1/notifications/live-activity-target");
    expect(await pts.json()).toEqual({
      version: 1, target: { kind: "pts", environment: "production", updatedAt: expect.any(Number) },
    });
    const rows = await env.ACCOUNTS.prepare(
      "SELECT kind,activity_id,expires_at-updated_at AS lifetime FROM push_targets ORDER BY kind",
    ).all();
    expect(rows.results).toEqual([
      { kind: "liveactivity", activity_id: "activity-1", lifetime: 12 * 3_600 },
      { kind: "pts", activity_id: "", lifetime: 60 * 86_400 },
    ]);
    for (const body of [{ version: 1, kind: "liveactivity", activityId: "activity-1" }, { version: 1, kind: "pts" }]) {
      const response = await installationRequest(
        installationKeys, installation.installationId, "DELETE", "/v1/notifications/live-activity-target", body,
      ).then((request) => handleLoopdyLinkRequest(request, targetEnv));
      expect(await response.json()).toEqual({ version: 1, target: null });
    }
    expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS n FROM push_targets").first()).toEqual({ n: 0 });
  });

  it.each([
    ["no kind", { token: TOKEN, environment: "production" }],
    ["an activity ID on pts", { kind: "pts", activityId: "a", token: TOKEN, environment: "production" }],
    ["no activity ID", { kind: "liveactivity", token: TOKEN, environment: "production" }],
    ["a bad activity ID", { kind: "liveactivity", activityId: "-bad", token: TOKEN, environment: "production" }],
    ["an unknown kind", { kind: "alert", token: TOKEN, environment: "production" }],
  ])("refuses a Live Activity target with %s", async (_name, change) => {
    const response = await put({ version: 1, ...change }, "/v1/notifications/live-activity-target");
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: { code: "notification_push_target_invalid" } });
  });

  it("keeps only the newest eight Live Activity tokens", async () => {
    for (let index = 0; index < 10; index += 1) {
      await putPushTarget(targetEnv, {
        installationId: installation.installationId, ownerCoordinate: installation.coordinate, authorizationEpoch: 1,
      }, { kind: "liveactivity", activityId: `activity-${index}`, token: TOKEN, environment: "production", appVersion: "" }, NOW + index);
    }
    const rows = await env.ACCOUNTS.prepare(
      "SELECT activity_id FROM push_targets WHERE installation_id=? ORDER BY activity_id",
    ).bind(installation.installationId).all<{ activity_id: string }>();
    expect(rows.results.map((row) => row.activity_id)).toEqual(
      Array.from({ length: 8 }, (_, index) => `activity-${index + 2}`),
    );
  });

  it("refuses an unauthenticated request, an account credential and a wrong method", async () => {
    const unsigned = await handleLoopdyLinkRequest(new Request("https://link.loopdy.example/v1/notifications/push-target", {
      method: "PUT", body: "{}", headers: { "content-type": "application/json" },
    }), targetEnv);
    expect(unsigned.status).toBe(401);

    const accountKeys = await keys();
    await env.ACCOUNTS.prepare("UPDATE device_directory SET public_key_spki=? WHERE device_id=?")
      .bind(accountKeys.publicKeySPKI, DEVICE).run();
    const raw = JSON.stringify({ version: 1, token: TOKEN, environment: "production", appVersion: "2.7.0(160)" });
    const nonce = encoded(crypto.getRandomValues(new Uint8Array(24)));
    const canonical = await canonicalDeviceRequest({
      method: "PUT", path: "/v1/notifications/push-target", deviceId: DEVICE, timestamp: NOW,
      nonce, authorizationEpoch: 1, body: raw,
    });
    const account = await handleLoopdyLinkRequest(new Request("https://link.loopdy.example/v1/notifications/push-target", {
      method: "PUT", body: raw,
      headers: {
        "content-type": "application/json", "x-loopdy-device-id": DEVICE, "x-loopdy-timestamp": String(NOW),
        "x-loopdy-nonce": nonce, "x-loopdy-authorization-epoch": "1",
        "x-loopdy-signature": encoded(await crypto.subtle.sign(
          { name: "ECDSA", hash: "SHA-256" }, accountKeys.privateKey, new TextEncoder().encode(canonical),
        )),
      },
    }), targetEnv);
    expect(account.status).toBe(403);
    expect(await account.json()).toMatchObject({ error: { code: "notification_scope_invalid" } });

    const wrongMethod = await installationRequest(
      installationKeys, installation.installationId, "POST", "/v1/notifications/push-target", { version: 1 },
    ).then((request) => handleLoopdyLinkRequest(request, targetEnv));
    expect(wrongMethod.status).toBe(405);
    expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS n FROM push_targets").first()).toEqual({ n: 0 });
  });

  it("answers 503 while the token key is not set, and stores nothing", async () => {
    targetEnv = targetEnvironment({ PUSH_TOKEN_KEY: undefined });
    const response = await put({ version: 1, token: TOKEN, environment: "production", appVersion: "2.7.0(160)" });
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ error: { code: "notification_push_target_unavailable" } });
  });

  it("refuses a replayed request", async () => {
    const request = await installationRequest(
      installationKeys, installation.installationId, "PUT", "/v1/notifications/push-target",
      { version: 1, token: TOKEN, environment: "production", appVersion: "2.7.0(160)" },
    );
    expect((await handleLoopdyLinkRequest(request.clone(), targetEnv)).status).toBe(200);
    expect((await handleLoopdyLinkRequest(request.clone(), targetEnv)).status).toBe(409);
  });

  it("deletes every target and send record when the installation is revoked", async () => {
    await addTarget(targetEnv, installation);
    await addTarget(targetEnv, installation, { kind: "liveactivity", activityId: "activity-1" });
    await env.ACCOUNTS.prepare(`INSERT INTO push_sends(dedupe_key,installation_id,apns_id,state,created_at,expires_at)
      VALUES('k',?,'id','sent',?,?)`).bind(installation.installationId, NOW, NOW + 100).run();
    const response = await installationRequest(
      installationKeys, installation.installationId, "DELETE", "/v1/notifications/installations/current", null,
    ).then((request) => handleLoopdyLinkRequest(request, targetEnv));
    expect(response.status).toBe(200);
    expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS n FROM push_targets").first()).toEqual({ n: 0 });
    expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS n FROM push_sends").first()).toEqual({ n: 0 });
  });

  it("keeps a revoked installation's targets unusable even before cleanup runs", async () => {
    await addTarget(targetEnv, installation);
    await env.ACCOUNTS.prepare(`UPDATE notification_installations
      SET state='revoked',authorization_epoch=authorization_epoch+1 WHERE installation_id=?`)
      .bind(installation.installationId).run();
    const { findPushTarget } = await import("../src/push-targets.js");
    expect(await findPushTarget(targetEnv, {
      installationId: installation.installationId, ownerCoordinate: installation.coordinate,
    }, "alert", "", NOW)).toBeNull();
    expect(await putPushTarget(targetEnv, {
      installationId: installation.installationId, ownerCoordinate: installation.coordinate, authorizationEpoch: 2,
    }, { kind: "alert", activityId: "", token: TOKEN, environment: "production", appVersion: "" }, NOW)).toBeNull();
  });

  it("purges expired rows in small batches", async () => {
    for (let index = 0; index < 60; index += 1) {
      await env.ACCOUNTS.prepare(`INSERT INTO push_targets(installation_id,kind,activity_id,environment,
        token_ciphertext,app_version,authorization_epoch,updated_at,expires_at)
        VALUES(?,'liveactivity',?,'production','v1.x','',1,?,?)`)
        .bind(installation.installationId, `old-${index}`, NOW - 100, NOW - 1).run();
    }
    await purgeExpiredPushState(targetEnv, NOW);
    expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS n FROM push_targets").first()).toEqual({ n: 10 });
    await purgeExpiredPushState(targetEnv, NOW);
    expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS n FROM push_targets").first()).toEqual({ n: 0 });
  });
});

// MARK: Sending

describe("choosing direct or BuzzKit", () => {
  let installationKeys: KeyPair;
  let hostKeys: KeyPair;
  let installation: Installation;

  beforeEach(async () => {
    installationKeys = await keys();
    hostKeys = await keys();
    installation = await insertInstallation(installationKeys, hostKeys);
  });

  const buzzKitMessages = () => buzzKitCalls.filter((call) => call.path === "/v1/messages" && call.method === "POST");

  it("keeps using BuzzKit, without a read-back, when DIRECT_APNS is off or unset", async () => {
    for (const [index, DIRECT_APNS] of ["off", undefined, "", "nonsense"].entries()) {
      buzzKitCalls = []; apnsCalls = [];
      const targetEnv = targetEnvironment({ DIRECT_APNS });
      await addTarget(targetEnv, installation);
      const response = await sendSealed(hostKeys, installation, targetEnv, String(index + 1));
      expect(response.status).toBe(202);
      expect(await response.json()).toEqual({
        version: 1, status: "accepted", deliveryId: "msg_buzzkit_1", providerStatus: "queued", counts: { total: 1 },
      });
      expect(apnsCalls).toEqual([]);
      expect(buzzKitCalls.map((call) => `${call.method} ${call.path}`)).toEqual(["POST /v1/messages"]);
    }
    expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS n FROM push_sends").first()).toEqual({ n: 0 });
  });

  it("adds bighelp_meta to what BuzzKit gets, without changing the rest", async () => {
    const targetEnv = targetEnvironment({ DIRECT_APNS: "off" });
    await sendSealed(hostKeys, installation, targetEnv);
    const body = buzzKitMessages()[0]!.body!;
    expect(body.data).toMatchObject({
      loopdy: { version: 2, eventType: "session.completed", grantId: installation.grantId },
      bighelp_meta: { v: 1, path: "buzzkit", sentAt: expect.any(Number), occurredAt: NOW * 1_000 },
    });
    expect(body).toMatchObject({ title: "bighelp", body: "New reply", sound: "default", priority: "high" });
  });

  it("a BuzzKit answer without a status is reported as accepted", async () => {
    vi.mocked(globalThis.fetch).mockImplementationOnce(async () =>
      Response.json({ success: true, data: { id: "msg_no_status" } }));
    const response = await sendSealed(hostKeys, installation, targetEnvironment({ DIRECT_APNS: "off" }));
    expect(await response.json()).toEqual({
      version: 1, status: "accepted", deliveryId: "msg_no_status", providerStatus: "accepted", counts: null,
    });
  });

  it("sends an old build's installation (no target) through BuzzKit even with DIRECT_APNS on", async () => {
    const targetEnv = targetEnvironment({ DIRECT_APNS: "on" });
    const response = await sendSealed(hostKeys, installation, targetEnv);
    expect(response.status).toBe(202);
    expect(apnsCalls).toEqual([]);
    expect(buzzKitMessages()).toHaveLength(1);
    expect(relayedEvents().filter((event) => event.name === "push.fallback_buzzkit").map((event) => event.p))
      .toEqual([{ reason: "no_target" }]);
  });

  it("sends directly when the flag, secrets and target agree, and answers like BuzzKit does", async () => {
    const targetEnv = targetEnvironment();
    await addTarget(targetEnv, installation);
    const response = await sendSealed(hostKeys, installation, targetEnv);
    expect(response.status).toBe(202);
    expect(buzzKitCalls).toEqual([]);
    expect(apnsCalls).toHaveLength(1);
    const call = apnsCalls[0]!;
    expect(call.url).toBe(`https://api.push.apple.com/3/device/${TOKEN}`);
    expect(await response.json()).toEqual({
      version: 1, status: "accepted", deliveryId: call.headers.get("apns-id"), providerStatus: "sent",
      counts: { total: 1, sent: 1 },
    });
    expect(call.headers.get("apns-id")).toBe(await apnsIdFor(`${installation.installationId}|alert|${installation.grantId}:${"c".repeat(64)}`));
    expect(call.headers.get("apns-push-type")).toBe("alert");
    expect(call.headers.get("apns-priority")).toBe("10");
    expect(Number(call.headers.get("apns-expiration"))).toBeGreaterThanOrEqual(NOW + 899);
    expect(Number(call.headers.get("apns-expiration"))).toBeLessThanOrEqual(NOW + 905);
    expect(call.headers.get("apns-collapse-id")!.length).toBeLessThanOrEqual(64);

    // The same object BuzzKit would have delivered, key for key.
    const viaBuzzKit = await (async () => {
      const sealed = await sealedBody(installation);
      const message = sealedMessage({
        eventId: sealed.eventId, eventType: "session.completed", grantId: installation.grantId, profile: "default",
        sessionReference: sealed.sessionReference, sealed: sealed.sealed,
        avatar: { mimeType: "application/octet-stream", sha256: sealed.avatar.sha256, data: sealed.avatar.data },
        sound: true, occurredAt: NOW,
      }, { url: "https://x.example/a.bin", mimeType: "application/octet-stream", sha256: sealed.avatar.sha256 });
      return message.body;
    })();
    const payload = call.payload as { aps: Record<string, unknown>; loopdy: Record<string, any>; bk: Record<string, unknown>; bighelp_meta: Record<string, unknown> };
    expect(payload.aps).toEqual({
      alert: { title: "bighelp", body: "New reply" },
      sound: "default",
      category: "LOOPDY_AGENT_UPDATE",
      "mutable-content": 1,
      "thread-id": "a".repeat(43),
      "interruption-level": "active",
    });
    expect(payload.loopdy).toMatchObject({
      version: 2, eventId: `${installation.grantId}:${"c".repeat(64)}`, eventType: "session.completed",
      grantId: installation.grantId, agent: { id: "default" }, sessionReference: "a".repeat(43),
    });
    expect(Object.keys(payload.loopdy).sort()).toEqual(
      Object.keys((viaBuzzKit.data as { loopdy: object }).loopdy).sort(),
    );
    expect(payload.loopdy.avatar.url).toMatch(/\.bin\?expires=/);
    expect(payload.bk).toEqual({
      deepLink: `loopdy:///dashboard?eventId=${encodeURIComponent(`${installation.grantId}:${"c".repeat(64)}`)}`,
      action: { name: "open_loopdy_managed_event", data: { eventId: `${installation.grantId}:${"c".repeat(64)}` } },
      category: "LOOPDY_AGENT_UPDATE",
      actions: [{ id: "open", title: "Open", foreground: true }],
    });
    expect(payload.bk).not.toHaveProperty("messageId");
    expect(payload.bighelp_meta).toEqual({ v: 1, path: "direct", sentAt: expect.any(Number), occurredAt: NOW * 1_000 });
    expect(Object.keys(payload).sort()).toEqual(["aps", "bighelp_meta", "bk", "loopdy"]);
  });

  it("uses the token's own environment: sandbox goes to the sandbox host", async () => {
    const targetEnv = targetEnvironment();
    await addTarget(targetEnv, installation, { environment: "sandbox" });
    await sendSealed(hostKeys, installation, targetEnv);
    expect(new URL(apnsCalls[0]!.url).host).toBe("api.sandbox.push.apple.com");
  });

  it("answers duplicate for a repeated event and sends it once", async () => {
    const targetEnv = targetEnvironment();
    await addTarget(targetEnv, installation);
    const first = await (await sendSealed(hostKeys, installation, targetEnv)).json() as Record<string, unknown>;
    const second = await sendSealed(hostKeys, installation, targetEnv);
    expect(second.status).toBe(202);
    expect(await second.json()).toEqual({
      version: 1, status: "duplicate", deliveryId: first.deliveryId, providerStatus: "sent", counts: { total: 1, sent: 1 },
    });
    expect(apnsCalls).toHaveLength(1);
  });

  it("is time sensitive for questions and approvals", async () => {
    const approval = await insertInstallation(installationKeys, hostKeys, ["approval.required"]);
    const targetEnv = targetEnvironment();
    await addTarget(targetEnv, approval);
    const event = { ...(await sealedBody(approval)), eventType: "approval.required" };
    const response = await handleLoopdyLinkRequest(
      await hostRequest(hostKeys, approval.grantId, "/events", event), targetEnv,
    );
    expect(response.status).toBe(202);
    const payload = apnsCalls[0]!.payload as { aps: Record<string, unknown> };
    expect(payload.aps["interruption-level"]).toBe("time-sensitive");
    expect(payload.aps.category).toBe("LOOPDY_REVIEW");
    expect(Number(apnsCalls[0]!.headers.get("apns-expiration"))).toBeLessThanOrEqual(NOW + 65);
  });

  it("omits sound when the event asks for none", async () => {
    const targetEnv = targetEnvironment();
    await addTarget(targetEnv, installation);
    const event = { ...(await sealedBody(installation)), sound: false };
    await handleLoopdyLinkRequest(await hostRequest(hostKeys, installation.grantId, "/events", event), targetEnv);
    expect((apnsCalls[0]!.payload as { aps: object }).aps).not.toHaveProperty("sound");
  });

  it("keeps the payload inside the byte budget at the largest sealed envelope", async () => {
    const event = await sealedBody(installation);
    const sealed = { ...event.sealed, ciphertext: "A" };
    const room = 2_300 - new TextEncoder().encode(JSON.stringify(sealed)).length;
    sealed.ciphertext = "A".repeat(Math.max(2, room));
    expect(new TextEncoder().encode(JSON.stringify(sealed)).length).toBeLessThanOrEqual(2_300);
    const targetEnv = targetEnvironment();
    await addTarget(targetEnv, installation);
    const response = await handleLoopdyLinkRequest(
      await hostRequest(hostKeys, installation.grantId, "/events", { ...event, sealed }), targetEnv,
    );
    expect(response.status).toBe(202);
    expect(new TextEncoder().encode(JSON.stringify(apnsCalls[0]!.payload)).length).toBeLessThanOrEqual(4_000);
    // And one that can't fit is not built.
    const huge = await messageSpec("alert", "session.completed", {
      body: { title: "t", body: "b", data: { loopdy: { pad: "x".repeat(5_000) } }, ttlSeconds: 900 },
      idempotencyKey: "k",
    }, Date.now());
    expect(huge).toBeNull();
  });

  describe("shadow mode", () => {
    it("sends through BuzzKit and reports that an installation with a target would go direct", async () => {
      const targetEnv = targetEnvironment({ DIRECT_APNS: "shadow" });
      await addTarget(targetEnv, installation);
      const response = await sendSealed(hostKeys, installation, targetEnv);
      expect(response.status).toBe(202);
      expect(apnsCalls).toEqual([]);
      expect(buzzKitMessages()).toHaveLength(1);
      expect(relayedEvents().filter((event) => event.name === "push.shadow").map((event) => event.p))
        .toEqual([{ eventType: "session.completed", wouldUseDirect: true }]);
    });

    it("says nothing about an installation with no target", async () => {
      await sendSealed(hostKeys, installation, targetEnvironment({ DIRECT_APNS: "shadow" }));
      expect(relayedEvents().filter((event) => event.name === "push.shadow")).toEqual([]);
    });

    it("goes direct for a canary installation only", async () => {
      const other = await insertInstallation(await keys(), hostKeys);
      const targetEnv = targetEnvironment({
        DIRECT_APNS: "shadow",
        DIRECT_APNS_CANARY: `, ${installation.installationId.toUpperCase()} ,`,
      });
      await addTarget(targetEnv, installation);
      await addTarget(targetEnv, other);
      expect((await sendSealed(hostKeys, installation, targetEnv)).status).toBe(202);
      expect(apnsCalls).toHaveLength(1);
      expect(buzzKitMessages()).toHaveLength(0);
      const response = await handleLoopdyLinkRequest(
        await hostRequest(hostKeys, other.grantId, "/events", await sealedBody(other, "d")), targetEnv,
      );
      expect(response.status).toBe(202);
      expect(apnsCalls).toHaveLength(1);
      expect(buzzKitMessages()).toHaveLength(1);
    });
  });

  it.each([
    ["APNS_KEY_P8"], ["APNS_KEY_ID"], ["APNS_TEAM_ID"], ["PUSH_TOKEN_KEY"],
  ])("uses BuzzKit while %s is missing", async (secret) => {
    const targetEnv = targetEnvironment();
    await addTarget(targetEnv, installation);
    const response = await sendSealed(hostKeys, installation, { ...targetEnv, [secret]: undefined } as LinkEnv);
    expect(response.status).toBe(202);
    expect(apnsCalls).toEqual([]);
    expect(buzzKitMessages()).toHaveLength(1);
    expect(relayedEvents().filter((event) => event.name === "push.fallback_buzzkit").map((event) => event.p))
      .toEqual([{ reason: "apns_unconfigured" }]);
  });

  it("keeps working before migration 0010 is applied: BuzzKit sends, revocation and the routes answer", async () => {
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare("DROP TABLE push_sends"),
      env.ACCOUNTS.prepare("DROP TABLE push_targets"),
    ]);
    try {
      const targetEnv = targetEnvironment({ DIRECT_APNS: "on" });
      const sent = await sendSealed(hostKeys, installation, targetEnv);
      expect(sent.status).toBe(202);
      expect(apnsCalls).toEqual([]);
      expect(buzzKitMessages()).toHaveLength(1);
      const shadow = await sendSealed(hostKeys, installation, targetEnvironment({ DIRECT_APNS: "shadow" }), "d");
      expect(shadow.status).toBe(202);

      const route = await installationRequest(
        installationKeys, installation.installationId, "PUT", "/v1/notifications/push-target",
        { version: 1, token: TOKEN, environment: "production", appVersion: "2.7.0(160)" },
      ).then((request) => handleLoopdyLinkRequest(request, targetEnv));
      expect(route.status).toBe(503);
      expect(await route.json()).toMatchObject({ error: { code: "notification_push_target_unavailable" } });

      const revoked = await installationRequest(
        installationKeys, installation.installationId, "DELETE", "/v1/notifications/installations/current", null,
      ).then((request) => handleLoopdyLinkRequest(request, targetEnv));
      expect(revoked.status).toBe(200);
    } finally {
      for (const statement of pushTargetsMigrationSql.split(";").map((value: string) => value.trim()).filter(Boolean)) {
        await env.ACCOUNTS.prepare(statement).run();
      }
    }
  });

  it("sends through BuzzKit when the target lookup or the send record fails", async () => {
    const withBrokenTable = (table: string) => new Proxy(env.ACCOUNTS, {
      get(target, property) {
        if (property === "prepare") {
          return (query: string) => {
            if (query.includes(table)) throw new Error("database unavailable");
            return target.prepare(query);
          };
        }
        const value = Reflect.get(target, property, target);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
    for (const [index, table] of ["FROM push_targets", "INTO push_sends"].entries()) {
      buzzKitCalls = [];
      const targetEnv = targetEnvironment();
      await addTarget(targetEnv, installation);
      const broken = targetEnvironment({ ACCOUNTS: withBrokenTable(table) });
      const response = await sendSealed(hostKeys, installation, broken, String(index + 1));
      expect(response.status).toBe(202);
      expect(buzzKitMessages()).toHaveLength(1);
      expect(apnsCalls).toEqual([]);
    }
  });

  it("sends through BuzzKit when the APNs key can't sign", async () => {
    const targetEnv = targetEnvironment({
      APNS_KEY_P8: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----",
    });
    await addTarget(targetEnv, installation);
    const response = await sendSealed(hostKeys, installation, targetEnv);
    expect(response.status).toBe(202);
    expect(apnsCalls).toEqual([]);
    expect(buzzKitMessages()).toHaveLength(1);
    expect(relayedEvents().find((event) => event.name === "push.fallback_buzzkit")!.p)
      .toEqual({ reason: "apns_provider_key_invalid" });
  });

  it("reads the flag loosely and defaults to off", async () => {
    const { deliveryMode } = await import("../src/push-delivery.js");
    expect([" ON ", "shadow", "Shadow", "off", "", "yes", undefined].map((value) => deliveryMode({ DIRECT_APNS: value })))
      .toEqual(["on", "shadow", "shadow", "off", "off", "off", "off"]);
  });

  describe("when APNs refuses", () => {
    it.each([
      [410, "Unregistered"],
      [400, "BadDeviceToken"],
      [400, "DeviceTokenNotForTopic"],
    ])("marks the token invalid on %s %s and sends through BuzzKit", async (status, reason) => {
      apnsAnswers.push({ status, reason });
      const targetEnv = targetEnvironment();
      await addTarget(targetEnv, installation);
      const response = await sendSealed(hostKeys, installation, targetEnv);
      expect(response.status).toBe(202);
      expect(await response.json()).toMatchObject({ status: "accepted", deliveryId: "msg_buzzkit_1" });
      expect(buzzKitMessages()).toHaveLength(1);
      expect((await env.ACCOUNTS.prepare("SELECT invalid_at FROM push_targets").first<{ invalid_at: number }>())!.invalid_at)
        .toBeGreaterThan(0);
      // The failed attempt left no row, so the host's retry isn't called a duplicate.
      expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS n FROM push_sends").first()).toEqual({ n: 0 });
      const names = relayedEvents().map((event) => event.name);
      expect(names).toEqual(expect.arrayContaining(["push.token_invalid", "push.fallback_buzzkit", "push.sent"]));
      expect(relayedEvents().find((event) => event.name === "push.token_invalid")!.p).toEqual({
        kind: "alert", reason: reason === "Unregistered" ? "unregistered" : reason === "BadDeviceToken" ? "bad_device_token" : "device_token_not_for_topic",
      });
      // From now on this installation has no usable target: BuzzKit, with no APNs call.
      const again = await sendSealed(hostKeys, installation, targetEnv, "d");
      expect(again.status).toBe(202);
      expect(apnsCalls).toHaveLength(1);
      expect(buzzKitMessages()).toHaveLength(2);
    });

    it("a new token from the phone makes the installation direct again", async () => {
      apnsAnswers.push({ status: 410, reason: "Unregistered" });
      const targetEnv = targetEnvironment();
      await addTarget(targetEnv, installation);
      await sendSealed(hostKeys, installation, targetEnv);
      await addTarget(targetEnv, installation, { token: OTHER_TOKEN });
      await sendSealed(hostKeys, installation, targetEnv, "d");
      expect(apnsCalls).toHaveLength(2);
      expect(apnsCalls[1]!.url).toContain(OTHER_TOKEN);
    });

    it("sends through BuzzKit on another rejection, and a host retry works", async () => {
      apnsAnswers.push({ status: 400, reason: "BadTopic" });
      const targetEnv = targetEnvironment();
      await addTarget(targetEnv, installation);
      const response = await sendSealed(hostKeys, installation, targetEnv);
      expect(await response.json()).toMatchObject({ status: "accepted", deliveryId: "msg_buzzkit_1" });
      expect(relayedEvents().filter((event) => event.name === "push.fallback_buzzkit").map((event) => event.p))
        .toEqual([{ reason: "apns_bad_topic" }]);
      // The token was not blamed.
      expect((await env.ACCOUNTS.prepare("SELECT invalid_at FROM push_targets").first<{ invalid_at: number | null }>())!.invalid_at).toBeNull();
      const retried = await sendSealed(hostKeys, installation, targetEnv);
      expect(await retried.json()).toMatchObject({ status: "accepted", providerStatus: "sent" });
      expect(apnsCalls).toHaveLength(2);
    });

    it("sends through BuzzKit after a provider token is refused twice", async () => {
      apnsAnswers.push({ status: 403, reason: "InvalidProviderToken" }, { status: 403, reason: "InvalidProviderToken" });
      const targetEnv = targetEnvironment();
      await addTarget(targetEnv, installation);
      const response = await sendSealed(hostKeys, installation, targetEnv);
      expect(response.status).toBe(202);
      expect(buzzKitMessages()).toHaveLength(1);
      expect(relayedEvents().filter((event) => event.name === "push.fallback_buzzkit").map((event) => event.p))
        .toEqual([{ reason: "provider_token" }]);
      expect((await env.ACCOUNTS.prepare("SELECT invalid_at FROM push_targets").first<{ invalid_at: number | null }>())!.invalid_at).toBeNull();
    });

    it.each([[503, "ServiceUnavailable"], [429, "TooManyRequests"], [500, "InternalServerError"], ["timeout", ""]] as const)(
      "queues a retry on %s and answers queued",
      async (status, reason) => {
        apnsAnswers.push(status === "timeout" ? "timeout" : { status, reason });
        const targetEnv = targetEnvironment();
        await addTarget(targetEnv, installation);
        const response = await sendSealed(hostKeys, installation, targetEnv);
        expect(response.status).toBe(202);
        const answer = await response.json() as Record<string, unknown>;
        expect(answer).toEqual({
          version: 1, status: "accepted", deliveryId: expect.any(String), providerStatus: "queued", counts: null,
        });
        expect(buzzKitCalls).toEqual([]);
        expect(retryQueue.send).toHaveBeenCalledTimes(1);
        const [message, options] = retryQueue.send.mock.calls[0]!;
        expect(options).toEqual({ delaySeconds: 5 });
        expect(parseRetryMessage(message)).not.toBeNull();
        expect(message).toMatchObject({
          v: 1, kind: "alert", grantId: installation.grantId, eventType: "session.completed",
          dedupeKey: `${installation.installationId}|alert|${installation.grantId}:${"c".repeat(64)}`,
        });
        // No token, and nothing it was sealed into.
        const ciphertext = (await env.ACCOUNTS.prepare("SELECT token_ciphertext FROM push_targets").first<{ token_ciphertext: string }>())!.token_ciphertext;
        expect(JSON.stringify(message)).not.toContain(TOKEN);
        expect(JSON.stringify(message)).not.toContain(ciphertext);
        expect(relayedEvents().find((event) => event.name === "push.retry")!.p).toMatchObject({ attempt: 1 });
        // The host's retry is a duplicate while the message waits.
        const repeat = await sendSealed(hostKeys, installation, targetEnv);
        expect(await repeat.json()).toMatchObject({ status: "duplicate", providerStatus: "queued" });
        expect(apnsCalls).toHaveLength(1);
      },
    );

    it("falls back to BuzzKit when there is no queue", async () => {
      apnsAnswers.push({ status: 503, reason: "ServiceUnavailable" });
      const targetEnv = targetEnvironment({ APNS_RETRY: undefined });
      await addTarget(targetEnv, installation);
      const response = await sendSealed(hostKeys, installation, targetEnv);
      expect(await response.json()).toMatchObject({ status: "accepted", deliveryId: "msg_buzzkit_1" });
      expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS n FROM push_sends").first()).toEqual({ n: 0 });
    });

    it("falls back to BuzzKit when the queue refuses the message", async () => {
      apnsAnswers.push({ status: 503, reason: "ServiceUnavailable" });
      retryQueue.send.mockRejectedValueOnce(new Error("queue down"));
      const targetEnv = targetEnvironment();
      await addTarget(targetEnv, installation);
      const response = await sendSealed(hostKeys, installation, targetEnv);
      expect(await response.json()).toMatchObject({ status: "accepted", deliveryId: "msg_buzzkit_1" });
      expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS n FROM push_sends").first()).toEqual({ n: 0 });
    });

    it("leaves no row when the fallback fails too, so the host can retry", async () => {
      apnsAnswers.push({ status: 410, reason: "Unregistered" });
      const targetEnv = targetEnvironment({ BUZZKIT_API_KEY: undefined });
      await addTarget(targetEnv, installation);
      const response = await sendSealed(hostKeys, installation, targetEnv);
      expect(response.status).toBe(503);
      expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS n FROM push_sends").first()).toEqual({ n: 0 });
    });
  });

  describe("egress authority", () => {
    it("is the last thing awaited before the APNs request", async () => {
      const targetEnv = targetEnvironment();
      await addTarget(targetEnv, installation);
      await sendSealed(hostKeys, installation, targetEnv);
      expect(log.at(-1)).toBe("apns");
      expect(log.at(-2)).toBe("authorize");
    });

    it("is asked again before the repeat after a refused provider token", async () => {
      apnsAnswers.push({ status: 403, reason: "ExpiredProviderToken" });
      const targetEnv = targetEnvironment();
      await addTarget(targetEnv, installation);
      await sendSealed(hostKeys, installation, targetEnv);
      expect(log.slice(-4)).toEqual(["authorize", "apns", "authorize", "apns"]);
    });

    it("stops a send when the installation is revoked before the request", async () => {
      const targetEnv = targetEnvironment({}, {
        authorizeNotificationEgress: async () => {
          log.push("authorize");
          throw new LoopdyLinkError("notification_credentials_revoked", "revoked");
        },
      });
      await addTarget(targetEnv, installation);
      const response = await sendSealed(hostKeys, installation, targetEnv);
      expect(response.status).toBe(410);
      expect(apnsCalls).toEqual([]);
      expect(buzzKitCalls).toEqual([]);
      expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS n FROM push_sends").first()).toEqual({ n: 0 });
    });

    it("sends nothing to an installation revoked after its target was stored", async () => {
      const targetEnv = targetEnvironment();
      await addTarget(targetEnv, installation);
      await env.ACCOUNTS.prepare(`UPDATE notification_installations
        SET state='revoked',authorization_epoch=authorization_epoch+1 WHERE installation_id=?`)
        .bind(installation.installationId).run();
      const response = await sendSealed(hostKeys, installation, targetEnv);
      expect(response.status).toBeGreaterThanOrEqual(400);
      expect(apnsCalls).toEqual([]);
    });
  });

  describe("sign-in wake", () => {
    const wake = (targetEnv: LinkEnv) => hostRequest(hostKeys, installation.grantId, "/wake", {
      version: 1, reason: "renew-sign-in",
    }).then((request) => handleLoopdyLinkRequest(request, targetEnv));

    it("goes out as a quiet background push, once per window", async () => {
      const targetEnv = targetEnvironment();
      await addTarget(targetEnv, installation);
      const first = await wake(targetEnv);
      expect(first.status).toBe(202);
      expect(await first.json()).toMatchObject({ status: "accepted", providerStatus: "sent" });
      const call = apnsCalls[0]!;
      expect(call.payload).toEqual({
        aps: { "content-available": 1 },
        bighelp_wake: { version: 1, type: "renew-sign-in", grantId: installation.grantId },
        bighelp_meta: { v: 1, path: "direct", sentAt: expect.any(Number) },
      });
      expect(call.headers.get("apns-push-type")).toBe("background");
      expect(call.headers.get("apns-priority")).toBe("5");
      expect(call.headers.get("apns-collapse-id")).toBe("bighelp-renew-sign-in");
      expect(Number(call.headers.get("apns-expiration"))).toBeGreaterThanOrEqual(NOW + 21_590);
      expect(await (await wake(targetEnv)).json()).toMatchObject({ status: "duplicate" });
      expect(apnsCalls).toHaveLength(1);
    });

    it("reaches BuzzKit unchanged when the flag is off, apart from bighelp_meta", async () => {
      await wake(targetEnvironment({ DIRECT_APNS: "off" }));
      expect(buzzKitCalls).toHaveLength(1);
      expect(buzzKitCalls[0]!.body).toMatchObject({
        data: {
          bighelp_wake: { version: 1, type: "renew-sign-in", grantId: installation.grantId },
          bighelp_meta: { v: 1, path: "buzzkit" },
        },
        collapseId: "bighelp-renew-sign-in", priority: "normal", ttlSeconds: 21_600, policy: "ignore",
        apns: { payload: { aps: { "content-available": 1 } } },
      });
    });
  });

  describe("test notification", () => {
    const test = (targetEnv: LinkEnv, requestId = crypto.randomUUID()) =>
      installationRequest(
        installationKeys, installation.installationId, "POST", "/v1/notifications/host-grants/buzzkit/test",
        { version: 1, requestId },
      ).then((request) => handleLoopdyLinkRequest(request, targetEnv));

    it("goes direct with BuzzKit's title, body and sound", async () => {
      const targetEnv = targetEnvironment();
      await addTarget(targetEnv, installation);
      const response = await test(targetEnv);
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({
        version: 1, test: { id: apnsCalls[0]!.headers.get("apns-id"), state: "accepted", providerStatus: "sent" },
      });
      expect(apnsCalls[0]!.payload).toMatchObject({
        aps: {
          alert: { title: "Loopdy test notification", body: "This is your requested BuzzKit notification test." },
          sound: "default", "mutable-content": 1,
        },
        loopdy_test: { version: 1 },
        bighelp_meta: { v: 1, path: "direct" },
      });
      expect(Number(apnsCalls[0]!.headers.get("apns-expiration"))).toBeLessThanOrEqual(NOW + 305);
    });

    it("keeps its BuzzKit read-back when it goes that way", async () => {
      vi.mocked(globalThis.fetch).mockImplementation(async (input, init) => {
        const url = new URL(String(input));
        buzzKitCalls.push({ method: init?.method ?? "GET", path: url.pathname, body: null });
        if (init?.method === "POST") return Response.json({ success: true, data: { id: "msg_test_1" } });
        return Response.json({ success: true, data: { id: "msg_test_1", status: "completed", counts: { sent: 1, delivered: 0 } } });
      });
      const response = await test(targetEnvironment({ DIRECT_APNS: "off" }));
      expect(await response.json()).toEqual({
        version: 1, test: { id: "msg_test_1", state: "accepted", providerStatus: "completed" },
      });
      expect(buzzKitCalls.map((call) => call.method)).toEqual(["POST", "GET"]);
    });

    it("does not queue: a transient failure falls back at once", async () => {
      vi.mocked(globalThis.fetch).mockImplementation(async (input, init) => {
        const url = new URL(String(input));
        if (url.hostname.endsWith("push.apple.com")) return new Response("{}", { status: 503 });
        if (init?.method === "POST") return Response.json({ success: true, data: { id: "msg_test_2" } });
        return Response.json({ success: true, data: { id: "msg_test_2", status: "queued", counts: null } });
      });
      const targetEnv = targetEnvironment();
      await addTarget(targetEnv, installation);
      const response = await test(targetEnv);
      expect(await response.json()).toMatchObject({ test: { id: "msg_test_2" } });
      expect(retryQueue.send).not.toHaveBeenCalled();
    });
  });
});

// MARK: Live Activity

describe("Live Activity updates", () => {
  const activityId = "activity-direct-1";
  const sessionReference = "a".repeat(43);
  let installationKeys: KeyPair;
  let hostKeys: KeyPair;
  let installation: Installation;
  let completed: number;
  const state = () => ({
    notificationActivity: async () => ({
      activityId, grantId: installation.grantId, sessionReference, revision: 1, leaseExpires: NOW + 900, status: "active",
    }),
    beginNotificationActivityUpdate: async () => ({ status: "send" }),
    completeNotificationActivityUpdate: async () => { completed += 1; },
  });
  const update = (phase: string, updateId = "u".repeat(43)) => ({
    version: 2, updateId, sessionReference, phase, currentAction: "Working", progress: 40, completedSteps: 2,
    activeSubagentCount: 0, latestTool: null, timestamp: NOW, expires: NOW + 900,
  });
  const send = (targetEnv: LinkEnv, phase: string, updateId?: string) =>
    hostRequest(hostKeys, installation.grantId, `/live-activities/${activityId}/updates`, update(phase, updateId))
      .then((request) => handleLoopdyLinkRequest(request, targetEnv));

  beforeEach(async () => {
    completed = 0;
    installationKeys = await keys();
    hostKeys = await keys();
    installation = await insertInstallation(installationKeys, hostKeys);
  });

  it("goes direct to the activity's own token, with Unix-second dates and the same content state", async () => {
    const targetEnv = targetEnvironment({}, state());
    await addTarget(targetEnv, installation, { kind: "liveactivity", activityId, token: OTHER_TOKEN, environment: "sandbox" });
    const response = await send(targetEnv, "using_tool");
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({
      version: 1, status: "accepted", deliveryId: apnsCalls[0]!.headers.get("apns-id"),
    });
    const call = apnsCalls[0]!;
    expect(call.url).toBe(`https://api.sandbox.push.apple.com/3/device/${OTHER_TOKEN}`);
    expect(call.headers.get("apns-topic")).toBe("app.loopdy.mobile.push-type.liveactivity");
    expect(call.headers.get("apns-push-type")).toBe("liveactivity");
    expect(call.headers.get("apns-priority")).toBe("10");
    expect(call.headers.has("apns-collapse-id")).toBe(false);
    expect(call.payload).toEqual({
      aps: {
        timestamp: NOW, event: "update", "stale-date": NOW + 900,
        "content-state": {
          phase: "using_tool", currentAction: "Working", progress: 40, completedSteps: 2,
          activeSubagentCount: 0, latestTool: null, timestamp: NOW,
        },
      },
    });
    expect(call.payload).not.toHaveProperty("bighelp_meta");
    expect(completed).toBe(1);
    expect(buzzKitCalls).toEqual([]);
  });

  it("sends a dismissal date only when the card ends, 30 seconds on", async () => {
    const targetEnv = targetEnvironment({}, state());
    await addTarget(targetEnv, installation, { kind: "liveactivity", activityId });
    await send(targetEnv, "completed");
    expect((apnsCalls[0]!.payload as { aps: Record<string, unknown> }).aps).toMatchObject({
      event: "end", "dismissal-date": NOW + 30,
    });
  });

  it("repeats the BuzzKit shape when there is no activity target", async () => {
    const targetEnv = targetEnvironment({}, state());
    await addTarget(targetEnv, installation);
    const response = await send(targetEnv, "using_tool");
    expect(response.status).toBe(202);
    expect(apnsCalls).toEqual([]);
    const call = buzzKitCalls.find((candidate) => candidate.path === "/v1/live-activities/send")!;
    expect(call.body).toMatchObject({
      event: "update", activityId, timestamp: NOW,
      staleDate: new Date((NOW + 900) * 1_000).toISOString(),
    });
  });

  it("falls back when the activity token is gone", async () => {
    apnsAnswers.push({ status: 410, reason: "Unregistered" });
    const targetEnv = targetEnvironment({}, state());
    await addTarget(targetEnv, installation, { kind: "liveactivity", activityId });
    const response = await send(targetEnv, "using_tool");
    expect(response.status).toBe(202);
    expect(buzzKitCalls.some((call) => call.path === "/v1/live-activities/send")).toBe(true);
    expect(relayedEvents().find((event) => event.name === "push.token_invalid")!.p).toMatchObject({ kind: "liveactivity" });
  });

  it("checks the activity again right before the request", async () => {
    const targetEnv = targetEnvironment({}, {
      ...state(),
      notificationActivity: async () => ({
        activityId, grantId: installation.grantId, sessionReference, revision: 1, leaseExpires: NOW + 900,
        status: log.includes("revoke-now") ? "revoked" : "active",
      }),
      beginNotificationActivityUpdate: async () => { log.push("revoke-now"); return { status: "send" }; },
    });
    await addTarget(targetEnv, installation, { kind: "liveactivity", activityId });
    const response = await send(targetEnv, "using_tool");
    expect(response.status).toBe(410);
    expect(apnsCalls).toEqual([]);
    expect(completed).toBe(0);
  });

  it("builds the spec from numbers", () => {
    const spec = liveActivitySpec({
      event: "end", activityId, contentState: { a: 1 }, timestamp: 10, staleDate: 20, dismissalDate: 15,
    }, 10)!;
    expect(spec.payload).toEqual({
      aps: { timestamp: 10, event: "end", "content-state": { a: 1 }, "stale-date": 20, "dismissal-date": 15 },
    });
    expect(spec.ttlSeconds).toBe(60);
  });
});

// MARK: Retry queue

describe("retry queue", () => {
  let installationKeys: KeyPair;
  let hostKeys: KeyPair;
  let installation: Installation;
  let targetEnv: LinkEnv;

  beforeEach(async () => {
    installationKeys = await keys();
    hostKeys = await keys();
    installation = await insertInstallation(installationKeys, hostKeys);
    targetEnv = targetEnvironment();
    await addTarget(targetEnv, installation);
  });

  /** Sends an event while APNs is down, to get a real queue message. */
  async function queuedMessage() {
    apnsAnswers.push({ status: 503, reason: "ServiceUnavailable" });
    expect((await sendSealed(hostKeys, installation, targetEnv)).status).toBe(202);
    apnsCalls = []; log = []; telemetry.mockClear();
    return retryQueue.send.mock.calls[0]![0] as unknown;
  }

  function fakeMessage(body: unknown, attempts = 1) {
    return { id: "m", timestamp: new Date(), body, attempts, ack: vi.fn(), retry: vi.fn() };
  }

  /** The Worker as the queue consumer sees it: same keys, optionally different settings. */
  const consumerEnv = (overrides: Record<string, unknown> = {}, state: Record<string, unknown> = {}) =>
    targetEnvironment({ PUSH_TOKEN_KEY: targetEnv.PUSH_TOKEN_KEY, ...overrides }, state);

  const run = async (messages: ReturnType<typeof fakeMessage>[], runEnv = targetEnv) => {
    const waits: Promise<unknown>[] = [];
    await handleApnsRetryBatch(
      { queue: "loopdy-link-apns-retry", messages, ackAll: vi.fn(), retryAll: vi.fn() } as never,
      runEnv, { waitUntil: (promise: Promise<unknown>) => waits.push(promise) } as never,
    );
    await Promise.all(waits);
  };

  it("sends the message and marks it sent, with the same APNs ID", async () => {
    const body = await queuedMessage();
    const message = fakeMessage(body);
    await run([message]);
    expect(message.ack).toHaveBeenCalled();
    expect(apnsCalls).toHaveLength(1);
    expect(apnsCalls[0]!.headers.get("apns-id")).toBe(await apnsIdFor((body as { dedupeKey: string }).dedupeKey));
    expect((apnsCalls[0]!.payload as { bighelp_meta: unknown }).bighelp_meta).toMatchObject({ path: "direct" });
    expect(await env.ACCOUNTS.prepare("SELECT state FROM push_sends").first()).toEqual({ state: "sent" });
    expect(log.slice(-2)).toEqual(["authorize", "apns"]);
    expect(relayedEvents().find((event) => event.name === "push.sent")!.p).toMatchObject({
      path: "direct", result: "sent", status: 200, attempt: 2,
    });
    // Not sent twice if the queue delivers it again.
    const again = fakeMessage(body, 2);
    await run([again]);
    expect(again.ack).toHaveBeenCalled();
    expect(apnsCalls).toHaveLength(1);
  });

  it("tries again later with a longer wait, and reports the retry", async () => {
    const body = await queuedMessage();
    apnsAnswers.push({ status: 503, reason: "ServiceUnavailable" });
    const message = fakeMessage(body, 2);
    await run([message]);
    expect(message.ack).not.toHaveBeenCalled();
    expect(message.retry).toHaveBeenCalledWith({ delaySeconds: 45 });
    expect(relayedEvents().find((event) => event.name === "push.retry")!.p).toEqual({ attempt: 3, reason: "service_unavailable" });
    expect(buzzKitCalls).toEqual([]);
  });

  it("falls back to BuzzKit on the last attempt", async () => {
    const body = await queuedMessage();
    apnsAnswers.push({ status: 503, reason: "ServiceUnavailable" });
    const message = fakeMessage(body, 6);
    await run([message]);
    expect(message.ack).toHaveBeenCalled();
    expect(message.retry).not.toHaveBeenCalled();
    const posts = buzzKitCalls.filter((call) => call.method === "POST");
    expect(posts).toHaveLength(1);
    expect(posts[0]!.body).toMatchObject({ data: { bighelp_meta: { path: "buzzkit" }, loopdy: { eventType: "session.completed" } } });
    expect(relayedEvents().find((event) => event.name === "push.fallback_buzzkit")!.p).toEqual({ reason: "retries_exhausted" });
    expect(log.slice(-2)).toEqual(["authorize", "buzzkit"]);
    expect(await env.ACCOUNTS.prepare("SELECT state FROM push_sends").first()).toEqual({ state: "sent" });
  });

  it("goes to the dead-letter queue when BuzzKit can't take it either", async () => {
    const body = await queuedMessage();
    apnsAnswers.push({ status: 503, reason: "ServiceUnavailable" });
    const message = fakeMessage(body, 6);
    await run([message], consumerEnv({ BUZZKIT_API_KEY: undefined }));
    expect(message.ack).not.toHaveBeenCalled();
    expect(message.retry).toHaveBeenCalledWith();
    expect(relayedEvents().find((event) => event.name === "push.dlq")!.p).toEqual({ reason: "buzzkit_server_key_unconfigured" });
    // The host can send it again.
    expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS n FROM push_sends").first()).toEqual({ n: 0 });
  });

  it("falls back at once for a token APNs refuses", async () => {
    const body = await queuedMessage();
    apnsAnswers.push({ status: 410, reason: "Unregistered" });
    const message = fakeMessage(body, 2);
    await run([message]);
    expect(message.ack).toHaveBeenCalled();
    expect(buzzKitCalls.filter((call) => call.method === "POST")).toHaveLength(1);
    expect((await env.ACCOUNTS.prepare("SELECT invalid_at FROM push_targets").first<{ invalid_at: number }>())!.invalid_at).toBeGreaterThan(0);
  });

  it("falls back when the target is gone", async () => {
    const body = await queuedMessage();
    await env.ACCOUNTS.prepare("DELETE FROM push_targets").run();
    const message = fakeMessage(body, 2);
    await run([message]);
    expect(apnsCalls).toEqual([]);
    expect(message.ack).toHaveBeenCalled();
    expect(relayedEvents().find((event) => event.name === "push.fallback_buzzkit")!.p).toEqual({ reason: "no_target" });
  });

  it("drops the message, sending nothing, when the installation was revoked", async () => {
    const body = await queuedMessage();
    await env.ACCOUNTS.prepare(`UPDATE notification_installations
      SET state='revoked',authorization_epoch=authorization_epoch+1 WHERE installation_id=?`)
      .bind(installation.installationId).run();
    const message = fakeMessage(body, 2);
    await run([message]);
    expect(message.ack).toHaveBeenCalled();
    expect(apnsCalls).toEqual([]);
    expect(buzzKitCalls).toEqual([]);
  });

  it("drops the message when egress authority is withdrawn right before the request", async () => {
    const body = await queuedMessage();
    const message = fakeMessage(body, 2);
    await run([message], consumerEnv({}, {
      authorizeNotificationEgress: async () => {
        throw new LoopdyLinkError("notification_credentials_revoked", "revoked");
      },
    }));
    expect(message.ack).toHaveBeenCalled();
    expect(apnsCalls).toEqual([]);
    expect(buzzKitCalls).toEqual([]);
  });

  it("drops a message that has outlived its push", async () => {
    const body = await queuedMessage() as { enqueuedAt: number };
    const message = fakeMessage({ ...body, enqueuedAt: (NOW - 7_200) * 1_000 }, 3);
    await run([message]);
    expect(message.ack).toHaveBeenCalled();
    expect(apnsCalls).toEqual([]);
  });

  it("drops messages it didn't write", async () => {
    const invalid = [fakeMessage({ v: 2 }), fakeMessage(null), fakeMessage("text"), fakeMessage({ v: 1, kind: "alert" })];
    await run(invalid);
    for (const message of invalid) expect(message.ack).toHaveBeenCalled();
    expect(apnsCalls).toEqual([]);
  });

  it("retries after something unexpected, and gives up on the last attempt", async () => {
    const body = await queuedMessage();
    const failing = { ...targetEnv, ACCOUNTS: undefined } as unknown as LinkEnv;
    const middle = fakeMessage(body, 2);
    const last = fakeMessage(body, 6);
    await run([middle, last], failing);
    expect(middle.retry).toHaveBeenCalledWith({ delaySeconds: 45 });
    expect(last.retry).toHaveBeenCalled();
    expect(relayedEvents().find((event) => event.name === "push.dlq")!.p).toEqual({ reason: "unexpected" });
  });

  it("sends a queued Live Activity update", async () => {
    const activityId = "activity-queued-1";
    const sessionReference = "a".repeat(43);
    const state = {
      notificationActivity: async () => ({
        activityId, grantId: installation.grantId, sessionReference, revision: 1, leaseExpires: NOW + 900, status: "active",
      }),
      beginNotificationActivityUpdate: async () => ({ status: "send" }),
      completeNotificationActivityUpdate: async () => {},
    };
    const liveEnv = targetEnvironment({ PUSH_TOKEN_KEY: targetEnv.PUSH_TOKEN_KEY }, state);
    await addTarget(liveEnv, installation, { kind: "liveactivity", activityId, token: OTHER_TOKEN });
    apnsAnswers.push({ status: 503, reason: "ServiceUnavailable" });
    retryQueue.send.mockClear();
    const response = await hostRequest(hostKeys, installation.grantId, `/live-activities/${activityId}/updates`, {
      version: 2, updateId: "u".repeat(43), sessionReference, phase: "using_tool", currentAction: "Working",
      progress: 1, completedSteps: 0, activeSubagentCount: 0, latestTool: null, timestamp: NOW, expires: NOW + 900,
    }).then((request) => handleLoopdyLinkRequest(request, liveEnv));
    expect(response.status).toBe(202);
    expect(retryQueue.send).toHaveBeenCalledTimes(1);
    const body = retryQueue.send.mock.calls[0]![0];
    expect(JSON.stringify(body)).not.toContain(OTHER_TOKEN);
    expect(body).toMatchObject({ kind: "liveactivity", live: { activityId, event: "update", staleDate: NOW + 900 } });
    apnsCalls = [];
    const message = fakeMessage(body);
    await run([message], liveEnv);
    expect(message.ack).toHaveBeenCalled();
    expect(apnsCalls[0]!.url).toContain(OTHER_TOKEN);
    expect((apnsCalls[0]!.payload as { aps: { event: string } }).aps.event).toBe("update");
  });
});

// MARK: Privacy

describe("what is logged and reported", () => {
  it("never holds a token, its ciphertext or payload text", async () => {
    const spies = (["log", "info", "warn", "error", "debug"] as const).map((method) => vi.spyOn(console, method));
    const installationKeys = await keys();
    const hostKeys = await keys();
    const installation = await insertInstallation(installationKeys, hostKeys);
    const targetEnv = targetEnvironment();
    await addTarget(targetEnv, installation);
    // A normal send, a token APNs refuses (fallback), a transient failure (queue) and a revoked one.
    await sendSealed(hostKeys, installation, targetEnv, "1");
    apnsAnswers.push({ status: 503, reason: "ServiceUnavailable" });
    await sendSealed(hostKeys, installation, targetEnv, "2");
    apnsAnswers.push({ status: 410, reason: "Unregistered" });
    await sendSealed(hostKeys, installation, targetEnv, "3");
    await env.ACCOUNTS.prepare("SELECT token_ciphertext FROM push_targets").first();
    const ciphertext = (await env.ACCOUNTS.prepare("SELECT token_ciphertext FROM push_targets").first<{ token_ciphertext: string }>())!.token_ciphertext;
    const seen = JSON.stringify([
      spies.flatMap((spy) => spy.mock.calls),
      telemetry.mock.calls,
      retryQueue.send.mock.calls,
    ]);
    expect(seen).not.toContain(TOKEN);
    expect(seen).not.toContain(ciphertext);
    expect(seen).not.toContain("BEGIN PRIVATE KEY");
    // The queue holds the sealed alert, which is opaque. Logs and telemetry never do.
    const reportedText = JSON.stringify([spies.flatMap((spy) => spy.mock.calls), telemetry.mock.calls]);
    expect(reportedText).not.toContain("opaque-ciphertext");
    // The target ID isn't in the telemetry or the logs either.
    const reported = JSON.stringify([spies.flatMap((spy) => spy.mock.calls), telemetry.mock.calls]);
    expect(reported).not.toContain(installation.installationId);
    expect(reported).not.toContain(installation.grantId);
    expect(reported).not.toContain(installation.coordinate);
  });

  it("reports only the fields the telemetry Worker allows", async () => {
    const hostKeys = await keys();
    const installation = await insertInstallation(await keys(), hostKeys);
    const targetEnv = targetEnvironment();
    await addTarget(targetEnv, installation);
    await sendSealed(hostKeys, installation, targetEnv);
    const allowed: Record<string, string[]> = {
      "push.sent": ["eventType", "path", "priority", "result", "status", "environment", "hostToWorkerMs", "providerMs", "attempt"],
      "push.token_invalid": ["kind", "reason"],
      "push.retry": ["attempt", "reason"],
      "push.dlq": ["reason"],
      "push.fallback_buzzkit": ["reason"],
      "push.shadow": ["eventType", "wouldUseDirect"],
    };
    expect(relayedEvents().length).toBeGreaterThan(0);
    for (const event of relayedEvents()) {
      expect(Object.keys(allowed)).toContain(event.name);
      for (const key of Object.keys(event.p)) expect(allowed[event.name]).toContain(key);
      for (const value of Object.values(event.p)) {
        if (typeof value === "string") expect(value).toMatch(/^[A-Za-z0-9._-]{1,64}$/);
      }
    }
    expect(relayedEvents().find((event) => event.name === "push.sent")!.p).toMatchObject({
      eventType: "session.completed", path: "direct", priority: 10, result: "sent", status: 200,
      environment: "production", attempt: 1,
    });
  });

  it("works with no telemetry binding", async () => {
    const hostKeys = await keys();
    const installation = await insertInstallation(await keys(), hostKeys);
    const targetEnv = targetEnvironment({ TELEMETRY: undefined });
    await addTarget(targetEnv, installation);
    expect((await sendSealed(hostKeys, installation, targetEnv)).status).toBe(202);
  });

  it("is not changed by a telemetry Worker that fails", async () => {
    const hostKeys = await keys();
    const installation = await insertInstallation(await keys(), hostKeys);
    const targetEnv = targetEnvironment({ TELEMETRY: { relay: async () => { throw new Error("down"); } } });
    await addTarget(targetEnv, installation);
    const pending: Promise<unknown>[] = [];
    const response = await sendSealed(hostKeys, installation, targetEnv, "c", { waitUntil: (p: Promise<unknown>) => pending.push(p) } as never);
    expect(response.status).toBe(202);
    await expect(Promise.all(pending)).resolves.toBeDefined();
  });
});
