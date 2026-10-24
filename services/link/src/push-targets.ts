import { decodeBase64URL, encodeBase64URL } from "./encoding.js";
import type { ApnsEnvironment } from "./apns.js";

export type PushTargetKind = "alert" | "liveactivity" | "pts";

export interface PushTargetEnv {
  ACCOUNTS: D1Database;
  PUSH_TOKEN_KEY?: string;
}

export interface PushTargetInput {
  kind: PushTargetKind;
  /** The Live Activity's ID; empty for the other kinds. */
  activityId: string;
  /** Lowercase hex. */
  token: string;
  environment: ApnsEnvironment;
  appVersion: string;
}

/** A stored target with its token opened. Never log or return one. */
export interface PushTarget {
  kind: PushTargetKind;
  activityId: string;
  environment: ApnsEnvironment;
  token: string;
  appVersion: string;
  /** The stored ciphertext, to tell whether the row changed since it was read. */
  ciphertext: string;
}

/** Alert and push-to-start rows last 60 days and every PUT refreshes them. */
export const LONG_TARGET_SECONDS = 60 * 86_400;
/** A Live Activity token is useful for 12 hours at most. */
export const LIVE_ACTIVITY_TARGET_SECONDS = 12 * 3_600;
export const MAX_LIVE_ACTIVITY_TARGETS = 8;
const PURGE_BATCH = 50;
const CIPHERTEXT_VERSION = "v1.";

export const TOKEN_PATTERN = /^(?:[0-9a-f]{2}){32,100}$/;
export const ACTIVITY_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
export const APP_VERSION_PATTERN = /^[0-9]{1,4}(\.[0-9]{1,4}){0,3}\([0-9]{1,7}\)$/;

const keys = new Map<string, Promise<CryptoKey>>();

/** True when this error is only a table that migration 0010 has not created yet. */
export function isMissingPushTable(error: unknown): boolean {
  return error instanceof Error && /no such table: push_(targets|sends)/i.test(error.message);
}

function keyBytes(value: string | undefined): Uint8Array | null {
  const text = value?.trim() ?? "";
  if (!/^[A-Za-z0-9+/_-]+=*$/.test(text)) return null;
  try {
    const bytes = decodeBase64URL(text.replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, ""));
    return bytes.length === 32 ? bytes : null;
  } catch { return null; }
}

/** True when `PUSH_TOKEN_KEY` is 32 bytes of base64. */
export function pushTokenKeyConfigured(env: { PUSH_TOKEN_KEY?: string }): boolean {
  return keyBytes(env.PUSH_TOKEN_KEY) !== null;
}

function tokenKey(env: { PUSH_TOKEN_KEY?: string }): Promise<CryptoKey> {
  const bytes = keyBytes(env.PUSH_TOKEN_KEY);
  if (!bytes) throw new Error("push_token_key_unconfigured");
  const id = encodeBase64URL(bytes);
  let key = keys.get(id);
  if (!key) {
    key = crypto.subtle.importKey("raw", bytes, "AES-GCM", false, ["encrypt", "decrypt"]);
    keys.set(id, key);
  }
  return key;
}

function associatedData(installationId: string, kind: string, activityId: string): Uint8Array {
  return new TextEncoder().encode(`${installationId}|${kind}|${activityId}`);
}

export async function sealPushToken(
  env: { PUSH_TOKEN_KEY?: string },
  installationId: string,
  kind: PushTargetKind,
  activityId: string,
  token: string,
): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: associatedData(installationId, kind, activityId) },
    await tokenKey(env),
    new TextEncoder().encode(token),
  ));
  const joined = new Uint8Array(iv.length + sealed.length);
  joined.set(iv);
  joined.set(sealed, iv.length);
  return `${CIPHERTEXT_VERSION}${encodeBase64URL(joined)}`;
}

export async function openPushToken(
  env: { PUSH_TOKEN_KEY?: string },
  installationId: string,
  kind: PushTargetKind,
  activityId: string,
  ciphertext: string,
): Promise<string | null> {
  if (!ciphertext.startsWith(CIPHERTEXT_VERSION)) return null;
  try {
    const joined = decodeBase64URL(ciphertext.slice(CIPHERTEXT_VERSION.length));
    if (joined.length < 12 + 16) return null;
    const opened = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: joined.slice(0, 12), additionalData: associatedData(installationId, kind, activityId) },
      await tokenKey(env),
      joined.slice(12),
    );
    const token = new TextDecoder().decode(opened);
    return TOKEN_PATTERN.test(token) ? token : null;
  } catch { return null; }
}

/**
 * Stores or replaces a target. Returns false when the installation is no
 * longer active, so a revoked phone can't leave a token behind.
 */
export async function putPushTarget(
  env: PushTargetEnv,
  principal: { installationId: string; ownerCoordinate: string; authorizationEpoch: number },
  input: PushTargetInput,
  now: number,
): Promise<{ updatedAt: number } | null> {
  const ciphertext = await sealPushToken(env, principal.installationId, input.kind, input.activityId, input.token);
  const expiresAt = now + (input.kind === "liveactivity" ? LIVE_ACTIVITY_TARGET_SECONDS : LONG_TARGET_SECONDS);
  const result = await env.ACCOUNTS.prepare(`INSERT INTO push_targets(
      installation_id,kind,activity_id,environment,token_ciphertext,app_version,
      authorization_epoch,updated_at,invalid_at,expires_at)
    SELECT ?,?,?,?,?,?,?,?,NULL,?
    WHERE EXISTS(SELECT 1 FROM notification_installations
      WHERE installation_id=? AND notification_coordinate=? AND state='active' AND authorization_epoch=?)
    ON CONFLICT(installation_id,kind,activity_id) DO UPDATE SET
      environment=excluded.environment,token_ciphertext=excluded.token_ciphertext,
      app_version=excluded.app_version,authorization_epoch=excluded.authorization_epoch,
      updated_at=excluded.updated_at,invalid_at=NULL,expires_at=excluded.expires_at`)
    .bind(
      principal.installationId, input.kind, input.activityId, input.environment, ciphertext,
      input.appVersion, principal.authorizationEpoch, now, expiresAt,
      principal.installationId, principal.ownerCoordinate, principal.authorizationEpoch,
    ).run();
  if (result.meta.changes !== 1) return null;
  if (input.kind === "liveactivity") {
    await env.ACCOUNTS.prepare(`DELETE FROM push_targets
      WHERE installation_id=? AND kind='liveactivity' AND rowid NOT IN (
        SELECT rowid FROM push_targets WHERE installation_id=? AND kind='liveactivity'
        ORDER BY updated_at DESC,rowid DESC LIMIT ?)`)
      .bind(principal.installationId, principal.installationId, MAX_LIVE_ACTIVITY_TARGETS).run();
  }
  return { updatedAt: now };
}

export async function deletePushTarget(
  env: PushTargetEnv,
  installationId: string,
  kind: PushTargetKind,
  activityId: string,
): Promise<void> {
  await env.ACCOUNTS.prepare("DELETE FROM push_targets WHERE installation_id=? AND kind=? AND activity_id=?")
    .bind(installationId, kind, activityId).run();
}

interface TargetRow {
  environment: ApnsEnvironment;
  token_ciphertext: string;
  app_version: string;
}

/**
 * The installation's live target of this kind, opened. Null when there is none,
 * it is expired or marked invalid, the installation is no longer active, the
 * key is missing or the row can't be opened. A table that isn't there yet
 * counts as no target, so a Worker deployed before the migration keeps working.
 */
export async function findPushTarget(
  env: PushTargetEnv,
  installation: { installationId: string; ownerCoordinate: string },
  kind: PushTargetKind,
  activityId: string,
  now: number,
): Promise<PushTarget | null> {
  let row: TargetRow | null;
  try {
    row = await env.ACCOUNTS.prepare(`SELECT target.environment,target.token_ciphertext,target.app_version
      FROM push_targets target
      JOIN notification_installations installation
        ON installation.installation_id=target.installation_id
        AND installation.authorization_epoch=target.authorization_epoch
      LEFT JOIN notification_installation_revocation_cleanup cleanup
        ON cleanup.installation_id=target.installation_id
      WHERE target.installation_id=? AND target.kind=? AND target.activity_id=?
        AND target.expires_at>? AND target.invalid_at IS NULL
        AND installation.notification_coordinate=? AND installation.state='active'
        AND cleanup.installation_id IS NULL`)
      .bind(installation.installationId, kind, activityId, now, installation.ownerCoordinate)
      .first<TargetRow>();
  } catch (error) {
    if (isMissingPushTable(error)) return null;
    throw error;
  }
  if (!row) return null;
  const token = await openPushToken(env, installation.installationId, kind, activityId, row.token_ciphertext);
  if (!token) return null;
  return {
    kind, activityId, environment: row.environment, token, appVersion: row.app_version,
    ciphertext: row.token_ciphertext,
  };
}

/** Marks the exact token APNs refused. A newer token for the same slot is left alone. */
export async function markPushTargetInvalid(
  env: PushTargetEnv,
  installationId: string,
  target: Pick<PushTarget, "kind" | "activityId" | "ciphertext">,
  now: number,
): Promise<void> {
  await env.ACCOUNTS.prepare(`UPDATE push_targets SET invalid_at=?
    WHERE installation_id=? AND kind=? AND activity_id=? AND token_ciphertext=? AND invalid_at IS NULL`)
    .bind(now, installationId, target.kind, target.activityId, target.ciphertext).run();
}

/** Removes every token and send record of a revoked installation. */
export async function deleteInstallationPushState(env: PushTargetEnv, installationId: string): Promise<void> {
  try {
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare("DELETE FROM push_targets WHERE installation_id=?").bind(installationId),
      env.ACCOUNTS.prepare("DELETE FROM push_sends WHERE installation_id=?").bind(installationId),
    ]);
  } catch (error) {
    // Before migration 0010 there is nothing to delete.
    if (!isMissingPushTable(error)) throw error;
  }
}

/** Deletes a small batch of expired rows. Safe to call often. */
export async function purgeExpiredPushState(env: PushTargetEnv, now: number): Promise<void> {
  try {
    await env.ACCOUNTS.batch([
      env.ACCOUNTS.prepare(`DELETE FROM push_targets WHERE rowid IN (
        SELECT rowid FROM push_targets WHERE expires_at<=? LIMIT ?)`).bind(now, PURGE_BATCH),
      env.ACCOUNTS.prepare(`DELETE FROM push_sends WHERE rowid IN (
        SELECT rowid FROM push_sends WHERE expires_at<=? LIMIT ?)`).bind(now, PURGE_BATCH),
    ]);
  } catch (error) {
    if (!isMissingPushTable(error)) throw error;
  }
}
