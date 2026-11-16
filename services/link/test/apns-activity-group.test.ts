import { env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { apnsIdFor, resetApnsTokenCache } from "../src/apns.js";
import { ACTIVITY_END_DELAY_SECONDS, activityMomentAlert } from "../src/activity-group.js";
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
  const send = (row: Awaited<ReturnType<typeof register>>, phase: string,
    more: { sealed?: string; quiet?: boolean; timestamp?: number } = {}) =>
    runInDurableObject<UserLink, unknown>(stub, async (instance) => instance.sendNotificationActivityGroup({
      ownerCoordinate, activityId: row.activity.activityId,
      state: { id: row.activity.rowId!, phase, timestamp: more.timestamp ?? now(), activeSubagentCount: 0,
        ...(more.sealed ? { sealed: more.sealed } : {}) },
      ...(more.quiet ? { quiet: true } : {}),
      externalId: "fixture-recipient", authority: { ...row.authority, activity: {
        activityId: row.activity.activityId, sessionReference: row.activity.sessionReference,
        leaseExpires: row.activity.leaseExpires,
      } },
    }));
  return { stub, groupId, credentialId, addTarget, register, send };
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

  it("forwards a row's sealed detail as it came, and a new step alone at low priority", async () => {
    const f = await fixture("on");
    await f.addTarget(f.groupId);
    const a = await f.register(1);
    await f.register(2);
    const sealed = "c".repeat(600);
    await f.send(a, "using_tool", { sealed });
    expect(sent[0]!.headers.get("apns-priority")).toBe("10");
    await f.send(a, "using_tool", { sealed: "d".repeat(600), quiet: true });
    expect(sent[1]!.headers.get("apns-priority")).toBe("5");
    const rows = sent[1]!.body.aps["content-state"].sessions as Array<{ id: string; sealed?: string }>;
    expect(rows.find((row) => row.id === rowId(1))?.sealed).toBe("d".repeat(600));
    expect(rows.find((row) => row.id === rowId(2))).not.toHaveProperty("sealed");
  });

  it("ends the card at once, with a dismissal date, when a chat that was already finished is resent last", async () => {
    // A group whose last chat finished before moments existed has no pending end: it ends as it always did.
    const f = await fixture("on");
    await f.addTarget(f.groupId);
    const a = await f.register(1);
    const timestamp = now();
    await runInDurableObject<UserLink, void>(f.stub, (_instance, state) => {
      state.storage.sql.exec("UPDATE managed_activity_rows SET state_json=? WHERE activity_id=?",
        JSON.stringify({ id: a.activity.rowId, phase: "completed", timestamp, activeSubagentCount: 0 }), a.activity.activityId);
    });
    await f.send(a, "completed", { timestamp });
    const aps = sent[0]!.body.aps;
    expect(aps).toMatchObject({ event: "end", "content-state": { activeCount: 0 } });
    expect(aps["dismissal-date"]).toBe(aps.timestamp + 30);
    expect(aps).not.toHaveProperty("alert");
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

// MARK: Moments

describe("a chat's moment on the shared card", () => {
  const apsOf = (index: number) => sent[index]!.body.aps;
  const priorityOf = (index: number) => sent[index]!.headers.get("apns-priority");
  /** Moves the clock past the deferred end's wait, runs the Durable Object's alarm, then lets the clock go on. */
  const runAlarmAfterWait = async (stub: DurableObjectStub<UserLink>) => {
    const clock = vi.spyOn(Date, "now").mockReturnValue(Date.now() + (ACTIVITY_END_DELAY_SECONDS + 1) * 1_000);
    try { return await runDurableObjectAlarm(stub); } finally { clock.mockRestore(); }
  };

  it("pushes an alert, silent, with the waiting chat first, when a chat starts waiting", async () => {
    const f = await fixture("on");
    await f.addTarget(f.groupId);
    await f.register(1);
    const b = await f.register(2);
    await f.send(b, "waiting");
    expect(apsOf(0).event).toBe("update");
    expect(apsOf(0).alert).toEqual(activityMomentAlert("waiting"));
    expect(apsOf(0).alert).toEqual({ title: "Bighelp", body: "A chat needs you." });
    expect(apsOf(0)).not.toHaveProperty("sound");
    expect(apsOf(0)["content-state"]).toMatchObject({ lead: rowId(2), activeCount: 2 });
    expect(apsOf(0)["content-state"].sessions[0].id).toBe(rowId(2));
    expect(priorityOf(0)).toBe("10");
  });

  it("sends no alert when the host resends the same waiting state", async () => {
    const f = await fixture("on");
    await f.addTarget(f.groupId);
    const a = await f.register(1);
    const timestamp = now();
    await f.send(a, "waiting", { timestamp });
    await f.send(a, "waiting", { timestamp: timestamp + 60 });
    expect(apsOf(0)).toHaveProperty("alert");
    expect(apsOf(1)).not.toHaveProperty("alert");
    expect(apsOf(1)["content-state"]).not.toHaveProperty("lead");
  });

  it("sends no alert for a step, and says nothing about a chat that is not the news", async () => {
    const f = await fixture("on");
    await f.addTarget(f.groupId);
    const a = await f.register(1);
    await f.send(a, "using_tool");
    await f.send(a, "responding");
    expect(sent.map((call) => call.body.aps)).toSatisfy((all: Array<Record<string, unknown>>) =>
      all.every((aps) => !("alert" in aps) && !("lead" in (aps["content-state"] as object))));
  });

  it("names the chat that finished while another still works, and keeps the card up", async () => {
    const f = await fixture("on");
    await f.addTarget(f.groupId);
    const a = await f.register(1);
    await f.register(2);
    await f.send(a, "completed");
    expect(apsOf(0).event).toBe("update");
    expect(apsOf(0).alert).toEqual({ title: "Bighelp", body: "A chat finished." });
    expect(apsOf(0)["content-state"]).toMatchObject({ lead: rowId(1), activeCount: 1 });
    // Without the lead, the finished chat would sort after the one that still works.
    expect(apsOf(0)["content-state"].sessions.map((row: { id: string }) => row.id)).toEqual([rowId(1), rowId(2)]);
    await runAlarmAfterWait(f.stub);
    expect(sent).toHaveLength(1);
  });

  it("says a chat could not finish", async () => {
    const f = await fixture("on");
    await f.addTarget(f.groupId);
    const a = await f.register(1);
    await f.register(2);
    await f.send(a, "failed");
    expect(apsOf(0).alert).toEqual({ title: "Bighelp", body: "A chat could not finish." });
    expect(apsOf(0)["content-state"]).toMatchObject({ lead: rowId(1) });
  });

  it("keeps a moment at high priority even when the host marks the update quiet", async () => {
    const f = await fixture("on");
    await f.addTarget(f.groupId);
    const a = await f.register(1);
    const b = await f.register(2);
    await f.send(a, "waiting", { quiet: true });
    expect(priorityOf(0)).toBe("10");
    await f.send(b, "completed", { quiet: true });
    expect(priorityOf(1)).toBe("10");
  });

  it("updates, then ends 30 seconds later and at once, when the last chat finishes", async () => {
    const f = await fixture("on");
    await f.addTarget(f.groupId);
    const a = await f.register(1);
    await f.send(a, "completed");
    expect(apsOf(0).event).toBe("update");
    expect(apsOf(0)).not.toHaveProperty("dismissal-date");
    expect(apsOf(0).alert).toEqual({ title: "Bighelp", body: "A chat finished." });
    expect(apsOf(0)["content-state"]).toMatchObject({ activeCount: 0, lead: rowId(1) });
    expect(sent).toHaveLength(1);
    // The alarm is set for the end, ahead of the hour-away lease purge registration set.
    await runInDurableObject<UserLink, void>(f.stub, async (_instance, state) => {
      expect(await state.storage.getAlarm()).toBeLessThanOrEqual(Date.now() + (ACTIVITY_END_DELAY_SECONDS + 2) * 1_000);
    });

    expect(await runAlarmAfterWait(f.stub)).toBe(true);
    expect(sent).toHaveLength(2);
    const end = apsOf(1);
    expect(end).toMatchObject({ event: "end", "content-state": { activeCount: 0 } });
    expect(end).not.toHaveProperty("alert");
    expect(end.timestamp).toBeGreaterThanOrEqual(apsOf(0).timestamp + ACTIVITY_END_DELAY_SECONDS);
    // The card leaves now, not 30 seconds from now.
    expect(end["dismissal-date"]).toBeLessThanOrEqual(end.timestamp);
    await runInDurableObject<UserLink, void>(f.stub, (_instance, state) => {
      expect(state.storage.sql.exec("SELECT COUNT(*) AS count FROM managed_activity_pending_ends").one().count).toBe(0);
    });
    // The group has ended: no chat can join it now.
    await expect(f.register(2)).rejects.toThrow();
  });

  it("does not end the card when a chat started working before the wait was over", async () => {
    const f = await fixture("on");
    await f.addTarget(f.groupId);
    const a = await f.register(1);
    await f.send(a, "completed");
    await f.register(2);
    expect(await runAlarmAfterWait(f.stub)).toBe(true);
    expect(sent).toHaveLength(1);
    expect(order).toEqual(["apns"]);
  });

  it("does not end the card early when the host resends the finished chat", async () => {
    const f = await fixture("on");
    await f.addTarget(f.groupId);
    const a = await f.register(1);
    const timestamp = now();
    await f.send(a, "completed", { timestamp });
    await f.send(a, "completed", { timestamp });
    expect(apsOf(1).event).toBe("update");
    expect(apsOf(1)).not.toHaveProperty("alert");
    expect(apsOf(1)).not.toHaveProperty("dismissal-date");
    expect(await runAlarmAfterWait(f.stub)).toBe(true);
    expect(sent).toHaveLength(3);
    expect(apsOf(2).event).toBe("end");
  });

  it("sends nothing for an end whose credential was revoked in the wait", async () => {
    const f = await fixture("on");
    await f.addTarget(f.groupId);
    const a = await f.register(1);
    await f.send(a, "completed");
    await f.stub.revokeNotificationCredential({ credentialId: f.credentialId, authorizationEpoch: 2 });
    await runAlarmAfterWait(f.stub);
    expect(sent).toHaveLength(1);
    await runInDurableObject<UserLink, void>(f.stub, (_instance, state) => {
      expect(state.storage.sql.exec("SELECT COUNT(*) AS count FROM managed_activity_pending_ends").one().count).toBe(0);
    });
  });
});
