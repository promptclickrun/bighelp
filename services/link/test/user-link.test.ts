import { env, evictDurableObject, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { RegisterLinkDevice } from "../src/contracts.js";
import type { LinkEnv, UserLink } from "../src/user-link.js";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    USER_LINKS: DurableObjectNamespace<UserLink>;
  }
}

function deviceFixture(overrides: Partial<RegisterLinkDevice> = {}): RegisterLinkDevice {
  return {
    deviceId: "device-1",
    publicKey: "fixture-public-key",
    role: "mobile",
    kind: "phone",
    encryptedName: "ciphertext-v3",
    revision: 3,
    createdAt: 1_788_000_000,
    ...overrides,
  };
}

afterEach(() => vi.restoreAllMocks());

describe("UserLink device registry", () => {
  it("rejects a wake when deletion tombstones the source after the recipient owner decision", async () => {
    const suffix = crypto.randomUUID();
    const account = `wake-delete-source-${suffix}`;
    const hostDeviceId = `wake-delete-host-${suffix}`;
    const mobileDeviceId = `wake-delete-mobile-${suffix}`;
    const notificationCoordinate = `wake-delete-notification-${suffix}`;
    const installationId = crypto.randomUUID();
    const grantId = crypto.randomUUID();
    const frameId = `wake_delete_${suffix}`;
    const now = Math.floor(Date.now() / 1_000);
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts(account_coordinate,status,authorization_epoch,created_at) VALUES(?,'active',1,?)",
      ).bind(account, now),
      env.ACCOUNTS.prepare(`INSERT INTO device_directory(
        device_id,account_coordinate,public_key_spki,status,authorization_epoch,created_at)
        VALUES(?,?,?,'active',1,?)`).bind(hostDeviceId, account, "fixture-public-key", now),
      env.ACCOUNTS.prepare(`INSERT INTO notification_installations(
        installation_id,notification_coordinate,public_key_spki,authorization_epoch,
        bootstrap_request_id,bootstrap_request_digest,state,created_at)
        VALUES(?,?,?,1,?,?,'active',?)`).bind(
          installationId, notificationCoordinate, "fixture-public-key",
          crypto.randomUUID(), "fixture-digest", now,
        ),
      env.ACCOUNTS.prepare(`INSERT INTO notification_instance_grants(
        grant_id,notification_coordinate,installation_id,authorization_epoch,idempotency_key,
        request_digest,public_json,state,revision,created_at,expires_at)
        VALUES(?,?,?,1,?,?,?,'active',1,?,?)`).bind(
          grantId, notificationCoordinate, installationId, crypto.randomUUID(),
          "fixture-digest", "{}", now, now + 1_800,
        ),
      env.ACCOUNTS.prepare(`INSERT INTO notification_account_installations(
        installation_id,notification_coordinate,account_coordinate,account_device_id,
        account_authorization_epoch,installation_authorization_epoch,bound_at)
        VALUES(?,?,?,?,1,1,?)`).bind(
          installationId, notificationCoordinate, account, hostDeviceId, now,
        ),
    ]);
    const stub = env.USER_LINKS.getByName(account);
    await stub.registerDevice(deviceFixture({
      deviceId: hostDeviceId, role: "host", kind: "hermes_host", createdAt: now,
    }));
    await stub.registerDevice(deviceFixture({ deviceId: mobileDeviceId, createdAt: now }));
    const provider = vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({
      success: true,
      data: { id: "msg_deleted_source", status: "queued", counts: { total: 1, sent: 0 } },
    }));

    await runInDurableObject<UserLink, void>(stub, async (instance, state) => {
      state.storage.sql.exec(
        `INSERT INTO pending_frames(
          recipient_device_id,sender_device_id,frame_id,sequence,encoded_frame,created_at)
         VALUES(?,?,?,?,?,?)`,
        mobileDeviceId, hostDeviceId, frameId, 1, "{}", now,
      );
      state.storage.sql.exec(
        `INSERT INTO buzzkit_wake_outbox(
          frame_id,account_coordinate,host_device_id,host_epoch,expires_at,attempts,next_attempt)
         VALUES(?,?,?,?,?,0,0)`,
        frameId, account, hostDeviceId, 1, now + 300,
      );
      type WakeOutboxHarness = {
        env: LinkEnv;
        drainBuzzKitWakeOutbox(): Promise<void>;
      };
      const harness = instance as unknown as WakeOutboxHarness;
      const userLinks = harness.env.USER_LINKS;
      Object.assign(harness.env, {
        USER_LINKS: {
          getByName: () => ({
            authorizeNotificationEgress: async () => { instance.beginAccountDeletion(); },
          }),
        },
        BUZZKIT_API_KEY: `bk_tn_${crypto.randomUUID()}`,
        BUZZKIT_IDENTITY_SECRET: crypto.randomUUID(),
        BUZZKIT_IDENTITY_SECRET_GENERATION: "notification-instance-v2",
      });
      try {
        await harness.drainBuzzKitWakeOutbox();
      } finally {
        harness.env.USER_LINKS = userLinks;
      }
      expect(state.storage.kv.get("account-deletion-tombstone-v1")).toEqual({ version: 1 });
    });

    expect(provider).not.toHaveBeenCalled();
  });

  it("retains and retries a terminal zero-recipient wake before clearing a valid delivery", async () => {
    const suffix = crypto.randomUUID();
    const account = `wake-outbox-account-${suffix}`;
    const hostDeviceId = `wake-host-${suffix}`;
    const mobileDeviceId = `wake-mobile-${suffix}`;
    const notificationCoordinate = `wake-notification-${suffix}`;
    const installationId = crypto.randomUUID();
    const now = Math.floor(Date.now() / 1_000);
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(
        "INSERT INTO accounts(account_coordinate,status,authorization_epoch,created_at) VALUES(?,'active',1,?)",
      ).bind(account, now),
      env.ACCOUNTS.prepare(`INSERT INTO device_directory(
        device_id,account_coordinate,public_key_spki,status,authorization_epoch,created_at)
        VALUES(?,?,?,'active',1,?)`).bind(hostDeviceId, account, "fixture-public-key", now),
      env.ACCOUNTS.prepare(`INSERT INTO notification_installations(
        installation_id,notification_coordinate,public_key_spki,authorization_epoch,
        bootstrap_request_id,bootstrap_request_digest,state,created_at)
        VALUES(?,?,?,1,?,?,'active',?)`).bind(
          installationId, notificationCoordinate, "fixture-public-key",
          crypto.randomUUID(), "fixture-digest", now,
        ),
      env.ACCOUNTS.prepare(`INSERT INTO notification_instance_grants(
        grant_id,notification_coordinate,installation_id,authorization_epoch,idempotency_key,
        request_digest,public_json,state,revision,created_at,expires_at)
        VALUES(?,?,?,1,?,?,?,'active',1,?,?)`).bind(
          crypto.randomUUID(), notificationCoordinate, installationId, crypto.randomUUID(),
          "fixture-digest", "{}", now, now + 1_800,
        ),
      env.ACCOUNTS.prepare(`INSERT INTO notification_account_installations(
        installation_id,notification_coordinate,account_coordinate,account_device_id,
        account_authorization_epoch,installation_authorization_epoch,bound_at)
        VALUES(?,?,?,?,1,1,?)`).bind(
          installationId, notificationCoordinate, account, hostDeviceId, now,
        ),
    ]);
    const stub = env.USER_LINKS.getByName(account);
    await stub.registerDevice(deviceFixture({
      deviceId: hostDeviceId, role: "host", kind: "hermes_host", createdAt: now,
    }));
    await stub.registerDevice(deviceFixture({ deviceId: mobileDeviceId, createdAt: now }));
    const zeroFrameId = `wake_zero_${suffix}`;
    const validFrameId = `wake_valid_${suffix}`;
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      state.storage.sql.exec(
        `INSERT INTO pending_frames(
          recipient_device_id,sender_device_id,frame_id,sequence,encoded_frame,created_at)
         VALUES(?,?,?,?,?,?)`,
        mobileDeviceId, hostDeviceId, zeroFrameId, 1, "{}", now,
      );
      state.storage.sql.exec(
        `INSERT INTO buzzkit_wake_outbox(
          frame_id,account_coordinate,host_device_id,host_epoch,expires_at,attempts,next_attempt)
         VALUES(?,?,?,?,?,0,0)`,
        zeroFrameId, account, hostDeviceId, 1, now + 300,
      );
    });
    let currentMessageId = "";
    const provider = vi.spyOn(globalThis, "fetch").mockImplementation(async (url, init) => {
      if (init?.method === "POST") {
        const body = JSON.parse(String(init.body)) as {
          data: { loopdy_link: { frameId: string } };
        };
        currentMessageId = body.data.loopdy_link.frameId === validFrameId
          ? "msg_wake_valid" : "msg_wake_zero";
        return Response.json({ success: true, data: {
          id: currentMessageId, status: "queued", counts: { total: 0 },
        } });
      }
      const messageId = new URL(String(url)).pathname.split("/").at(-1)!;
      const valid = messageId === "msg_wake_valid";
      return Response.json({ success: true, data: {
        id: messageId, status: "completed",
        counts: valid ? { total: 1, sent: 1 } : { total: 0, sent: 0 },
      } });
    });
    type WakeOutboxHarness = {
      env: LinkEnv;
      drainBuzzKitWakeOutbox(): Promise<void>;
    };

    const retained = await runInDurableObject<UserLink, { attempts: number; delayed: boolean }>(
      stub,
      async (instance, state) => {
        const harness = instance as unknown as WakeOutboxHarness;
        Object.assign(harness.env, {
          BUZZKIT_API_KEY: `bk_tn_${crypto.randomUUID()}`,
          BUZZKIT_IDENTITY_SECRET: crypto.randomUUID(),
          BUZZKIT_IDENTITY_SECRET_GENERATION: "notification-instance-v2",
        });
        await harness.drainBuzzKitWakeOutbox();
        const row = state.storage.sql.exec<{ attempts: number; next_attempt: number }>(
          "SELECT attempts,next_attempt FROM buzzkit_wake_outbox WHERE frame_id=?",
          zeroFrameId,
        ).one();
        return { attempts: row.attempts, delayed: row.next_attempt > now };
      },
    );
    expect(retained).toEqual({ attempts: 1, delayed: true });

    const retriedAttempts = await runInDurableObject<UserLink, number>(
      stub,
      async (instance, state) => {
        state.storage.sql.exec(
          "UPDATE buzzkit_wake_outbox SET next_attempt=0 WHERE frame_id=?",
          zeroFrameId,
        );
        await (instance as unknown as WakeOutboxHarness).drainBuzzKitWakeOutbox();
        return state.storage.sql.exec<{ attempts: number }>(
          "SELECT attempts FROM buzzkit_wake_outbox WHERE frame_id=?",
          zeroFrameId,
        ).one().attempts;
      },
    );
    expect(retriedAttempts).toBe(2);

    const remaining = await runInDurableObject<UserLink, Array<{ frame_id: string; attempts: number }>>(
      stub,
      async (instance, state) => {
        state.storage.sql.exec(
          "UPDATE buzzkit_wake_outbox SET next_attempt=? WHERE frame_id=?",
          now + 300, zeroFrameId,
        );
        state.storage.sql.exec(
          `INSERT INTO pending_frames(
            recipient_device_id,sender_device_id,frame_id,sequence,encoded_frame,created_at)
           VALUES(?,?,?,?,?,?)`,
          mobileDeviceId, hostDeviceId, validFrameId, 2, "{}", now,
        );
        state.storage.sql.exec(
          `INSERT INTO buzzkit_wake_outbox(
            frame_id,account_coordinate,host_device_id,host_epoch,expires_at,attempts,next_attempt)
           VALUES(?,?,?,?,?,0,0)`,
          validFrameId, account, hostDeviceId, 1, now + 300,
        );
        await (instance as unknown as WakeOutboxHarness).drainBuzzKitWakeOutbox();
        return state.storage.sql.exec<{ frame_id: string; attempts: number }>(
          "SELECT frame_id,attempts FROM buzzkit_wake_outbox ORDER BY frame_id",
        ).toArray();
      },
    );
    expect(remaining).toEqual([{ frame_id: zeroFrameId, attempts: 2 }]);
    expect(currentMessageId).toBe("msg_wake_valid");
    expect(provider).toHaveBeenCalledTimes(6);
  });

  it("caps new active registrations without breaking idempotency or explicit slot reuse", async () => {
    const stub = env.USER_LINKS.getByName(`account-enrollment-cap-${crypto.randomUUID()}`);
    for (let index = 0; index < 16; index++) {
      await stub.registerDevice(deviceFixture({ deviceId: `cap-device-${index}` }));
    }
    await expect(stub.registerDevice(deviceFixture({ deviceId: "cap-device-0" }))).resolves.toMatchObject({ deviceId: "cap-device-0" });
    await runInDurableObject<UserLink, void>(stub, (instance) => {
      expect(() => instance.registerDevice(deviceFixture({ deviceId: "cap-device-overflow" })))
        .toThrowError(expect.objectContaining({ code: "device_limit" }));
    });
    await stub.revokeDevice({ deviceId: "cap-device-0", expectedRevision: 3, revokedAt: 1_788_000_100 });
    await expect(stub.registerDevice(deviceFixture({ deviceId: "cap-device-replacement" }))).resolves.toMatchObject({ deviceId: "cap-device-replacement" });
    expect((await stub.listDevices()).devices).toHaveLength(16);
    expect(await runInDurableObject<UserLink, number>(stub, (_instance, state) =>
      state.storage.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM legacy_sender_rescue").one().n,
    )).toBe(0);
  });

  it("persists the account profile avatar in durable account storage", async () => {
    const account = `account-fixture-profile-avatar-${crypto.randomUUID()}`;
    const stub = env.USER_LINKS.getByName(account);
    const avatar = {
      mimeType: "image/png",
      byteCount: 8,
      sha256: "sha256-profile-avatar-0001",
      encryptedData: "encrypted-profile-avatar-0001",
    };

    await expect(
      stub.saveAccountProfile({
        expectedRevision: 0,
        encryptedDisplayName: "encrypted-display-name-0001",
        avatar,
        updatedAt: 1_788_000_010,
      }),
    ).resolves.toEqual({
      revision: 1,
      encryptedDisplayName: "encrypted-display-name-0001",
      avatar,
      updatedAt: 1_788_000_010,
    });

    const reloaded = env.USER_LINKS.getByName(account);
    await expect(reloaded.loadAccountProfile()).resolves.toEqual({
      revision: 1,
      encryptedDisplayName: "encrypted-display-name-0001",
      avatar,
      updatedAt: 1_788_000_010,
    });
  });

  it("rejects stale account profile avatar updates", async () => {
    const stub = env.USER_LINKS.getByName(
      `account-fixture-profile-avatar-stale-${crypto.randomUUID()}`,
    );
    await stub.saveAccountProfile({
      expectedRevision: 0,
      encryptedDisplayName: "encrypted-display-name-0001",
      avatar: null,
      updatedAt: 1_788_000_010,
    });

    await runInDurableObject<UserLink, void>(stub, (instance) => {
      expect(() =>
        instance.saveAccountProfile({
          expectedRevision: 0,
          encryptedDisplayName: "encrypted-display-name-0002",
          avatar: null,
          updatedAt: 1_788_000_011,
        }),
      ).toThrowError(expect.objectContaining({ code: "stale_profile_revision" }));
    });

    await expect(stub.loadAccountProfile()).resolves.toMatchObject({
      revision: 1,
      encryptedDisplayName: "encrypted-display-name-0001",
    });
  });

  it("retains an idempotent deletion tombstone that rejects delayed mutations", async () => {
    const account = `account-fixture-delete-tombstone-${crypto.randomUUID()}`;
    const stub = env.USER_LINKS.getByName(account);
    await stub.registerDevice(deviceFixture());
    const delayedAuthorizedMutation = deviceFixture({
      deviceId: "delayed-device", revision: 1,
    });

    await expect(stub.deleteAccountData()).resolves.toBeUndefined();
    await runInDurableObject<UserLink, void>(stub, (instance) => {
      expect(() => instance.registerDevice(delayedAuthorizedMutation)).toThrowError(
        expect.objectContaining({ code: "account_deleted" }),
      );
    });

    await evictDurableObject(stub);
    const reinitializedStub = env.USER_LINKS.getByName(account);
    await runInDurableObject<UserLink, void>(reinitializedStub, (instance) => {
      expect(() => instance.renameDevice({
        deviceId: "device-1", expectedRevision: 3, encryptedName: "recreated-data",
      })).toThrowError(expect.objectContaining({ code: "account_deleted" }));
      expect(() => instance.saveAccountProfile({
        expectedRevision: 0, encryptedDisplayName: "recreated-profile",
        avatar: null, updatedAt: 1_788_000_100,
      })).toThrowError(expect.objectContaining({ code: "account_deleted" }));
    });

    const expectPurgedState = () => runInDurableObject<UserLink, void>(
      reinitializedStub,
      (_instance, state) => {
        expect(state.storage.kv.get("account-deletion-tombstone-v1")).toEqual({ version: 1 });
        const tables = state.storage.sql.exec<{ name: string }>(
          `SELECT name FROM sqlite_master
           WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT GLOB '_cf_*'`,
        ).toArray();
        for (const { name } of tables) {
          const quoted = `"${name.replaceAll('"', '""')}"`;
          expect(state.storage.sql.exec<{ count: number }>(
            `SELECT COUNT(*) AS count FROM ${quoted}`,
          ).one().count, name).toBe(0);
        }
      },
    );
    await expectPurgedState();
    await expect(reinitializedStub.deleteAccountData()).resolves.toBeUndefined();
    await expectPurgedState();
  });

  it("rejects a stale rename without changing the active device", async () => {
    const stub = env.USER_LINKS.getByName("account-fixture-stale-rename");
    await stub.registerDevice(deviceFixture());

    await runInDurableObject<UserLink, void>(stub, (instance) => {
      expect(() =>
        instance.renameDevice({
          deviceId: "device-1",
          expectedRevision: 2,
          encryptedName: "ciphertext-v4",
        }),
      ).toThrowError(expect.objectContaining({ code: "stale_revision" }));
    });

    expect((await stub.listDevices()).devices[0]).toMatchObject({
      deviceId: "device-1",
      revision: 3,
      lifecycle: "active",
    });
  });

  it("returns encrypted display metadata without exposing device public keys", async () => {
    const stub = env.USER_LINKS.getByName("account-fixture-public-projection");
    await stub.registerDevice(deviceFixture());

    const encoded = JSON.stringify(await stub.listDevices());

    expect(encoded).not.toContain("fixture-public-key");
    expect(encoded).toContain("ciphertext-v3");
  });

  it("renames only by advancing the authoritative revision", async () => {
    const stub = env.USER_LINKS.getByName("account-fixture-confirmed-rename");
    await stub.registerDevice(deviceFixture());

    const renamed = await stub.renameDevice({
      deviceId: "device-1",
      expectedRevision: 3,
      encryptedName: "ciphertext-v4",
    });

    expect(renamed).toMatchObject({
      deviceId: "device-1",
      revision: 4,
      encryptedName: "ciphertext-v4",
    });
  });

  it("revokes only the exact current revision", async () => {
    const stub = env.USER_LINKS.getByName("account-fixture-revoke");
    await stub.registerDevice(deviceFixture());

    await runInDurableObject<UserLink, void>(stub, (instance) => {
      expect(() =>
        instance.revokeDevice({
          deviceId: "device-1",
          expectedRevision: 2,
          revokedAt: 1_788_000_100,
        }),
      ).toThrowError(expect.objectContaining({ code: "stale_revision" }));
    });

    const revoked = await stub.revokeDevice({
      deviceId: "device-1",
      expectedRevision: 3,
      revokedAt: 1_788_000_100,
    });
    expect(revoked).toMatchObject({ lifecycle: "revoked", revision: 4 });
    expect((await stub.listDevices()).devices).toEqual([]);
    expect(await stub.revokeDevice({
      deviceId: "device-1",
      expectedRevision: 3,
      revokedAt: 1_788_000_101,
    })).toEqual(revoked);
  });

  it("isolates registries by the server-selected Durable Object name", async () => {
    const first = env.USER_LINKS.getByName("account-fixture-a");
    const second = env.USER_LINKS.getByName("account-fixture-b");
    await first.registerDevice(deviceFixture());

    expect((await first.listDevices()).devices).toHaveLength(1);
    expect((await second.listDevices()).devices).toHaveLength(0);
  });

  it("does not retain the removed relay enrollment API", async () => {
    const stub = env.USER_LINKS.getByName("account-fixture-push-revision");
    await stub.registerDevice(deviceFixture());
    await runInDurableObject<UserLink, void>(stub, (instance) => {
      expect("confirmPushEnrollment" in instance).toBe(false);
      expect("registerLiveActivity" in instance).toBe(false);
    });
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      state.storage.sql.exec("UPDATE devices SET push_state='ready',push_revision=7");
    });
    expect((await stub.listDevices()).devices[0]).toMatchObject({pushState:null,pushRevision:0});
  });

  it("binds managed Live Activities to one sender grant and session coordinate", async () => {
    const stub = env.USER_LINKS.getByName("account-fixture-live-activity");
    const grantId = crypto.randomUUID();
    const input = {
      grantId,
      activityId: "activity-1",
      sessionReference: "A".repeat(43),
      revision: 1,
      leaseExpires: 1_788_028_800,
      timestamp: 1_788_000_000,
      status: "active" as const,
    };
    const registered = await stub.registerNotificationActivity(input);
    expect(registered).toMatchObject({ grantId, status: "active", revision: 1 });
    expect(await stub.registerNotificationActivity(input)).toEqual(registered);
    expect(await stub.notificationActivity({ grantId, activityId: input.activityId, now: input.timestamp + 1 })).toEqual(registered);
    expect(await stub.revokeNotificationActivity({ grantId, activityId: input.activityId, revision: 2, timestamp: input.timestamp + 2 }))
      .toMatchObject({ status: "revoked", revision: 2 });
  });

  it("rejects replacing a managed activity's sender grant", async () => {
    const stub = env.USER_LINKS.getByName("account-fixture-live-activity-ownership");
    const input = { grantId: crypto.randomUUID(), activityId: "activity-1", sessionReference: "B".repeat(43),
      revision: 1, leaseExpires: 1_788_028_800, timestamp: 1_788_000_000, status: "active" as const };
    await stub.registerNotificationActivity(input);
    await runInDurableObject<UserLink, void>(stub, (instance) => {
      expect(() => instance.registerNotificationActivity({ ...input, grantId: crypto.randomUUID() }))
        .toThrowError(expect.objectContaining({ code: "notification_activity_conflict" }));
    });
  });
});

describe("notification state retention", () => {
  it("purges expired avatars and finished Live Activity records on the alarm", async () => {
    const stub = env.USER_LINKS.getByName("account-fixture-notification-retention");
    const now = Math.floor(Date.now() / 1_000);
    await stub.putNotificationAsset({
      assetId: "A".repeat(43), mimeType: "application/octet-stream", data: new Uint8Array([1]), expiresAt: now + 1_200,
    });
    await stub.registerNotificationActivity({
      grantId: crypto.randomUUID(), activityId: "activity-retention", sessionReference: "C".repeat(43),
      revision: 1, leaseExpires: now + 600, timestamp: now, status: "active",
    });
    const alarm = await runInDurableObject<UserLink, number | null>(stub, (_instance, state) => state.storage.getAlarm());
    expect(alarm).not.toBeNull();
    expect(alarm!).toBeLessThanOrEqual((now + 1_200) * 1_000);
    const later = (now + 600 + 3_600 + 1) * 1_000;
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(later);
    try {
      await runInDurableObject<UserLink, void>(stub, async (instance, state) => {
        await instance.alarm();
        expect(state.storage.sql.exec("SELECT COUNT(*) AS n FROM notification_assets").one().n).toBe(0);
        expect(state.storage.sql.exec("SELECT COUNT(*) AS n FROM managed_notification_activities").one().n).toBe(0);
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it("deletes an installation's avatars and Live Activity records when it is turned off", async () => {
    const stub = env.USER_LINKS.getByName("notify-fixture-turn-off");
    const now = Math.floor(Date.now() / 1_000);
    await stub.putNotificationAsset({
      assetId: "E".repeat(43), mimeType: "application/octet-stream", data: new Uint8Array([1]), expiresAt: now + 1_200,
    });
    await stub.registerNotificationActivity({
      grantId: crypto.randomUUID(), activityId: "activity-turn-off", sessionReference: "F".repeat(43),
      revision: 1, leaseExpires: now + 600, timestamp: now, status: "active",
    });
    await stub.revokeNotificationCredential({ credentialId: crypto.randomUUID(), authorizationEpoch: 1 });
    await runInDurableObject<UserLink, void>(stub, async (_instance, state) => {
      expect(state.storage.sql.exec("SELECT COUNT(*) AS n FROM notification_assets").one().n).toBe(0);
      expect(state.storage.sql.exec("SELECT COUNT(*) AS n FROM managed_notification_activities").one().n).toBe(0);
      expect(state.storage.sql.exec("SELECT state FROM managed_notification_credentials").one().state).toBe("revoked");
    });
  });

  it("keeps a Live Activity record until an hour after its lease", async () => {
    const stub = env.USER_LINKS.getByName("account-fixture-notification-retention-live");
    const now = Math.floor(Date.now() / 1_000);
    await stub.registerNotificationActivity({
      grantId: crypto.randomUUID(), activityId: "activity-live", sessionReference: "D".repeat(43),
      revision: 1, leaseExpires: now + 600, timestamp: now, status: "active",
    });
    await runInDurableObject<UserLink, void>(stub, async (instance, state) => {
      await instance.alarm();
      expect(state.storage.sql.exec("SELECT COUNT(*) AS n FROM managed_notification_activities").one().n).toBe(1);
      expect(await state.storage.getAlarm()).toBe((now + 600 + 3_600) * 1_000);
    });
  });
});
