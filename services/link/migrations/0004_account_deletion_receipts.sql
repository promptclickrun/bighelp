CREATE TABLE account_deletion_receipts (
  token_hash TEXT PRIMARY KEY,
  expires_at INTEGER NOT NULL
);

CREATE INDEX account_deletion_receipts_expiry_idx
  ON account_deletion_receipts(expires_at);
