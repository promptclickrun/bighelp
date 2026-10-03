import { env } from "cloudflare:test";
import { beforeAll } from "vitest";
import migrationSql from "../migrations/0001_accounts.sql?raw";
import pairingMigrationSql from "../migrations/0002_pairing.sql?raw";
import keyEnvelopeMigrationSql from "../migrations/0003_key_envelope.sql?raw";
import accountDeletionReceiptMigrationSql from "../migrations/0004_account_deletion_receipts.sql?raw";
import notificationMigrationSql from "../migrations/0005_notification_grants.sql?raw";
import notificationIdentityMigrationSql from "../migrations/0006_notification_identity.sql?raw";
import notificationRetirementMigrationSql from "../migrations/0007_retire_account_notifications.sql?raw";
import notificationRevocationFenceMigrationSql from "../migrations/0008_notification_revocation_fences.sql?raw";
import notificationAccountInstallationsMigrationSql from "../migrations/0009_notification_account_installations.sql?raw";
import marketplaceRetirementMigrationSql from "../marketplace-migrations/0005_retire_marketplace.sql?raw";

beforeAll(async () => {
  await applyMigrationIfMissing("accounts", migrationSql);
  await applyMigrationIfMissing("pairing_challenges", pairingMigrationSql);
  await applyMigrationIfMissingColumn("accounts", "key_envelope", keyEnvelopeMigrationSql);
  await applyMigrationIfMissing("account_deletion_receipts", accountDeletionReceiptMigrationSql);
  await applyMigrationIfMissing("notification_grants", notificationMigrationSql);
  await applyMigrationIfMissing("notification_installations", notificationIdentityMigrationSql);
  await applyMigrationIfMissing("notification_account_scope_retirements", notificationRetirementMigrationSql);
  await applyMigrationIfMissing(
    "notification_installation_revocation_cleanup",
    notificationRevocationFenceMigrationSql,
  );
  await applyMigrationIfMissing(
    "notification_account_installations",
    notificationAccountInstallationsMigrationSql,
  );
  await applyMigrationIfMissing(
    "marketplace_retirement",
    marketplaceRetirementMigrationSql,
    env.MARKETPLACE_RETIREMENT,
  );
});

async function applyMigrationIfMissing(
  table: string,
  sql: string,
  database: D1Database = env.ACCOUNTS,
): Promise<void> {
  const existing = await database.prepare(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
  )
    .bind(table)
    .first();
  if (existing) return;

  for (const statement of sql
    .split(";")
    .map((value: string) => value.trim())
    .filter(Boolean)) {
    await database.prepare(statement).run();
  }
}

async function applyMigrationIfMissingColumn(
  table: string,
  column: string,
  sql: string,
): Promise<void> {
  const columns = await env.ACCOUNTS.prepare(`PRAGMA table_info(${table})`).all<{
    name: string;
  }>();
  if (columns.results.some((candidate) => candidate.name === column)) return;

  for (const statement of sql
    .split(";")
    .map((value: string) => value.trim())
    .filter(Boolean)) {
    await env.ACCOUNTS.prepare(statement).run();
  }
}
