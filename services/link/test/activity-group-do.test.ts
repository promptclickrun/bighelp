import { env, evictDurableObject, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { UserLinkNotificationStore } from "../src/user-link-notifications.js";
import type { LinkEnv, UserLink } from "../src/user-link.js";
import type { NotificationActivity, NotificationEgressSnapshot } from "../src/notification-grants.js";

const now = () => Math.floor(Date.now() / 1_000);
// The format the app sends: "native-" and a SHA-256 in hex. Real digests differ in their last
// 16 characters, which the card uses to list active chats, so these do too.
const rowToken = (n: number) => n.toString(16).padStart(16, "0");
const rowId = (n: number) => `native-${"ab".repeat(24)}${rowToken(n)}`;
const providerReceipt = () => Response.json({ success: true, data: { results: [{ id: "fixture-receipt", ok: true }] } });
type Payload = { activityId: string; event: string; timestamp: number; contentState: { activeCount: number; activeRows: string[]; sessions: { id: string; phase: string }[] } };
afterEach(() => vi.restoreAllMocks());

async function fixture() {
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
  const authority = (grantId: string): NotificationEgressSnapshot => ({
    ownerKind: "notification-instance", credentialId, authorizationEpoch: 1, now: now(),
    grant: { grantId, revision: 1, expiresAt },
  });
  const configure = () => runInDurableObject<UserLink, void>(stub, (instance) => {
    Object.assign((instance as unknown as { env: LinkEnv }).env, { BUZZKIT_API_KEY: "bk_fixture_group_key",
      BUZZKIT_IDENTITY_SECRET_GENERATION: "notification-instance-v2" });
  });
  await configure();
  const register = async (n: number, grantId = crypto.randomUUID(), alias = `activity-${n}`, rowRevision = 1) => {
    const auth = authority(grantId);
    await env.ACCOUNTS.prepare(`INSERT OR IGNORE INTO notification_instance_grants(
      grant_id,notification_coordinate,installation_id,authorization_epoch,idempotency_key,
      request_digest,public_json,state,revision,created_at,expires_at)
      VALUES(?,?,?,1,?,?,?,'active',1,?,?)`).bind(grantId, ownerCoordinate, credentialId,
        crypto.randomUUID(), "fixture-digest", "{}", now(), expiresAt).run();
    const input = { grantId, activityId: alias, sessionReference: String(n).padStart(43, "s"),
      revision: 1, leaseExpires: auth.grant!.expiresAt, status: "active" as const, timestamp: now(),
      groupId, rowId: rowId(n), rowRevision, credentialId, authority: auth };
    await runInDurableObject<UserLink, void>(stub, async (instance) => {
      await instance.registerNotificationActivity(input);
    });
    return { activity: input, authority: auth };
  };
  const send = async (row: { activity: NotificationActivity; authority: NotificationEgressSnapshot }, phase: string, timestamp = now()) => {
    return runInDurableObject<UserLink, void>(stub, async (instance) => {
      await instance.sendNotificationActivityGroup({ ownerCoordinate, activityId: row.activity.activityId,
        state: { id: row.activity.rowId!, phase, timestamp, activeSubagentCount: 0 },
        externalId: "fixture-recipient", authority: { ...row.authority, activity: {
          activityId: row.activity.activityId, sessionReference: row.activity.sessionReference,
          leaseExpires: row.activity.leaseExpires,
        } },
      });
    });
  };
  const payloads: Payload[] = [];
  vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
    payloads.push(JSON.parse(String(init?.body)) as Payload);
    return providerReceipt();
  });
  return { stub, credentialId, groupId, register, send, payloads, configure };
}

describe("shared activity owner integration", () => {
  it("keeps a newly registered second grant active before its first host update", async () => {
    const f = await fixture();
    const a = await f.register(1);
    await f.register(2);
    await f.send(a, "completed");
    expect(f.payloads[0]).toMatchObject({ event: "update", contentState: { activeCount: 1 } });
    expect(f.payloads[0]!.contentState.sessions.map((r) => r.id)).toContain(rowId(2));
  });

  it("permanently supersedes the previous alias of the same chat, even in the same second", async () => {
    const f = await fixture();
    const old = await f.register(1);
    const current = await f.register(1, old.activity.grantId, "new-turn", 2);
    await expect(f.send(old, "completed", now() + 1)).rejects.toThrow();
    await f.send(current, "thinking");
    expect(f.payloads).toHaveLength(1);
    expect(f.payloads[0]).toMatchObject({ event: "update", contentState: { activeCount: 1 } });
  });

  it("rejects an unseen delayed first registration of an older turn", async () => {
    const f = await fixture();
    const current = await f.register(1, crypto.randomUUID(), "new-turn", 2);
    const staleGrant = crypto.randomUUID();
    await expect(f.register(1, staleGrant, "never-seen-old-turn", 1)).rejects.toThrow();
    await runInDurableObject<UserLink, void>(f.stub, (_instance, state) => {
      expect(state.storage.sql.exec("SELECT COUNT(*) AS count FROM managed_notification_grants WHERE grant_id=?", staleGrant).one().count).toBe(0);
    });
    await f.send(current, "waiting");
    expect(f.payloads[0]).toMatchObject({ activityId: f.groupId, event: "update", contentState: { activeCount: 1 } });
  });

  it("retains the row generation high-water after pruning its terminal history", async () => {
    const f = await fixture();
    const old = await f.register(0, crypto.randomUUID(), "new-turn", 2);
    await runInDurableObject<UserLink, void>(f.stub, (_instance, state) => {
      state.storage.sql.exec("UPDATE managed_notification_activities SET status='ended' WHERE activity_id=?", old.activity.activityId);
    });
    for (let n = 1; n <= 64; n++) await f.register(n, old.activity.grantId);
    await runInDurableObject<UserLink, void>(f.stub, (_instance, state) => {
      expect(state.storage.sql.exec("SELECT COUNT(*) AS count FROM managed_activity_rows WHERE activity_id=?", old.activity.activityId).one().count).toBe(0);
    });
    await f.stub.revokeNotificationActivity({ grantId: old.activity.grantId,
      activityId: "activity-64", revision: 2, timestamp: now() });
    await expect(f.register(0, old.activity.grantId, "late-older-turn", 1)).rejects.toThrow();
  });

  it("uses the physical group ID at the provider boundary", async () => {
    const f = await fixture();
    const a = await f.register(1);
    await f.send(a, "thinking");
    expect(f.payloads[0]!.activityId).toBe(f.groupId);
  });

  it("keeps active work ahead of more than 64 completed or failed rows", async () => {
    const f = await fixture();
    const active = await f.register(0);
    for (let n = 1; n <= 70; n++) {
      const row = await f.register(n, active.activity.grantId);
      await runInDurableObject<UserLink, void>(f.stub, (_instance, state) => {
        state.storage.sql.exec("UPDATE managed_activity_rows SET state_json=? WHERE activity_id=?",
          JSON.stringify({ id: rowId(n), phase: "failed", timestamp: now(), activeSubagentCount: 0 }), row.activity.activityId);
        state.storage.sql.exec("UPDATE managed_notification_activities SET status='ended',updated_at=? WHERE activity_id=?", now() + n, row.activity.activityId);
      });
    }
    await runInDurableObject<UserLink, void>(f.stub, (_instance, state) => {
      expect(state.storage.sql.exec("SELECT COUNT(*) AS count FROM managed_activity_rows").one().count).toBeLessThanOrEqual(64);
    });
    await f.send(active, "thinking");
    expect(f.payloads[0]).toMatchObject({ event: "update", contentState: { activeCount: 1 } });
    expect(f.payloads[0]!.contentState.sessions[0]).toMatchObject({ id: rowId(0), phase: "thinking" });
  });

  it("never turns a pruned pending terminal alias into a legacy single-card sender", async () => {
    const f = await fixture();
    const first = await f.register(0);
    for (let n = 1; n < 64; n++) await f.register(n, first.activity.grantId);
    await runInDurableObject<UserLink, void>(f.stub, (_instance, state) => {
      // A terminal state persists before provider confirmation, while its alias is active.
      state.storage.sql.exec("UPDATE managed_activity_rows SET state_json=? WHERE activity_id=?",
        JSON.stringify({ id: rowId(0), phase: "completed", timestamp: now(), activeSubagentCount: 0 }), first.activity.activityId);
    });
    await f.register(64, first.activity.grantId);
    const old = await f.stub.notificationActivity({ grantId: first.activity.grantId,
      activityId: first.activity.activityId, now: now() });
    expect(old.status).not.toBe("active");
    await expect(f.send(first, "completed")).rejects.toThrow();
    expect(f.payloads).toHaveLength(0);
  });

  it("rejects overflow instead of silently omitting active work", async () => {
    const f = await fixture();
    const first = await f.register(0);
    for (let n = 1; n < 64; n++) await f.register(n, first.activity.grantId);
    await expect(f.register(64, first.activity.grantId)).rejects.toThrow();
    await f.send(first, "thinking");
    expect(f.payloads[0]!.contentState.activeCount).toBe(64);
    expect(f.payloads[0]!.contentState.activeRows).toHaveLength(64);
    expect(f.payloads[0]!.contentState.activeRows).toContain(rowToken(63));
    expect(f.payloads[0]!.contentState.sessions).toHaveLength(5);
  });

  it("persists physical delivery timestamps across object eviction", async () => {
    const f = await fixture();
    const a = await f.register(1);
    await f.send(a, "thinking");
    await evictDurableObject(f.stub);
    await f.configure();
    vi.spyOn(Date, "now").mockReturnValue(f.payloads[0]!.timestamp * 1000 + 999);
    await f.send(a, "waiting");
    expect(f.payloads[1]!.timestamp).toBeGreaterThan(f.payloads[0]!.timestamp);
  }, 20_000);

  it("excludes a different grant revoked while a physical send is queued", async () => {
    const f = await fixture();
    const a = await f.register(1);
    const b = await f.register(2);
    await f.send(a, "thinking");
    const pending = f.send(a, "completed");
    await f.stub.revokeNotificationGrantAuthority({ grantId: b.activity.grantId,
      credentialId: f.credentialId, authorizationEpoch: 1, revision: 2 });
    await pending;
    expect(f.payloads.at(-1)).toMatchObject({ event: "end", contentState: { activeCount: 0 } });
    expect(f.payloads.at(-1)!.contentState.sessions.map((r) => r.id)).not.toContain(rowId(2));
  });

  it("fences every included grant again after preparing the aggregate", async () => {
    const f = await fixture();
    const a = await f.register(1);
    const b = await f.register(2, a.activity.grantId);
    const c = await f.register(3);
    // Make the draft's missing-registration-authority bug independent of this fence.
    await f.stub.authorizeNotificationEgress(c.authority);
    await runInDurableObject<UserLink, void>(f.stub, (instance) => {
      const store = (instance as unknown as { notificationState: UserLinkNotificationStore }).notificationState;
      const aggregate = store.activityGroup.bind(store);
      let intercepted = false;
      vi.spyOn(store, "activityGroup").mockImplementation((...args) => {
        const result = aggregate(...args);
        if (!intercepted) {
          intercepted = true;
          instance.revokeNotificationGrantAuthority({ grantId: c.activity.grantId,
            credentialId: f.credentialId, authorizationEpoch: 1, revision: 2 });
        }
        return result;
      });
    });
    await expect(f.send(a, "completed")).rejects.toThrow();
    expect(f.payloads).toHaveLength(0);
    await f.send(b, "thinking");
    expect(f.payloads[0]!.contentState.sessions.map((r) => r.id)).not.toContain(rowId(3));
  });

  it("accepts a first host update when its clock is behind mobile registration", async () => {
    const f = await fixture();
    const a = await f.register(1);
    await f.send(a, "waiting", now() - 30);
    expect(f.payloads[0]!.contentState.sessions[0]!.phase).toBe("waiting");
  });

  it("revalidates a non-target grant against the durable directory before egress", async () => {
    const f = await fixture();
    const a = await f.register(1);
    const b = await f.register(2);
    await env.ACCOUNTS.prepare("UPDATE notification_instance_grants SET state='revoked',revision=2 WHERE grant_id=?")
      .bind(b.activity.grantId).run();
    await expect(f.send(a, "thinking")).rejects.toThrow();
    expect(f.payloads).toHaveLength(0);
  });

  it("rechecks another row's lease after asynchronous directory authorization", async () => {
    const f = await fixture();
    const a = await f.register(1);
    const b = await f.register(2);
    const before = Date.now();
    await runInDurableObject<UserLink, void>(f.stub, (instance, state) => {
      state.storage.sql.exec("UPDATE managed_notification_activities SET lease_expires=? WHERE activity_id=?",
        Math.floor(before / 1000) + 1, b.activity.activityId);
      const store = (instance as unknown as { notificationState: UserLinkNotificationStore }).notificationState;
      const read = store.activityGroupGrants.bind(store);
      let intercepted = false;
      vi.spyOn(store, "activityGroupGrants").mockImplementation((...args) => {
        const result = read(...args);
        if (!intercepted) {
          intercepted = true;
          vi.spyOn(Date, "now").mockReturnValue(before + 2000);
        }
        return result;
      });
    });
    await expect(f.send(a, "completed")).rejects.toThrow();
    expect(f.payloads).toHaveLength(0);
  });

  it("cancels queued physical sends when the installation is revoked", async () => {
    const f = await fixture();
    const a = await f.register(1);
    await f.register(2);
    await f.send(a, "thinking");
    const pending = f.send(a, "completed");
    const rejected = expect(pending).rejects.toThrow();
    await f.stub.revokeNotificationCredential({ credentialId: f.credentialId, authorizationEpoch: 2 });
    await rejected;
    expect(f.payloads).toHaveLength(1);
  });

  it("does not revive a terminal row on a later nonterminal update", async () => {
    const f = await fixture();
    const a = await f.register(1);
    const b = await f.register(2, a.activity.grantId);
    await f.send(a, "completed");
    await expect(f.send(a, "thinking", now() + 1)).rejects.toThrow();
    await f.send(b, "completed");
    expect(f.payloads.at(-1)).toMatchObject({ event: "end", contentState: { activeCount: 0 } });
  });

  it("refuses a new alias once a physical end has been dispatched", async () => {
    const f = await fixture();
    const a = await f.register(1);
    await f.send(a, "completed");
    await expect(f.register(2, a.activity.grantId)).rejects.toThrow();
  });
});
