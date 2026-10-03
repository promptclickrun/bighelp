import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import retirementMigrationSql from "../marketplace-migrations/0005_retire_marketplace.sql?raw";
import {
  legacyMarketplaceTableNames,
  requireMarketplaceRetirementAcknowledgement,
} from "../src/marketplace-retirement.js";

describe("retired Marketplace D1 migration", () => {
  it("purges every legacy table and leaves only a verified acknowledgement", async () => {
    await env.MARKETPLACE_RETIREMENT.prepare("DROP TABLE IF EXISTS marketplace_retirement").run();
    for (const table of legacyMarketplaceTableNames) {
      await env.MARKETPLACE_RETIREMENT.prepare(
        `CREATE TABLE ${table} (owner_account_id TEXT NOT NULL)`,
      ).run();
      await env.MARKETPLACE_RETIREMENT.prepare(
        `INSERT INTO ${table} (owner_account_id) VALUES (?)`,
      )
        .bind("legacy-account-coordinate")
        .run();
    }

    await applyMigration(retirementMigrationSql);

    await expect(
      requireMarketplaceRetirementAcknowledgement(env.MARKETPLACE_RETIREMENT),
    ).resolves.toBeUndefined();
    const remaining = await env.MARKETPLACE_RETIREMENT.prepare(
      `SELECT name FROM sqlite_master
       WHERE type = 'table'
         AND name NOT LIKE '_cf_%'
         AND name NOT IN ('d1_migrations', 'marketplace_retirement', 'sqlite_sequence')
       ORDER BY name`,
    ).all<{ name: string }>();
    expect(remaining.results).toEqual([]);
    expect(
      await env.MARKETPLACE_RETIREMENT.prepare(
        "SELECT id, schema_version, state FROM marketplace_retirement",
      ).first(),
    ).toEqual({
      id: "marketplace-retirement-v1",
      schema_version: 1,
      state: "purged",
    });
  });
});

async function applyMigration(sql: string): Promise<void> {
  for (const statement of sql
    .split(";")
    .map((value) => value.trim())
    .filter(Boolean)) {
    await env.MARKETPLACE_RETIREMENT.prepare(statement).run();
  }
}
