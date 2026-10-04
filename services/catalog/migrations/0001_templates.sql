-- Every template, from the bundled starter set or submitted by someone, with its review state.
-- Only `approved` rows are public; submitter emails never leave the review API.
CREATE TABLE templates (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('blueprint', 'agent')),
  status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'rejected')),
  source TEXT NOT NULL CHECK (source IN ('bighelp', 'community')),
  payload TEXT NOT NULL,
  credit_name TEXT,
  submitter_email TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  reviewed_at TEXT,
  reviewed_by TEXT,
  review_note TEXT,
  sort_key INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX templates_status_kind ON templates (status, kind, sort_key, created_at);
CREATE INDEX templates_submitter ON templates (submitter_email, created_at);
