import {
  type AccountProfileAvatar, type PublicAccountProfile, type SaveAccountProfile,
  parseSaveAccountProfile, LoopdyLinkError,
} from "./contracts.js";

interface AccountProfileRow extends Record<string, SqlStorageValue> {
  id: string;
  revision: number;
  encrypted_display_name: string;
  avatar_mime_type: string | null;
  avatar_byte_count: number | null;
  avatar_sha256: string | null;
  encrypted_avatar_data: string | null;
  updated_at: number;
}

// Retained indefinitely so a request authorized before D1 account removal can
// never recreate account data after this object's final purge or reinitialization.
const ACCOUNT_DELETION_TOMBSTONE_KEY = "account-deletion-tombstone-v1";
const ACCOUNT_DELETION_TOMBSTONE = Object.freeze({ version: 1 });

export class UserLinkAccount {
  constructor(private readonly ctx: DurableObjectState) {}

  beginAccountDeletion(): void {
    if (!this.isAccountDeleted()) {
      this.ctx.storage.transactionSync(() => {
        // Fence both live relay and notification egress in the serialized owner
        // before any external cleanup can block or fail.
        this.ctx.storage.sql.exec(
          "UPDATE managed_notification_scope SET state='retired' WHERE singleton=1",
        );
        this.ctx.storage.kv.put(ACCOUNT_DELETION_TOMBSTONE_KEY, ACCOUNT_DELETION_TOMBSTONE);
      });
    }
    for (const socket of this.ctx.getWebSockets()) {
      socket.close(4003, "account deleted");
    }
  }

  async deleteAccountData(): Promise<void> {
    this.beginAccountDeletion();
    this.ctx.storage.transactionSync(() => {
      // The tombstone and purge share one SQLite transaction. Sync KV is backed
      // by the object's hidden SQLite table, so no mutation can observe a gap.
      this.ctx.storage.kv.put(ACCOUNT_DELETION_TOMBSTONE_KEY, ACCOUNT_DELETION_TOMBSTONE);
      for (const [key] of this.ctx.storage.kv.list()) {
        if (key !== ACCOUNT_DELETION_TOMBSTONE_KEY) this.ctx.storage.kv.delete(key);
      }
      const tables = this.ctx.storage.sql.exec<{ name: string }>(
        `SELECT name FROM sqlite_master
         WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT GLOB '_cf_*'`,
      ).toArray();
      for (const { name } of tables) {
        this.ctx.storage.sql.exec(`DELETE FROM ${quotedIdentifier(name)}`);
      }
    });
    await this.ctx.storage.deleteAlarm();
    const residualRows = this.ctx.storage.sql.exec<{ name: string }>(
      `SELECT name FROM sqlite_master
       WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT GLOB '_cf_*'`,
    ).toArray().some(({ name }) =>
      this.ctx.storage.sql.exec<{ count: number }>(
        `SELECT COUNT(*) AS count FROM ${quotedIdentifier(name)}`,
      ).one().count !== 0);
    const residualKeys = [...this.ctx.storage.kv.list()].some(
      ([key]) => key !== ACCOUNT_DELETION_TOMBSTONE_KEY,
    );
    if (!this.isAccountDeleted() || residualRows || residualKeys) {
      throw new LoopdyLinkError("account_delete_incomplete", "Account relay data was not erased");
    }
  }

  loadAccountProfile(): PublicAccountProfile | null {
    this.assertAccountActive();
    const row = this.ctx.storage.sql
      .exec<AccountProfileRow>("SELECT * FROM account_profile WHERE id = 'current' LIMIT 1")
      .toArray()[0];
    if (!row) return null;
    return accountProfileProjection(row);
  }

  saveAccountProfile(input: SaveAccountProfile): PublicAccountProfile {
    this.assertAccountActive();
    const profile = parseSaveAccountProfile(input);
    return this.ctx.storage.transactionSync(() => {
      const current = this.loadAccountProfile();
      if ((current?.revision ?? 0) !== profile.expectedRevision) {
        throw new LoopdyLinkError(
          "stale_profile_revision",
          "Account profile changed. Refresh and try again.",
        );
      }
      const revision = profile.expectedRevision + 1;
      this.ctx.storage.sql
        .exec(
          `INSERT INTO account_profile (
             id, revision, encrypted_display_name, avatar_mime_type,
             avatar_byte_count, avatar_sha256, encrypted_avatar_data, updated_at
           ) VALUES ('current', ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(id) DO UPDATE SET
             revision = excluded.revision,
             encrypted_display_name = excluded.encrypted_display_name,
             avatar_mime_type = excluded.avatar_mime_type,
             avatar_byte_count = excluded.avatar_byte_count,
             avatar_sha256 = excluded.avatar_sha256,
             encrypted_avatar_data = excluded.encrypted_avatar_data,
             updated_at = excluded.updated_at`,
          revision,
          profile.encryptedDisplayName,
          profile.avatar?.mimeType ?? null,
          profile.avatar?.byteCount ?? null,
          profile.avatar?.sha256 ?? null,
          profile.avatar?.encryptedData ?? null,
          profile.updatedAt,
        )
        .toArray();
      return this.loadAccountProfile()!;
    });
  }

  isAccountDeleted(): boolean {
    return this.ctx.storage.kv.get<{ version?: unknown }>(ACCOUNT_DELETION_TOMBSTONE_KEY)?.version === 1;
  }

  assertAccountActive(): void {
    if (this.isAccountDeleted()) {
      throw new LoopdyLinkError("account_deleted", "Loopdy account was deleted");
    }
  }
}

function accountProfileProjection(row: AccountProfileRow): PublicAccountProfile {
  const avatar =
    row.avatar_mime_type && row.avatar_byte_count && row.avatar_sha256 && row.encrypted_avatar_data
      ? {
          mimeType: row.avatar_mime_type as AccountProfileAvatar["mimeType"],
          byteCount: row.avatar_byte_count,
          sha256: row.avatar_sha256,
          encryptedData: row.encrypted_avatar_data,
        }
      : null;
  return {
    revision: row.revision,
    encryptedDisplayName: row.encrypted_display_name,
    avatar,
    updatedAt: row.updated_at,
  };
}

function quotedIdentifier(value: string): string {
  return `"${value.replaceAll('"', '""')}"`;
}
