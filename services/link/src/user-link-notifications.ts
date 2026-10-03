import { LoopdyLinkError } from "./contracts.js";
import type { NotificationActivity, NotificationAsset, NotificationEgressSnapshot } from "./notification-grants.js";
import type { UserLinkAccount } from "./user-link-account.js";

interface ManagedNotificationActivityRow extends Record<string, SqlStorageValue> {
  activity_id: string;
  grant_id: string;
  session_reference: string;
  status: string;
  revision: number;
  lease_expires: number;
  updated_at: number;
  last_update_id: string | null;
  last_update_state: string | null;
  last_update_timestamp: number | null;
}

const DEVICE_COORDINATE = /^[A-Za-z0-9_-]{1,96}$/;
const GRANT_COORDINATE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

// This is a synchronous component of UserLink, not another authority or RPC
// boundary. All egress/revocation decisions remain in its serialized owner.
/** Agent avatars, plus sealed avatars only the recipient phone can open. */
const NOTIFICATION_ASSET_TYPES: string[] = ["image/png", "image/jpeg", "image/webp", "application/octet-stream"];

// A lease that just ran out can still get its final update, so its record
// stays an hour longer.
export const ACTIVITY_RECORD_GRACE_SECONDS = 3_600;

export class UserLinkNotificationStore {
  constructor(
    private readonly storage: DurableObjectStorage,
    private readonly account: UserLinkAccount,
    private readonly requiredActiveDevice: (deviceId: string) => { role: string; authorization_epoch: number },
  ) {}

  putNotificationAsset(input: NotificationAsset): NotificationAsset {
    this.account.assertAccountActive();
    if (!/^[A-Za-z0-9_-]{43}$/.test(input.assetId)
        || !NOTIFICATION_ASSET_TYPES.includes(input.mimeType)
        || !(input.data instanceof Uint8Array) || input.data.byteLength < 1
        || input.data.byteLength > 524_304 || !positiveInteger(input.expiresAt)) {
      throw new LoopdyLinkError("notification_asset_invalid", "Notification avatar is invalid");
    }
    this.storage.sql.exec(
      "DELETE FROM notification_assets WHERE expires_at<=?",
      Math.floor(Date.now() / 1_000),
    );
    this.storage.sql.exec(
      `INSERT INTO notification_assets(asset_id,mime_type,data,expires_at)
       VALUES(?,?,?,?) ON CONFLICT(asset_id) DO UPDATE SET
       mime_type=excluded.mime_type,data=excluded.data,
       expires_at=MAX(notification_assets.expires_at,excluded.expires_at)`,
      input.assetId, input.mimeType, input.data, input.expiresAt,
    );
    return input;
  }

  notificationAsset(input: { assetId: string; now: number }): NotificationAsset | null {
    this.account.assertAccountActive();
    if (!/^[A-Za-z0-9_-]{43}$/.test(input.assetId) || !positiveInteger(input.now)) return null;
    this.storage.sql.exec("DELETE FROM notification_assets WHERE expires_at<=?", input.now);
    const row = this.storage.sql.exec<{
      asset_id: string; mime_type: string; data: ArrayBuffer; expires_at: number;
    }>(
      "SELECT * FROM notification_assets WHERE asset_id=? AND expires_at>? LIMIT 1",
      input.assetId, input.now,
    ).toArray()[0];
    if (!row || !NOTIFICATION_ASSET_TYPES.includes(row.mime_type)) return null;
    return {
      assetId: row.asset_id,
      mimeType: row.mime_type as NotificationAsset["mimeType"],
      data: new Uint8Array(row.data),
      expiresAt: row.expires_at,
    };
  }

  registerNotificationActivity(
    input: NotificationActivity & { timestamp: number },
  ): NotificationActivity {
    this.account.assertAccountActive();
    validateManagedNotificationActivity(input);
    return this.storage.transactionSync(() => {
      const current = this.readManagedNotificationActivity(input.activityId);
      if (current) {
        if (current.grant_id !== input.grantId || current.session_reference !== input.sessionReference
            || current.status !== "active" || input.revision < current.revision
            || input.revision > current.revision + 1) {
          throw new LoopdyLinkError(
            "notification_activity_conflict",
            "Notification activity conflicts with state",
          );
        }
        if (input.revision === current.revision && input.leaseExpires === current.lease_expires) {
          return managedNotificationActivityProjection(current);
        }
      }
      this.storage.sql.exec(
        `INSERT INTO managed_notification_activities(
           activity_id,grant_id,session_reference,status,revision,lease_expires,updated_at)
         VALUES(?,?,?,'active',?,?,?) ON CONFLICT(activity_id) DO UPDATE SET
           status='active',revision=excluded.revision,lease_expires=excluded.lease_expires,
           updated_at=excluded.updated_at,last_update_id=NULL,last_update_state=NULL,
           last_update_timestamp=NULL`,
        input.activityId, input.grantId, input.sessionReference, input.revision,
        input.leaseExpires, input.timestamp,
      );
      return managedNotificationActivityProjection(
        this.requiredManagedNotificationActivity(input.activityId),
      );
    });
  }

  notificationActivity(input: {
    grantId: string; activityId: string; now: number;
  }): NotificationActivity {
    this.account.assertAccountActive();
    if (!GRANT_COORDINATE.test(input.grantId) || !DEVICE_COORDINATE.test(input.activityId)
        || !positiveInteger(input.now)) {
      throw new LoopdyLinkError("notification_activity_invalid", "Notification activity is invalid");
    }
    const row = this.requiredManagedNotificationActivity(input.activityId);
    if (row.grant_id !== input.grantId || row.lease_expires <= input.now) {
      throw new LoopdyLinkError("notification_activity_inactive", "Notification activity is inactive");
    }
    return managedNotificationActivityProjection(row);
  }

  revokeNotificationActivity(input: {
    grantId: string; activityId: string; revision: number; timestamp: number;
  }): NotificationActivity {
    this.account.assertAccountActive();
    if (!GRANT_COORDINATE.test(input.grantId) || !DEVICE_COORDINATE.test(input.activityId)
        || !positiveInteger(input.revision) || !positiveInteger(input.timestamp)) {
      throw new LoopdyLinkError("notification_activity_invalid", "Notification activity is invalid");
    }
    const current = this.requiredManagedNotificationActivity(input.activityId);
    if (current.grant_id !== input.grantId
        || (current.status === "active" && input.revision !== current.revision + 1)
        || (current.status !== "active" && input.revision !== current.revision)) {
      throw new LoopdyLinkError(
        "notification_activity_conflict",
        "Notification activity conflicts with state",
      );
    }
    if (current.status === "active") {
      this.storage.sql.exec(
        `UPDATE managed_notification_activities
         SET status='revoked',revision=?,updated_at=?
         WHERE activity_id=? AND grant_id=? AND status='active'`,
        input.revision, input.timestamp, input.activityId, input.grantId,
      );
    }
    return managedNotificationActivityProjection(
      this.requiredManagedNotificationActivity(input.activityId),
    );
  }

  revokeNotificationGrantActivities(input: { grantId: string; timestamp: number }): void {
    this.account.assertAccountActive();
    if (!GRANT_COORDINATE.test(input.grantId) || !positiveInteger(input.timestamp)) {
      throw new LoopdyLinkError("notification_activity_invalid", "Notification activity is invalid");
    }
    this.storage.sql.exec(
      `UPDATE managed_notification_activities
       SET status='revoked',revision=revision+1,updated_at=?
       WHERE grant_id=? AND status='active'`,
      input.timestamp, input.grantId,
    );
  }

  authorizeNotificationEgress(input: NotificationEgressSnapshot): void {
    this.account.assertAccountActive();
    if (!DEVICE_COORDINATE.test(input.credentialId) || !positiveInteger(input.authorizationEpoch)
        || !positiveInteger(input.now)) {
      throw new LoopdyLinkError("notification_credentials_revoked", "Notification authority is invalid");
    }
    this.storage.transactionSync(() => {
      const currentNow = Math.floor(Date.now() / 1_000);
      const scope = this.storage.sql.exec<{ state: string }>(
        "SELECT state FROM managed_notification_scope WHERE singleton=1",
      ).one();
      if (scope.state !== "active") {
        throw new LoopdyLinkError("notification_account_scope_retired", "Notification scope is retired");
      }
      if (input.ownerKind === "account") {
        const device = this.requiredActiveDevice(input.credentialId);
        if (device.role !== "mobile" || device.authorization_epoch !== input.authorizationEpoch) {
          throw new LoopdyLinkError("notification_credentials_revoked", "Notification credential is revoked");
        }
      } else {
        this.storage.sql.exec(
          `INSERT INTO managed_notification_credentials(credential_id,authorization_epoch,state)
           VALUES(?,?,'active') ON CONFLICT(credential_id) DO NOTHING`,
          input.credentialId, input.authorizationEpoch,
        );
        const credential = this.storage.sql.exec<{ authorization_epoch: number; state: string }>(
          "SELECT authorization_epoch,state FROM managed_notification_credentials WHERE credential_id=?",
          input.credentialId,
        ).one();
        if (credential.state !== "active" || credential.authorization_epoch !== input.authorizationEpoch) {
          throw new LoopdyLinkError("notification_credentials_revoked", "Notification credential is revoked");
        }
      }
      if (input.grant) {
        this.storage.sql.exec(
          `INSERT INTO managed_notification_grants(
             grant_id,credential_id,authorization_epoch,revision,state,expires_at)
           VALUES(?,?,?,?,'active',?) ON CONFLICT(grant_id) DO NOTHING`,
          input.grant.grantId, input.credentialId, input.authorizationEpoch,
          input.grant.revision, input.grant.expiresAt,
        );
        const grant = this.storage.sql.exec<{
          credential_id: string; authorization_epoch: number; revision: number;
          state: string; expires_at: number;
        }>(
          `SELECT credential_id,authorization_epoch,revision,state,expires_at
           FROM managed_notification_grants WHERE grant_id=?`,
          input.grant.grantId,
        ).one();
        if (grant.state !== "active" || grant.credential_id !== input.credentialId
            || grant.authorization_epoch !== input.authorizationEpoch
            || grant.revision !== input.grant.revision || grant.expires_at !== input.grant.expiresAt
            || grant.expires_at <= currentNow) {
          throw new LoopdyLinkError("notification_grant_inactive", "Notification grant is inactive");
        }
      }
      if (input.activity) {
        const activity = this.requiredManagedNotificationActivity(input.activity.activityId);
        if (!input.grant || activity.grant_id !== input.grant.grantId
            || activity.status !== "active"
            || activity.session_reference !== input.activity.sessionReference
            || activity.lease_expires !== input.activity.leaseExpires
            || activity.lease_expires <= currentNow) {
          throw new LoopdyLinkError("notification_activity_inactive", "Notification activity is inactive");
        }
      }
    });
  }

  revokeNotificationCredential(input: {
    credentialId: string; authorizationEpoch: number;
  }): void {
    this.account.assertAccountActive();
    if (!DEVICE_COORDINATE.test(input.credentialId) || !positiveInteger(input.authorizationEpoch)) {
      throw new LoopdyLinkError("notification_credentials_revoked", "Notification credential is invalid");
    }
    this.storage.transactionSync(() => {
      this.storage.sql.exec(
        `INSERT INTO managed_notification_credentials(credential_id,authorization_epoch,state)
         VALUES(?,?,'revoked') ON CONFLICT(credential_id) DO UPDATE SET
         authorization_epoch=MAX(managed_notification_credentials.authorization_epoch,excluded.authorization_epoch),
         state='revoked'`,
        input.credentialId, input.authorizationEpoch,
      );
      // Only a notification-only installation's own owner is revoked this way,
      // so everything it holds is that phone's: delete its avatars and Live
      // Activity records now rather than when they expire.
      this.storage.sql.exec("DELETE FROM notification_assets");
      this.storage.sql.exec("DELETE FROM managed_notification_activities");
    });
  }

  revokeNotificationGrantAuthority(input: {
    grantId: string; credentialId: string; authorizationEpoch: number; revision: number;
  }): void {
    this.account.assertAccountActive();
    if (!GRANT_COORDINATE.test(input.grantId) || !DEVICE_COORDINATE.test(input.credentialId)
        || !positiveInteger(input.authorizationEpoch) || !positiveInteger(input.revision)) {
      throw new LoopdyLinkError("notification_grant_inactive", "Notification grant is invalid");
    }
    this.storage.transactionSync(() => {
      this.storage.sql.exec(
        `INSERT INTO managed_notification_grants(
           grant_id,credential_id,authorization_epoch,revision,state,expires_at)
         VALUES(?,?,?,?,'revoked',0) ON CONFLICT(grant_id) DO UPDATE SET
         revision=MAX(managed_notification_grants.revision,excluded.revision),state='revoked'
         WHERE excluded.revision>=managed_notification_grants.revision`,
        input.grantId, input.credentialId, input.authorizationEpoch, input.revision,
      );
      this.storage.sql.exec(
        `UPDATE managed_notification_activities
         SET status='revoked',revision=revision+1
         WHERE grant_id=? AND status='active'`,
        input.grantId,
      );
    });
  }

  retireDeletedAccountNotificationGrantAuthority(input: {
    grantId: string; credentialId: string; authorizationEpoch: number; revision: number;
  }): void {
    // This is deliberately separate from ordinary grant revocation. It admits
    // only the narrow cleanup continuation created by beginAccountDeletion's
    // atomic tombstone/scope-retirement transaction.
    if (!this.account.isAccountDeleted()) {
      throw new LoopdyLinkError("notification_grant_inactive", "Deletion cleanup is not authorized");
    }
    if (!GRANT_COORDINATE.test(input.grantId) || !DEVICE_COORDINATE.test(input.credentialId)
        || !positiveInteger(input.authorizationEpoch) || !positiveInteger(input.revision)) {
      throw new LoopdyLinkError("notification_grant_inactive", "Notification grant is invalid");
    }
    this.storage.transactionSync(() => {
      const scope = this.storage.sql.exec<{ state: string }>(
        "SELECT state FROM managed_notification_scope WHERE singleton=1",
      ).one();
      if (scope.state !== "retired") {
        throw new LoopdyLinkError("notification_grant_inactive", "Deletion cleanup is not authorized");
      }
      const existing = this.storage.sql.exec<{
        credential_id: string; authorization_epoch: number;
      }>(
        "SELECT credential_id,authorization_epoch FROM managed_notification_grants WHERE grant_id=?",
        input.grantId,
      ).toArray()[0];
      if (existing && (existing.credential_id !== input.credentialId
          || existing.authorization_epoch !== input.authorizationEpoch)) {
        throw new LoopdyLinkError("notification_grant_inactive", "Notification grant ownership conflicts");
      }
      this.storage.sql.exec(
        `INSERT INTO managed_notification_grants(
           grant_id,credential_id,authorization_epoch,revision,state,expires_at)
         VALUES(?,?,?,?,'revoked',0) ON CONFLICT(grant_id) DO UPDATE SET
         revision=MAX(managed_notification_grants.revision,excluded.revision),state='revoked'`,
        input.grantId, input.credentialId, input.authorizationEpoch, input.revision,
      );
      this.storage.sql.exec(
        `UPDATE managed_notification_activities
         SET status='revoked',revision=revision+1
         WHERE grant_id=? AND status='active'`,
        input.grantId,
      );
    });
  }

  retireNotificationScope(): void {
    // beginAccountDeletion retires this scope atomically with the live relay
    // fence. Provider-cleanup retries after acceptance are idempotent no-ops.
    if (this.account.isAccountDeleted()) return;
    this.storage.sql.exec(
      "UPDATE managed_notification_scope SET state='retired' WHERE singleton=1",
    );
  }

  beginNotificationActivityUpdate(input: {
    grantId: string; activityId: string; updateId: string; timestamp: number;
  }): { status: "send" | "duplicate" } {
    this.account.assertAccountActive();
    if (!GRANT_COORDINATE.test(input.grantId) || !DEVICE_COORDINATE.test(input.activityId)
        || !/^[A-Za-z0-9_-]{43}$/.test(input.updateId) || !positiveInteger(input.timestamp)) {
      throw new LoopdyLinkError("notification_activity_invalid", "Notification activity is invalid");
    }
    return this.storage.transactionSync(() => {
      const row = this.requiredManagedNotificationActivity(input.activityId);
      if (row.grant_id !== input.grantId || row.status !== "active") {
        throw new LoopdyLinkError("notification_activity_inactive", "Notification activity is inactive");
      }
      if (row.last_update_id === input.updateId && row.last_update_state === "accepted") {
        return { status: "duplicate" };
      }
      if (row.last_update_timestamp !== null && input.timestamp < row.last_update_timestamp) {
        throw new LoopdyLinkError("notification_activity_stale", "Notification activity update is stale");
      }
      this.storage.sql.exec(
        `UPDATE managed_notification_activities
         SET last_update_id=?,last_update_state='pending',last_update_timestamp=?,updated_at=?
         WHERE activity_id=? AND grant_id=? AND status='active'`,
        input.updateId, input.timestamp, input.timestamp, input.activityId, input.grantId,
      );
      return { status: "send" };
    });
  }

  completeNotificationActivityUpdate(input: {
    grantId: string; activityId: string; updateId: string; timestamp: number; terminal: boolean;
  }): void {
    this.account.assertAccountActive();
    if (!GRANT_COORDINATE.test(input.grantId) || !DEVICE_COORDINATE.test(input.activityId)
        || !/^[A-Za-z0-9_-]{43}$/.test(input.updateId) || !positiveInteger(input.timestamp)
        || typeof input.terminal !== "boolean") {
      throw new LoopdyLinkError("notification_activity_invalid", "Notification activity is invalid");
    }
    this.storage.sql.exec(
      `UPDATE managed_notification_activities SET
       last_update_state='accepted',status=CASE WHEN ? THEN 'ended' ELSE status END,updated_at=?
       WHERE activity_id=? AND grant_id=? AND last_update_id=? AND last_update_state='pending'`,
      input.terminal ? 1 : 0, input.timestamp, input.activityId, input.grantId, input.updateId,
    );
  }

  /**
   * Deletes avatars past their link expiry and Live Activity records an hour
   * after their lease ends. Returns when the next row expires, so the alarm
   * can come back for it.
   */
  purgeExpiredNotificationState(now: number): number | null {
    this.storage.sql.exec("DELETE FROM notification_assets WHERE expires_at<=?", now);
    this.storage.sql.exec(
      "DELETE FROM managed_notification_activities WHERE lease_expires<=?",
      now - ACTIVITY_RECORD_GRACE_SECONDS,
    );
    const asset = this.storage.sql.exec<{ next: number | null }>(
      "SELECT MIN(expires_at) AS next FROM notification_assets",
    ).one().next;
    const activity = this.storage.sql.exec<{ next: number | null }>(
      "SELECT MIN(lease_expires)+? AS next FROM managed_notification_activities",
      ACTIVITY_RECORD_GRACE_SECONDS,
    ).one().next;
    return [asset, activity].filter((value): value is number => value !== null)
      .reduce<number | null>((selected, value) => selected === null ? value : Math.min(selected, value), null);
  }

  private readManagedNotificationActivity(
    activityId: string,
  ): ManagedNotificationActivityRow | undefined {
    return this.storage.sql
      .exec<ManagedNotificationActivityRow>(
        "SELECT * FROM managed_notification_activities WHERE activity_id = ? LIMIT 1",
        activityId,
      )
      .toArray()[0];
  }

  private requiredManagedNotificationActivity(activityId: string): ManagedNotificationActivityRow {
    const row = this.readManagedNotificationActivity(activityId);
    if (!row) {
      throw new LoopdyLinkError(
        "notification_activity_unknown",
        "Notification activity was not found",
      );
    }
    return row;
  }
}

function managedNotificationActivityProjection(
  row: ManagedNotificationActivityRow,
): NotificationActivity {
  return {
    activityId: row.activity_id,
    grantId: row.grant_id,
    sessionReference: row.session_reference,
    revision: row.revision,
    leaseExpires: row.lease_expires,
    status: row.status as NotificationActivity["status"],
  };
}

function validateManagedNotificationActivity(
  input: NotificationActivity & { timestamp: number },
): void {
  if (!DEVICE_COORDINATE.test(input.activityId) || !GRANT_COORDINATE.test(input.grantId)
      || !/^[A-Za-z0-9_-]{43}$/.test(input.sessionReference)
      || input.status !== "active" || !positiveInteger(input.revision)
      || !positiveInteger(input.leaseExpires) || !positiveInteger(input.timestamp)
      || input.leaseExpires <= input.timestamp || input.leaseExpires - input.timestamp > 28_800) {
    throw new LoopdyLinkError("notification_activity_invalid", "Notification activity is invalid");
  }
}

function positiveInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) > 0;
}
