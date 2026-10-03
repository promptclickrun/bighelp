import type { EncryptedLinkFrame } from "./frame.js";
import type { LinkSocketAttachment } from "./socket-attachment.js";

export const STATE_BACKED_PRESENTATION_CAPABILITY = "state-backed-presentation-v1";
// Independent of the durable receipt pump. Never recycle unreceipted capacity on
// overflow: ws.send() is nonblocking and could otherwise buffer without bound.
export const PRESENTATION_FRAME_WINDOW = 32;
export const PRESENTATION_BYTE_WINDOW = 262_144;
export const PRESENTATION_RESET_CLOSE_CODE = 4005;

interface PresentationDeviceRow extends Record<string, SqlStorageValue> {
  device_id: string;
  authorization_epoch: number;
  enabled: number;
  connection_id: string | null;
  pending_frame_id: string | null;
  needs_reset: number;
  reset_notified: number;
}

export type PresentationResetReason = "reconnect" | "gap" | "overflow";

/** Metadata-only state. This store never receives or persists ciphertext. */
export class StatePresentationStore {
  constructor(private readonly storage: DurableObjectStorage) {}

  initialize(): void {
    // Additive migration, separate from pending-delivery's schema and triggers.
    // A missing row/epoch/capability is legacy. Never inspect historical payloads.
    this.storage.transactionSync(() => {
      this.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS link_presentation_devices (
          device_id TEXT PRIMARY KEY,
          authorization_epoch INTEGER NOT NULL CHECK (authorization_epoch > 0),
          enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
          connection_id TEXT,
          pending_frame_id TEXT,
          needs_reset INTEGER NOT NULL DEFAULT 0 CHECK (needs_reset IN (0, 1)),
          reset_notified INTEGER NOT NULL DEFAULT 0 CHECK (reset_notified IN (0, 1))
        );
        CREATE TABLE IF NOT EXISTS link_presentation_receipts (
          recipient_device_id TEXT NOT NULL,
          connection_id TEXT NOT NULL,
          sender_device_id TEXT NOT NULL,
          sender_epoch INTEGER NOT NULL,
          frame_id TEXT NOT NULL,
          sequence INTEGER NOT NULL,
          encoded_bytes INTEGER NOT NULL CHECK (encoded_bytes > 0),
          PRIMARY KEY (recipient_device_id, frame_id)
        );
        CREATE INDEX IF NOT EXISTS link_presentation_receipts_frame_idx
          ON link_presentation_receipts (frame_id);
      `);
    });
  }

  negotiate(deviceId: string, epoch: number, enabled: boolean, connectionId: string): void {
    this.storage.transactionSync(() => {
      // Only ephemeral receipt metadata is cleared; accepted durable rows survive
      // upgrade, downgrade, reconnect and migration byte-for-byte.
      this.storage.sql.exec(
        "DELETE FROM link_presentation_receipts WHERE recipient_device_id = ?", deviceId,
      );
      this.storage.sql.exec(`
        INSERT INTO link_presentation_devices (
          device_id, authorization_epoch, enabled, connection_id,
          pending_frame_id, needs_reset, reset_notified
        ) VALUES (?, ?, ?, ?, NULL, 0, 0)
        ON CONFLICT(device_id) DO UPDATE SET
          authorization_epoch = excluded.authorization_epoch,
          enabled = excluded.enabled, connection_id = excluded.connection_id,
          pending_frame_id = NULL, needs_reset = 0, reset_notified = 0
      `, deviceId, epoch, enabled ? 1 : 0, connectionId);
    });
  }

  isEnabled(deviceId: string, epoch: number): boolean {
    const row = this.read(deviceId);
    return row?.enabled === 1 && row.authorization_epoch === epoch;
  }

  ownsConnection(attachment: LinkSocketAttachment): boolean {
    return this.connection(attachment) !== undefined;
  }

  /** Run inside the sender acceptance transaction, even for offline recipients. */
  recordAcceptance(deviceIds: readonly string[], frameId: string): void {
    for (const deviceId of deviceIds) {
      this.storage.sql.exec(`
        UPDATE link_presentation_devices SET
          needs_reset = CASE WHEN pending_frame_id IS NOT NULL THEN 1 ELSE needs_reset END,
          pending_frame_id = ?
        WHERE device_id = ? AND enabled = 1
      `, frameId, deviceId);
    }
  }

  /** Called after hibernation, or on the idempotent retry of an accepted frame. */
  recoverGap(socket: WebSocket, attachment: LinkSocketAttachment): void {
    const row = this.connection(attachment);
    if (row && row.pending_frame_id !== null) {
      this.reset(socket, attachment, "gap");
    }
  }

  reset(socket: WebSocket, attachment: LinkSocketAttachment, reason: PresentationResetReason): void {
    const row = this.connection(attachment);
    if (!row || socket.readyState !== WebSocket.OPEN) return;
    const encoded = JSON.stringify({
      version: 1, type: "presentation.reset", deviceId: attachment.deviceId,
      authorizationEpoch: attachment.authorizationEpoch, reason,
    });
    if (reason === "reconnect") {
      // This reset covers the previous connection only. It must not suppress a
      // later overflow which occurs after the receiver has installed its state.
      socket.send(encoded);
      return;
    }
    this.storage.sql.exec(`
      UPDATE link_presentation_devices SET needs_reset = 1
      WHERE device_id = ? AND connection_id = ?
    `, attachment.deviceId, attachment.presentationConnectionId!);
    if (row.reset_notified !== 1) {
      socket.send(encoded);
      // Persist after send; a crash can duplicate a reset, never hide one.
      this.storage.sql.exec(`
        UPDATE link_presentation_devices SET reset_notified = 1
        WHERE device_id = ? AND connection_id = ?
      `, attachment.deviceId, attachment.presentationConnectionId!);
    }
    // A gap ends this subscription. Silently resuming after receipts drain could
    // miss the *last* dropped update while a snapshot was in flight. A fresh
    // authenticated connection establishes the next subscribe-before-state fence.
    // Only this recipient reconnects; its durable backlog remains untouched.
    socket.close(PRESENTATION_RESET_CLOSE_CODE, "presentation state reset");
  }

  /** Reserve before ws.send; finish only after send returns successfully. */
  reserve(
    socket: WebSocket, attachment: LinkSocketAttachment,
    frame: Pick<EncryptedLinkFrame, "id" | "senderDeviceId" | "senderEpoch" | "sequence">, encodedBytes: number,
  ): boolean {
    const row = this.connection(attachment);
    if (!row || row.pending_frame_id !== frame.id || socket.readyState !== WebSocket.OPEN) return false;
    const usage = this.storage.sql.exec<{ frames: number; bytes: number }>(`
      SELECT COUNT(*) AS frames, COALESCE(SUM(encoded_bytes), 0) AS bytes
      FROM link_presentation_receipts WHERE recipient_device_id = ? AND connection_id = ?
    `, attachment.deviceId, attachment.presentationConnectionId!).one();
    if (usage.frames >= PRESENTATION_FRAME_WINDOW || usage.bytes + encodedBytes > PRESENTATION_BYTE_WINDOW) {
      this.reset(socket, attachment, "overflow");
      return false;
    }
    if (row.needs_reset === 1) {
      this.reset(socket, attachment, "gap");
      return false;
    }
    this.storage.sql.exec(`
      INSERT INTO link_presentation_receipts (
        recipient_device_id, connection_id, sender_device_id, sender_epoch, frame_id, sequence, encoded_bytes
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
    `, attachment.deviceId, attachment.presentationConnectionId!, frame.senderDeviceId,
    frame.senderEpoch, frame.id, frame.sequence, encodedBytes);
    return true;
  }

  finish(attachment: LinkSocketAttachment, frameId: string): void {
    this.storage.sql.exec(`
      UPDATE link_presentation_devices SET pending_frame_id = NULL, needs_reset = 0, reset_notified = 0
      WHERE device_id = ? AND authorization_epoch = ? AND connection_id = ? AND pending_frame_id = ?
    `, attachment.deviceId, attachment.authorizationEpoch, attachment.presentationConnectionId!, frameId);
  }

  receipt(
    attachment: LinkSocketAttachment, receipt: { frameId: string; sourceDeviceId: string; sequence: number },
  ): void {
    if (!this.connection(attachment)) return;
    // Never free capacity with a different device, source, frame, sequence or
    // replaced socket. Durable receipts still execute through the original path.
    this.storage.sql.exec(`
      DELETE FROM link_presentation_receipts WHERE recipient_device_id = ? AND connection_id = ?
        AND frame_id = ? AND sender_device_id = ? AND sequence = ?
    `, attachment.deviceId, attachment.presentationConnectionId!, receipt.frameId,
    receipt.sourceDeviceId, receipt.sequence);
  }

  disconnect(attachment: LinkSocketAttachment): void {
    if (!this.connection(attachment)) return;
    this.storage.transactionSync(() => {
      this.storage.sql.exec(`
        DELETE FROM link_presentation_receipts WHERE recipient_device_id = ? AND connection_id = ?
      `, attachment.deviceId, attachment.presentationConnectionId!);
      // Preserve opted-in epoch while offline; a legacy reconnect clears it.
      this.storage.sql.exec(`
        UPDATE link_presentation_devices SET connection_id = NULL, needs_reset = 1, reset_notified = 0
        WHERE device_id = ? AND connection_id = ?
      `, attachment.deviceId, attachment.presentationConnectionId!);
    });
  }

  revoke(deviceId: string): void {
    this.storage.sql.exec(
      "DELETE FROM link_presentation_receipts WHERE recipient_device_id = ?", deviceId,
    );
    // Sender metadata is already bounded; keep it until receipt/disconnect. Freeing
    // an unreceipted send on host revocation would bypass the real socket window.
    this.storage.sql.exec("DELETE FROM link_presentation_devices WHERE device_id = ?", deviceId);
  }

  private connection(attachment: LinkSocketAttachment): PresentationDeviceRow | undefined {
    if (attachment.stateBackedPresentationV1 !== true || !attachment.presentationConnectionId) return undefined;
    const row = this.read(attachment.deviceId);
    if (row?.enabled !== 1 || row.authorization_epoch !== attachment.authorizationEpoch ||
        row.connection_id !== attachment.presentationConnectionId) return undefined;
    return row;
  }

  private read(deviceId: string): PresentationDeviceRow | undefined {
    return this.storage.sql.exec<PresentationDeviceRow>(
      "SELECT * FROM link_presentation_devices WHERE device_id = ?", deviceId,
    ).toArray()[0];
  }
}
