-- Direct APNs delivery. A phone gives the Link service its own push token, sealed
-- here with AES-256-GCM, so alerts can reach APNs without a third-party relay.
-- Token rows belong to one notification installation and go with it when it is
-- revoked. Alert and push-to-start rows last 60 days and a Live Activity row 12 hours.
CREATE TABLE IF NOT EXISTS push_targets (
  installation_id TEXT NOT NULL REFERENCES notification_installations(installation_id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK(kind IN ('alert','liveactivity','pts')),
  activity_id TEXT NOT NULL DEFAULT '' CHECK((kind='liveactivity') = (activity_id<>'')),
  environment TEXT NOT NULL CHECK(environment IN ('sandbox','production')),
  token_ciphertext TEXT NOT NULL,
  -- The topics this person turned off, as a JSON array. Null means the app never said, and the
  -- target is not used for direct delivery.
  muted_topics TEXT,
  app_version TEXT NOT NULL DEFAULT '',
  authorization_epoch INTEGER NOT NULL CHECK(authorization_epoch > 0),
  updated_at INTEGER NOT NULL,
  invalid_at INTEGER,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY(installation_id, kind, activity_id)
);
CREATE INDEX IF NOT EXISTS push_targets_expiry ON push_targets(expires_at);

-- One row per direct send, so a repeat of the same event answers "duplicate".
-- State buzzkit means the message went to BuzzKit, which deduplicates a repeat by its own key.
CREATE TABLE IF NOT EXISTS push_sends (
  dedupe_key TEXT PRIMARY KEY,
  installation_id TEXT NOT NULL,
  apns_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('sending','sent','queued','buzzkit')),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS push_sends_expiry ON push_sends(expires_at);
CREATE INDEX IF NOT EXISTS push_sends_installation ON push_sends(installation_id);

-- Writes to the two target routes in each hour, per installation, so a stuck app can't hammer the database.
CREATE TABLE IF NOT EXISTS push_target_writes (
  installation_id TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  writes INTEGER NOT NULL CHECK(writes > 0),
  PRIMARY KEY(installation_id, window_start)
);
CREATE INDEX IF NOT EXISTS push_target_writes_window ON push_target_writes(window_start);
