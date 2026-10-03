-- Permanently retire legacy account-scoped notification authority after an
-- installation-scoped recipient has migrated. This marker prevents older
-- clients from recreating shared account grants or BuzzKit subscribers.
CREATE TABLE IF NOT EXISTS notification_account_scope_retirements (
  account_coordinate TEXT PRIMARY KEY REFERENCES accounts(account_coordinate) ON DELETE CASCADE,
  retired_at INTEGER NOT NULL
);
