import {
  type AuthenticationResponseJSON,
  type AuthenticatorTransportFuture,
  type CredentialDeviceType,
  generateAuthenticationOptions,
  generateRegistrationOptions,
  type PublicKeyCredentialCreationOptionsJSON,
  type PublicKeyCredentialRequestOptionsJSON,
  type RegistrationResponseJSON,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from "@simplewebauthn/server";
import { LoopdyLinkError } from "./contracts.js";
import { encodeBase64URL as base64url, randomBase64URL, sha256Base64URL } from "./encoding.js";

export interface LoopdyPasskeyConfiguration {
  rpName: string;
  rpID: string;
  expectedOrigin: string;
  challengeTTLSeconds: number;
  sessionTTLSeconds: number;
}

export interface RegistrationVerification {
  verified: boolean;
  credential: {
    id: string;
    publicKey: Uint8Array;
    counter: number;
    transports?: AuthenticatorTransportFuture[];
  };
  credentialDeviceType: CredentialDeviceType;
  credentialBackedUp: boolean;
}

export interface AuthenticationVerification {
  verified: boolean;
  newCounter: number;
}

export interface AccountAccessSession {
  accessToken: string;
  expiresAt: number;
  authorizationEpoch: number;
}

export interface ResolvedAccessSession {
  accountCoordinate: string;
  authorizationEpoch: number;
}

const ACCOUNT_KEY_ENVELOPE = /^[A-Za-z0-9_-]{32,4096}$/;

type RegistrationVerifier = (input: {
  response: unknown;
  expectedChallenge: string;
  expectedOrigin: string;
  expectedRPID: string;
}) => Promise<RegistrationVerification>;

type AuthenticationVerifier = (input: {
  response: unknown;
  expectedChallenge: string;
  expectedOrigin: string;
  expectedRPID: string;
  credential: StoredPasskey;
}) => Promise<AuthenticationVerification>;

interface ChallengeRow extends Record<string, SqlStorageValue> {
  flow_id: string;
  kind: string;
  account_coordinate: string | null;
  webauthn_user_id: string | null;
  challenge: string;
  expires_at: number;
  consumed_at: number | null;
}

interface StoredPasskey extends Record<string, SqlStorageValue> {
  credential_id: string;
  account_coordinate: string;
  webauthn_user_id: string;
  public_key: ArrayBuffer;
  counter: number;
  device_type: string;
  backed_up: number;
  transports_json: string | null;
  account_status: string;
  authorization_epoch: number;
}

const MAX_RESPONSE_CHARACTERS = 65_536;
const OPAQUE_COORDINATE_BYTES = 32;
// The legacy expiry column remains for schema compatibility, but deletion
// receipts have no hard expiry. They store only a one-way bearer-token digest,
// never an account coordinate or normal account authority.
const ACCOUNT_DELETION_RECEIPT_NO_EXPIRY = Number.MAX_SAFE_INTEGER;

export type AccountDeletionResolution =
  | { state: "active"; session: ResolvedAccessSession; tokenHash: string }
  | { state: "deleted" };

export async function beginAccountRegistration(
  db: D1Database,
  configuration: LoopdyPasskeyConfiguration,
  now: number,
): Promise<{ flowId: string; options: PublicKeyCredentialCreationOptionsJSON }> {
  validateConfiguration(configuration);
  const accountCoordinate = randomBase64URL(OPAQUE_COORDINATE_BYTES);
  const flowId = randomBase64URL(24);
  const userID = crypto.getRandomValues(new Uint8Array(32));
  const webauthnUserID = base64url(userID);
  const options = await generateRegistrationOptions({
    rpName: configuration.rpName,
    rpID: configuration.rpID,
    userID,
    userName: `loopdy-${accountCoordinate.slice(0, 16)}`,
    userDisplayName: "Loopdy account",
    attestationType: "none",
    authenticatorSelection: {
      residentKey: "required",
      userVerification: "required",
    },
    preferredAuthenticatorType: "localDevice",
    timeout: configuration.challengeTTLSeconds * 1_000,
  });
  await db
    .prepare(
      `INSERT INTO auth_challenges (
         flow_id, kind, account_coordinate, webauthn_user_id, challenge, expires_at
       ) VALUES (?, 'registration', ?, ?, ?, ?)`,
    )
    .bind(
      flowId,
      accountCoordinate,
      webauthnUserID,
      options.challenge,
      now + configuration.challengeTTLSeconds,
    )
    .run();
  return { flowId, options };
}

export async function completeAccountRegistration(
  db: D1Database,
  configuration: LoopdyPasskeyConfiguration,
  input: { flowId: string; response: unknown },
  now: number,
  verifier: RegistrationVerifier = verifyRegistration,
): Promise<AccountAccessSession> {
  const challenge = await requiredChallenge(db, input.flowId, "registration", now);
  boundedCredentialResponse(input.response);
  const verification = await verifier({
    response: input.response,
    expectedChallenge: challenge.challenge,
    expectedOrigin: configuration.expectedOrigin,
    expectedRPID: configuration.rpID,
  });
  if (!verification.verified) {
    throw new LoopdyLinkError("passkey_invalid", "Passkey registration could not be verified");
  }
  const accountCoordinate = requiredCoordinate(challenge.account_coordinate);
  const webauthnUserID = requiredCoordinate(challenge.webauthn_user_id);
  const session = await createAccessSession(configuration, now);
  const publicKey = exactArrayBuffer(verification.credential.publicKey);
  const transports = verification.credential.transports
    ? JSON.stringify(verification.credential.transports)
    : null;

  await db.batch([
    db
      .prepare(
        `INSERT INTO accounts (
           account_coordinate, status, authorization_epoch, recovery_verifier, created_at
         ) VALUES (?, 'active', 1, NULL, ?)`,
      )
      .bind(accountCoordinate, now),
    db
      .prepare(
        `INSERT INTO passkeys (
           credential_id, account_coordinate, webauthn_user_id, public_key, counter,
           device_type, backed_up, transports_json, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(
        verification.credential.id,
        accountCoordinate,
        webauthnUserID,
        publicKey,
        verification.credential.counter,
        verification.credentialDeviceType,
        verification.credentialBackedUp ? 1 : 0,
        transports,
        now,
      ),
    db
      .prepare(
        "UPDATE auth_challenges SET consumed_at = ? WHERE flow_id = ? AND consumed_at IS NULL",
      )
      .bind(now, input.flowId),
    db
      .prepare(
        `INSERT INTO access_sessions (
           token_hash, account_coordinate, authorization_epoch, created_at, expires_at
         ) VALUES (?, ?, 1, ?, ?)`,
      )
      .bind(session.tokenHash, accountCoordinate, now, session.expiresAt),
  ]);
  return {
    accessToken: session.accessToken,
    expiresAt: session.expiresAt,
    authorizationEpoch: 1,
  };
}

export async function beginAccountAuthentication(
  db: D1Database,
  configuration: LoopdyPasskeyConfiguration,
  now: number,
): Promise<{ flowId: string; options: PublicKeyCredentialRequestOptionsJSON }> {
  validateConfiguration(configuration);
  const flowId = randomBase64URL(24);
  const options = await generateAuthenticationOptions({
    rpID: configuration.rpID,
    userVerification: "required",
    timeout: configuration.challengeTTLSeconds * 1_000,
  });
  await db
    .prepare(
      `INSERT INTO auth_challenges (flow_id, kind, challenge, expires_at)
       VALUES (?, 'authentication', ?, ?)`,
    )
    .bind(flowId, options.challenge, now + configuration.challengeTTLSeconds)
    .run();
  return { flowId, options };
}

export async function completeAccountAuthentication(
  db: D1Database,
  configuration: LoopdyPasskeyConfiguration,
  input: { flowId: string; response: unknown },
  now: number,
  verifier: AuthenticationVerifier = verifyAuthentication,
): Promise<AccountAccessSession> {
  const challenge = await requiredChallenge(db, input.flowId, "authentication", now);
  const credentialID = credentialResponseID(input.response);
  const passkey = await db
    .prepare(
      `SELECT p.*, a.status AS account_status, a.authorization_epoch
       FROM passkeys p JOIN accounts a USING (account_coordinate)
       WHERE p.credential_id = ? LIMIT 1`,
    )
    .bind(credentialID)
    .first<StoredPasskey>();
  if (passkey?.account_status !== "active") {
    throw new LoopdyLinkError("passkey_unknown", "Passkey is not registered");
  }
  const verification = await verifier({
    response: input.response,
    expectedChallenge: challenge.challenge,
    expectedOrigin: configuration.expectedOrigin,
    expectedRPID: configuration.rpID,
    credential: passkey,
  });
  if (!verification.verified) {
    throw new LoopdyLinkError("passkey_invalid", "Passkey authentication could not be verified");
  }
  const session = await createAccessSession(configuration, now);
  const committed = await db.batch([
    db
      .prepare(
        `INSERT INTO access_sessions (
           token_hash, account_coordinate, authorization_epoch, created_at, expires_at
         )
         SELECT ?, a.account_coordinate, a.authorization_epoch, ?, ?
         FROM accounts a
         WHERE a.account_coordinate = ? AND a.status = 'active'
           AND a.authorization_epoch = ?`,
      )
      .bind(
        session.tokenHash,
        now,
        session.expiresAt,
        passkey.account_coordinate,
        passkey.authorization_epoch,
      ),
    db
      .prepare(
        `UPDATE passkeys SET counter = ?
         WHERE credential_id = ? AND counter = ?
           AND EXISTS (SELECT 1 FROM access_sessions WHERE token_hash = ?)`,
      )
      .bind(verification.newCounter, credentialID, passkey.counter, session.tokenHash),
    db
      .prepare(
        `UPDATE auth_challenges SET consumed_at = ?
         WHERE flow_id = ? AND consumed_at IS NULL
           AND EXISTS (SELECT 1 FROM access_sessions WHERE token_hash = ?)`,
      )
      .bind(now, input.flowId, session.tokenHash),
  ]);
  if (committed[0]?.meta.changes !== 1) {
    throw new LoopdyLinkError("passkey_unknown", "Passkey is not registered");
  }
  return {
    accessToken: session.accessToken,
    expiresAt: session.expiresAt,
    authorizationEpoch: passkey.authorization_epoch,
  };
}

export async function resolveAccessSession(
  db: D1Database,
  accessToken: string,
  now: number,
): Promise<ResolvedAccessSession> {
  const tokenHash = await accessTokenHash(accessToken);
  const row = await db
    .prepare(
      `SELECT s.account_coordinate, s.authorization_epoch, s.expires_at,
              s.revoked_at, a.status, a.authorization_epoch AS account_epoch
       FROM access_sessions s JOIN accounts a USING (account_coordinate)
       WHERE s.token_hash = ? LIMIT 1`,
    )
    .bind(tokenHash)
    .first<{
      account_coordinate: string;
      authorization_epoch: number;
      expires_at: number;
      revoked_at: number | null;
      status: string;
      account_epoch: number;
    }>();
  if (
    !row ||
    row.revoked_at !== null ||
    row.expires_at <= now ||
    row.status !== "active" ||
    row.authorization_epoch !== row.account_epoch
  ) {
    throw new LoopdyLinkError("session_expired", "Account session has expired");
  }
  return {
    accountCoordinate: row.account_coordinate,
    authorizationEpoch: row.authorization_epoch,
  };
}

export async function resolveAccountDeletion(
  db: D1Database,
  accessToken: string,
  now: number,
): Promise<AccountDeletionResolution> {
  const tokenHash = await accessTokenHash(accessToken);
  try {
    return {
      state: "active",
      session: await resolveAccessSession(db, accessToken, now),
      tokenHash,
    };
  } catch (error) {
    if (!(error instanceof LoopdyLinkError) || error.code !== "session_expired") throw error;
  }

  const receipt = await db
    .prepare(
      `SELECT token_hash
       FROM account_deletion_receipts
       WHERE token_hash = ?
       LIMIT 1`,
    )
    .bind(tokenHash)
    .first<{ token_hash: string }>();
  if (receipt) return { state: "deleted" };
  throw new LoopdyLinkError("session_expired", "Account session has expired");
}

export async function storeAccountKeyEnvelope(
  db: D1Database,
  accessToken: string,
  envelope: string,
  now: number,
): Promise<void> {
  if (!ACCOUNT_KEY_ENVELOPE.test(envelope)) {
    throw new LoopdyLinkError("account_key_invalid", "The encrypted account key is invalid");
  }
  const session = await resolveAccessSession(db, accessToken, now);
  const update = await db
    .prepare(
      `UPDATE accounts SET key_envelope = ?
       WHERE account_coordinate = ? AND key_envelope IS NULL`,
    )
    .bind(envelope, session.accountCoordinate)
    .run();
  if (update.meta.changes === 1) return;

  const existing = await db
    .prepare("SELECT key_envelope FROM accounts WHERE account_coordinate = ? LIMIT 1")
    .bind(session.accountCoordinate)
    .first<{ key_envelope: string | null }>();
  if (existing?.key_envelope === envelope) return;
  throw new LoopdyLinkError(
    "account_key_conflict",
    "The encrypted account key is already established",
  );
}

export async function loadAccountKeyEnvelope(
  db: D1Database,
  accessToken: string,
  now: number,
): Promise<string> {
  const session = await resolveAccessSession(db, accessToken, now);
  const account = await db
    .prepare("SELECT key_envelope FROM accounts WHERE account_coordinate = ? LIMIT 1")
    .bind(session.accountCoordinate)
    .first<{ key_envelope: string | null }>();
  if (!account?.key_envelope || !ACCOUNT_KEY_ENVELOPE.test(account.key_envelope)) {
    throw new LoopdyLinkError("account_key_missing", "The encrypted account key is not available");
  }
  return account.key_envelope;
}

export async function deleteAccountRecord(
  db: D1Database,
  session: ResolvedAccessSession,
  tokenHash: string,
  _now: number,
): Promise<void> {
  await db.batch([
    // Registration challenges keep their account coordinate for the short
    // registration window but intentionally do not have a foreign key: the
    // account does not exist until verification succeeds. Purge them
    // explicitly so account deletion removes every account-linked record.
    db
      .prepare("DELETE FROM auth_challenges WHERE account_coordinate = ?")
      .bind(session.accountCoordinate),
    db
      .prepare(
        `DELETE FROM accounts
         WHERE account_coordinate = ? AND status = 'active' AND authorization_epoch = ?`,
      )
      .bind(session.accountCoordinate, session.authorizationEpoch),
    db
      .prepare(
        `INSERT INTO account_deletion_receipts (token_hash, expires_at)
         SELECT ?, ? WHERE changes() = 1
         ON CONFLICT(token_hash) DO UPDATE SET expires_at = excluded.expires_at`,
      )
      .bind(tokenHash, ACCOUNT_DELETION_RECEIPT_NO_EXPIRY),
  ]);
  const remaining = await db
    .prepare("SELECT account_coordinate FROM accounts WHERE account_coordinate = ? LIMIT 1")
    .bind(session.accountCoordinate)
    .first();
  if (remaining) {
    throw new LoopdyLinkError("account_not_found", "Loopdy account was not found");
  }
}

export async function deleteAccountRecordFromPendingPurge(
  db: D1Database,
  accountCoordinate: string,
  tokenHash: string,
): Promise<void> {
  // The encrypted pending-purge marker is durable server-side proof that this
  // exact bearer was accepted while its session was active. Finish from that
  // authority even if the short-lived access session has since expired.
  await db.batch([
    db
      .prepare("DELETE FROM auth_challenges WHERE account_coordinate = ?")
      .bind(accountCoordinate),
    db
      .prepare("DELETE FROM accounts WHERE account_coordinate = ?")
      .bind(accountCoordinate),
    db
      .prepare(
        `INSERT INTO account_deletion_receipts (token_hash, expires_at) VALUES (?, ?)
         ON CONFLICT(token_hash) DO UPDATE SET expires_at = excluded.expires_at`,
      )
      .bind(tokenHash, ACCOUNT_DELETION_RECEIPT_NO_EXPIRY),
  ]);
}

async function verifyRegistration(input: {
  response: unknown;
  expectedChallenge: string;
  expectedOrigin: string;
  expectedRPID: string;
}): Promise<RegistrationVerification> {
  const result = await verifyRegistrationResponse({
    response: input.response as RegistrationResponseJSON,
    expectedChallenge: input.expectedChallenge,
    expectedOrigin: input.expectedOrigin,
    expectedRPID: input.expectedRPID,
    requireUserVerification: true,
  });
  if (!result.verified) {
    throw new LoopdyLinkError("passkey_invalid", "Passkey registration could not be verified");
  }
  return {
    verified: true,
    credential: result.registrationInfo.credential,
    credentialDeviceType: result.registrationInfo.credentialDeviceType,
    credentialBackedUp: result.registrationInfo.credentialBackedUp,
  };
}

async function verifyAuthentication(input: {
  response: unknown;
  expectedChallenge: string;
  expectedOrigin: string;
  expectedRPID: string;
  credential: StoredPasskey;
}): Promise<AuthenticationVerification> {
  const transports = input.credential.transports_json
    ? (JSON.parse(input.credential.transports_json) as AuthenticatorTransportFuture[])
    : undefined;
  const result = await verifyAuthenticationResponse({
    response: input.response as AuthenticationResponseJSON,
    expectedChallenge: input.expectedChallenge,
    expectedOrigin: input.expectedOrigin,
    expectedRPID: input.expectedRPID,
    requireUserVerification: true,
    credential: {
      id: input.credential.credential_id,
      publicKey: new Uint8Array(input.credential.public_key),
      counter: input.credential.counter,
      transports,
    },
  });
  return {
    verified: result.verified,
    newCounter: result.authenticationInfo.newCounter,
  };
}

async function requiredChallenge(
  db: D1Database,
  flowId: string,
  kind: "registration" | "authentication",
  now: number,
): Promise<ChallengeRow> {
  if (!/^[A-Za-z0-9_-]{24,128}$/.test(flowId)) {
    throw new LoopdyLinkError("challenge_invalid", "Passkey challenge is invalid");
  }
  const row = await db
    .prepare("SELECT * FROM auth_challenges WHERE flow_id = ? AND kind = ? LIMIT 1")
    .bind(flowId, kind)
    .first<ChallengeRow>();
  if (!row) throw new LoopdyLinkError("challenge_invalid", "Passkey challenge is invalid");
  if (row.consumed_at !== null) {
    throw new LoopdyLinkError("challenge_used", "Passkey challenge was already used");
  }
  if (row.expires_at <= now) {
    throw new LoopdyLinkError("challenge_expired", "Passkey challenge has expired");
  }
  return row;
}

function validateConfiguration(configuration: LoopdyPasskeyConfiguration): void {
  if (
    !configuration.rpName ||
    !/^[A-Za-z0-9.-]+$/.test(configuration.rpID) ||
    !configuration.expectedOrigin.startsWith("https://") ||
    !Number.isSafeInteger(configuration.challengeTTLSeconds) ||
    configuration.challengeTTLSeconds < 60 ||
    configuration.challengeTTLSeconds > 600 ||
    !Number.isSafeInteger(configuration.sessionTTLSeconds) ||
    configuration.sessionTTLSeconds < 300 ||
    configuration.sessionTTLSeconds > 3_600
  ) {
    throw new LoopdyLinkError("configuration_invalid", "Passkey configuration is invalid");
  }
}

function boundedCredentialResponse(response: unknown): void {
  if (!response || typeof response !== "object") {
    throw new LoopdyLinkError("passkey_invalid", "Passkey response is invalid");
  }
  let serialized: string;
  try {
    serialized = JSON.stringify(response);
  } catch {
    throw new LoopdyLinkError("passkey_invalid", "Passkey response is invalid");
  }
  if (serialized.length > MAX_RESPONSE_CHARACTERS) {
    throw new LoopdyLinkError("passkey_invalid", "Passkey response is too large");
  }
}

function credentialResponseID(response: unknown): string {
  boundedCredentialResponse(response);
  const id = (response as { id?: unknown }).id;
  if (typeof id !== "string" || !/^[A-Za-z0-9_-]{1,1024}$/.test(id)) {
    throw new LoopdyLinkError("passkey_invalid", "Passkey response is invalid");
  }
  return id;
}

async function createAccessSession(
  configuration: LoopdyPasskeyConfiguration,
  now: number,
): Promise<{ accessToken: string; tokenHash: string; expiresAt: number }> {
  const accessToken = randomBase64URL(32);
  return {
    accessToken,
    tokenHash: await sha256Base64URL(accessToken),
    expiresAt: now + configuration.sessionTTLSeconds,
  };
}

async function accessTokenHash(accessToken: string): Promise<string> {
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(accessToken)) {
    throw new LoopdyLinkError("session_invalid", "Account session is invalid");
  }
  return sha256Base64URL(accessToken);
}

function exactArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.slice().buffer as ArrayBuffer;
}

function requiredCoordinate(value: string | null): string {
  if (!value || !/^[A-Za-z0-9_-]{24,128}$/.test(value)) {
    throw new LoopdyLinkError("challenge_invalid", "Passkey challenge is invalid");
  }
  return value;
}
