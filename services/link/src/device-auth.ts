import { decodeBase64URL as decodeBase64URLBytes, sha256Base64URL } from "./encoding.js";
import { LoopdyLinkError } from "./contracts.js";

export const DEVICE_AUTH_HEADERS = {
  deviceId: "x-loopdy-device-id",
  timestamp: "x-loopdy-timestamp",
  nonce: "x-loopdy-nonce",
  authorizationEpoch: "x-loopdy-authorization-epoch",
  signature: "x-loopdy-signature",
} as const;

export interface RegisterDeviceDirectoryInput {
  accountCoordinate: string;
  deviceId: string;
  publicKeySPKI: string;
  authorizationEpoch: number;
  createdAt: number;
}

export interface VerifiedDeviceRequest {
  accountCoordinate: string;
  deviceId: string;
  authorizationEpoch: number;
  nonce: string;
}

interface DeviceDirectoryRow {
  device_id: string;
  account_coordinate: string;
  public_key_spki: string;
  status: string;
  authorization_epoch: number;
  account_status: string;
  account_epoch: number;
  revocation_account_coordinate: string | null;
  revocation_expected_revision: number | null;
  revocation_authorization_epoch: number | null;
}

const NONCE_WINDOW_SECONDS = 120;
const DEFAULT_MAXIMUM_BODY_CHARACTERS = 65_536;
const DEVICE_ID = /^[A-Za-z0-9_-]{1,96}$/;
const OPAQUE = /^[A-Za-z0-9_-]{22,256}$/;

interface VerifyDeviceRequestOptions {
  maximumBodyCharacters?: number;
  revocationRecovery?: { deviceId: string; expectedRevision: number };
}

export async function registerDeviceDirectory(
  db: D1Database,
  input: RegisterDeviceDirectoryInput,
): Promise<void> {
  validateDirectoryInput(input);
  const existing = await db
    .prepare("SELECT * FROM device_directory WHERE device_id = ? LIMIT 1")
    .bind(input.deviceId)
    .first<{
      account_coordinate: string;
      public_key_spki: string;
      status: string;
      authorization_epoch: number;
    }>();
  if (existing) {
    if (
      existing.account_coordinate === input.accountCoordinate &&
      existing.public_key_spki === input.publicKeySPKI &&
      existing.status === "active" &&
      existing.authorization_epoch === input.authorizationEpoch
    ) {
      return;
    }
    throw new LoopdyLinkError("device_conflict", "Device registration conflicts with state");
  }
  await db
    .prepare(
      `INSERT INTO device_directory (
         device_id, account_coordinate, public_key_spki, status,
         authorization_epoch, created_at
       ) VALUES (?, ?, ?, 'active', ?, ?)`,
    )
    .bind(
      input.deviceId,
      input.accountCoordinate,
      input.publicKeySPKI,
      input.authorizationEpoch,
      input.createdAt,
    )
    .run();
}

/**
 * Resolve the account Durable Object for a socket request without authenticating
 * the device. The request itself must remain untouched while it crosses the
 * Worker -> Durable Object boundary, so the Durable Object performs the full
 * signature, epoch, and nonce verification after routing.
 */
export async function lookupDeviceAccountCoordinate(
  db: D1Database,
  deviceId: string,
): Promise<string> {
  if (!deviceId) {
    throw new LoopdyLinkError("device_credentials_missing", "Device credentials are missing");
  }
  if (!DEVICE_ID.test(deviceId)) {
    throw new LoopdyLinkError("device_credentials_invalid", "Device credentials are invalid");
  }
  const row = await db
    .prepare("SELECT account_coordinate FROM device_directory WHERE device_id = ? LIMIT 1")
    .bind(deviceId)
    .first<{ account_coordinate: string }>();
  if (!row || !OPAQUE.test(row.account_coordinate)) {
    throw new LoopdyLinkError("device_revoked", "Device authorization is revoked");
  }
  return row.account_coordinate;
}

export async function canonicalDeviceRequest(input: {
  method: string;
  path: string;
  deviceId: string;
  timestamp: number;
  nonce: string;
  authorizationEpoch: number;
  body: string | Uint8Array;
}): Promise<string> {
  const bodyDigest = await sha256Base64URL(input.body);
  return [
    "loopdy-link-device-v1",
    input.method.toUpperCase(),
    input.path,
    input.deviceId,
    String(input.timestamp),
    input.nonce,
    String(input.authorizationEpoch),
    bodyDigest,
  ].join("\n");
}

export async function verifyDeviceRequest(
  request: Request,
  body: string | Uint8Array,
  db: D1Database,
  now: number,
  options: VerifyDeviceRequestOptions = {},
): Promise<VerifiedDeviceRequest> {
  const maximumBodyCharacters =
    options.maximumBodyCharacters ?? DEFAULT_MAXIMUM_BODY_CHARACTERS;
  if (body.length > maximumBodyCharacters) {
    throw new LoopdyLinkError("body_too_large", "Request body is too large");
  }
  const deviceId = requiredHeader(request, DEVICE_AUTH_HEADERS.deviceId);
  const nonce = requiredHeader(request, DEVICE_AUTH_HEADERS.nonce);
  const signature = requiredHeader(request, DEVICE_AUTH_HEADERS.signature);
  const timestamp = strictInteger(requiredHeader(request, DEVICE_AUTH_HEADERS.timestamp));
  const authorizationEpoch = strictInteger(
    requiredHeader(request, DEVICE_AUTH_HEADERS.authorizationEpoch),
  );
  if (!DEVICE_ID.test(deviceId) || !OPAQUE.test(nonce) || !OPAQUE.test(signature)) {
    throw new LoopdyLinkError("device_credentials_invalid", "Device credentials are invalid");
  }
  if (Math.abs(timestamp - now) > NONCE_WINDOW_SECONDS) {
    throw new LoopdyLinkError("stale_timestamp", "Device timestamp is outside the clock window");
  }

  const url = new URL(request.url);
  const row = await loadDeviceDirectoryRow(db, deviceId);
  const recovery = isRevocationRecovery(
    request, url, deviceId, authorizationEpoch, row, options.revocationRecovery,
  );
  assertDeviceAuthority(row, authorizationEpoch, recovery);
  const canonical = await canonicalDeviceRequest({
    method: request.method,
    path: `${url.pathname}${url.search}`,
    deviceId,
    timestamp,
    nonce,
    authorizationEpoch,
    body,
  });
  const publicKey = await importDevicePublicKey(row.public_key_spki);
  const verified = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    decodeBase64URL(signature),
    new TextEncoder().encode(canonical),
  );
  if (!verified) {
    throw new LoopdyLinkError("device_signature_invalid", "Device signature is invalid");
  }

  await db.prepare("DELETE FROM device_nonces WHERE expires_at <= ?").bind(now).run();
  const nonceInsert = await db
    .prepare(
      `INSERT INTO device_nonces (device_id, nonce, expires_at)
       SELECT d.device_id, ?, ?
       FROM device_directory d JOIN accounts a USING (account_coordinate)
       WHERE d.device_id = ? AND a.status = 'active' AND a.authorization_epoch = ?
         AND (
           (? = 0 AND d.status = 'active' AND d.authorization_epoch = ?
             AND NOT EXISTS(SELECT 1 FROM notification_device_revocations r
               WHERE r.device_id=d.device_id AND r.account_coordinate=d.account_coordinate))
           OR
           (? = 1 AND EXISTS(SELECT 1 FROM notification_device_revocations r
             WHERE r.device_id=d.device_id AND r.account_coordinate=d.account_coordinate
               AND r.expected_revision=? AND r.authorization_epoch=?)
             AND ((d.status='active' AND d.authorization_epoch=?)
               OR (d.status='revoked' AND d.authorization_epoch=?)))
         )
       ON CONFLICT (device_id, nonce) DO NOTHING`,
    )
    .bind(
      nonce,
      now + NONCE_WINDOW_SECONDS,
      deviceId,
      authorizationEpoch,
      recovery ? 1 : 0,
      authorizationEpoch,
      recovery ? 1 : 0,
      options.revocationRecovery?.expectedRevision ?? 0,
      authorizationEpoch,
      authorizationEpoch,
      authorizationEpoch + 1,
    )
    .run();
  if (nonceInsert.meta.changes !== 1) {
    const current = await loadDeviceDirectoryRow(db, deviceId);
    const currentRecovery = isRevocationRecovery(
      request, url, deviceId, authorizationEpoch, current, options.revocationRecovery,
    );
    assertDeviceAuthority(current, authorizationEpoch, currentRecovery);
    throw new LoopdyLinkError("nonce_replayed", "Device nonce was already used");
  }
  return {
    accountCoordinate: row.account_coordinate,
    deviceId,
    authorizationEpoch,
    nonce,
  };
}

async function loadDeviceDirectoryRow(
  db: D1Database,
  deviceId: string,
): Promise<DeviceDirectoryRow | null> {
  return db.prepare(
    `SELECT d.*, a.status AS account_status, a.authorization_epoch AS account_epoch,
            r.account_coordinate AS revocation_account_coordinate,
            r.expected_revision AS revocation_expected_revision,
            r.authorization_epoch AS revocation_authorization_epoch
     FROM device_directory d JOIN accounts a USING (account_coordinate)
     LEFT JOIN notification_device_revocations r
       ON r.device_id=d.device_id AND r.account_coordinate=d.account_coordinate
     WHERE d.device_id = ? LIMIT 1`,
  ).bind(deviceId).first<DeviceDirectoryRow>();
}

function isRevocationRecovery(
  request: Request,
  url: URL,
  signedDeviceId: string,
  authorizationEpoch: number,
  row: DeviceDirectoryRow | null,
  recovery: VerifyDeviceRequestOptions["revocationRecovery"],
): boolean {
  if (!recovery || !row || request.method !== "DELETE" || url.search || url.hash) return false;
  if (recovery.deviceId !== signedDeviceId
      || url.pathname !== `/v1/devices/${recovery.deviceId}`
      || !Number.isSafeInteger(recovery.expectedRevision) || recovery.expectedRevision < 1) return false;
  if (row.revocation_account_coordinate !== row.account_coordinate
      || row.revocation_expected_revision !== recovery.expectedRevision
      || row.revocation_authorization_epoch !== authorizationEpoch) return false;
  return (row.status === "active" && row.authorization_epoch === authorizationEpoch)
    || (row.status === "revoked" && row.authorization_epoch === authorizationEpoch + 1);
}

function assertDeviceAuthority(
  row: DeviceDirectoryRow | null,
  authorizationEpoch: number,
  recovery: boolean,
): asserts row is DeviceDirectoryRow {
  if (!row || row.account_status !== "active") {
    throw new LoopdyLinkError("device_revoked", "Device authorization is revoked");
  }
  if (recovery) {
    if (row.account_epoch !== authorizationEpoch) {
      throw new LoopdyLinkError("authorization_epoch_stale", "Device authorization epoch is stale");
    }
    return;
  }
  if (row.status !== "active" || row.revocation_account_coordinate !== null) {
    throw new LoopdyLinkError("device_revoked", "Device authorization is revoked");
  }
  if (authorizationEpoch !== row.authorization_epoch || authorizationEpoch !== row.account_epoch) {
    throw new LoopdyLinkError("authorization_epoch_stale", "Device authorization epoch is stale");
  }
}

function validateDirectoryInput(input: RegisterDeviceDirectoryInput): void {
  if (
    !OPAQUE.test(input.accountCoordinate) ||
    !DEVICE_ID.test(input.deviceId) ||
    !OPAQUE.test(input.publicKeySPKI) ||
    input.publicKeySPKI.length > 2_048 ||
    !Number.isSafeInteger(input.authorizationEpoch) ||
    input.authorizationEpoch < 1 ||
    !Number.isSafeInteger(input.createdAt) ||
    input.createdAt < 1
  ) {
    throw new LoopdyLinkError("device_invalid", "Device registration is invalid");
  }
}

function requiredHeader(request: Request, name: string): string {
  const value = request.headers.get(name);
  if (!value) {
    throw new LoopdyLinkError("device_credentials_missing", "Device credentials are missing");
  }
  return value;
}

function strictInteger(value: string): number {
  if (!/^[1-9][0-9]*$/.test(value)) {
    throw new LoopdyLinkError("device_credentials_invalid", "Device credentials are invalid");
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) {
    throw new LoopdyLinkError("device_credentials_invalid", "Device credentials are invalid");
  }
  return parsed;
}

async function importDevicePublicKey(encoded: string): Promise<CryptoKey> {
  try {
    return await crypto.subtle.importKey(
      "spki",
      decodeBase64URL(encoded),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
  } catch {
    throw new LoopdyLinkError("device_key_invalid", "Device public key is invalid");
  }
}

function decodeBase64URL(value: string): Uint8Array {
  try {
    return decodeBase64URLBytes(value);
  } catch {
    throw new LoopdyLinkError("device_credentials_invalid", "Device credentials are invalid");
  }
}
