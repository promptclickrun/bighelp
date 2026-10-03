-- Restricted automatic notification identities. These rows are intentionally
-- outside accounts/device_directory/access_sessions and cannot authorize Link.
CREATE TABLE IF NOT EXISTS notification_installations (
  installation_id TEXT PRIMARY KEY,
  notification_coordinate TEXT NOT NULL UNIQUE,
  public_key_spki TEXT NOT NULL,
  authorization_epoch INTEGER NOT NULL CHECK(authorization_epoch > 0),
  bootstrap_request_id TEXT NOT NULL,
  bootstrap_request_digest TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('active','revoked')),
  created_at INTEGER NOT NULL,
  revoked_at INTEGER
);

CREATE TABLE IF NOT EXISTS notification_installation_nonces (
  installation_id TEXT NOT NULL REFERENCES notification_installations(installation_id) ON DELETE CASCADE,
  nonce TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY(installation_id, nonce)
);
CREATE INDEX IF NOT EXISTS notification_installation_nonce_expiry
  ON notification_installation_nonces(expires_at);

CREATE TABLE IF NOT EXISTS notification_bootstrap_nonces (
  public_key_digest TEXT NOT NULL,
  nonce TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY(public_key_digest, nonce)
);
CREATE INDEX IF NOT EXISTS notification_bootstrap_nonce_expiry
  ON notification_bootstrap_nonces(expires_at);

CREATE TABLE IF NOT EXISTS notification_bootstrap_rate (
  rate_key TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  attempts INTEGER NOT NULL CHECK(attempts > 0),
  PRIMARY KEY(rate_key, window_start)
);

CREATE TABLE IF NOT EXISTS notification_instance_grants (
  grant_id TEXT PRIMARY KEY,
  notification_coordinate TEXT NOT NULL REFERENCES notification_installations(notification_coordinate) ON DELETE CASCADE,
  installation_id TEXT NOT NULL REFERENCES notification_installations(installation_id) ON DELETE CASCADE,
  authorization_epoch INTEGER NOT NULL,
  idempotency_key TEXT NOT NULL,
  request_digest TEXT NOT NULL,
  public_json TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('issued','active','revoked')),
  revision INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  UNIQUE(notification_coordinate, installation_id, idempotency_key)
);
CREATE INDEX IF NOT EXISTS notification_instance_grants_owner
  ON notification_instance_grants(notification_coordinate, installation_id);
CREATE UNIQUE INDEX IF NOT EXISTS notification_instance_grants_single_sender
  ON notification_instance_grants(
    notification_coordinate,
    installation_id,
    json_extract(public_json,'$.instanceId'),
    json_extract(public_json,'$.hostKeyId'),
    json_extract(public_json,'$.profile')
  ) WHERE state IN ('issued','active');

CREATE TABLE IF NOT EXISTS notification_instance_host_nonces (
  grant_id TEXT NOT NULL REFERENCES notification_instance_grants(grant_id) ON DELETE CASCADE,
  nonce TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY(grant_id, nonce)
);
CREATE INDEX IF NOT EXISTS notification_instance_host_nonce_expiry
  ON notification_instance_host_nonces(expires_at);
