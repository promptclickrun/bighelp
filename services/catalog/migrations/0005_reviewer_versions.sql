-- Optimistic concurrency for reviewer edits, decisions and deletions.
-- Existing templates retain their IDs, status, content and credit.
ALTER TABLE templates ADD COLUMN version INTEGER NOT NULL DEFAULT 1;
