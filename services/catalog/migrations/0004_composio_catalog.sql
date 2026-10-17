-- Composio's app list for the app's Composio Apps section, refreshed by the daily cron (src/composio.ts).
-- One row: the normalized JSON document that /v1/composio/catalog.json serves as is. The developer key that
-- reads Composio never lands here.
CREATE TABLE composio_catalog (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  document TEXT NOT NULL,
  revision TEXT NOT NULL,
  fetched_at TEXT NOT NULL
);
