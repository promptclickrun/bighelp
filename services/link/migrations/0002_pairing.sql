CREATE TABLE pairing_challenges (
  flow_id TEXT PRIMARY KEY,
  code_hash TEXT NOT NULL,
  host_device_id TEXT NOT NULL,
  host_signing_public_key_spki TEXT NOT NULL,
  host_agreement_public_key TEXT NOT NULL,
  claim_secret_hash TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending', 'approved', 'claimed', 'expired')),
  account_coordinate TEXT REFERENCES accounts(account_coordinate) ON DELETE CASCADE,
  authorization_epoch INTEGER,
  encrypted_name TEXT,
  grant_envelope TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  approved_at INTEGER,
  claimed_at INTEGER
);

CREATE INDEX pairing_challenges_expiry_idx
  ON pairing_challenges(state, expires_at);

CREATE UNIQUE INDEX pairing_challenges_active_host_idx
  ON pairing_challenges(host_device_id)
  WHERE state IN ('pending', 'approved');
