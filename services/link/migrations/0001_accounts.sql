CREATE TABLE accounts (
  account_coordinate TEXT PRIMARY KEY,
  status TEXT NOT NULL CHECK (status IN ('active', 'revoked')),
  authorization_epoch INTEGER NOT NULL CHECK (authorization_epoch > 0),
  recovery_verifier TEXT,
  created_at INTEGER NOT NULL,
  revoked_at INTEGER
);

CREATE TABLE passkeys (
  credential_id TEXT PRIMARY KEY,
  account_coordinate TEXT NOT NULL REFERENCES accounts(account_coordinate) ON DELETE CASCADE,
  webauthn_user_id TEXT NOT NULL,
  public_key BLOB NOT NULL,
  counter INTEGER NOT NULL CHECK (counter >= 0),
  device_type TEXT NOT NULL,
  backed_up INTEGER NOT NULL CHECK (backed_up IN (0, 1)),
  transports_json TEXT,
  created_at INTEGER NOT NULL
);

CREATE INDEX passkeys_account_idx ON passkeys(account_coordinate);

CREATE TABLE auth_challenges (
  flow_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('registration', 'authentication')),
  account_coordinate TEXT,
  webauthn_user_id TEXT,
  challenge TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER
);

CREATE INDEX auth_challenges_expiry_idx ON auth_challenges(expires_at);

CREATE TABLE access_sessions (
  token_hash TEXT PRIMARY KEY,
  account_coordinate TEXT NOT NULL REFERENCES accounts(account_coordinate) ON DELETE CASCADE,
  authorization_epoch INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  revoked_at INTEGER
);

CREATE INDEX access_sessions_account_idx ON access_sessions(account_coordinate, expires_at);

CREATE TABLE device_directory (
  device_id TEXT PRIMARY KEY,
  account_coordinate TEXT NOT NULL REFERENCES accounts(account_coordinate) ON DELETE CASCADE,
  public_key_spki TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active', 'revoked')),
  authorization_epoch INTEGER NOT NULL CHECK (authorization_epoch > 0),
  created_at INTEGER NOT NULL,
  revoked_at INTEGER
);

CREATE INDEX device_directory_account_idx ON device_directory(account_coordinate, status);

CREATE TABLE device_nonces (
  device_id TEXT NOT NULL REFERENCES device_directory(device_id) ON DELETE CASCADE,
  nonce TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (device_id, nonce)
);

CREATE INDEX device_nonces_expiry_idx ON device_nonces(expires_at);
