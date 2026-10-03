export function initializeUserLinkStorage(storage: DurableObjectStorage): void {
  storage.sql.exec(`
    CREATE TABLE IF NOT EXISTS devices (
      device_id TEXT PRIMARY KEY,
      public_key TEXT NOT NULL,
      role TEXT NOT NULL CHECK (role IN ('mobile', 'host')),
      kind TEXT NOT NULL CHECK (kind IN ('phone', 'tablet', 'computer', 'hermes_host')),
      encrypted_name TEXT NOT NULL,
      lifecycle TEXT NOT NULL CHECK (lifecycle IN ('active', 'revoked')),
      revision INTEGER NOT NULL CHECK (revision > 0),
      authorization_epoch INTEGER NOT NULL CHECK (authorization_epoch > 0),
      connection_state TEXT NOT NULL CHECK (connection_state IN ('online', 'recent', 'offline')),
      push_state TEXT,
      push_revision INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      revoked_at INTEGER,
      last_seen_bucket INTEGER,
      last_inbound_sequence INTEGER NOT NULL DEFAULT 0,
      last_ack_sequence INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS devices_lifecycle_idx
      ON devices (lifecycle, role, created_at, device_id);
    CREATE TABLE IF NOT EXISTS host_grants (
      host_device_id TEXT PRIMARY KEY,
      state TEXT NOT NULL CHECK (state IN ('active', 'revoked')),
      created_at INTEGER NOT NULL,
      revoked_at INTEGER
    );
    CREATE TABLE IF NOT EXISTS frame_ids (
      frame_id TEXT PRIMARY KEY,
      sender_device_id TEXT NOT NULL,
      sequence INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS frame_ids_sender_idx
      ON frame_ids (sender_device_id, sequence DESC);
    CREATE TABLE IF NOT EXISTS pending_frames (
      recipient_device_id TEXT NOT NULL,
      sender_device_id TEXT NOT NULL,
      frame_id TEXT NOT NULL,
      sequence INTEGER NOT NULL,
      encoded_frame TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      PRIMARY KEY (recipient_device_id, frame_id)
    );
    CREATE INDEX IF NOT EXISTS pending_frames_recipient_idx
      ON pending_frames (recipient_device_id, created_at, sender_device_id, sequence);
    CREATE TABLE IF NOT EXISTS pending_frame_chunks (
      recipient_device_id TEXT NOT NULL,
      frame_id TEXT NOT NULL,
      chunk_index INTEGER NOT NULL CHECK (chunk_index >= 0),
      encoded_chunk TEXT NOT NULL,
      PRIMARY KEY (recipient_device_id, frame_id, chunk_index)
    );
    CREATE TABLE IF NOT EXISTS buzzkit_wake_outbox (
      frame_id TEXT PRIMARY KEY,
      account_coordinate TEXT NOT NULL,
      host_device_id TEXT NOT NULL,
      host_epoch INTEGER NOT NULL,
      expires_at INTEGER NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      next_attempt INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS buzzkit_wake_outbox_due_idx
      ON buzzkit_wake_outbox (next_attempt, expires_at);
    CREATE TABLE IF NOT EXISTS account_profile (
      id TEXT PRIMARY KEY CHECK (id = 'current'),
      revision INTEGER NOT NULL CHECK (revision >= 0),
      encrypted_display_name TEXT NOT NULL,
      avatar_mime_type TEXT,
      avatar_byte_count INTEGER,
      avatar_sha256 TEXT,
      encrypted_avatar_data TEXT,
      updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS notification_assets (
      asset_id TEXT PRIMARY KEY,
      mime_type TEXT NOT NULL,
      data BLOB NOT NULL,
      expires_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS notification_assets_expiry_idx
      ON notification_assets (expires_at);
    CREATE TABLE IF NOT EXISTS managed_notification_activities (
      activity_id TEXT PRIMARY KEY,
      grant_id TEXT NOT NULL,
      session_reference TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('active', 'ended', 'revoked')),
      revision INTEGER NOT NULL CHECK (revision > 0),
      lease_expires INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      last_update_id TEXT,
      last_update_state TEXT CHECK (last_update_state IS NULL OR last_update_state IN ('pending','accepted')),
      last_update_timestamp INTEGER
    );
    CREATE INDEX IF NOT EXISTS managed_notification_activities_grant_idx
      ON managed_notification_activities (grant_id, status, lease_expires);
    CREATE TABLE IF NOT EXISTS managed_notification_credentials (
      credential_id TEXT PRIMARY KEY,
      authorization_epoch INTEGER NOT NULL CHECK (authorization_epoch > 0),
      state TEXT NOT NULL CHECK (state IN ('active', 'revoked'))
    );
    CREATE TABLE IF NOT EXISTS managed_notification_grants (
      grant_id TEXT PRIMARY KEY,
      credential_id TEXT NOT NULL,
      authorization_epoch INTEGER NOT NULL CHECK (authorization_epoch > 0),
      revision INTEGER NOT NULL CHECK (revision > 0),
      state TEXT NOT NULL CHECK (state IN ('active', 'revoked')),
      expires_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS managed_notification_scope (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
      state TEXT NOT NULL CHECK (state IN ('active', 'retired'))
    );
    INSERT OR IGNORE INTO managed_notification_scope(singleton,state) VALUES(1,'active');
  `);
  const columns = new Set(
    storage.sql
      .exec<{ name: string }>("PRAGMA table_info(devices)")
      .toArray()
      .map((column) => column.name),
  );
  for (const [name, statement] of [
    ["last_inbound_sequence", "ALTER TABLE devices ADD COLUMN last_inbound_sequence INTEGER NOT NULL DEFAULT 0"],
    ["last_ack_sequence", "ALTER TABLE devices ADD COLUMN last_ack_sequence INTEGER NOT NULL DEFAULT 0"],
    ["push_revision", "ALTER TABLE devices ADD COLUMN push_revision INTEGER NOT NULL DEFAULT 0"],
  ] as const) {
    if (!columns.has(name)) storage.sql.exec(statement);
  }
}
