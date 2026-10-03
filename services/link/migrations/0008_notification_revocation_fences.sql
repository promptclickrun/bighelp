-- Durable egress fences established before revocation cleanup crosses into a
-- Durable Object or notification provider. Row presence means notification
-- authority is already retired even when the remaining cleanup must be retried.
CREATE TABLE IF NOT EXISTS notification_installation_revocation_cleanup (
  installation_id TEXT PRIMARY KEY REFERENCES notification_installations(installation_id) ON DELETE CASCADE,
  notification_coordinate TEXT NOT NULL,
  authorization_epoch INTEGER NOT NULL CHECK(authorization_epoch > 0),
  started_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS notification_device_revocations (
  device_id TEXT PRIMARY KEY,
  account_coordinate TEXT NOT NULL REFERENCES accounts(account_coordinate) ON DELETE CASCADE,
  expected_revision INTEGER NOT NULL CHECK(expected_revision > 0),
  authorization_epoch INTEGER NOT NULL CHECK(authorization_epoch > 0),
  started_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS notification_device_revocations_account
  ON notification_device_revocations(account_coordinate);
