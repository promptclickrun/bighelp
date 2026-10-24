import { env, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { apnsIdFor, resetApnsTokenCache } from "../src/apns.js";
import { resetApnsBreaker } from "../src/push-delivery.js";
import { putPushTarget } from "../src/push-targets.js";
import type { NotificationActivity, NotificationEgressSnapshot } from "../src/notification-grants.js";
import type { LinkEnv, UserLink } from "../src/user-link.js";

// The direct path for the shared chat Live Activity (PR #575): one physical card per group ID.
const now = () => Math.floor(Date.now() / 1_000);
const rowId = (n: number) => `native-${String(n).padStart(43, "a")}`;
const TOKEN = "ab".repeat(32);

async function throwawayP8(): Promise<string> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey) as ArrayBuffer);
  return `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der)).match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----`;
}

interface Sent { host: string; url: string; headers: Headers; body: Record<string, any> }
let sent: Sent[];
let order: string[];
let apnsAnswers: Array<{ status: number; reason?: string }>;
let pem: string;
let tokenKey: string;
const queue = { send: vi.fn(async () => {}) };

beforeEach(async () => {
  pem = pem ?? await throwawayP8();
  tokenKey = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))));
  sent = []; order = []; apnsAnswers = [];
  await env.ACCOUNTS.batch([env.ACCOUNTS.prepare("DELETE FROM push_sends")]);
  queue.send.mockClear();
  resetApnsTokenCache();
  resetApnsBreaker();
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const url = new URL(String(input));
    const entry = { host: url.hostname, url: url.toString(), headers: new Headers(init?.headers),
      body: JSON.parse(String(init?.body)) as Record<string, any> };
    sent.push(entry);
    if (url.hostname.endsWith("push.apple.com")) {
      order.push("apns");
      const answer = apnsAnswers.shift() ?? { status: 200 };
      return new Response(answer.reason ? JSON.stringify({ reason: answer.reason }) : null, { status: answer.status });
    }
    order.push("buzzkit");
    return Response.json({ success: true, data: { results: [{ id: "group-receipt", ok: true }] } });
  });
});
afterEach(() => vi.restoreAllMocks());

async function fixture(mode: "off" | "on") {
  const ownerCoordinate = `activity-group-${crypto.randomUUID()}`;
  const stub = env.USER_LINKS.getByName(ownerCoordinate);
  const credentialId = crypto.randomUUID();
  const groupId = crypto.randomUUID();
  const expiresAt = now() + 3600;
  await env.ACCOUNTS.prepare(`INSERT INTO notification_installations(
    installation_id,notification_coordinate,public_key_spki,authorization_epoch,
    bootstrap_request_id,bootstrap_request_digest,state,created_at)
    VALUES(?,?,?,1,?,?,'active',?)`).bind(credentialId, ownerCoordinate, "fixture-key",
      crypto.randomUUID(), "fixture-digest", now()).run();
  await runInDurableObject<UserLink, void>(stub, (instance) => {
    Object.assign((instance as unknown as { env: LinkEnv }).env, {
      BUZZKIT_API_KEY: "bk_fixture_group_key", BUZZKIT_IDENTITY_SECRET: "fixture-secret",
      BUZZKIT_IDENTITY_SECRET_GENERATION: "notification-instance-v2",
      APNS_KEY_P8: pem, APNS_KEY_ID: "ABC123DEFG", APNS_TEAM_ID: "TEAM123456", PUSH_TOKEN_KEY: tokenKey,
      DIRECT_APNS: mode, APNS_RETRY: queue,
    });
  });
  const targetEnv = { ...env, PUSH_TOKEN_KEY: tokenKey } as LinkEnv;
  const addTarget = (activityId: string, environment: "sandbox" | "production" = "production") =>
    putPushTarget(targetEnv, { installationId: credentialId, ownerCoordinate, authorizationEpoch: 1 },
      { kind: "liveactivity", activityId, token: TOKEN, environment, appVersion: "" }, now());
  const register = async (n: number, alias = `activity-${n}`) => {
    const grantId = crypto.randomUUID();
    const authority: NotificationEgressSnapshot = {
      ownerKind: "notification-instance", credentialId, authorizationEpoch: 1, now: now(),
      grant: { grantId, revision: 1, expiresAt },
    };
    await env.ACCOUNTS.prepare(`INSERT OR IGNORE INTO notification_instance_grants(
      grant_id,notification_coordinate,installation_id,authorization_epoch,idempotency_key,
      request_digest,public_json,state,revision,created_at,expires_at)
      VALUES(?,?,?,1,?,?,?,'active',1,?,?)`).bind(grantId, ownerCoordinate, credentialId,
        crypto.randomUUID(), "fixture-digest", "{}", now(), expiresAt).run();
    const input = { grantId, activityId: alias, sessionReference: String(n).padStart(43, "s"),
      revision: 1, leaseExpires: expiresAt, status: "active" as const, timestamp: now(),
      groupId, rowId: rowId(n), rowRevision: 1, credentialId, authority };
    await runInDurableObject<UserLink, void>(stub, async (instance) => { await instance.registerNotificationActivity(input); });
    return { activity: input as NotificationActivity, authority };
  };
  const send = (row: Awaited<ReturnType<typeof register>>, phase: string) =>
    runInDurableObject<UserLink, unknown>(stub, async (instance) => instance.sendNotificationActivityGroup({
      ownerCoordinate, activityId: row.activity.activityId,
      state: { id: row.activity.rowId!, phase, timestamp: now(), activeSubagentCount: 0 },
      externalId: "fixture-recipient", authority: { ...row.authority, activity: {
        activityId: row.activity.activityId, sessionReference: row.activity.sessionReference,
        leaseExpires: row.activity.leaseExpires,
      } },
    }));
  return { groupId, credentialId, addTarget, register, send };
}

describe("direct delivery of the shared chat Live Activity", () => {
  it("sends the aggregate to the token registered under the physical group ID", async () => {
    const f = await fixture("on");
    await f.addTarget(f.groupId);
    const a = await f.register(1);
    await f.register(2);
    const receipt = await f.send(a, "thinking") as { status: string; deliveryId: string };
    expect(order).toEqual(["apns"]);
    const [call] = sent;
    expect(call!.host).toBe("api.push.apple.com");
    expect(call!.url).toContain(`/3/device/${TOKEN}`);
    expect(call!.headers.get("apns-push-type")).toBe("liveactivity");
    expect(call!.headers.get("apns-topic")).toBe("app.loopdy.mobile.push-type.liveactivity");
    expect(call!.headers.get("apns-collapse-id")).toBeNull();
    const aps = call!.body.aps;
    expect(aps.event).toBe("update");
    expect(aps["content-state"]).toMatchObject({ groupId: f.groupId, activeCount: 2 });
    expect(aps["content-state"].sessions.map((row: { id: string }) => row.id).sort()).toEqual([rowId(1), rowId(2)]);
    expect(aps["stale-date"]).toBe(aps.timestamp + 120);
    expect(aps).not.toHaveProperty("dismissal-date");
    expect(receipt).toMatchObject({ status: "accepted", deliveryId: call!.headers.get("apns-id") });
    expect(call!.headers.get("apns-id")).toBe(await apnsIdFor(`${f.credentialId}|liveactivity|${f.groupId}|${aps.timestamp}`));
  });

  it("ends the card with a dismissal date only when no chat is left", async () => {
    const f = await fixture("on");
    await f.addTarget(f.groupId);
    const a = await f.register(1);
    await f.send(a, "completed");
    const aps = sent[0]!.body.aps;
    expect(aps).toMatchObject({ event: "end", "content-state": { activeCount: 0 } });
    expect(aps["dismissal-date"]).toBe(aps.timestamp + 30);
  });

  it("ignores a token registered under a chat's own alias: the card is addressed by its group", async () => {
    const f = await fixture("on");
    await f.addTarget("activity-1");
    const a = await f.register(1);
    await f.send(a, "thinking");
    expect(order).toEqual(["buzzkit"]);
  });

  it("goes through BuzzKit, never the queue, when APNs can't take the push", async () => {
    const f = await fixture("on");
    await f.addTarget(f.groupId);
    const a = await f.register(1);
    apnsAnswers.push({ status: 503, reason: "ServiceUnavailable" });
    await f.send(a, "thinking");
    expect(order).toEqual(["apns", "buzzkit"]);
    expect(queue.send).not.toHaveBeenCalled();
    // BuzzKit gets the same aggregate the direct push carried.
    expect(sent[1]!.body).toMatchObject({ activityId: f.groupId, event: "update", contentState: sent[0]!.body.aps["content-state"] });
  });

  it("asks for the group's authority again for the BuzzKit fallback, and reserves the send once", async () => {
    const f = await fixture("on");
    await f.addTarget(f.groupId);
    const a = await f.register(1);
    apnsAnswers.push({ status: 410, reason: "Unregistered" });
    await f.send(a, "thinking");
    expect(order).toEqual(["apns", "buzzkit"]);
    // Next update: the dead token is no longer used.
    await f.send(a, "responding");
    expect(order).toEqual(["apns", "buzzkit", "buzzkit"]);
  });

  it("sends nothing directly, and BuzzKit exactly what it did, when DIRECT_APNS is off", async () => {
    const off = await fixture("off");
    await off.addTarget(off.groupId);
    const a = await off.register(1);
    await off.register(2);
    await off.send(a, "thinking");
    expect(order).toEqual(["buzzkit"]);
    const body = sent[0]!.body;
    expect(Object.keys(body).sort()).toEqual(["activityId", "contentState", "event", "priority", "staleDate", "timestamp", "to"]);
    expect(body).toMatchObject({
      to: "fixture-recipient", activityId: off.groupId, event: "update", priority: "high",
      staleDate: new Date((body.timestamp + 120) * 1_000).toISOString(),
      contentState: { groupId: off.groupId, activeCount: 2 },
    });
    expect(await env.ACCOUNTS.prepare("SELECT COUNT(*) AS n FROM push_sends").first()).toEqual({ n: 0 });
  });
});
