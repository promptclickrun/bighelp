import { env, evictDurableObject, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { PendingDeliveryStore, RETAINED_BYTE_LIMIT, RECIPIENT_RECOVERY_BYTE_LIMIT } from "../src/pending-delivery.js";
import type { UserLink } from "../src/user-link.js";

const recipient = "recipient-accounting-fixture";

describe("recipient-local retention accounting", () => {
  it("tracks exact inline/chunk bytes through updates, classification and deletion", async () => {
    const stub = env.USER_LINKS.getByName(`account-retention-bytes-${crypto.randomUUID()}`);
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      const sql = state.storage.sql;
      const store = new PendingDeliveryStore(state.storage);
      const usage = (kind: number) => sql.exec<{ frames: number; encoded_bytes: number }>(
        "SELECT frames, encoded_bytes FROM pending_recipient_usage WHERE recipient_device_id = ? AND retention_class = ?", recipient, kind,
      ).toArray()[0] ?? { frames: 0, encoded_bytes: 0 };
      sql.exec("INSERT INTO pending_frames (recipient_device_id, sender_device_id, frame_id, sequence, encoded_frame, created_at) VALUES (?, 'host', 'frame-accounting-fixture', 1, ?, 1)", recipient, "é");
      expect(usage(1)).toEqual({ frames: 1, encoded_bytes: 2 });
      sql.exec("INSERT INTO pending_frame_chunks VALUES (?, 'frame-accounting-fixture', 0, 'xx')", recipient);
      expect(usage(1)).toEqual({ frames: 1, encoded_bytes: 4 });
      expect(store.selectRecipients(RETAINED_BYTE_LIMIT - 4, [recipient], new Set(), false)).toHaveLength(1);
      expect(store.selectRecipients(RETAINED_BYTE_LIMIT - 3, [recipient], new Set(), false)).toHaveLength(0);
      sql.exec("UPDATE pending_frames SET encoded_frame = 'abc' WHERE recipient_device_id = ?", recipient);
      sql.exec("UPDATE pending_frame_chunks SET encoded_chunk = 'xxxx' WHERE recipient_device_id = ?", recipient);
      expect(usage(1)).toEqual({ frames: 1, encoded_bytes: 7 });
      sql.exec("UPDATE pending_frames SET retention_class = 2 WHERE recipient_device_id = ?", recipient);
      expect(usage(1)).toEqual({ frames: 0, encoded_bytes: 0 });
      expect(usage(2)).toEqual({ frames: 1, encoded_bytes: 7 });
      sql.exec("DELETE FROM pending_frame_chunks WHERE recipient_device_id = ?", recipient);
      expect(usage(2)).toEqual({ frames: 1, encoded_bytes: 3 });
      sql.exec("DELETE FROM pending_frames WHERE recipient_device_id = ?", recipient);
      expect(usage(2)).toEqual({ frames: 0, encoded_bytes: 0 });
      expect(sql.exec<{ encoded_bytes: number }>("SELECT encoded_bytes FROM link_delivery_state").one().encoded_bytes).toBe(0);
    });
  });

  it("never renews connected recovery reserve on eviction and enforces both quota dimensions", async () => {
    const stub = env.USER_LINKS.getByName(`account-retention-reserve-${crypto.randomUUID()}`);
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      state.storage.sql.exec(`WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < 4096)
        INSERT INTO pending_frames (recipient_device_id, sender_device_id, frame_id, sequence, encoded_frame, created_at)
        SELECT ?, 'host', 'normal-frame-' || x, x, 'normal', 1 FROM n`, recipient);
      const store = new PendingDeliveryStore(state.storage, { frames: 65536, bytes: 536870912 });
      expect(store.selectRecipients(1, [recipient], new Set(), false)).toEqual([]);
      expect(store.selectRecipients(RECIPIENT_RECOVERY_BYTE_LIMIT, [recipient], new Set([recipient]), false))
        .toEqual([{ deviceId: recipient, retentionClass: 2 }]);
      expect(store.selectRecipients(RECIPIENT_RECOVERY_BYTE_LIMIT + 1, [recipient], new Set([recipient]), false)).toEqual([]);
      state.storage.sql.exec(`WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < 512)
        INSERT INTO pending_frames (recipient_device_id, sender_device_id, frame_id, sequence, encoded_frame, created_at, retention_class)
        SELECT ?, 'host', 'recovery-frame-' || x, x + 4096, 'reserve', 1, 2 FROM n`, recipient);
    });
    for (let attempt = 0; attempt < 2; attempt++) {
      await evictDurableObject(stub);
      await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
        const store = new PendingDeliveryStore(state.storage);
        expect(store.selectRecipients(1, [recipient], new Set([recipient]), false)).toEqual([]);
        expect(state.storage.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM pending_frames WHERE retention_class = 2").one().n).toBe(512);
      });
    }
    await runInDurableObject<UserLink, void>(stub, (_instance, state) => {
      state.storage.sql.exec("DELETE FROM pending_frames WHERE frame_id = 'recovery-frame-1'");
      expect(new PendingDeliveryStore(state.storage).selectRecipients(1, [recipient], new Set([recipient]), false))
        .toEqual([{ deviceId: recipient, retentionClass: 2 }]);
    });
  });
});
