import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { buzzKitIdentity, sendBuzzKitLinkWake as sendWakeWithSource } from "../src/buzzkit.js";
import { canonicalDeviceRequest } from "../src/device-auth.js";
import { handleLoopdyLinkRequest } from "../src/http.js";
import {
  canonicalNotificationHostRequest,
  type NotificationEgressSnapshot,
} from "../src/notification-grants.js";
import { LoopdyLinkError } from "../src/contracts.js";
import type { LinkEnv } from "../src/user-link.js";

const NOW = Math.floor(Date.now() / 1_000);
const ACCOUNT = "wake-routing-account-coordinate";
const DEVICE = "wake-routing-mobile-device";
const HOST = "wake-routing-source-host";
const BINDING_PATH = "/v1/notifications/installations/current/account-binding";

function sendBuzzKitLinkWake(targetEnv: LinkEnv, account: string, frameId: string) {
  return sendWakeWithSource(targetEnv, account, frameId, {
    hostDeviceId: DEVICE,
    authorizationEpoch: 1,
    authorizeEgress: () => {},
  });
}

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

type TestD1 = typeof env.ACCOUNTS;
type TestD1Statement = ReturnType<TestD1["prepare"]>;
type NotificationOwnerStub = {
  authorizeNotificationEgress(input: NotificationEgressSnapshot): Promise<void>;
  revokeNotificationCredential(input: {
    credentialId: string; authorizationEpoch: number;
  }): Promise<void>;
  revokeNotificationGrantAuthority(input: {
    grantId: string; credentialId: string; authorizationEpoch: number; revision: number;
  }): Promise<void>;
};

function notificationOwnerStub(ownerCoordinate: string): NotificationOwnerStub {
  return (env as unknown as {
    USER_LINKS: { getByName(name: string): NotificationOwnerStub };
  }).USER_LINKS.getByName(ownerCoordinate);
}

function targetEnvironment(
  state: Record<string, unknown> = {},
  accounts: TestD1 = env.ACCOUNTS,
): LinkEnv {
  return {
    ...env,
    ACCOUNTS: accounts,
    USER_LINKS: {
      getByName: () => ({
        listDevices: async () => ({ devices: [{
          deviceId: DEVICE, role: "mobile", lifecycle: "active",
        }] }),
        authorizeNotificationEgress: async (input: {
          activity?: { activityId: string; sessionReference: string; leaseExpires: number };
          grant?: { grantId: string };
          now: number;
        }) => {
          if (!input.activity || typeof state.notificationActivity !== "function") return;
          const activity = await (state.notificationActivity as (input: object) => Promise<{
            status: string; sessionReference: string; leaseExpires: number;
          }>)({ grantId: input.grant?.grantId, activityId: input.activity.activityId, now: input.now });
          const currentNow = Math.floor(Date.now() / 1_000);
          if (activity.status !== "active" || activity.sessionReference !== input.activity.sessionReference
              || activity.leaseExpires <= currentNow) {
            throw new LoopdyLinkError("notification_activity_inactive", "Notification activity is inactive");
          }
        },
        revokeNotificationCredential: async () => {},
        revokeNotificationGrantAuthority: async () => {
          if (typeof state.revokeNotificationGrantActivities === "function") {
            await (state.revokeNotificationGrantActivities as () => Promise<void>)();
          }
        },
        retireNotificationScope: async () => {},
        ...state,
      }),
    } as never,
    BUZZKIT_API_KEY: `bk_tn_${crypto.randomUUID()}`,
    BUZZKIT_IDENTITY_SECRET: crypto.randomUUID(),
    BUZZKIT_IDENTITY_SECRET_GENERATION: "notification-instance-v2",
  } as LinkEnv;
}

function afterD1Query(
  database: TestD1,
  queryNeedle: string,
  occurrence: number,
  action: () => Promise<void>,
): TestD1 {
  let matches = 0;
  const wrap = (statement: TestD1Statement, matched: boolean): TestD1Statement => new Proxy(statement, {
    get(target, property) {
      if (property === "bind") {
        return (...values: unknown[]) => wrap(target.bind(...values), matched);
      }
      if (property === "first") {
        return async (...values: unknown[]) => {
          const result = await (target.first as (...input: unknown[]) => Promise<unknown>)(...values);
          if (matched && ++matches === occurrence) await action();
          return result;
        };
      }
      if (property === "all") {
        return async (...values: unknown[]) => {
          const result = await (target.all as (...input: unknown[]) => Promise<unknown>)(...values);
          if (matched && ++matches === occurrence) await action();
          return result;
        };
      }
      const value = Reflect.get(target, property, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  return new Proxy(database, {
    get(target, property) {
      if (property === "prepare") {
        return (query: string) => wrap(target.prepare(query), query.includes(queryNeedle));
      }
      const value = Reflect.get(target, property, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

function failD1RunOnce(database: TestD1, queryNeedle: string): TestD1 {
  let failed = false;
  const wrap = (statement: TestD1Statement, matched: boolean): TestD1Statement => new Proxy(statement, {
    get(target, property) {
      if (property === "bind") {
        return (...values: unknown[]) => wrap(target.bind(...values), matched);
      }
      if (property === "run" && matched) {
        return async () => {
          if (!failed) {
            failed = true;
            throw new Error("simulated directory commit interruption");
          }
          return target.run();
        };
      }
      const value = Reflect.get(target, property, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  return new Proxy(database, {
    get(target, property) {
      if (property === "prepare") {
        return (query: string) => wrap(target.prepare(query), query.includes(queryNeedle));
      }
      const value = Reflect.get(target, property, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

async function insertLegacyGrant(hostKeys: KeyPair) {
  const grantId = crypto.randomUUID();
  const hostRaw = new Uint8Array(await crypto.subtle.exportKey("raw", hostKeys.publicKey) as ArrayBuffer);
  const hostKeyId = encoded(await crypto.subtle.digest("SHA-256", hostRaw));
  const grant = {
    grantId,
    hostKeyId,
    hostPublicKey: encoded(hostRaw),
    authorizationEpoch: 1,
    profile: "default",
    eventTypes: ["session.completed"],
    createdAt: NOW,
    expiresAt: NOW + 1_800,
    revision: 1,
    provider: "buzzkit",
    subscriberScope: "account",
    state: "active",
  };
  await env.ACCOUNTS.prepare(`INSERT INTO notification_grants(
    grant_id,account_coordinate,device_id,authorization_epoch,idempotency_key,
    request_digest,public_json,state,revision,created_at,expires_at)
    VALUES(?,?,?,1,?,?,?,'active',1,?,?)`)
    .bind(grantId, ACCOUNT, DEVICE, crypto.randomUUID(), "digest", JSON.stringify(grant), NOW, NOW + 1_800)
    .run();
  return { grantId, hostKeyId };
}

async function accountHostRequest(
  hostKeys: KeyPair,
  grantId: string,
  hostKeyId: string,
  suffix: string,
  method: "GET" | "POST",
  body?: object,
): Promise<Request> {
  const path = `/v1/notifications/host-grants/${grantId}${suffix}`;
  const raw = body === undefined ? "" : JSON.stringify(body);
  const nonce = encoded(crypto.getRandomValues(new Uint8Array(32)));
  const transcript = await canonicalNotificationHostRequest(
    method, path, grantId, NOW, nonce, new TextEncoder().encode(raw),
  );
  return new Request(`https://link.loopdy.example${path}`, {
    method,
    body: raw || undefined,
    headers: {
      ...(raw ? { "content-type": "application/json" } : {}),
      "x-loopdy-host-key-id": hostKeyId,
      "x-loopdy-timestamp": String(NOW),
      "x-loopdy-nonce": nonce,
      "x-loopdy-signature": encoded(await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" }, hostKeys.privateKey,
        new TextEncoder().encode(transcript),
      )),
    },
  });
}

async function richEvent(grantId: string) {
  const avatar = new Uint8Array([1, 2, 3]);
  const sha256 = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", avatar)),
    (byte) => byte.toString(16).padStart(2, "0")).join("");
  return {
    version: 2,
    eventId: `${grantId}:${"a".repeat(64)}`,
    eventType: "session.completed",
    sessionReference: "a".repeat(43),
    turnId: "turn-retirement-race",
    occurredAt: NOW,
    agent: {
      id: "default",
      name: "Retirement Race",
      avatar: { mimeType: "image/png", sha256, data: "data:image/png;base64,AQID" },
    },
    content: { kind: "reply", text: "This legacy send must stay retired." },
    sound: false,
  };
}

async function sealedEvent(grantId: string, hostKeyId: string) {
  const blob = new Uint8Array([9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6, 7]);
  const sha256 = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", blob)),
    (byte) => byte.toString(16).padStart(2, "0")).join("");
  const eventId = `${grantId}:${"c".repeat(64)}`;
  return {
    version: 3,
    eventId,
    eventType: "session.completed",
    sessionReference: "a".repeat(43),
    turnId: "turn-sealed",
    occurredAt: NOW,
    sealed: {
      v: 2, grantId, eventId, recipientKeyId: "r".repeat(43), senderKeyId: hostKeyId, issued: NOW,
      ephemeralPublicKey: "e".repeat(87), salt: "s".repeat(43), nonce: "n".repeat(16),
      ciphertext: "opaque-ciphertext", tag: "t".repeat(22), signature: "g".repeat(86),
    },
    avatar: { sha256, data: `data:application/octet-stream;base64,${btoa(String.fromCharCode(...blob))}` },
    sound: true,
  };
}

async function insertInstallation(
  coordinate: string,
  installationKeys: KeyPair,
  hostKeys?: KeyPair,
): Promise<{ installationId: string; grantId: string; hostKeyId: string }> {
  const installationId = crypto.randomUUID();
  const grantId = crypto.randomUUID();
  const hostRaw = hostKeys
    ? new Uint8Array(await crypto.subtle.exportKey("raw", hostKeys.publicKey) as ArrayBuffer)
    : crypto.getRandomValues(new Uint8Array(65));
  const hostKeyId = encoded(await crypto.subtle.digest("SHA-256", hostRaw));
  const grant = {
    grantId,
    instanceId: crypto.randomUUID(),
    hostKeyId,
    hostPublicKey: encoded(hostRaw),
    authorizationEpoch: 1,
    profile: "default",
    eventTypes: ["session.completed"],
    createdAt: NOW,
    expiresAt: NOW + 1_800,
    revision: 1,
    provider: "buzzkit",
    subscriberScope: "notification-instance",
    state: "active",
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
  return { installationId, grantId, hostKeyId };
}

async function bindingRequest(
  accountKeys: KeyPair,
  installationKeys: KeyPair,
  installationId: string,
  grantId: string,
): Promise<Request> {
  const raw = JSON.stringify({ version: 1, grantId });
  const accountNonce = encoded(crypto.getRandomValues(new Uint8Array(24)));
  const accountCanonical = await canonicalDeviceRequest({
    method: "POST", path: BINDING_PATH, deviceId: DEVICE, timestamp: NOW,
    nonce: accountNonce, authorizationEpoch: 1, body: raw,
  });
  const installationNonce = encoded(crypto.getRandomValues(new Uint8Array(24)));
  const installationCanonical = [
    "loopdy-notification-device-v1", "POST", BINDING_PATH, installationId,
    String(NOW), installationNonce, "1",
    encoded(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw))),
  ].join("\n");
  return new Request(`https://link.loopdy.example${BINDING_PATH}`, {
    method: "POST",
    body: raw,
    headers: {
      "content-type": "application/json",
      "x-loopdy-notification-installation": installationId,
      "x-loopdy-timestamp": String(NOW),
      "x-loopdy-nonce": installationNonce,
      "x-loopdy-authorization-epoch": "1",
      "x-loopdy-signature": encoded(await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" }, installationKeys.privateKey,
        new TextEncoder().encode(installationCanonical),
      )),
      "x-loopdy-account-device-id": DEVICE,
      "x-loopdy-account-timestamp": String(NOW),
      "x-loopdy-account-nonce": accountNonce,
      "x-loopdy-account-authorization-epoch": "1",
      "x-loopdy-account-signature": encoded(await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" }, accountKeys.privateKey,
        new TextEncoder().encode(accountCanonical),
      )),
    },
  });
}

async function notificationInstallationRequest(
  installationKeys: KeyPair,
  installationId: string,
  path: string,
  body: object | null,
  method: "GET" | "POST" = "POST",
): Promise<Request> {
  const raw = body === null ? "" : JSON.stringify(body);
  const nonce = encoded(crypto.getRandomValues(new Uint8Array(24)));
  const canonical = [
    "loopdy-notification-device-v1", method, path, installationId,
    String(NOW), nonce, "1",
    encoded(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw))),
  ].join("\n");
  return new Request(`https://link.loopdy.example${path}`, {
    method,
    ...(raw ? { body: raw } : {}),
    headers: {
      "content-type": "application/json",
      "x-loopdy-notification-installation": installationId,
      "x-loopdy-timestamp": String(NOW),
      "x-loopdy-nonce": nonce,
      "x-loopdy-authorization-epoch": "1",
      "x-loopdy-signature": encoded(await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" }, installationKeys.privateKey,
        new TextEncoder().encode(canonical),
      )),
    },
  });
}

async function accountDeviceRequest(
  accountKeys: KeyPair,
  path: string,
  body: object,
  method: "POST" | "DELETE" = "POST",
): Promise<Request> {
  const raw = JSON.stringify(body);
  const nonce = encoded(crypto.getRandomValues(new Uint8Array(24)));
  const canonical = await canonicalDeviceRequest({
    method, path, deviceId: DEVICE, timestamp: NOW,
    nonce, authorizationEpoch: 1, body: raw,
  });
  return new Request(`https://link.loopdy.example${path}`, {
    method,
    body: raw,
    headers: {
      "content-type": "application/json",
      "x-loopdy-device-id": DEVICE,
      "x-loopdy-timestamp": String(NOW),
      "x-loopdy-nonce": nonce,
      "x-loopdy-authorization-epoch": "1",
      "x-loopdy-signature": encoded(await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" }, accountKeys.privateKey,
        new TextEncoder().encode(canonical),
      )),
    },
  });
}

function interceptRecipientPreparation(action: () => Promise<void>): void {
  const digest = crypto.subtle.digest.bind(crypto.subtle);
  let intercepted = false;
  vi.spyOn(crypto.subtle, "digest").mockImplementation(async (algorithm, data) => {
    const bytes = data instanceof ArrayBuffer
      ? new Uint8Array(data)
      : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    if (!intercepted && new TextDecoder().decode(bytes).startsWith("loopdy-buzzkit-")) {
      intercepted = true;
      await action();
    }
    return digest(algorithm, data);
  });
}

describe("post-migration Link wake ownership", () => {
  let accountKeys: KeyPair;

  afterEach(() => vi.restoreAllMocks());

  beforeEach(async () => {
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare("DELETE FROM notification_installation_revocation_cleanup"),
      env.ACCOUNTS.prepare("DELETE FROM notification_device_revocations"),
      env.ACCOUNTS.prepare("DELETE FROM notification_instance_host_nonces"),
      env.ACCOUNTS.prepare("DELETE FROM notification_instance_grants"),
      env.ACCOUNTS.prepare("DELETE FROM notification_installations"),
      env.ACCOUNTS.prepare("DELETE FROM notification_host_nonces"),
      env.ACCOUNTS.prepare("DELETE FROM notification_grants"),
      env.ACCOUNTS.prepare("DELETE FROM notification_account_scope_retirements"),
      env.ACCOUNTS.prepare("DELETE FROM notification_account_installations"),
      env.ACCOUNTS.prepare("DELETE FROM device_directory"),
      env.ACCOUNTS.prepare("DELETE FROM accounts"),
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts(account_coordinate,status,authorization_epoch,created_at) VALUES(?,'active',1,?)",
      ).bind(ACCOUNT, NOW),
      env.ACCOUNTS.prepare(`INSERT INTO device_directory(
        device_id,account_coordinate,public_key_spki,status,authorization_epoch,created_at)
        VALUES(?,?,?,'active',1,?)`).bind(DEVICE, ACCOUNT, "public-key-fixture", NOW),
      env.ACCOUNTS.prepare(`INSERT INTO device_directory(
        device_id,account_coordinate,public_key_spki,status,authorization_epoch,created_at)
        VALUES(?,?,?,'active',1,?)`).bind(HOST, ACCOUNT, "host-public-key-fixture", NOW),
    ]);
    accountKeys = await keys();
    await env.ACCOUNTS.prepare(
      "UPDATE device_directory SET public_key_spki=? WHERE device_id=?",
    ).bind(accountKeys.publicKeySPKI, DEVICE).run();
  });

  it("fences a legacy host grant when retirement survives partial cleanup", async () => {
    const hostKeys = await keys();
    const grant = await insertLegacyGrant(hostKeys);
    await env.ACCOUNTS.prepare(`INSERT INTO notification_account_scope_retirements(
      account_coordinate,retired_at) VALUES(?,?)`).bind(ACCOUNT, NOW).run();

    const result = await handleLoopdyLinkRequest(await accountHostRequest(
      hostKeys, grant.grantId, grant.hostKeyId, "", "GET",
    ), targetEnvironment());

    expect(result.status).toBe(410);
    expect(await result.json()).toMatchObject({
      error: { code: "notification_account_scope_retired" },
    });
    expect((await env.ACCOUNTS.prepare("SELECT state FROM notification_grants WHERE grant_id=?")
      .bind(grant.grantId).first<{ state: string }>())?.state).toBe("active");
  });

  it("rechecks retirement immediately before rich notification provider egress", async () => {
    const hostKeys = await keys();
    const grant = await insertLegacyGrant(hostKeys);
    const provider = vi.spyOn(globalThis, "fetch").mockImplementation(async () => Response.json({
      success: true,
      data: { id: "msg_retirement_race", status: "queued", counts: { total: 1, sent: 0 } },
    }));
    const targetEnv = targetEnvironment({
      putNotificationAsset: async (asset: object) => {
        await env.ACCOUNTS.prepare(`INSERT INTO notification_account_scope_retirements(
          account_coordinate,retired_at) VALUES(?,?)`).bind(ACCOUNT, NOW).run();
        return asset;
      },
    });

    const result = await handleLoopdyLinkRequest(await accountHostRequest(
      hostKeys, grant.grantId, grant.hostKeyId, "/events", "POST", await richEvent(grant.grantId),
    ), targetEnv);

    expect(result.status).toBe(410);
    expect(await result.json()).toMatchObject({
      error: { code: "notification_account_scope_retired" },
    });
    expect(provider).not.toHaveBeenCalled();
  });

  it("uses current wall time for the rich notification egress grant check", async () => {
    const hostKeys = await keys();
    const grant = await insertLegacyGrant(hostKeys);
    const provider = vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({
      success: true,
      data: { id: "msg_expired_race", status: "queued", counts: { total: 1, sent: 0 } },
    }));
    const targetEnv = targetEnvironment({
      putNotificationAsset: async (asset: object) => {
        vi.spyOn(Date, "now").mockReturnValue((NOW + 1_801) * 1_000);
        return asset;
      },
    });

    const result = await handleLoopdyLinkRequest(await accountHostRequest(
      hostKeys, grant.grantId, grant.hostKeyId, "/events", "POST", await richEvent(grant.grantId),
    ), targetEnv);

    expect(result.status).toBe(410);
    expect(provider).not.toHaveBeenCalled();
  });

  it("rejects a grant revocation mirrored while the final D1 snapshot is returning", async () => {
    const hostKeys = await keys();
    const grant = await insertLegacyGrant(hostKeys);
    let ownerRevoked = false;
    const accounts = afterD1Query(env.ACCOUNTS, "FROM notification_grants grant_row", 1, async () => {
      ownerRevoked = true;
      await env.ACCOUNTS.prepare(
        "UPDATE notification_grants SET state='revoked',revision=revision+1 WHERE grant_id=?",
      ).bind(grant.grantId).run();
    });
    const provider = vi.spyOn(globalThis, "fetch").mockImplementation(async () => Response.json({
      success: true,
      data: { id: "msg_rich_intra_fence", status: "queued", counts: { total: 1, sent: 0 } },
    }));

    const result = await handleLoopdyLinkRequest(await accountHostRequest(
      hostKeys, grant.grantId, grant.hostKeyId, "/events", "POST", await richEvent(grant.grantId),
    ), targetEnvironment({
      putNotificationAsset: async (asset: object) => asset,
      authorizeNotificationEgress: async () => {
        if (ownerRevoked) {
          throw new LoopdyLinkError("notification_grant_inactive", "Notification grant is inactive");
        }
      },
    }, accounts));

    expect(result.status).toBe(410);
    expect(provider).not.toHaveBeenCalled();
  });

  it("rechecks retirement immediately before live activity provider egress", async () => {
    const hostKeys = await keys();
    const grant = await insertLegacyGrant(hostKeys);
    const activityId = "activity-retirement-race";
    const sessionReference = "a".repeat(43);
    let completed = false;
    const provider = vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({
      success: true,
      data: { results: [{ ok: true, id: "live_retirement_race" }] },
    }));
    const targetEnv = targetEnvironment({
      notificationActivity: async () => ({
        activityId,
        grantId: grant.grantId,
        sessionReference,
        revision: 1,
        leaseExpires: NOW + 900,
        status: "active",
      }),
      beginNotificationActivityUpdate: async () => {
        await env.ACCOUNTS.prepare(`INSERT INTO notification_account_scope_retirements(
          account_coordinate,retired_at) VALUES(?,?)`).bind(ACCOUNT, NOW).run();
        return { status: "send" };
      },
      completeNotificationActivityUpdate: async () => { completed = true; },
    });
    const update = {
      version: 2,
      updateId: "b".repeat(43),
      sessionReference,
      phase: "using_tool",
      currentAction: "Testing retirement fence",
      progress: 50,
      completedSteps: 1,
      activeSubagentCount: 0,
      latestTool: "vitest",
      timestamp: NOW,
      expires: NOW + 900,
    };

    const result = await handleLoopdyLinkRequest(await accountHostRequest(
      hostKeys, grant.grantId, grant.hostKeyId,
      `/live-activities/${activityId}/updates`, "POST", update,
    ), targetEnv);

    expect(result.status).toBe(410);
    expect(await result.json()).toMatchObject({
      error: { code: "notification_account_scope_retired" },
    });
    expect(provider).not.toHaveBeenCalled();
    expect(completed).toBe(false);
  });

  it.each([
    ["revoked", "revoked", NOW + 900],
    ["lease-expired", "active", NOW + 900],
  ] as const)("rechecks a %s activity after reserving its live update", async (race, status, leaseExpires) => {
    const hostKeys = await keys();
    const grant = await insertLegacyGrant(hostKeys);
    const activityId = `activity-${status}-race`;
    const sessionReference = "a".repeat(43);
    let currentStatus: "active" | "revoked" = "active";
    let completed = false;
    const provider = vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({
      success: true,
      data: { results: [{ ok: true, id: `live_${status}_race` }] },
    }));
    const targetEnv = targetEnvironment({
      notificationActivity: async () => ({
        activityId,
        grantId: grant.grantId,
        sessionReference,
        revision: 1,
        leaseExpires,
        status: currentStatus,
      }),
      beginNotificationActivityUpdate: async () => {
        currentStatus = status;
        if (race === "lease-expired") {
          vi.spyOn(Date, "now").mockReturnValue((NOW + 901) * 1_000);
        }
        return { status: "send" };
      },
      completeNotificationActivityUpdate: async () => { completed = true; },
    });
    const update = {
      version: 2,
      updateId: "c".repeat(43),
      sessionReference,
      phase: "using_tool",
      currentAction: "Testing activity fence",
      progress: 50,
      completedSteps: 1,
      activeSubagentCount: 0,
      latestTool: "vitest",
      timestamp: NOW,
      expires: NOW + 900,
    };

    const result = await handleLoopdyLinkRequest(await accountHostRequest(
      hostKeys, grant.grantId, grant.hostKeyId,
      `/live-activities/${activityId}/updates`, "POST", update,
    ), targetEnv);

    expect(result.status).toBe(410);
    expect(provider).not.toHaveBeenCalled();
    expect(completed).toBe(false);
  });

  it.each([
    ["completed", true],
    ["using_tool", false],
  ] as const)("a %s update leaves the Lock Screen on time: dismissal date %s", async (phase, dismisses) => {
    const hostKeys = await keys();
    const grant = await insertLegacyGrant(hostKeys);
    const activityId = `activity-dismissal-${phase}`;
    const sessionReference = "a".repeat(43);
    const provider = vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({
      success: true,
      data: { results: [{ ok: true, id: `live_dismissal_${phase}` }] },
    }));
    const targetEnv = targetEnvironment({
      notificationActivity: async () => ({
        activityId,
        grantId: grant.grantId,
        sessionReference,
        revision: 1,
        leaseExpires: NOW + 900,
        status: "active",
      }),
      beginNotificationActivityUpdate: async () => ({ status: "send" }),
      completeNotificationActivityUpdate: async () => {},
    });
    const update = {
      version: 2,
      updateId: "d".repeat(43),
      sessionReference,
      phase,
      currentAction: "Finished",
      progress: 100,
      completedSteps: 1,
      activeSubagentCount: 0,
      latestTool: null,
      timestamp: NOW,
      expires: NOW + 120,
    };

    const result = await handleLoopdyLinkRequest(await accountHostRequest(
      hostKeys, grant.grantId, grant.hostKeyId,
      `/live-activities/${activityId}/updates`, "POST", update,
    ), targetEnv);

    expect(result.status).toBe(202);
    const sent = JSON.parse(String((provider.mock.calls.at(-1)?.[1] as RequestInit).body));
    expect(sent.event).toBe(dismisses ? "end" : "update");
    if (dismisses) {
      expect(sent.dismissalDate).toBe(new Date((NOW + 30) * 1_000).toISOString());
    } else {
      expect(sent.dismissalDate).toBeUndefined();
    }
  });

  it.each(["revoked", "lease-expired"] as const)(
    "rechecks live activity %s authority changed after the first final activity read",
    async (race) => {
      const hostKeys = await keys();
      const grant = await insertLegacyGrant(hostKeys);
      const activityId = `activity-intra-fence-${race}`;
      const sessionReference = "a".repeat(43);
      let activityCalls = 0;
      let currentStatus: "active" | "revoked" = "active";
      let completed = false;
      const provider = vi.spyOn(globalThis, "fetch").mockImplementation(async () => Response.json({
        success: true,
        data: { results: [{ ok: true, id: `live_intra_${race}` }] },
      }));
      const targetEnv = targetEnvironment({
        notificationActivity: async () => {
          activityCalls += 1;
          if (activityCalls === 2) {
            if (race === "revoked") currentStatus = "revoked";
            else vi.spyOn(Date, "now").mockReturnValue((NOW + 901) * 1_000);
          }
          return {
            activityId,
            grantId: grant.grantId,
            sessionReference,
            revision: 1,
            leaseExpires: NOW + 900,
            status: currentStatus,
          };
        },
        beginNotificationActivityUpdate: async () => ({ status: "send" }),
        completeNotificationActivityUpdate: async () => { completed = true; },
      });
      const update = {
        version: 2,
        updateId: "d".repeat(43),
        sessionReference,
        phase: "using_tool",
        currentAction: "Testing intra-fence activity authority",
        progress: 50,
        completedSteps: 1,
        activeSubagentCount: 0,
        latestTool: "vitest",
        timestamp: NOW,
        expires: NOW + 900,
      };

      const result = await handleLoopdyLinkRequest(await accountHostRequest(
        hostKeys, grant.grantId, grant.hostKeyId,
        `/live-activities/${activityId}/updates`, "POST", update,
      ), targetEnv);

      expect(result.status).toBe(410);
      expect(provider).not.toHaveBeenCalled();
      expect(completed).toBe(false);
    },
  );

  it("rechecks installation authority before test-notification provider egress", async () => {
    const installationKeys = await keys();
    const installation = await insertInstallation("notification-owned-coordinate", installationKeys);
    const request = await notificationInstallationRequest(
      installationKeys,
      installation.installationId,
      "/v1/notifications/host-grants/buzzkit/test",
      { version: 1, requestId: crypto.randomUUID() },
    );
    interceptRecipientPreparation(async () => {
      await env.ACCOUNTS.prepare(`UPDATE notification_installations
        SET state='revoked',authorization_epoch=authorization_epoch+1,revoked_at=?
        WHERE installation_id=?`).bind(NOW, installation.installationId).run();
    });
    const provider = vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({
      success: true,
      data: { id: "msg_test_race", status: "queued", counts: { total: 1, sent: 0 } },
    }));

    const result = await handleLoopdyLinkRequest(request, targetEnvironment());

    expect(result.status).toBe(410);
    expect(provider).not.toHaveBeenCalled();
  });

  it("rejects identity issuance when the installation owner revokes after directory discovery", async () => {
    const coordinate = "notification-identity-owner-coordinate";
    const installationKeys = await keys();
    const installation = await insertInstallation(coordinate, installationKeys);
    const realStub = notificationOwnerStub(coordinate);
    await realStub.authorizeNotificationEgress({
      ownerKind: "notification-instance",
      credentialId: installation.installationId,
      authorizationEpoch: 1,
      now: NOW,
    });
    const request = await notificationInstallationRequest(
      installationKeys,
      installation.installationId,
      "/v1/notifications/host-grants/buzzkit/identity",
      null,
      "GET",
    );
    const sign = crypto.subtle.sign.bind(crypto.subtle);
    let revoked = false;
    vi.spyOn(crypto.subtle, "sign").mockImplementation(async (algorithm, key, data) => {
      if (!revoked && algorithm === "HMAC") {
        revoked = true;
        await realStub.revokeNotificationCredential({
          credentialId: installation.installationId,
          authorizationEpoch: 1,
        });
      }
      return sign(algorithm, key, data);
    });

    const result = await handleLoopdyLinkRequest(request, targetEnvironment({
      authorizeNotificationEgress: (input: Parameters<typeof realStub.authorizeNotificationEgress>[0]) =>
        realStub.authorizeNotificationEgress(input),
    }));

    expect(result.status).toBe(410);
    expect(await result.json()).toMatchObject({
      error: { code: "notification_credentials_revoked" },
    });
  });

  it("rechecks account device authority before test-notification provider egress", async () => {
    const request = await accountDeviceRequest(
      accountKeys,
      "/v1/notifications/host-grants/buzzkit/test",
      { version: 1, requestId: crypto.randomUUID() },
    );
    interceptRecipientPreparation(async () => {
      await env.ACCOUNTS.prepare(
        "UPDATE device_directory SET status='revoked',authorization_epoch=authorization_epoch+1 WHERE device_id=?",
      ).bind(DEVICE).run();
    });
    const provider = vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({
      success: true,
      data: { id: "msg_test_device_race", status: "queued", counts: { total: 1, sent: 0 } },
    }));

    const result = await handleLoopdyLinkRequest(request, targetEnvironment());

    expect(result.status).toBe(410);
    expect(provider).not.toHaveBeenCalled();
  });

  it("linearizes a test send after a device revocation inside the final aggregate read", async () => {
    const realStub = env.USER_LINKS.getByName(ACCOUNT);
    await realStub.registerDevice({
      deviceId: DEVICE,
      publicKey: accountKeys.publicKeySPKI,
      role: "mobile",
      kind: "phone",
      encryptedName: "opaque-final-fence-device",
      revision: 1,
      createdAt: NOW,
    });
    const accounts = afterD1Query(env.ACCOUNTS, "SELECT 1 AS active", 1, async () => {
      await realStub.revokeDevice({ deviceId: DEVICE, expectedRevision: 1, revokedAt: NOW });
    });
    const targetEnv = targetEnvironment({
      listDevices: () => realStub.listDevices(),
      authorizeNotificationEgress: (input: Parameters<typeof realStub.authorizeNotificationEgress>[0]) =>
        realStub.authorizeNotificationEgress(input),
    }, accounts);
    const provider = vi.spyOn(globalThis, "fetch").mockImplementation(async () => Response.json({
      success: true,
      data: { id: "msg_final_owner_race", status: "queued", counts: { total: 1, sent: 0 } },
    }));

    const result = await handleLoopdyLinkRequest(await accountDeviceRequest(
      accountKeys,
      "/v1/notifications/host-grants/buzzkit/test",
      { version: 1, requestId: crypto.randomUUID() },
    ), targetEnv);

    expect(result.status).toBe(410);
    expect(provider).not.toHaveBeenCalled();
  });

  it("blocks test sends while device revocation cleanup is awaiting", async () => {
    const hostKeys = await keys();
    await insertLegacyGrant(hostKeys);
    let releaseCleanup!: () => void;
    let signalCleanup!: () => void;
    const cleanupEntered = new Promise<void>((resolve) => { signalCleanup = resolve; });
    const cleanupRelease = new Promise<void>((resolve) => { releaseCleanup = resolve; });
    const activeDevice = {
      deviceId: DEVICE,
      encryptedName: "fixture",
      role: "mobile" as const,
      kind: "phone" as const,
      lifecycle: "active" as const,
      revision: 1,
      authorizationEpoch: 1,
      connection: "offline" as const,
      pushState: null,
      pushRevision: 0,
      createdAt: NOW,
      revokedAt: null,
      lastSeenBucket: null,
    };
    const targetEnv = targetEnvironment({
      listDevices: async () => ({ devices: [activeDevice] }),
      revokeNotificationGrantActivities: async () => {
        signalCleanup();
        await cleanupRelease;
      },
      revokeDevice: async () => ({
        ...activeDevice,
        lifecycle: "revoked",
        revision: 2,
        authorizationEpoch: 2,
        revokedAt: NOW,
      }),
    });
    const provider = vi.spyOn(globalThis, "fetch").mockImplementation(async () => Response.json({
      success: true,
      data: { id: "msg_device_cleanup_race", status: "queued", counts: { total: 1, sent: 0 } },
    }));
    const revocation = handleLoopdyLinkRequest(await accountDeviceRequest(
      accountKeys, `/v1/devices/${DEVICE}`, { expectedRevision: 1 }, "DELETE",
    ), targetEnv);
    await cleanupEntered;

    let send: Response;
    try {
      send = await handleLoopdyLinkRequest(await accountDeviceRequest(
        accountKeys,
        "/v1/notifications/host-grants/buzzkit/test",
        { version: 1, requestId: crypto.randomUUID() },
      ), targetEnv);
    } finally {
      releaseCleanup();
    }

    expect(send.status).toBe(403);
    expect(provider).not.toHaveBeenCalled();
    expect((await revocation).status).toBe(200);
  });

  it("resumes real UserLink revocation after its DO commit without re-authorizing D1", async () => {
    const retryDevice = "wake-routing-retry-device";
    const realStub = (env as unknown as LinkEnv).USER_LINKS.getByName(ACCOUNT);
    await realStub.registerDevice({
      deviceId: retryDevice,
      publicKey: accountKeys.publicKeySPKI,
      role: "mobile",
      kind: "phone",
      encryptedName: "opaque-retry-device",
      revision: 1,
      createdAt: NOW,
    });
    await env.ACCOUNTS.prepare(`INSERT INTO device_directory(
      device_id,account_coordinate,public_key_spki,status,authorization_epoch,created_at)
      VALUES(?,?,?,'active',1,?)`)
      .bind(retryDevice, ACCOUNT, accountKeys.publicKeySPKI, NOW).run();
    const interruptedEnv = {
      ...targetEnvironment({}, failD1RunOnce(env.ACCOUNTS, "UPDATE device_directory SET")),
      USER_LINKS: (env as unknown as LinkEnv).USER_LINKS,
    } as LinkEnv;

    const failed = await handleLoopdyLinkRequest(await accountDeviceRequest(
      accountKeys, `/v1/devices/${retryDevice}`, { expectedRevision: 1 }, "DELETE",
    ), interruptedEnv);

    expect(failed.status).toBe(500);
    expect((await realStub.listDevices()).devices.find(
      (device: { deviceId: string }) => device.deviceId === retryDevice,
    )).toBeUndefined();
    expect(await env.ACCOUNTS.prepare(`SELECT status,authorization_epoch FROM device_directory
      WHERE device_id=?`).bind(retryDevice).first())
      .toEqual({ status: "active", authorization_epoch: 1 });

    const realEnv = {
      ...targetEnvironment(), USER_LINKS: (env as unknown as LinkEnv).USER_LINKS,
    } as LinkEnv;
    const retried = await handleLoopdyLinkRequest(await accountDeviceRequest(
      accountKeys, `/v1/devices/${retryDevice}`, { expectedRevision: 1 }, "DELETE",
    ), realEnv);

    expect(retried.status).toBe(200);
    expect(await env.ACCOUNTS.prepare(`SELECT status,authorization_epoch FROM device_directory
      WHERE device_id=?`).bind(retryDevice).first())
      .toEqual({ status: "revoked", authorization_epoch: 2 });
    expect(await env.ACCOUNTS.prepare(
      "SELECT device_id FROM notification_device_revocations WHERE device_id=?",
    ).bind(retryDevice).first()).toEqual({ device_id: retryDevice });
    const denied = await handleLoopdyLinkRequest(await accountDeviceRequest(
      accountKeys,
      "/v1/notifications/host-grants/buzzkit/test",
      { version: 1, requestId: crypto.randomUUID() },
    ), realEnv);
    expect(denied.status).toBe(403);
  });

  it("rechecks installation revocation immediately before rich notification provider egress", async () => {
    const installationKeys = await keys();
    const hostKeys = await keys();
    const installation = await insertInstallation(
      "notification-owned-coordinate",
      installationKeys,
      hostKeys,
    );
    const provider = vi.spyOn(globalThis, "fetch").mockImplementation(async () => Response.json({
      success: true,
      data: { id: "msg_installation_race", status: "queued", counts: { total: 1, sent: 0 } },
    }));
    const targetEnv = targetEnvironment({
      putNotificationAsset: async (asset: object) => {
        await env.ACCOUNTS.prepare(`UPDATE notification_installations
          SET state='revoked',authorization_epoch=authorization_epoch+1,revoked_at=?
          WHERE installation_id=?`).bind(NOW, installation.installationId).run();
        return asset;
      },
    });

    const result = await handleLoopdyLinkRequest(await accountHostRequest(
      hostKeys,
      installation.grantId,
      installation.hostKeyId,
      "/events",
      "POST",
      await richEvent(installation.grantId),
    ), targetEnv);

    expect(result.status).toBe(410);
    expect(provider).not.toHaveBeenCalled();
  });

  it("forwards sealed alerts without reading them and stores the sealed avatar as opaque bytes", async () => {
    const installationKeys = await keys();
    const hostKeys = await keys();
    const installation = await insertInstallation("notification-owned-coordinate", installationKeys, hostKeys);
    const sent: Array<Record<string, unknown>> = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
      if (init?.body) sent.push(JSON.parse(String(init.body)) as Record<string, unknown>);
      return Response.json({ success: true, data: { id: "msg_sealed", status: "queued", counts: { total: 1 } } });
    });
    const stored: Array<{ mimeType: string; data: Uint8Array }> = [];
    const targetEnv = targetEnvironment({
      putNotificationAsset: async (asset: { mimeType: string; data: Uint8Array }) => { stored.push(asset); return asset; },
    });
    const event = await sealedEvent(installation.grantId, installation.hostKeyId);

    const result = await handleLoopdyLinkRequest(await accountHostRequest(
      hostKeys, installation.grantId, installation.hostKeyId, "/events", "POST", event,
    ), targetEnv);

    expect(result.status).toBe(202);
    expect(stored).toEqual([expect.objectContaining({ mimeType: "application/octet-stream" })]);
    expect(sent[0]).toMatchObject({ title: "bighelp", body: "New reply",
      data: { loopdy: { sealed: event.sealed, eventId: event.eventId } } });
    expect(String((sent[0]?.data as { loopdy: { avatar: { url: string } } }).loopdy.avatar.url)).toMatch(/\.bin\?expires=/);
    expect(sent[0]).not.toHaveProperty("imageUrl");

    const forged = await sealedEvent(installation.grantId, "x".repeat(43));
    const rejected = await handleLoopdyLinkRequest(await accountHostRequest(
      hostKeys, installation.grantId, installation.hostKeyId, "/events", "POST", forged,
    ), targetEnv);
    expect(rejected.status).toBe(422);
  });

  it("sends a quiet wake that asks the phone to renew its sign-in, at most once per window", async () => {
    const installationKeys = await keys();
    const hostKeys = await keys();
    const installation = await insertInstallation("notification-owned-coordinate", installationKeys, hostKeys);
    const sent: Array<{ body: Record<string, unknown>; key: string | null }> = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
      if (init?.body) {
        sent.push({ body: JSON.parse(String(init.body)) as Record<string, unknown>,
          key: new Headers(init.headers).get("idempotency-key") });
      }
      return Response.json({ success: true, data: { id: "msg_wake", status: "queued", counts: { total: 1 } } });
    });
    const targetEnv = targetEnvironment();
    const wake = () => accountHostRequest(
      hostKeys, installation.grantId, installation.hostKeyId, "/wake", "POST",
      { version: 1, reason: "renew-sign-in" },
    );

    expect((await handleLoopdyLinkRequest(await wake(), targetEnv)).status).toBe(202);
    expect((await handleLoopdyLinkRequest(await wake(), targetEnv)).status).toBe(202);

    expect(sent).toHaveLength(2);
    expect(sent[0]!.body).toMatchObject({
      data: { bighelp_wake: { version: 1, type: "renew-sign-in", grantId: installation.grantId } },
      priority: "normal",
      apns: { payload: { aps: { "content-available": 1 } } },
    });
    for (const field of ["title", "body", "sound", "topic", "deepLink", "action"]) {
      expect(sent[0]!.body).not.toHaveProperty(field);
    }
    // The same key inside a window, so the provider sends it once.
    expect(sent[0]!.key).toMatch(/^bighelp-renew-/);
    expect(sent[1]!.key).toBe(sent[0]!.key);

    for (const invalid of [{ version: 1, reason: "anything" }, { version: 2, reason: "renew-sign-in" },
      { version: 1, reason: "renew-sign-in", text: "no content" }]) {
      const rejected = await handleLoopdyLinkRequest(await accountHostRequest(
        hostKeys, installation.grantId, installation.hostKeyId, "/wake", "POST", invalid,
      ), targetEnv);
      expect(rejected.status).toBe(400);
    }
    expect(sent).toHaveLength(2);
  });

  it("does not wake a phone whose installation was revoked", async () => {
    const installationKeys = await keys();
    const hostKeys = await keys();
    const installation = await insertInstallation("notification-owned-coordinate", installationKeys, hostKeys);
    const provider = vi.spyOn(globalThis, "fetch").mockImplementation(async () => Response.json({
      success: true, data: { id: "msg_wake", status: "queued", counts: { total: 1 } } }));
    await env.ACCOUNTS.prepare(`UPDATE notification_installations
      SET state='revoked',authorization_epoch=authorization_epoch+1,revoked_at=?
      WHERE installation_id=?`).bind(NOW, installation.installationId).run();

    const result = await handleLoopdyLinkRequest(await accountHostRequest(
      hostKeys, installation.grantId, installation.hostKeyId, "/wake", "POST",
      { version: 1, reason: "renew-sign-in" },
    ), targetEnvironment());

    expect(result.status).toBeGreaterThanOrEqual(400);
    expect(provider).not.toHaveBeenCalled();
  });

  it("routes first-enrollment wake without any legacy notification grant", async () => {
    const coordinate = "notification-owned-coordinate";
    const installationKeys = await keys();
    const installation = await insertInstallation(coordinate, installationKeys);
    const binding = await handleLoopdyLinkRequest(await bindingRequest(
      accountKeys, installationKeys, installation.installationId, installation.grantId,
    ), targetEnvironment());
    expect(binding.status).toBe(200);
    const repeatedBinding = await handleLoopdyLinkRequest(await bindingRequest(
      accountKeys, installationKeys, installation.installationId, installation.grantId,
    ), targetEnvironment());
    expect(repeatedBinding.status).toBe(200);
    expect((await env.ACCOUNTS.prepare(
      "SELECT COUNT(*) AS count FROM notification_account_installations WHERE installation_id=?",
    ).bind(installation.installationId).first<{ count: number }>())?.count).toBe(1);
    expect(await env.ACCOUNTS.prepare("SELECT 1 FROM notification_grants WHERE account_coordinate=?")
      .bind(ACCOUNT).first()).toBeNull();
    const calls: Array<Record<string, unknown>> = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
      if (init?.method === "POST") calls.push(JSON.parse(String(init.body)) as Record<string, unknown>);
      return Response.json({
        success: true,
        data: { id: "msg_fixture", status: "queued", counts: { total: 1, sent: 0 } },
      });
    });
    const targetEnv = targetEnvironment();

    const receipts = await sendBuzzKitLinkWake(targetEnv, ACCOUNT, "frame_fixture_0001");

    expect(receipts).toHaveLength(1);
    expect(calls).toHaveLength(1);
    expect(calls[0]?.to).toBe(
      (await buzzKitIdentity(targetEnv, coordinate, "notification-instance")).externalId,
    );
    expect(String(calls[0]?.to)).toMatch(/^notify_/);
  });

  it("routes wake to every explicitly bound active installation", async () => {
    const firstKeys = await keys();
    const secondKeys = await keys();
    const first = await insertInstallation("notification-owned-coordinate-a", firstKeys);
    const second = await insertInstallation("notification-owned-coordinate-b", secondKeys);
    for (const [installationKeys, installation] of [[firstKeys, first], [secondKeys, second]] as const) {
      const response = await handleLoopdyLinkRequest(await bindingRequest(
        accountKeys, installationKeys, installation.installationId, installation.grantId,
      ), targetEnvironment());
      expect(response.status).toBe(200);
    }
    const calls: Array<Record<string, unknown>> = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
      if (init?.method === "POST") calls.push(JSON.parse(String(init.body)) as Record<string, unknown>);
      return Response.json({ success: true, data: {
        id: `msg_fixture_${calls.length}`, status: "queued", counts: { total: 1, sent: 0 },
      } });
    });
    const targetEnv = targetEnvironment();

    const receipts = await sendBuzzKitLinkWake(targetEnv, ACCOUNT, "frame_fixture_0001");

    expect(receipts).toHaveLength(2);
    expect(calls.map((call) => call.to).sort()).toEqual((await Promise.all([
      buzzKitIdentity(targetEnv, "notification-owned-coordinate-a", "notification-instance"),
      buzzKitIdentity(targetEnv, "notification-owned-coordinate-b", "notification-instance"),
    ])).map((identity) => identity.externalId).sort());

    await env.ACCOUNTS.prepare(`UPDATE notification_installations
      SET state='revoked',authorization_epoch=authorization_epoch+1,revoked_at=?
      WHERE installation_id=?`).bind(NOW, first.installationId).run();
    calls.length = 0;
    const remaining = await sendBuzzKitLinkWake(targetEnv, ACCOUNT, "frame_fixture_0002");
    expect(remaining).toHaveLength(1);
    expect(calls.map((call) => call.to)).toEqual([
      (await buzzKitIdentity(
        targetEnv, "notification-owned-coordinate-b", "notification-instance",
      )).externalId,
    ]);
  });

  it.each(["grant-revoked", "grant-expired"] as const)(
    "rechecks recipient authority before wake egress when the %s after selection",
    async (race) => {
      const coordinate = "notification-owned-coordinate";
      const installationKeys = await keys();
      const installation = await insertInstallation(coordinate, installationKeys);
      const binding = await handleLoopdyLinkRequest(await bindingRequest(
        accountKeys, installationKeys, installation.installationId, installation.grantId,
      ), targetEnvironment());
      expect(binding.status).toBe(200);
      interceptRecipientPreparation(async () => {
        if (race === "grant-revoked") {
          await env.ACCOUNTS.prepare(
            "UPDATE notification_instance_grants SET state='revoked' WHERE grant_id=?",
          ).bind(installation.grantId).run();
        } else {
          vi.spyOn(Date, "now").mockReturnValue((NOW + 1_801) * 1_000);
        }
      });
      const provider = vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({
        success: true,
        data: { id: "msg_stale_wake", status: "queued", counts: { total: 1, sent: 0 } },
      }));

      await expect(sendBuzzKitLinkWake(targetEnvironment(), ACCOUNT, "frame_fixture_0001"))
        .rejects.toMatchObject({ status: 503, code: "link_wake_recipient_unavailable" });
      expect(provider).not.toHaveBeenCalled();
    },
  );

  it("rechecks wake authority changed after the first final-fence read", async () => {
    const coordinate = "notification-owned-coordinate";
    const installationKeys = await keys();
    const installation = await insertInstallation(coordinate, installationKeys);
    const binding = await handleLoopdyLinkRequest(await bindingRequest(
      accountKeys, installationKeys, installation.installationId, installation.grantId,
    ), targetEnvironment());
    expect(binding.status).toBe(200);
    const accounts = afterD1Query(
      env.ACCOUNTS,
      "SELECT binding.notification_coordinate AS owner_coordinate",
      2,
      async () => {
        await env.ACCOUNTS.prepare(
          "UPDATE notification_instance_grants SET state='revoked' WHERE grant_id=?",
        ).bind(installation.grantId).run();
      },
    );
    const provider = vi.spyOn(globalThis, "fetch").mockImplementation(async () => Response.json({
      success: true,
      data: { id: "msg_wake_intra_fence", status: "queued", counts: { total: 1, sent: 0 } },
    }));

    await expect(sendBuzzKitLinkWake(
      targetEnvironment({}, accounts), ACCOUNT, "frame_fixture_0001",
    )).rejects.toMatchObject({ status: 503, code: "link_wake_recipient_unavailable" });
    expect(provider).not.toHaveBeenCalled();
  });

  it("uses the recipient owner decision after D1 wake discovery", async () => {
    const coordinate = "notification-owned-coordinate";
    const installationKeys = await keys();
    const installation = await insertInstallation(coordinate, installationKeys);
    const binding = await handleLoopdyLinkRequest(await bindingRequest(
      accountKeys, installationKeys, installation.installationId, installation.grantId,
    ), targetEnvironment());
    expect(binding.status).toBe(200);
    const realStub = notificationOwnerStub(coordinate);
    await realStub.authorizeNotificationEgress({
      ownerKind: "notification-instance",
      credentialId: installation.installationId,
      authorizationEpoch: 1,
      now: NOW,
      grant: { grantId: installation.grantId, revision: 1, expiresAt: NOW + 1_800 },
    });
    const accounts = afterD1Query(
      env.ACCOUNTS,
      "SELECT binding.notification_coordinate AS owner_coordinate",
      1,
      async () => {
        await realStub.revokeNotificationGrantAuthority({
          grantId: installation.grantId,
          credentialId: installation.installationId,
          authorizationEpoch: 1,
          revision: 1,
        });
      },
    );
    const provider = vi.spyOn(globalThis, "fetch").mockImplementation(async () => Response.json({
      success: true,
      data: { id: "msg_revoked_recipient_owner", status: "queued", counts: { total: 1, sent: 0 } },
    }));

    await expect(sendBuzzKitLinkWake(
      targetEnvironment({
        authorizeNotificationEgress: (input: Parameters<typeof realStub.authorizeNotificationEgress>[0]) =>
          realStub.authorizeNotificationEgress(input),
      }, accounts),
      ACCOUNT,
      "frame_fixture_0001",
    )).rejects.toMatchObject({ code: "notification_grant_inactive" });
    expect(provider).not.toHaveBeenCalled();
  });

  it("rechecks source-host authority before each wake provider POST", async () => {
    const coordinate = "notification-owned-coordinate";
    const installationKeys = await keys();
    const installation = await insertInstallation(coordinate, installationKeys);
    const binding = await handleLoopdyLinkRequest(await bindingRequest(
      accountKeys, installationKeys, installation.installationId, installation.grantId,
    ), targetEnvironment());
    expect(binding.status).toBe(200);
    const accounts = afterD1Query(
      env.ACCOUNTS,
      "SELECT binding.notification_coordinate AS owner_coordinate",
      2,
      async () => {
        await env.ACCOUNTS.prepare(`UPDATE device_directory
          SET status='revoked',authorization_epoch=authorization_epoch+1,revoked_at=?
          WHERE device_id=?`).bind(NOW, HOST).run();
      },
    );
    let localFenceCalls = 0;
    const provider = vi.spyOn(globalThis, "fetch").mockImplementation(async () => Response.json({
      success: true,
      data: { id: "msg_source_host_race", status: "queued", counts: { total: 1, sent: 0 } },
    }));

    await expect(sendWakeWithSource(
      targetEnvironment({}, accounts), ACCOUNT, "frame_fixture_0001", {
        hostDeviceId: HOST,
        authorizationEpoch: 1,
        authorizeEgress: () => { localFenceCalls += 1; },
      },
    )).rejects.toMatchObject({ status: 503, code: "link_wake_recipient_unavailable" });
    expect(localFenceCalls).toBe(0);
    expect(provider).not.toHaveBeenCalled();
  });

  it("rejects account authority without possession of the installation key", async () => {
    const installationKeys = await keys();
    const installation = await insertInstallation("notification-owned-coordinate", installationKeys);

    const response = await handleLoopdyLinkRequest(await bindingRequest(
      accountKeys, await keys(), installation.installationId, installation.grantId,
    ), targetEnvironment());

    expect(response.status).toBe(401);
    expect(await env.ACCOUNTS.prepare(
      "SELECT installation_id FROM notification_account_installations WHERE installation_id=?",
    ).bind(installation.installationId).first()).toBeNull();
  });

  it("requires a currently active installation grant before binding", async () => {
    const installationKeys = await keys();
    const installation = await insertInstallation("notification-owned-coordinate", installationKeys);
    await env.ACCOUNTS.prepare(
      "UPDATE notification_instance_grants SET state='revoked' WHERE grant_id=?",
    ).bind(installation.grantId).run();

    const response = await handleLoopdyLinkRequest(await bindingRequest(
      accountKeys, installationKeys, installation.installationId, installation.grantId,
    ), targetEnvironment());

    expect(response.status).toBe(403);
    expect(await env.ACCOUNTS.prepare(
      "SELECT installation_id FROM notification_account_installations WHERE installation_id=?",
    ).bind(installation.installationId).first()).toBeNull();
  });
});
