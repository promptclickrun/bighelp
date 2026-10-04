-- Submissions no longer sign in. Submitters give a name, username and email, and get a private status
-- token back (only its hash is stored) so the site can show them how their review went.
ALTER TABLE templates ADD COLUMN submitter_name TEXT;
ALTER TABLE templates ADD COLUMN submitter_username TEXT;
ALTER TABLE templates ADD COLUMN status_token_hash TEXT;
ALTER TABLE templates ADD COLUMN submitter_ip_hash TEXT;
CREATE INDEX templates_submitter_ip ON templates (submitter_ip_hash, created_at);
