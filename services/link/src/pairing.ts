import { decodeBase64URL as decodeBase64URLBytes, randomBase64URL, sha256Base64URL } from "./encoding.js";
import { LoopdyLinkError } from "./contracts.js";

const PAIRING_TTL_SECONDS = 600;
const CLOCK_WINDOW_SECONDS = 120;
const CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
const DEVICE_ID = /^[A-Za-z0-9_-]{1,96}$/;
const BASE64URL = /^[A-Za-z0-9_-]+$/;

export interface BeginPairingInput {
  deviceId: string;
  signingPublicKeySPKI: string;
  agreementPublicKey: string;
  claimSecretHash: string;
  timestamp: number;
  nonce: string;
  proof: string;
}

export interface ApprovePairingInput {
  flowId: string;
  code: string;
  accountCoordinate: string;
  authorizationEpoch: number;
  encryptedName: string;
  grantEnvelope: string;
}

export interface ClaimPairingInput {
  flowId: string;
  claimSecret: string;
  timestamp: number;
  nonce: string;
  proof: string;
}

export interface InspectPairingInput {
  flowId?: string;
  code: string;
}

interface PairingRow {
  flow_id: string;
  code_hash: string;
  host_device_id: string;
  host_signing_public_key_spki: string;
  host_agreement_public_key: string;
  claim_secret_hash: string;
  state: "pending" | "approved" | "claimed" | "expired";
  account_coordinate: string | null;
  authorization_epoch: number | null;
  encrypted_name: string | null;
  grant_envelope: string | null;
  created_at: number;
  expires_at: number;
  approved_at: number | null;
  claimed_at: number | null;
}

export interface ApprovedPairing {
  deviceId: string;
  signingPublicKeySPKI: string;
  agreementPublicKey: string;
  encryptedName: string;
  authorizationEpoch: number;
}

export interface ClaimedPairing {
  deviceId: string;
  authorizationEpoch: number;
  grantEnvelope: string;
}

export interface InspectedPairing {
  flowId: string;
  deviceId: string;
  signingPublicKeySPKI: string;
  agreementPublicKey: string;
  expiresAt: number;
}

export async function canonicalPairingProof(input: {
  action: "create" | "claim";
  flowId: string;
  deviceId: string;
  signingPublicKeySPKI: string;
  agreementPublicKey: string;
  timestamp: number;
  nonce: string;
  secretHash: string;
}): Promise<string> {
  return [
    "loopdy-link-pair-v1",
    input.action,
    input.flowId,
    input.deviceId,
    input.signingPublicKeySPKI,
    input.agreementPublicKey,
    String(input.timestamp),
    input.nonce,
    input.secretHash,
  ].join("\n");
}

export async function beginPairingChallenge(
  db: D1Database,
  input: BeginPairingInput,
  now: number,
): Promise<{ flowId: string; code: string; expiresAt: number; pairingURL: string }> {
  validateBeginInput(input, now);
  const canonical = await canonicalPairingProof({
    action: "create",
    flowId: "-",
    deviceId: input.deviceId,
    signingPublicKeySPKI: input.signingPublicKeySPKI,
    agreementPublicKey: input.agreementPublicKey,
    timestamp: input.timestamp,
    nonce: input.nonce,
    secretHash: input.claimSecretHash,
  });
  if (!(await verifyProof(input.signingPublicKeySPKI, input.proof, canonical))) {
    throw new LoopdyLinkError("pairing_proof_invalid", "Host pairing proof is invalid");
  }

  const registered = await db
    .prepare("SELECT device_id FROM device_directory WHERE device_id = ? LIMIT 1")
    .bind(input.deviceId)
    .first();
  if (registered) {
    throw new LoopdyLinkError("device_conflict", "Host device is already registered");
  }

  await db
    .prepare(
      "UPDATE pairing_challenges SET state = 'expired' WHERE state IN ('pending', 'approved') AND expires_at <= ?",
    )
    .bind(now)
    .run();
  const flowId = randomBase64URL(24);
  const code = randomCode(6);
  const expiresAt = now + PAIRING_TTL_SECONDS;
  try {
    await db
      .prepare(
        `INSERT INTO pairing_challenges (
           flow_id, code_hash, host_device_id, host_signing_public_key_spki,
           host_agreement_public_key, claim_secret_hash, state,
           created_at, expires_at
         ) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)`,
      )
      .bind(
        flowId,
        await sha256Base64URL(code),
        input.deviceId,
        input.signingPublicKeySPKI,
        input.agreementPublicKey,
        input.claimSecretHash,
        now,
        expiresAt,
      )
      .run();
  } catch {
    throw new LoopdyLinkError(
      "pairing_already_pending",
      "This Loopdy Link host already has a pending pairing request",
    );
  }
  return {
    flowId,
    code,
    expiresAt,
    pairingURL: `loopdy://link/pair?flow=${flowId}&code=${code}`,
  };
}

export async function approvePairingChallenge(
  db: D1Database,
  input: ApprovePairingInput,
  now: number,
  beforeApprove?: (approval: ApprovedPairing) => Promise<void>,
): Promise<ApprovedPairing> {
  validateOpaque(input.flowId, "flowId", 22, 96);
  if (!/^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$/.test(input.code)) {
    throw new LoopdyLinkError("pairing_code_invalid", "Pairing code is invalid");
  }
  validateOpaque(input.accountCoordinate, "accountCoordinate", 22, 256);
  positiveInteger(input.authorizationEpoch, "authorizationEpoch");
  boundedString(input.encryptedName, "encryptedName", 1, 4_096);
  boundedString(input.grantEnvelope, "grantEnvelope", 16, 32_768);

  const row = await requiredPairing(db, input.flowId);
  requireUnexpired(row, now);
  if (!(await equalDigest(row.code_hash, await sha256Base64URL(input.code)))) {
    throw new LoopdyLinkError("pairing_code_invalid", "Pairing code is invalid");
  }
  if (row.state === "claimed" || row.state === "expired") {
    throw new LoopdyLinkError("challenge_used", "Pairing request is no longer available");
  }
  if (row.state === "approved") {
    if (
      row.account_coordinate !== input.accountCoordinate ||
      row.authorization_epoch !== input.authorizationEpoch ||
      row.encrypted_name !== input.encryptedName ||
      row.grant_envelope !== input.grantEnvelope
    ) {
      throw new LoopdyLinkError("device_conflict", "Pairing approval conflicts with state");
    }
    const approval = approvedProjection(row);
    await beforeApprove?.(approval);
    return approval;
  }

  // Capacity and device admission must succeed before the grant is claimable.
  // A retry repeats idempotent registration after any ambiguous D1 failure.
  const approval = approvedProjection({
    ...row, state: "approved", account_coordinate: input.accountCoordinate,
    authorization_epoch: input.authorizationEpoch, encrypted_name: input.encryptedName,
    grant_envelope: input.grantEnvelope, approved_at: now,
  });
  await beforeApprove?.(approval);
  const updated = await db
    .prepare(
      `UPDATE pairing_challenges SET
         state = 'approved', account_coordinate = ?, authorization_epoch = ?,
         encrypted_name = ?, grant_envelope = ?, approved_at = ?
       WHERE flow_id = ? AND state = 'pending' AND expires_at > ?`,
    )
    .bind(
      input.accountCoordinate,
      input.authorizationEpoch,
      input.encryptedName,
      input.grantEnvelope,
      now,
      input.flowId,
      now,
    )
    .run();
  if (updated.meta.changes !== 1) {
    throw new LoopdyLinkError("device_conflict", "Pairing approval was not confirmed");
  }
  return approval;
}

export async function inspectPairingChallenge(
  db: D1Database,
  input: InspectPairingInput,
  now: number,
): Promise<InspectedPairing> {
  if (!/^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$/.test(input.code)) {
    throw new LoopdyLinkError("pairing_code_invalid", "Pairing code is invalid");
  }
  if (input.flowId !== undefined) {
    validateOpaque(input.flowId, "flowId", 22, 96);
  }
  await db
    .prepare(
      "UPDATE pairing_challenges SET state = 'expired' WHERE state IN ('pending', 'approved') AND expires_at <= ?",
    )
    .bind(now)
    .run();
  const codeHash = await sha256Base64URL(input.code);
  const query = input.flowId
    ? `SELECT * FROM pairing_challenges
       WHERE flow_id = ? AND code_hash = ? AND state = 'pending' AND expires_at > ?
       LIMIT 2`
    : `SELECT * FROM pairing_challenges
       WHERE code_hash = ? AND state = 'pending' AND expires_at > ?
       LIMIT 2`;
  const result = input.flowId
    ? await db.prepare(query).bind(input.flowId, codeHash, now).all<PairingRow>()
    : await db.prepare(query).bind(codeHash, now).all<PairingRow>();
  if (result.results.length !== 1) {
    throw new LoopdyLinkError("pairing_code_invalid", "Pairing code is invalid");
  }
  const row = result.results[0]!;
  return {
    flowId: row.flow_id,
    deviceId: row.host_device_id,
    signingPublicKeySPKI: row.host_signing_public_key_spki,
    agreementPublicKey: row.host_agreement_public_key,
    expiresAt: row.expires_at,
  };
}

export async function claimPairingChallenge(
  db: D1Database,
  input: ClaimPairingInput,
  now: number,
): Promise<ClaimedPairing> {
  validateOpaque(input.flowId, "flowId", 22, 96);
  validateOpaque(input.claimSecret, "claimSecret", 32, 128);
  validateOpaque(input.nonce, "nonce", 22, 256);
  validateOpaque(input.proof, "proof", 22, 256);
  positiveInteger(input.timestamp, "timestamp");
  if (Math.abs(input.timestamp - now) > CLOCK_WINDOW_SECONDS) {
    throw new LoopdyLinkError("stale_timestamp", "Pairing timestamp is outside the clock window");
  }

  const row = await requiredPairing(db, input.flowId);
  requireUnexpired(row, now);
  if (row.state !== "approved") {
    throw new LoopdyLinkError(
      row.state === "pending" ? "pairing_pending" : "challenge_used",
      row.state === "pending"
        ? "Pairing request is waiting for approval"
        : "Pairing request is no longer available",
    );
  }
  const suppliedHash = await sha256Base64URL(input.claimSecret);
  if (!(await equalDigest(row.claim_secret_hash, suppliedHash))) {
    throw new LoopdyLinkError("pairing_secret_invalid", "Pairing claim is invalid");
  }
  const canonical = await canonicalPairingProof({
    action: "claim",
    flowId: row.flow_id,
    deviceId: row.host_device_id,
    signingPublicKeySPKI: row.host_signing_public_key_spki,
    agreementPublicKey: row.host_agreement_public_key,
    timestamp: input.timestamp,
    nonce: input.nonce,
    secretHash: row.claim_secret_hash,
  });
  if (!(await verifyProof(row.host_signing_public_key_spki, input.proof, canonical))) {
    throw new LoopdyLinkError("pairing_proof_invalid", "Host pairing proof is invalid");
  }
  const updated = await db
    .prepare(
      `UPDATE pairing_challenges SET state = 'claimed', claimed_at = ?
       WHERE flow_id = ? AND state = 'approved' AND expires_at > ?
         AND EXISTS (
           SELECT 1 FROM accounts
           WHERE accounts.account_coordinate = pairing_challenges.account_coordinate
             AND accounts.status = 'active'
             AND accounts.authorization_epoch = pairing_challenges.authorization_epoch
         )`,
    )
    .bind(now, row.flow_id, now)
    .run();
  if (updated.meta.changes !== 1) {
    throw new LoopdyLinkError("challenge_used", "Pairing request is no longer available");
  }
  if (!row.authorization_epoch || !row.grant_envelope) {
    throw new LoopdyLinkError("device_conflict", "Pairing grant is incomplete");
  }
  return {
    deviceId: row.host_device_id,
    authorizationEpoch: row.authorization_epoch,
    grantEnvelope: row.grant_envelope,
  };
}

function approvedProjection(row: PairingRow): ApprovedPairing {
  if (!row.authorization_epoch || !row.encrypted_name) {
    throw new LoopdyLinkError("device_conflict", "Pairing approval is incomplete");
  }
  return {
    deviceId: row.host_device_id,
    signingPublicKeySPKI: row.host_signing_public_key_spki,
    agreementPublicKey: row.host_agreement_public_key,
    encryptedName: row.encrypted_name,
    authorizationEpoch: row.authorization_epoch,
  };
}

async function requiredPairing(db: D1Database, flowId: string): Promise<PairingRow> {
  const row = await db
    .prepare("SELECT * FROM pairing_challenges WHERE flow_id = ? LIMIT 1")
    .bind(flowId)
    .first<PairingRow>();
  if (!row) throw new LoopdyLinkError("pairing_not_found", "Pairing request was not found");
  return row;
}

function requireUnexpired(row: PairingRow, now: number): void {
  if (row.expires_at <= now || row.state === "expired") {
    throw new LoopdyLinkError("pairing_expired", "Pairing request expired");
  }
}

function validateBeginInput(input: BeginPairingInput, now: number): void {
  if (!DEVICE_ID.test(input.deviceId)) {
    throw new LoopdyLinkError("pairing_request_invalid", "Host device identifier is invalid");
  }
  validateOpaque(input.signingPublicKeySPKI, "signingPublicKeySPKI", 64, 2_048);
  validateOpaque(input.agreementPublicKey, "agreementPublicKey", 42, 128);
  validateOpaque(input.claimSecretHash, "claimSecretHash", 42, 128);
  validateOpaque(input.nonce, "nonce", 22, 256);
  validateOpaque(input.proof, "proof", 22, 256);
  positiveInteger(input.timestamp, "timestamp");
  if (Math.abs(input.timestamp - now) > CLOCK_WINDOW_SECONDS) {
    throw new LoopdyLinkError("stale_timestamp", "Pairing timestamp is outside the clock window");
  }
}

async function verifyProof(
  publicKeySPKI: string,
  proof: string,
  canonical: string,
): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey(
      "spki",
      decodeBase64URL(publicKeySPKI),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
    return await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      decodeBase64URL(proof),
      new TextEncoder().encode(canonical),
    );
  } catch {
    return false;
  }
}

function randomCode(length: number): string {
  const random = crypto.getRandomValues(new Uint8Array(length));
  return Array.from(random, (value) => CODE_ALPHABET[value % CODE_ALPHABET.length]).join("");
}

async function equalDigest(left: string, right: string): Promise<boolean> {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

function decodeBase64URL(value: string): Uint8Array {
  if (!BASE64URL.test(value)) throw new Error("invalid base64url");
  return decodeBase64URLBytes(value);
}

function validateOpaque(value: unknown, field: string, minimum: number, maximum: number): string {
  const parsed = boundedString(value, field, minimum, maximum);
  if (!BASE64URL.test(parsed)) {
    throw new LoopdyLinkError("pairing_request_invalid", `${field} is invalid`);
  }
  return parsed;
}

function boundedString(value: unknown, field: string, minimum: number, maximum: number): string {
  if (typeof value !== "string" || value.length < minimum || value.length > maximum) {
    throw new LoopdyLinkError("pairing_request_invalid", `${field} is invalid`);
  }
  return value;
}

function positiveInteger(value: unknown, field: string): number {
  if (!Number.isSafeInteger(value) || Number(value) < 1) {
    throw new LoopdyLinkError("pairing_request_invalid", `${field} is invalid`);
  }
  return Number(value);
}
