const RETIREMENT_ID = "marketplace-retirement-v1";
const LEGACY_MARKETPLACE_TABLES = [
  "account_deletion_queue",
  "account_tombstones",
  "artifact_objects",
  "artifact_reclamation_claims",
  "author_blocks",
  "draft_revisions",
  "drafts",
  "idempotency_records",
  "install_approvals",
  "items",
  "moderation_events",
  "operator_nonces",
  "publishers",
  "rate_limit_buckets",
  "releases",
  "reports",
  "upload_reservations",
] as const;

interface MarketplaceRetirementReceipt extends Record<string, SqlStorageValue> {
  id: string;
  schema_version: number;
  state: string;
}

export async function requireMarketplaceRetirementAcknowledgement(
  database: D1Database,
): Promise<void> {
  const receipt = await database
    .prepare(
      `SELECT id, schema_version, state
       FROM marketplace_retirement
       WHERE id = ? LIMIT 1`,
    )
    .bind(RETIREMENT_ID)
    .first<MarketplaceRetirementReceipt>();
  if (
    receipt?.id !== RETIREMENT_ID ||
    receipt.schema_version !== 1 ||
    receipt.state !== "purged"
  ) {
    throw new Error("marketplace_retirement_unacknowledged");
  }

  const placeholders = LEGACY_MARKETPLACE_TABLES.map(() => "?").join(", ");
  const remaining = await database
    .prepare(
      `SELECT name FROM sqlite_master
       WHERE type = 'table' AND name IN (${placeholders})
       ORDER BY name LIMIT 1`,
    )
    .bind(...LEGACY_MARKETPLACE_TABLES)
    .first<{ name: string }>();
  if (remaining) {
    throw new Error("marketplace_retirement_incomplete");
  }
}

export const legacyMarketplaceTableNames = LEGACY_MARKETPLACE_TABLES;
