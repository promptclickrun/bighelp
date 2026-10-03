-- Marketplace is permanently retired. This migration removes every
-- Marketplace-owned D1 table and leaves only a narrow acknowledgement that
-- Loopdy Link can verify before deleting an account.
PRAGMA foreign_keys = ON;

DROP TABLE IF EXISTS install_approvals;
DROP TABLE IF EXISTS reports;
DROP TABLE IF EXISTS author_blocks;
DROP TABLE IF EXISTS moderation_events;
DROP TABLE IF EXISTS releases;
DROP TABLE IF EXISTS upload_reservations;
DROP TABLE IF EXISTS draft_revisions;
DROP TABLE IF EXISTS drafts;
DROP TABLE IF EXISTS items;
DROP TABLE IF EXISTS publishers;
DROP TABLE IF EXISTS artifact_reclamation_claims;
DROP TABLE IF EXISTS artifact_objects;
DROP TABLE IF EXISTS account_deletion_queue;
DROP TABLE IF EXISTS account_tombstones;
DROP TABLE IF EXISTS idempotency_records;
DROP TABLE IF EXISTS rate_limit_buckets;
DROP TABLE IF EXISTS operator_nonces;

CREATE TABLE IF NOT EXISTS marketplace_retirement (
  id TEXT PRIMARY KEY CHECK (id = 'marketplace-retirement-v1'),
  schema_version INTEGER NOT NULL CHECK (schema_version = 1),
  state TEXT NOT NULL CHECK (state = 'purged')
);

INSERT INTO marketplace_retirement (id, schema_version, state)
VALUES ('marketplace-retirement-v1', 1, 'purged')
ON CONFLICT(id) DO UPDATE SET
  schema_version = excluded.schema_version,
  state = excluded.state;
