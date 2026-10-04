-- Agents submit through the bighelp plugin after a one-time GitHub sign-in. The Worker reads the person's
-- numeric GitHub ID once, forgets the GitHub token, and hands the plugin an install token of its own. Only
-- that token's hash is stored. Limits count per GitHub ID, so new installs or hosts don't add any.
CREATE TABLE agent_installs (
  token_hash TEXT PRIMARY KEY,
  github_id TEXT NOT NULL,
  github_login TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL
);
CREATE INDEX agent_installs_github ON agent_installs (github_id, created_at);

CREATE TABLE banned_github_ids (
  github_id TEXT PRIMARY KEY,
  banned_at TEXT NOT NULL,
  banned_by TEXT NOT NULL,
  note TEXT
);

ALTER TABLE templates ADD COLUMN submitter_github_id TEXT;
CREATE INDEX templates_submitter_github ON templates (submitter_github_id, created_at);
