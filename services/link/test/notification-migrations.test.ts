import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import current0007 from "../migrations/0007_retire_account_notifications.sql?raw";
import originalApplied0007 from "./fixtures/0007_retire_account_notifications.original.sql?raw";
import notificationFences0008 from "../migrations/0008_notification_revocation_fences.sql?raw";
import notificationAccountInstallations0009 from "../migrations/0009_notification_account_installations.sql?raw";

const ORIGINAL_0007_SHA256 = "39e4c12fa8cd3ee1a995fb1e19f5c1f17add37d669617294fb121650295df644";

async function sha256(value: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function apply(sql: string): Promise<void> {
  for (const statement of sql
    .split(";")
    .map((value) => value.trim())
    .filter(Boolean)) {
    await env.ACCOUNTS.prepare(statement).run();
  }
}

async function notificationMigrationTables(): Promise<string[]> {
  const rows = await env.ACCOUNTS.prepare(`SELECT name FROM sqlite_master
    WHERE type='table' AND name IN (
      'notification_account_scope_retirements',
      'notification_account_installations',
      'notification_installation_revocation_cleanup',
      'notification_device_revocations'
    ) ORDER BY name`).all<{ name: string }>();
  return rows.results.map((row: { name: string }) => row.name);
}

describe("notification migration upgrade safety", () => {
  it("upgrades an original applied 0007 through the preserved 0008 fence and new 0009", async () => {
    expect(await sha256(originalApplied0007)).toBe(ORIGINAL_0007_SHA256);
    expect(await sha256(current0007)).toBe(ORIGINAL_0007_SHA256);
    expect(originalApplied0007).not.toContain("notification_account_installations");
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare("DROP TABLE IF EXISTS notification_account_installations"),
      env.ACCOUNTS.prepare("DROP TABLE IF EXISTS notification_installation_revocation_cleanup"),
      env.ACCOUNTS.prepare("DROP TABLE IF EXISTS notification_device_revocations"),
      env.ACCOUNTS.prepare("DROP TABLE IF EXISTS notification_account_scope_retirements"),
    ]);

    await apply(originalApplied0007);
    expect(await notificationMigrationTables()).toEqual([
      "notification_account_scope_retirements",
    ]);

    await apply(notificationFences0008);
    await apply(notificationAccountInstallations0009);
    expect(await notificationMigrationTables()).toEqual([
      "notification_account_installations",
      "notification_account_scope_retirements",
      "notification_device_revocations",
      "notification_installation_revocation_cleanup",
    ]);
  });
});
