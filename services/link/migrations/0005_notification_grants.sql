-- Notification-only authority. No chat pairing or new database/namespace.
CREATE TABLE IF NOT EXISTS notification_grants (
  grant_id TEXT PRIMARY KEY,
  account_coordinate TEXT NOT NULL REFERENCES accounts(account_coordinate) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  authorization_epoch INTEGER NOT NULL,
  idempotency_key TEXT NOT NULL,
  request_digest TEXT NOT NULL,
  public_json TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('issued','active','revoked')),
  revision INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  UNIQUE(account_coordinate, device_id, idempotency_key)
);
CREATE INDEX IF NOT EXISTS notification_grants_owner ON notification_grants(account_coordinate,device_id);
CREATE UNIQUE INDEX IF NOT EXISTS notification_grants_single_sender
  ON notification_grants(account_coordinate,device_id,json_extract(public_json,'$.hostKeyId'),json_extract(public_json,'$.profile'))
  WHERE state IN ('issued','active');
CREATE TABLE IF NOT EXISTS notification_host_nonces (
  grant_id TEXT NOT NULL REFERENCES notification_grants(grant_id) ON DELETE CASCADE,
  nonce TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY(grant_id,nonce)
);
CREATE INDEX IF NOT EXISTS notification_host_nonce_expiry ON notification_host_nonces(expires_at);
