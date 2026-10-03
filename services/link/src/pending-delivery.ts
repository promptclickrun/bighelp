import { LINK_LIMITS } from "./contracts.js";
import type { EncryptedLinkFrame } from "./frame.js";

// Internal delivery order is deliberately separate from encrypted v1 sender sequences.
// Normal admission budgets count each recipient's own encoded UTF-8 copy.
export const RETAINED_BYTE_LIMIT = 64 * 1024 * 1024;
export const RETAINED_FRAME_LIMIT = 4096;
export const DELIVERY_WINDOW = 512;
export const DELIVERY_BYTE_WINDOW = 4 * 1024 * 1024;
export const ACTIVE_DEVICE_LIMIT = 16;
export const RECIPIENT_RECOVERY_BYTE_LIMIT = 4 * 1024 * 1024;
export const RECIPIENT_RECOVERY_FRAME_LIMIT = 512;
export type RetentionClass = 0 | 1 | 2; // Grandfathered debt, normal, connected recovery.

const MAX_INLINE_PENDING_FRAME_CHARACTERS = 1_900_000;
const PENDING_FRAME_CHUNK_CHARACTERS = 1_000_000;

export interface RecipientAdmission {
  deviceId: string;
  retentionClass: RetentionClass;
}

interface RecipientUsage extends Record<string, SqlStorageValue> {
  retention_class: RetentionClass;
  frames: number;
  encoded_bytes: number;
}

export interface PendingDelivery extends Record<string, SqlStorageValue> {
  frame_id: string;
  delivery_order: number;
  encoded_bytes: number;
}

/** Private storage helper, not a Durable Object RPC or authentication bypass. */
export class PendingDeliveryStore {
  readonly limits: { frames: number; bytes: number };

  constructor(
    private readonly storage: DurableObjectStorage,
    limits: { frames?: unknown; bytes?: unknown } = {},
  ) {
    const frames = Number(limits.frames);
    const bytes = Number(limits.bytes);
    this.limits = {
      frames: Number.isSafeInteger(frames) && frames >= RETAINED_FRAME_LIMIT && frames <= 65_536
        ? frames : RETAINED_FRAME_LIMIT,
      bytes: Number.isSafeInteger(bytes) && bytes >= RETAINED_BYTE_LIMIT && bytes <= 512 * 1024 * 1024
        ? bytes : RETAINED_BYTE_LIMIT,
    };
  }

  initialize(): void {
    this.storage.transactionSync(() => {
      const sql = this.storage.sql;
      const columns = new Set(
        sql.exec<{ name: string }>("PRAGMA table_info(pending_frames)").toArray().map((c) => c.name),
      );
      if (!columns.has("delivery_order")) {
        sql.exec("ALTER TABLE pending_frames ADD COLUMN delivery_order INTEGER NOT NULL DEFAULT 0");
      }
      if (!columns.has("encoded_bytes")) {
        sql.exec("ALTER TABLE pending_frames ADD COLUMN encoded_bytes INTEGER NOT NULL DEFAULT 0");
      }
      sql.exec(`
        CREATE TABLE IF NOT EXISTS link_delivery_state (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          schema_version INTEGER NOT NULL,
          last_order INTEGER NOT NULL,
          encoded_bytes INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS pending_frame_refs (
          frame_id TEXT PRIMARY KEY,
          recipients INTEGER NOT NULL
        );
      `);
      const initialized = sql.exec("SELECT singleton FROM link_delivery_state WHERE singleton = 1").toArray().length > 0;
      if (!initialized) {
        // Preserve all old rows, including chunked frames and over-budget accounts.
        // SQL performs the one-time backfill without loading ciphertext into JS.
        sql.exec(`
          WITH ordered AS MATERIALIZED (
            SELECT rowid AS pending_rowid,
              ROW_NUMBER() OVER (ORDER BY created_at, sender_device_id, sequence, frame_id, recipient_device_id)
                + (SELECT COALESCE(MAX(delivery_order), 0) FROM pending_frames) AS new_order
            FROM pending_frames WHERE delivery_order = 0
          )
          UPDATE pending_frames SET delivery_order = (
            SELECT new_order FROM ordered WHERE pending_rowid = pending_frames.rowid
          ) WHERE delivery_order = 0;
          UPDATE pending_frames SET encoded_bytes = length(CAST(encoded_frame AS BLOB)) + COALESCE((
            SELECT SUM(length(CAST(encoded_chunk AS BLOB))) FROM pending_frame_chunks c
            WHERE c.recipient_device_id = pending_frames.recipient_device_id
              AND c.frame_id = pending_frames.frame_id
          ), 0);
          INSERT INTO pending_frame_refs (frame_id, recipients)
            SELECT frame_id, COUNT(*) FROM pending_frames GROUP BY frame_id;
          INSERT INTO link_delivery_state (singleton, schema_version, last_order, encoded_bytes)
            SELECT 1, 1, COALESCE(MAX(delivery_order), 0),
              (SELECT COALESCE(SUM(length(CAST(encoded_frame AS BLOB))), 0) FROM pending_frames)
              + (SELECT COALESCE(SUM(length(CAST(encoded_chunk AS BLOB))), 0) FROM pending_frame_chunks)
            FROM pending_frames;
        `);
      }
      const recipientPolicyInitialized = sql.exec<{ schema_version: number }>(
        "SELECT schema_version FROM link_delivery_state WHERE singleton = 1",
      ).one().schema_version >= 2;
      if (!columns.has("retention_class")) {
        sql.exec("ALTER TABLE pending_frames ADD COLUMN retention_class INTEGER NOT NULL DEFAULT 1 CHECK (retention_class IN (0, 1, 2))");
      }
      sql.exec(`
        CREATE TABLE IF NOT EXISTS pending_recipient_usage (
          recipient_device_id TEXT NOT NULL,
          retention_class INTEGER NOT NULL CHECK (retention_class IN (0, 1, 2)),
          frames INTEGER NOT NULL,
          encoded_bytes INTEGER NOT NULL,
          PRIMARY KEY (recipient_device_id, retention_class)
        );
        CREATE TABLE IF NOT EXISTS pending_recipient_skips (
          recipient_device_id TEXT PRIMARY KEY,
          skipped_frames INTEGER NOT NULL,
          skipped_bytes INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS legacy_sender_rescue (
          device_id TEXT NOT NULL,
          authorization_epoch INTEGER NOT NULL,
          next_sequence INTEGER NOT NULL,
          consumed INTEGER NOT NULL DEFAULT 0 CHECK (consumed IN (0, 1)),
          PRIMARY KEY (device_id, authorization_epoch)
        );
      `);
      if (!recipientPolicyInitialized) {
        // One transaction grandfathers retained bytes and snapshots only devices
        // that already existed. Restart, receipt and reconnect cannot renew rescue.
        sql.exec(`
          UPDATE pending_frames SET retention_class = 0;
          INSERT INTO pending_recipient_usage (recipient_device_id, retention_class, frames, encoded_bytes)
            SELECT recipient_device_id, 0, COUNT(*), SUM(encoded_bytes)
            FROM pending_frames GROUP BY recipient_device_id;
          INSERT INTO legacy_sender_rescue (device_id, authorization_epoch, next_sequence, consumed)
            SELECT device_id, authorization_epoch, last_inbound_sequence + 1, 0
            FROM devices WHERE lifecycle = 'active';
          UPDATE link_delivery_state SET schema_version = 2 WHERE singleton = 1;
          DROP TRIGGER IF EXISTS pending_delivery_insert;
          DROP TRIGGER IF EXISTS pending_delivery_delete;
        `);
      }
      // Triggers keep counters correct for receipts, revocation, inline/chunk writes,
      // and legacy-shaped inserts. No independent in-memory accounting can go stale.
      sql.exec(`
        CREATE INDEX IF NOT EXISTS pending_frames_delivery_idx
          ON pending_frames (recipient_device_id, delivery_order);
        CREATE INDEX IF NOT EXISTS pending_frames_frame_idx ON pending_frames (frame_id);
        CREATE TRIGGER IF NOT EXISTS pending_delivery_insert AFTER INSERT ON pending_frames BEGIN
          INSERT INTO pending_recipient_usage (recipient_device_id, retention_class, frames, encoded_bytes)
            VALUES (NEW.recipient_device_id, NEW.retention_class, 1, NEW.encoded_bytes)
            ON CONFLICT(recipient_device_id, retention_class) DO UPDATE SET
              frames = frames + 1, encoded_bytes = encoded_bytes + NEW.encoded_bytes;
          UPDATE link_delivery_state SET last_order = last_order + 1,
            encoded_bytes = encoded_bytes + length(CAST(NEW.encoded_frame AS BLOB)) WHERE singleton = 1;
          UPDATE pending_frames SET
            delivery_order = (SELECT last_order FROM link_delivery_state WHERE singleton = 1),
            encoded_bytes = length(CAST(NEW.encoded_frame AS BLOB))
            WHERE recipient_device_id = NEW.recipient_device_id AND frame_id = NEW.frame_id;
          INSERT INTO pending_frame_refs (frame_id, recipients) VALUES (NEW.frame_id, 1)
            ON CONFLICT(frame_id) DO UPDATE SET recipients = recipients + 1;
        END;
        CREATE TRIGGER IF NOT EXISTS pending_delivery_delete AFTER DELETE ON pending_frames BEGIN
          UPDATE pending_recipient_usage SET frames = frames - 1, encoded_bytes = encoded_bytes - OLD.encoded_bytes
            WHERE recipient_device_id = OLD.recipient_device_id AND retention_class = OLD.retention_class;
          UPDATE link_delivery_state SET encoded_bytes = encoded_bytes - length(CAST(OLD.encoded_frame AS BLOB))
            WHERE singleton = 1;
          UPDATE pending_frame_refs SET recipients = recipients - 1 WHERE frame_id = OLD.frame_id;
          DELETE FROM pending_frame_refs WHERE frame_id = OLD.frame_id AND recipients = 0;
        END;
        CREATE TRIGGER IF NOT EXISTS pending_delivery_inline_update AFTER UPDATE OF encoded_frame ON pending_frames BEGIN
          UPDATE link_delivery_state SET encoded_bytes = encoded_bytes
            + length(CAST(NEW.encoded_frame AS BLOB)) - length(CAST(OLD.encoded_frame AS BLOB)) WHERE singleton = 1;
          UPDATE pending_frames SET encoded_bytes = encoded_bytes
            + length(CAST(NEW.encoded_frame AS BLOB)) - length(CAST(OLD.encoded_frame AS BLOB))
            WHERE recipient_device_id = NEW.recipient_device_id AND frame_id = NEW.frame_id;
        END;
        CREATE TRIGGER IF NOT EXISTS pending_recipient_update
        AFTER UPDATE OF encoded_bytes, retention_class, recipient_device_id ON pending_frames BEGIN
          UPDATE pending_recipient_usage SET frames = frames - 1, encoded_bytes = encoded_bytes - OLD.encoded_bytes
            WHERE recipient_device_id = OLD.recipient_device_id AND retention_class = OLD.retention_class;
          INSERT INTO pending_recipient_usage (recipient_device_id, retention_class, frames, encoded_bytes)
            VALUES (NEW.recipient_device_id, NEW.retention_class, 1, NEW.encoded_bytes)
            ON CONFLICT(recipient_device_id, retention_class) DO UPDATE SET
              frames = frames + 1, encoded_bytes = encoded_bytes + NEW.encoded_bytes;
        END;
        CREATE TRIGGER IF NOT EXISTS pending_delivery_chunk_insert AFTER INSERT ON pending_frame_chunks BEGIN
          UPDATE link_delivery_state SET encoded_bytes = encoded_bytes + length(CAST(NEW.encoded_chunk AS BLOB))
            WHERE singleton = 1;
          UPDATE pending_frames SET encoded_bytes = encoded_bytes + length(CAST(NEW.encoded_chunk AS BLOB))
            WHERE recipient_device_id = NEW.recipient_device_id AND frame_id = NEW.frame_id;
        END;
        CREATE TRIGGER IF NOT EXISTS pending_delivery_chunk_delete AFTER DELETE ON pending_frame_chunks BEGIN
          UPDATE link_delivery_state SET encoded_bytes = encoded_bytes - length(CAST(OLD.encoded_chunk AS BLOB))
            WHERE singleton = 1;
          UPDATE pending_frames SET encoded_bytes = encoded_bytes - length(CAST(OLD.encoded_chunk AS BLOB))
            WHERE recipient_device_id = OLD.recipient_device_id AND frame_id = OLD.frame_id;
        END;
        CREATE TRIGGER IF NOT EXISTS pending_delivery_chunk_update AFTER UPDATE OF encoded_chunk ON pending_frame_chunks BEGIN
          UPDATE link_delivery_state SET encoded_bytes = encoded_bytes
            + length(CAST(NEW.encoded_chunk AS BLOB)) - length(CAST(OLD.encoded_chunk AS BLOB)) WHERE singleton = 1;
          UPDATE pending_frames SET encoded_bytes = encoded_bytes
            + length(CAST(NEW.encoded_chunk AS BLOB)) - length(CAST(OLD.encoded_chunk AS BLOB))
            WHERE recipient_device_id = NEW.recipient_device_id AND frame_id = NEW.frame_id;
        END;
      `);
    });
  }

  diagnostics() {
    // Account routing and signature verification live at the HTTP boundary.
    // Never read or return ciphertext, keys, names, or message contents here.
    const usage = this.storage.sql.exec<{ encoded_bytes: number; frames: number }>(`
      SELECT encoded_bytes, (SELECT COUNT(*) FROM pending_frame_refs) AS frames
      FROM link_delivery_state WHERE singleton = 1
    `).one();
    const recipients = this.storage.sql.exec<{
      device_id: string; pending_frames: number; pending_bytes: number; oldest_created_at: number | null;
      normal_frames: number; normal_bytes: number; debt_frames: number; debt_bytes: number;
      recovery_frames: number; recovery_bytes: number; skipped_frames: number; skipped_bytes: number;
      rescue_sequence: number | null; rescue_consumed: number | null;
    }>(`
      WITH recipient_ids AS (
        SELECT device_id FROM devices WHERE lifecycle = 'active'
        UNION SELECT recipient_device_id FROM pending_recipient_usage WHERE frames > 0
        UNION SELECT recipient_device_id FROM pending_recipient_skips
      )
      SELECT ids.device_id,
        COALESCE(n.frames, 0) AS normal_frames, COALESCE(n.encoded_bytes, 0) AS normal_bytes,
        COALESCE(d.frames, 0) AS debt_frames, COALESCE(d.encoded_bytes, 0) AS debt_bytes,
        COALESCE(r.frames, 0) AS recovery_frames, COALESCE(r.encoded_bytes, 0) AS recovery_bytes,
        COALESCE(n.frames, 0) + COALESCE(d.frames, 0) + COALESCE(r.frames, 0) AS pending_frames,
        COALESCE(n.encoded_bytes, 0) + COALESCE(d.encoded_bytes, 0) + COALESCE(r.encoded_bytes, 0) AS pending_bytes,
        (SELECT MIN(created_at) FROM pending_frames p WHERE p.recipient_device_id = ids.device_id) AS oldest_created_at,
        COALESCE(s.skipped_frames, 0) AS skipped_frames, COALESCE(s.skipped_bytes, 0) AS skipped_bytes,
        rescue.next_sequence AS rescue_sequence, rescue.consumed AS rescue_consumed
      FROM recipient_ids ids
      LEFT JOIN pending_recipient_usage n ON n.recipient_device_id = ids.device_id AND n.retention_class = 1
      LEFT JOIN pending_recipient_usage d ON d.recipient_device_id = ids.device_id AND d.retention_class = 0
      LEFT JOIN pending_recipient_usage r ON r.recipient_device_id = ids.device_id AND r.retention_class = 2
      LEFT JOIN pending_recipient_skips s ON s.recipient_device_id = ids.device_id
      LEFT JOIN devices device ON device.device_id = ids.device_id
      LEFT JOIN legacy_sender_rescue rescue ON rescue.device_id = ids.device_id
        AND rescue.authorization_epoch = device.authorization_epoch
      ORDER BY pending_bytes DESC, ids.device_id LIMIT ?
    `, LINK_LIMITS.listDevices).toArray();
    return {
      retainedBytes: usage.encoded_bytes,
      retainedFrames: usage.frames,
      limitScope: "per_recipient",
      byteLimit: RETAINED_BYTE_LIMIT,
      frameLimit: RETAINED_FRAME_LIMIT,
      recoveryByteLimit: RECIPIENT_RECOVERY_BYTE_LIMIT,
      recoveryFrameLimit: RECIPIENT_RECOVERY_FRAME_LIMIT,
      activeDeviceLimit: ACTIVE_DEVICE_LIMIT,
      legacyGlobalLimits: { ...this.limits, enforced: false },
      recipients: recipients.map((row) => ({
        deviceId: row.device_id, pendingFrames: row.pending_frames,
        pendingBytes: row.pending_bytes, oldestCreatedAt: row.oldest_created_at,
        normalFrames: row.normal_frames, normalBytes: row.normal_bytes,
        debtFrames: row.debt_frames, debtBytes: row.debt_bytes,
        recoveryFrames: row.recovery_frames, recoveryBytes: row.recovery_bytes,
        skippedFrames: row.skipped_frames, skippedBytes: row.skipped_bytes,
        rescueSequence: row.rescue_sequence,
        rescueConsumed: row.rescue_consumed === null ? null : row.rescue_consumed === 1,
      })),
    };
  }

  /** Called inside the owner's synchronous acceptance transaction. */
  persistFrame(
    recipientDeviceId: string,
    senderDeviceId: string,
    frame: EncryptedLinkFrame,
    encodedFrame: string,
    createdAt: number,
    retentionClass: RetentionClass,
  ): void {
    const inline = encodedFrame.length <= MAX_INLINE_PENDING_FRAME_CHARACTERS;
    this.storage.sql
      .exec(
        `INSERT INTO pending_frames (
           recipient_device_id, sender_device_id, frame_id,
           sequence, encoded_frame, created_at, retention_class
         ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
        recipientDeviceId,
        senderDeviceId,
        frame.id,
        frame.sequence,
        inline ? encodedFrame : "",
        createdAt,
        retentionClass,
      )
      .toArray();
    if (inline) return;

    for (
      let offset = 0, chunkIndex = 0;
      offset < encodedFrame.length;
      offset += PENDING_FRAME_CHUNK_CHARACTERS, chunkIndex += 1
    ) {
      this.storage.sql
        .exec(
          `INSERT INTO pending_frame_chunks (
             recipient_device_id, frame_id, chunk_index, encoded_chunk
           ) VALUES (?, ?, ?, ?)`,
          recipientDeviceId,
          frame.id,
          chunkIndex,
          encodedFrame.slice(offset, offset + PENDING_FRAME_CHUNK_CHARACTERS),
        )
        .toArray();
    }
  }

  acceptReceipt(receipt: { deviceId: string; frameId: string; sourceDeviceId: string; sequence: number }): void {
    this.storage.transactionSync(() => {
      this.storage.sql
        .exec(
          `DELETE FROM pending_frame_chunks
           WHERE recipient_device_id = ? AND frame_id = ?
             AND EXISTS (
               SELECT 1 FROM pending_frames
               WHERE pending_frames.recipient_device_id = ?
                 AND pending_frames.sender_device_id = ?
                 AND pending_frames.frame_id = ?
                 AND pending_frames.sequence = ?
             )`,
          receipt.deviceId,
          receipt.frameId,
          receipt.deviceId,
          receipt.sourceDeviceId,
          receipt.frameId,
          receipt.sequence,
        )
        .toArray();
      this.storage.sql
        .exec(
          `DELETE FROM pending_frames
           WHERE recipient_device_id = ? AND sender_device_id = ?
             AND frame_id = ? AND sequence = ?`,
          receipt.deviceId,
          receipt.sourceDeviceId,
          receipt.frameId,
          receipt.sequence,
        )
        .toArray();
    });
  }

  /** Called inside the owner's synchronous device-revocation transaction. */
  revokeDevice(deviceId: string): void {
    this.storage.sql
      .exec(
        `DELETE FROM pending_frame_chunks
         WHERE EXISTS (
           SELECT 1 FROM pending_frames
           WHERE pending_frames.recipient_device_id = pending_frame_chunks.recipient_device_id
             AND pending_frames.frame_id = pending_frame_chunks.frame_id
             AND (
               pending_frames.recipient_device_id = ? OR
               pending_frames.sender_device_id = ?
             )
         )`,
        deviceId,
        deviceId,
      )
      .toArray();
    this.storage.sql
      .exec(
        `DELETE FROM pending_frames
         WHERE recipient_device_id = ? OR sender_device_id = ?`,
        deviceId,
        deviceId,
      )
      .toArray();
  }

  hasLegacyRescue(deviceId: string, epoch: number, sequence: number): boolean {
    return this.storage.sql.exec(`
      SELECT 1 FROM legacy_sender_rescue
      WHERE device_id = ? AND authorization_epoch = ? AND next_sequence = ? AND consumed = 0
    `, deviceId, epoch, sequence).toArray().length > 0;
  }

  /** Call only inside the original synchronous acceptance transaction. */
  selectRecipients(
    encodedBytes: number,
    candidates: readonly string[],
    connected: ReadonlySet<string>,
    rescue: boolean,
  ): RecipientAdmission[] {
    const recipients: RecipientAdmission[] = [];
    for (const deviceId of candidates) {
      if (rescue) {
        // Preserve the original all-recipient admission contract for this one
        // pending envelope, including recipients enrolled after the cutover.
        // Sender entitlements and active enrollment independently bound copies.
        recipients.push({ deviceId, retentionClass: 0 });
        continue;
      }
      // At most three indexed metadata rows; never scan retained ciphertext or
      // apply the former account-wide override to every device's budget.
      const usage = this.storage.sql.exec<RecipientUsage>(`
        SELECT retention_class, frames, encoded_bytes FROM pending_recipient_usage
        WHERE recipient_device_id = ?
      `, deviceId).toArray();
      const normal = usage.find((row) => row.retention_class === 1);
      if ((normal?.frames ?? 0) < RETAINED_FRAME_LIMIT &&
          (normal?.encoded_bytes ?? 0) + encodedBytes <= RETAINED_BYTE_LIMIT) {
        recipients.push({ deviceId, retentionClass: 1 });
        continue;
      }
      const recovery = usage.find((row) => row.retention_class === 2);
      // Outstanding reserve usage is durable, not a per-connection allowance.
      // Only deletion/receipts reclaim it; reconnect and eviction change nothing.
      if (connected.has(deviceId) && (recovery?.frames ?? 0) < RECIPIENT_RECOVERY_FRAME_LIMIT &&
          (recovery?.encoded_bytes ?? 0) + encodedBytes <= RECIPIENT_RECOVERY_BYTE_LIMIT) {
        recipients.push({ deviceId, retentionClass: 2 });
      }
    }
    return recipients;
  }

  recordSkippedRecipients(deviceIds: readonly string[], encodedBytes: number): void {
    for (const deviceId of deviceIds) {
      // One fixed-size row per omitted recipient; count only accepted envelopes,
      // not failed retries. Saturate before exceeding exact JSON integer range.
      this.storage.sql.exec(`
        INSERT INTO pending_recipient_skips (recipient_device_id, skipped_frames, skipped_bytes)
          VALUES (?, 1, ?)
          ON CONFLICT(recipient_device_id) DO UPDATE SET
            skipped_frames = MIN(9007199254740991, skipped_frames + 1),
            skipped_bytes = MIN(9007199254740991, skipped_bytes + excluded.skipped_bytes)
      `, deviceId, encodedBytes);
    }
  }

  consumeLegacyRescue(deviceId: string, epoch: number, sequence: number): void {
    this.storage.sql.exec(`
      UPDATE legacy_sender_rescue SET consumed = 1
      WHERE device_id = ? AND authorization_epoch = ? AND next_sequence = ? AND consumed = 0
    `, deviceId, epoch, sequence);
  }

  // Compatibility diagnostic only; production admission is per recipient.
  canRetain(encodedFrame: string, recipientCount: number): boolean {
    const usage = this.storage.sql.exec<{ encoded_bytes: number; frames: number }>(`
      SELECT encoded_bytes, (SELECT COUNT(*) FROM pending_frame_refs) AS frames
      FROM link_delivery_state WHERE singleton = 1
    `).one();
    // The canonical encrypted v1 envelope is ASCII. Use UTF-8 explicitly so the
    // storage budget remains correct if a future compatible envelope adds text.
    const incomingBytes = new TextEncoder().encode(encodedFrame).byteLength * recipientCount;
    const accepted = Number.isSafeInteger(incomingBytes)
      && usage.encoded_bytes + incomingBytes <= this.limits.bytes
      && usage.frames < this.limits.frames;
    if (!accepted) {
      console.info(JSON.stringify({
        event: "link_backpressure", reason: "storage_limit",
        retainedBytes: usage.encoded_bytes, retainedFrames: usage.frames,
        incomingBytes, recipientCount,
      }));
    }
    return accepted;
  }

  page(deviceId: string, afterOrder: number, availableSlots: number): PendingDelivery[] {
    // Only small metadata rows are materialized; each ciphertext is loaded alone.
    return this.storage.sql.exec<PendingDelivery>(`
      SELECT frame_id, delivery_order, encoded_bytes FROM pending_frames
      WHERE recipient_device_id = ? AND delivery_order > ?
      ORDER BY delivery_order LIMIT ?
    `, deviceId, afterOrder, Math.min(availableSlots, DELIVERY_WINDOW)).toArray();
  }

  inFlight(deviceId: string, throughOrder: number): { frames: number; bytes: number } {
    return this.storage.sql.exec<{ frames: number; bytes: number }>(`
      SELECT COUNT(*) AS frames, COALESCE(SUM(encoded_bytes), 0) AS bytes FROM pending_frames
      WHERE recipient_device_id = ? AND delivery_order <= ?
    `, deviceId, throughOrder).one();
  }

  encodedFrame(deviceId: string, frameId: string): string {
    const inline = this.storage.sql.exec<{ encoded_frame: string }>(`
      SELECT encoded_frame FROM pending_frames WHERE recipient_device_id = ? AND frame_id = ?
    `, deviceId, frameId).one().encoded_frame;
    if (inline.length > 0) return inline;
    return this.storage.sql.exec<{ encoded_chunk: string }>(`
      SELECT encoded_chunk FROM pending_frame_chunks
      WHERE recipient_device_id = ? AND frame_id = ? ORDER BY chunk_index
    `, deviceId, frameId).toArray().map((chunk) => chunk.encoded_chunk).join("");
  }
}
