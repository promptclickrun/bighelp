-- Read-only schema capture from the existing primary relay. No customer data.
-- Used only to construct an isolated integration-test database.
CREATE TABLE activity_tombstones (
  tenant_id TEXT NOT NULL,
  activity_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  revoked_at INTEGER NOT NULL,
  PRIMARY KEY (tenant_id, activity_id),
  FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id)
);

CREATE TABLE admission_guards (
  guard_id TEXT PRIMARY KEY NOT NULL
);

CREATE TABLE daily_usage (
  tenant_id TEXT NOT NULL,
  usage_day TEXT NOT NULL,
  accepted INTEGER NOT NULL DEFAULT 0,
  routine_live_activity INTEGER NOT NULL DEFAULT 0,
  recovery INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (tenant_id, usage_day),
  FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id)
);

CREATE TABLE deliveries (
  tenant_id TEXT NOT NULL,
  delivery_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('alert', 'live_activity')),
  activity_id TEXT,
  revision INTEGER NOT NULL,
  issued INTEGER NOT NULL,
  expires INTEGER NOT NULL,
  payload_ciphertext TEXT NOT NULL,
  payload_key_version TEXT NOT NULL,
  payload_hash TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending_enqueue', 'queued', 'sending', 'delivered', 'failed', 'cancelled')),
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt INTEGER NOT NULL,
  lease_id TEXT,
  lease_expires INTEGER,
  last_error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (tenant_id, delivery_id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, device_id)
);

CREATE TABLE device_tombstones (
  tenant_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  revoked_at INTEGER NOT NULL,
  PRIMARY KEY (tenant_id, device_id),
  FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id)
);

CREATE TABLE devices (
  tenant_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  lease_expires INTEGER NOT NULL,
  recipient_key_id TEXT NOT NULL,
  recipient_public_key TEXT NOT NULL,
  token_ciphertext TEXT NOT NULL,
  token_key_version TEXT NOT NULL,
  environment TEXT NOT NULL CHECK (environment IN ('production', 'sandbox')),
  topic TEXT NOT NULL,
  label TEXT NOT NULL,
  groups_json TEXT NOT NULL,
  acknowledged_sender_key_ids_json TEXT NOT NULL DEFAULT '[]',
  sender_key_revision INTEGER NOT NULL DEFAULT 0,
  revoked_at INTEGER,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (tenant_id, device_id),
  FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id)
);

CREATE TABLE idempotency_keys (
  tenant_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  route TEXT NOT NULL,
  body_digest TEXT NOT NULL,
  response_json TEXT,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (tenant_id, idempotency_key)
);

CREATE TABLE live_activities (
  tenant_id TEXT NOT NULL,
  activity_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  lease_expires INTEGER NOT NULL,
  token_ciphertext TEXT NOT NULL,
  token_key_version TEXT NOT NULL,
  environment TEXT NOT NULL CHECK (environment IN ('production', 'sandbox')),
  topic TEXT NOT NULL,
  session_ref TEXT NOT NULL,
  state_json TEXT,
  state_hash TEXT,
  state_timestamp INTEGER,
  status TEXT NOT NULL CHECK (status IN ('active', 'revoked', 'ended')),
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (tenant_id, activity_id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, device_id)
);

CREATE TABLE request_nonces (
  tenant_id TEXT NOT NULL,
  nonce TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (tenant_id, nonce)
);

CREATE TABLE service_daily_usage (
  usage_day TEXT PRIMARY KEY,
  accepted INTEGER NOT NULL DEFAULT 0,
  routine_live_activity INTEGER NOT NULL DEFAULT 0,
  recovery INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE tenants (
  tenant_id TEXT PRIMARY KEY,
  revision INTEGER NOT NULL DEFAULT 1,
  state TEXT NOT NULL CHECK (state IN ('active', 'revoked', 'deleted')),
  updated_at INTEGER NOT NULL
);

CREATE INDEX deliveries_device ON deliveries (tenant_id, device_id, state);

CREATE INDEX deliveries_due ON deliveries (state, next_attempt, lease_expires);

CREATE INDEX deliveries_retention ON deliveries (state, expires);

CREATE INDEX devices_lease ON devices (lease_expires, revoked_at);

CREATE INDEX idempotency_keys_retention ON idempotency_keys (created_at);

CREATE INDEX live_activities_lease ON live_activities (lease_expires, status);

CREATE INDEX request_nonces_expiry ON request_nonces (expires_at);

CREATE INDEX service_daily_usage_retention ON service_daily_usage (usage_day);
