import { encodeBase64URL as base64url, decodeBase64URL as decodeBase64URLBytes, sha256Base64URL as accountDeletionTokenHash } from "./encoding.js";
import { deleteAccountRecordFromPendingPurge, resolveAccountDeletion, type AccountDeletionResolution } from "./account-auth.js";
import { LoopdyLinkError } from "./contracts.js";
import { retireAcceptedAccountNotificationAuthority } from "./notification-grants.js";
import { requireMarketplaceRetirementAcknowledgement } from "./marketplace-retirement.js";
import { BuzzKitBackendError } from "./buzzkit.js";
import type { LinkEnv } from "./user-link.js";
import type { HTTPRouteContext } from "./http-route-context.js";
import { bearerToken } from "./http-request.js";
import { HTTPError, json } from "./http-response.js";

const ACCOUNT_DELETION_RECEIPT_NO_EXPIRY = Number.MAX_SAFE_INTEGER;
// Acceptance is persisted before cleanup begins so an expired client bearer
// can never turn an already-authorized deletion into a normal signed-in account.
const ACCOUNT_DELETION_AUTHORITY_MARKER_PREFIX = "accepted-v1:";
// A durable companion receipt keeps the purge target recoverable without
// storing its plaintext coordinate. The deleting bearer token alone decrypts
// it, and successful final purge removes it while retaining the normal receipt.
const ACCOUNT_DELETION_PURGE_MARKER_PREFIX = "pending-purge-v1:";
const ACCOUNT_DELETION_PURGE_KEY_CONTEXT = "loopdy-account-deletion-purge-v1";

export async function deleteCurrentAccount({ request, env, now }: HTTPRouteContext): Promise<Response> {
  const accessToken = bearerToken(request);
  let deletion: AccountDeletionResolution | undefined;
  try {
    deletion = await resolveAccountDeletion(env.ACCOUNTS, accessToken, now);
  } catch (error) {
    if (!(error instanceof LoopdyLinkError && error.code === "session_expired")) throw error;
    // Expiry cannot create deletion authority. Only this exact bearer's durable
    // pending/accepted markers may resume the already-authorized cleanup below.
  }
  const pendingAccountCoordinate = await loadAccountDeletionMarker(
    env.ACCOUNTS,
    accessToken,
    ACCOUNT_DELETION_PURGE_MARKER_PREFIX,
  );
  if (deletion?.state === "deleted") {
    const accountCoordinate = pendingAccountCoordinate ?? await loadAccountDeletionMarker(
      env.ACCOUNTS,
      accessToken,
      ACCOUNT_DELETION_AUTHORITY_MARKER_PREFIX,
    );
    if (accountCoordinate) {
      await env.USER_LINKS.getByName(accountCoordinate).deleteAccountData();
      await clearAccountDeletionMarkers(env.ACCOUNTS, accessToken);
    }
    return json({ version: 1, state: "deleted" });
  }
  if (pendingAccountCoordinate) {
    await finishPendingAccountPurge(env, accessToken, pendingAccountCoordinate);
    return json({ version: 1, state: "deleted" });
  }
  let acceptedAccountCoordinate = await loadAccountDeletionMarker(
    env.ACCOUNTS,
    accessToken,
    ACCOUNT_DELETION_AUTHORITY_MARKER_PREFIX,
  );
  if (!acceptedAccountCoordinate) {
    if (!deletion) {
      throw new LoopdyLinkError("account_deletion_not_accepted", "Account deletion was not accepted");
    }
    const { session } = deletion;
    await storeAccountDeletionMarker(
      env.ACCOUNTS,
      accessToken,
      deletion.tokenHash,
      session.accountCoordinate,
      ACCOUNT_DELETION_AUTHORITY_MARKER_PREFIX,
      { authorizationEpoch: session.authorizationEpoch, now },
    );
    acceptedAccountCoordinate = session.accountCoordinate;
  }
  await finishAcceptedAccountDeletion(env, accessToken, acceptedAccountCoordinate, now);
  return json({ version: 1, state: "deleted" });
}

async function storeAccountDeletionMarker(
  db: D1Database,
  accessToken: string,
  tokenHash: string,
  accountCoordinate: string,
  markerPrefix: string,
  acceptance?: { authorizationEpoch: number; now: number },
): Promise<void> {
  const prefix = accountDeletionMarkerPrefix(markerPrefix, tokenHash);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv, additionalData: new TextEncoder().encode(prefix) },
      await accountDeletionPurgeKey(accessToken, "encrypt"),
      new TextEncoder().encode(accountCoordinate),
    ),
  );
  const payload = new Uint8Array(iv.length + ciphertext.length);
  payload.set(iv);
  payload.set(ciphertext, iv.length);
  const marker = `${prefix}${base64url(payload)}`;
  if (acceptance) {
    await db.batch([
      db.prepare(
        `UPDATE accounts SET
           status = 'revoked', authorization_epoch = authorization_epoch + 1, revoked_at = ?
         WHERE account_coordinate = ? AND status = 'active' AND authorization_epoch = ?`,
      ).bind(acceptance.now, accountCoordinate, acceptance.authorizationEpoch),
      db.prepare(
        `INSERT INTO account_deletion_receipts (token_hash, expires_at)
         SELECT ?, ? WHERE changes() = 1`,
      ).bind(marker, ACCOUNT_DELETION_RECEIPT_NO_EXPIRY),
      db.prepare(
        `UPDATE pairing_challenges SET state = 'expired'
         WHERE account_coordinate = ? AND authorization_epoch = ? AND state = 'approved'`,
      ).bind(accountCoordinate, acceptance.authorizationEpoch),
    ]);
    const accepted = await db.prepare(
      "SELECT token_hash FROM account_deletion_receipts WHERE token_hash = ? LIMIT 1",
    ).bind(marker).first();
    if (!accepted) {
      throw new LoopdyLinkError("account_not_found", "Loopdy account was not found");
    }
    return;
  }
  await db.batch([
    db
      .prepare("DELETE FROM account_deletion_receipts WHERE substr(token_hash, 1, ?) = ?")
      .bind(prefix.length, prefix),
    db
      .prepare("INSERT INTO account_deletion_receipts (token_hash, expires_at) VALUES (?, ?)")
      .bind(marker, ACCOUNT_DELETION_RECEIPT_NO_EXPIRY),
  ]);
}

async function loadAccountDeletionMarker(
  db: D1Database,
  accessToken: string,
  markerPrefix: string,
): Promise<string | null> {
  const tokenHash = await accountDeletionTokenHash(accessToken);
  const prefix = accountDeletionMarkerPrefix(markerPrefix, tokenHash);
  const markers = await db
    .prepare(
      `SELECT token_hash FROM account_deletion_receipts
       WHERE substr(token_hash, 1, ?) = ?`,
    )
    .bind(prefix.length, prefix)
    .all<{ token_hash: string }>();
  if (markers.results.length === 0) return null;

  const key = await accountDeletionPurgeKey(accessToken, "decrypt");
  const coordinates = await Promise.all(
    markers.results.map(async ({ token_hash }) => {
      const payload = decodeBase64url(token_hash.slice(prefix.length));
      if (payload.length <= 12) throw new Error("Account deletion marker is invalid");
      const coordinate = new TextDecoder().decode(
        await crypto.subtle.decrypt(
          {
            name: "AES-GCM",
            iv: payload.slice(0, 12),
            additionalData: new TextEncoder().encode(prefix),
          },
          key,
          payload.slice(12),
        ),
      );
      if (!/^[A-Za-z0-9_-]{1,128}$/.test(coordinate)) {
        throw new Error("Account deletion marker is invalid");
      }
      return coordinate;
    }),
  );
  if (coordinates.some((coordinate) => coordinate !== coordinates[0])) {
    throw new Error("Account deletion markers conflict");
  }
  return coordinates[0]!;
}

async function clearAccountDeletionMarkers(
  db: D1Database,
  accessToken: string,
): Promise<void> {
  const tokenHash = await accountDeletionTokenHash(accessToken);
  const prefixes = [
    accountDeletionMarkerPrefix(ACCOUNT_DELETION_AUTHORITY_MARKER_PREFIX, tokenHash),
    accountDeletionMarkerPrefix(ACCOUNT_DELETION_PURGE_MARKER_PREFIX, tokenHash),
  ];
  await db.batch(prefixes.map((prefix) => db
    .prepare("DELETE FROM account_deletion_receipts WHERE substr(token_hash, 1, ?) = ?")
    .bind(prefix.length, prefix)));
}

async function finishAcceptedAccountDeletion(
  env: LinkEnv,
  accessToken: string,
  accountCoordinate: string,
  now: number,
): Promise<void> {
  // Persist the serialized-owner fence and close every accepted socket before
  // any external cleanup can block or fail. Final purge keeps the same marker.
  await env.USER_LINKS.getByName(accountCoordinate).beginAccountDeletion();
  try {
    await requireMarketplaceRetirementAcknowledgement(env.MARKETPLACE_RETIREMENT);
  } catch {
    throw new HTTPError(
      503,
      "marketplace_cleanup_unavailable",
      "Retired Marketplace data cleanup is not acknowledged. Try account deletion again.",
    );
  }
  try {
    // Provider cleanup is idempotent. If the server stopped before recording the
    // completed-cleanup marker, retry it under the original deletion authority.
    await retireAcceptedAccountNotificationAuthority(env, accountCoordinate, now);
  } catch (error) {
    if (error instanceof BuzzKitBackendError) {
      throw new HTTPError(
        503,
        "notification_cleanup_unavailable",
        "Notification provider cleanup was not confirmed. Try account deletion again.",
      );
    }
    throw error;
  }
  await storeAccountDeletionMarker(
    env.ACCOUNTS,
    accessToken,
    await accountDeletionTokenHash(accessToken),
    accountCoordinate,
    ACCOUNT_DELETION_PURGE_MARKER_PREFIX,
  );
  await finishPendingAccountPurge(env, accessToken, accountCoordinate);
}

async function finishPendingAccountPurge(
  env: LinkEnv,
  accessToken: string,
  accountCoordinate: string,
): Promise<void> {
  const stub = env.USER_LINKS.getByName(accountCoordinate);
  await stub.deleteAccountData();
  await deleteAccountRecordFromPendingPurge(
    env.ACCOUNTS,
    accountCoordinate,
    await accountDeletionTokenHash(accessToken),
  );
  // Match the accepted path's post-D1 fence against a request that reached the
  // Durable Object between the first purge and account-row deletion.
  await stub.deleteAccountData();
  await clearAccountDeletionMarkers(env.ACCOUNTS, accessToken);
}

function accountDeletionMarkerPrefix(markerPrefix: string, tokenHash: string): string {
  return `${markerPrefix}${tokenHash}:`;
}

async function accountDeletionPurgeKey(
  accessToken: string,
  keyUsage: "encrypt" | "decrypt",
): Promise<CryptoKey> {
  const material = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${ACCOUNT_DELETION_PURGE_KEY_CONTEXT}\n${accessToken}`),
  );
  return crypto.subtle.importKey("raw", material, "AES-GCM", false, [keyUsage]);
}

function decodeBase64url(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new Error("Account deletion purge marker is invalid");
  }
  return decodeBase64URLBytes(value);
}
