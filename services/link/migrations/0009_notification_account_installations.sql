-- Wake routing is an explicit dual-authority association. It does not grant the
-- installation account access or restore account-scoped notification identity.
CREATE TABLE IF NOT EXISTS notification_account_installations (
  installation_id TEXT PRIMARY KEY REFERENCES notification_installations(installation_id) ON DELETE CASCADE,
  notification_coordinate TEXT NOT NULL REFERENCES notification_installations(notification_coordinate) ON DELETE CASCADE,
  account_coordinate TEXT NOT NULL REFERENCES accounts(account_coordinate) ON DELETE CASCADE,
  account_device_id TEXT NOT NULL,
  account_authorization_epoch INTEGER NOT NULL CHECK(account_authorization_epoch > 0),
  installation_authorization_epoch INTEGER NOT NULL CHECK(installation_authorization_epoch > 0),
  bound_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS notification_account_installations_account
  ON notification_account_installations(account_coordinate);
