import { encodeSmallBase64URL as base64, decodeBase64URL, sha256Bytes as digest } from "./encoding.js";
import { privateJSON as json } from "./http-primitives.js";
import type { LinkEnv } from "./user-link.js";

export interface NotificationOnlyPrincipal {
  ownerKind: "notification-instance";
  ownerCoordinate: string;
  credentialId: string;
  authorizationEpoch: number;
}

export interface NotificationOnlyInstallation extends NotificationOnlyPrincipal {
  publicKeySPKI: string;
  requestId: string;
  requestDigest: string;
  state: "active" | "revoked";
}

const BOOTSTRAP_PATH = "/v1/notifications/bootstrap";
const CURRENT_PATH = "/v1/notifications/installations/current";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const OPAQUE = /^[A-Za-z0-9_-]{22,256}$/;
const SPKI = /^[A-Za-z0-9_-]{120,256}$/;
const WINDOW_SECONDS = 120;
const RATE_WINDOW_SECONDS = 3_600;
const RATE_LIMIT = 20;

export class NotificationIdentityError extends Error {
  constructor(readonly status: number, readonly code: string) {
    super(code);
  }
}

const fail = (status: number, code: string): never => { throw new NotificationIdentityError(status, code); };

export async function handleNotificationIdentityRequest(
  request: Request,
  env: LinkEnv,
  now: number,
  beforeRevoke: (principal: NotificationOnlyPrincipal) => Promise<void>,
): Promise<Response | null> {
  const url = new URL(request.url);
  if (url.pathname !== BOOTSTRAP_PATH && url.pathname !== CURRENT_PATH) return null;
  try {
    if (url.search || url.hash) return fail(400, "notification_path_invalid");
    if (url.pathname === BOOTSTRAP_PATH) {
      if (request.method !== "POST") return fail(405, "notification_method_invalid");
      const raw = await boundedBody(request, 16_384);
      const body = object(JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(raw)));
      exact(body, ["version", "installationId", "requestId", "publicKeySPKI", "timestamp", "nonce", "proof"]);
      const installationId = string(body.installationId);
      const requestId = string(body.requestId);
      const publicKeySPKI = string(body.publicKeySPKI);
      const nonce = string(body.nonce);
      const proof = string(body.proof);
      const timestamp = number(body.timestamp);
      if (body.version !== 1 || !UUID.test(installationId) || !UUID.test(requestId)
          || !SPKI.test(publicKeySPKI) || !OPAQUE.test(nonce) || !OPAQUE.test(proof)) {
        return fail(400, "notification_bootstrap_invalid");
      }
      const requestDigest = base64(await digest(raw));
      const existing = await loadInstallation(env, installationId);
      if (existing) {
        if (existing.publicKeySPKI !== publicKeySPKI || existing.requestId !== requestId
            || existing.requestDigest !== requestDigest || existing.state !== "active") {
          return fail(409, "notification_bootstrap_conflict");
        }
        return identityResponse(existing, 200);
      }
      if (Math.abs(timestamp - now) > WINDOW_SECONDS) return fail(401, "notification_bootstrap_stale");
      const key = await importKey(publicKeySPKI);
      const transcript = [
        "loopdy-notification-bootstrap-v1", "POST", BOOTSTRAP_PATH,
        installationId, requestId, String(timestamp), nonce, publicKeySPKI,
      ].join("\n");
      if (!await crypto.subtle.verify(
        { name: "ECDSA", hash: "SHA-256" }, key, decode(proof), new TextEncoder().encode(transcript),
      )) return fail(401, "notification_bootstrap_proof_invalid");
      await enforceBootstrapRate(request, env, publicKeySPKI, now);
      await env.ACCOUNTS.prepare("DELETE FROM notification_bootstrap_nonces WHERE expires_at<=?").bind(now).run();
      const nonceInsert = await env.ACCOUNTS.prepare(`INSERT INTO notification_bootstrap_nonces(
          public_key_digest,nonce,expires_at) VALUES(?,?,?) ON CONFLICT DO NOTHING`)
        .bind(base64(await digest(new TextEncoder().encode(publicKeySPKI))), nonce, now + WINDOW_SECONDS).run();
      if (nonceInsert.meta.changes !== 1) return fail(409, "notification_bootstrap_replayed");
      const installation: NotificationOnlyInstallation = {
        ownerKind: "notification-instance",
        ownerCoordinate: `notify_${base64(crypto.getRandomValues(new Uint8Array(32)))}`,
        credentialId: installationId,
        authorizationEpoch: 1,
        publicKeySPKI,
        requestId,
        requestDigest,
        state: "active",
      };
      const inserted = await env.ACCOUNTS.prepare(`INSERT INTO notification_installations(
          installation_id,notification_coordinate,public_key_spki,authorization_epoch,
          bootstrap_request_id,bootstrap_request_digest,state,created_at)
        VALUES(?,?,?,1,?,?,'active',?) ON CONFLICT DO NOTHING`)
        .bind(installationId, installation.ownerCoordinate, publicKeySPKI, requestId, requestDigest, now).run();
      if (inserted.meta.changes !== 1) return fail(409, "notification_bootstrap_conflict");
      return identityResponse(installation, 201);
    }

    if (request.method !== "DELETE") return fail(405, "notification_method_invalid");
    const raw = await boundedBody(request, 1);
    if (raw.length) return fail(400, "notification_request_invalid");
    const verification = await verifyNotificationRequest(request, raw, env, now, true);
    if (verification.alreadyRevoked && !verification.cleanupPending) {
      return revokedResponse(verification.principal.credentialId);
    }
    const principal = verification.principal;
    if (!verification.cleanupPending) {
      // The installation's owning object is the final notification authority.
      // Revoke it before D1 so no send with an earlier directory snapshot can
      // linearize after this revocation begins.
      await (env.USER_LINKS.getByName(principal.ownerCoordinate) as unknown as {
        revokeNotificationCredential(input: {
          credentialId: string; authorizationEpoch: number;
        }): Promise<void>;
      }).revokeNotificationCredential({
        credentialId: principal.credentialId,
        authorizationEpoch: principal.authorizationEpoch,
      });
      const committed = await env.ACCOUNTS.batch([
        env.ACCOUNTS.prepare(`INSERT INTO notification_installation_revocation_cleanup(
          installation_id,notification_coordinate,authorization_epoch,started_at)
          SELECT installation_id,notification_coordinate,authorization_epoch,?
          FROM notification_installations
          WHERE installation_id=? AND notification_coordinate=? AND state='active'
            AND authorization_epoch=?
          ON CONFLICT(installation_id) DO NOTHING`)
          .bind(now, principal.credentialId, principal.ownerCoordinate, principal.authorizationEpoch),
        env.ACCOUNTS.prepare(`UPDATE notification_installations
          SET state='revoked',authorization_epoch=authorization_epoch+1,revoked_at=?
          WHERE installation_id=? AND notification_coordinate=? AND state='active'
            AND authorization_epoch=?`)
          .bind(now, principal.credentialId, principal.ownerCoordinate, principal.authorizationEpoch),
      ]);
      const readback = await loadInstallation(env, principal.credentialId);
      const marker = await loadRevocationCleanup(env, principal.credentialId);
      if (committed[0]?.meta.changes !== 1 || committed[1]?.meta.changes !== 1
          || !readback || readback.state !== "revoked"
          || readback.authorizationEpoch !== principal.authorizationEpoch + 1
          || !marker || marker.notificationCoordinate !== principal.ownerCoordinate
          || marker.authorizationEpoch !== principal.authorizationEpoch) {
        return fail(503, "notification_revocation_unconfirmed");
      }
    }
    await beforeRevoke(principal);
    await env.ACCOUNTS.prepare(`DELETE FROM notification_installation_revocation_cleanup
      WHERE installation_id=? AND notification_coordinate=? AND authorization_epoch=?`)
      .bind(principal.credentialId, principal.ownerCoordinate, principal.authorizationEpoch).run();
    if (await loadRevocationCleanup(env, principal.credentialId)) {
      return fail(503, "notification_revocation_unconfirmed");
    }
    return revokedResponse(principal.credentialId);
  } catch (error) {
    if (error instanceof NotificationIdentityError) {
      return json({ version: 2, error: { code: error.code } }, error.status);
    }
    if (error instanceof SyntaxError || error instanceof TypeError) {
      return json({ version: 2, error: { code: "notification_request_invalid" } }, 400);
    }
    throw error;
  }
}

export async function verifyNotificationOnlyRequest(
  request: Request,
  raw: Uint8Array,
  env: LinkEnv,
  now: number,
): Promise<NotificationOnlyPrincipal> {
  return (await verifyNotificationRequest(request, raw, env, now, false)).principal;
}

async function verifyNotificationRequest(
  request: Request,
  raw: Uint8Array,
  env: LinkEnv,
  now: number,
  allowRevokedRetry: boolean,
): Promise<{ principal: NotificationOnlyPrincipal; alreadyRevoked: boolean; cleanupPending: boolean }> {
  const installationId = request.headers.get("x-loopdy-notification-installation") ?? "";
  const timestampText = request.headers.get("x-loopdy-timestamp") ?? "";
  const nonce = request.headers.get("x-loopdy-nonce") ?? "";
  const epochText = request.headers.get("x-loopdy-authorization-epoch") ?? "";
  const signature = request.headers.get("x-loopdy-signature") ?? "";
  const timestamp = Number(timestampText);
  const authorizationEpoch = Number(epochText);
  if (!UUID.test(installationId) || !/^[1-9][0-9]{0,12}$/.test(timestampText)
      || !/^[1-9][0-9]{0,12}$/.test(epochText) || !Number.isSafeInteger(timestamp)
      || !Number.isSafeInteger(authorizationEpoch) || Math.abs(timestamp - now) > WINDOW_SECONDS
      || !OPAQUE.test(nonce) || !OPAQUE.test(signature)) {
    return fail(401, "notification_credentials_invalid");
  }
  const installation = await loadInstallation(env, installationId);
  const cleanup = installation?.state === "revoked"
    ? await loadRevocationCleanup(env, installationId) : null;
  const url = new URL(request.url);
  const active = installation?.state === "active"
    && installation.authorizationEpoch === authorizationEpoch;
  const alreadyRevoked = allowRevokedRetry
    && request.method === "DELETE" && url.pathname === CURRENT_PATH && !url.search && !url.hash
    && installation?.state === "revoked"
    && installation.authorizationEpoch === authorizationEpoch + 1;
  const cleanupPending = alreadyRevoked && cleanup?.notificationCoordinate === installation?.ownerCoordinate
    && cleanup.authorizationEpoch === authorizationEpoch;
  if (!installation || (!active && !alreadyRevoked)) {
    return fail(403, "notification_credentials_revoked");
  }
  const transcript = [
    "loopdy-notification-device-v1", request.method.toUpperCase(), `${url.pathname}${url.search}`,
    installationId, String(timestamp), nonce, String(authorizationEpoch), base64(await digest(raw)),
  ].join("\n");
  const key = await importKey(installation.publicKeySPKI);
  if (!await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" }, key, decode(signature), new TextEncoder().encode(transcript),
  )) return fail(401, "notification_signature_invalid");
  if (!alreadyRevoked) {
    await env.ACCOUNTS.prepare("DELETE FROM notification_installation_nonces WHERE expires_at<=?").bind(now).run();
    const inserted = await env.ACCOUNTS.prepare(`INSERT INTO notification_installation_nonces(
        installation_id,nonce,expires_at) VALUES(?,?,?) ON CONFLICT DO NOTHING`)
      .bind(installationId, nonce, now + WINDOW_SECONDS).run();
    if (inserted.meta.changes !== 1) return fail(409, "notification_nonce_replayed");
  }
  return {
    principal: {
      ownerKind: "notification-instance",
      ownerCoordinate: installation.ownerCoordinate,
      credentialId: installation.credentialId,
      authorizationEpoch,
    },
    alreadyRevoked,
    cleanupPending,
  };
}

async function loadRevocationCleanup(
  env: LinkEnv,
  installationId: string,
): Promise<{ notificationCoordinate: string; authorizationEpoch: number } | null> {
  const row = await env.ACCOUNTS.prepare(`SELECT notification_coordinate,authorization_epoch
    FROM notification_installation_revocation_cleanup WHERE installation_id=?`)
    .bind(installationId).first<{ notification_coordinate: string; authorization_epoch: number }>();
  return row ? {
    notificationCoordinate: row.notification_coordinate,
    authorizationEpoch: row.authorization_epoch,
  } : null;
}

export async function loadInstallation(
  env: LinkEnv,
  installationId: string,
): Promise<NotificationOnlyInstallation | null> {
  const row = await env.ACCOUNTS.prepare(`SELECT installation_id,notification_coordinate,public_key_spki,
      authorization_epoch,bootstrap_request_id,bootstrap_request_digest,state
    FROM notification_installations WHERE installation_id=?`)
    .bind(installationId).first<{
      installation_id: string; notification_coordinate: string; public_key_spki: string;
      authorization_epoch: number; bootstrap_request_id: string; bootstrap_request_digest: string;
      state: "active" | "revoked";
    }>();
  return row ? {
    ownerKind: "notification-instance",
    ownerCoordinate: row.notification_coordinate,
    credentialId: row.installation_id,
    authorizationEpoch: row.authorization_epoch,
    publicKeySPKI: row.public_key_spki,
    requestId: row.bootstrap_request_id,
    requestDigest: row.bootstrap_request_digest,
    state: row.state,
  } : null;
}

async function enforceBootstrapRate(request: Request, env: LinkEnv, publicKey: string, now: number) {
  const address = request.headers.get("cf-connecting-ip") ?? "";
  const secret = env.NOTIFICATION_BOOTSTRAP_RATE_SECRET?.trim() ?? "";
  if (!address || !secret) return fail(503, "notification_bootstrap_rate_unavailable");
  const imported = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const ipKey = base64(new Uint8Array(await crypto.subtle.sign("HMAC", imported, new TextEncoder().encode(address))));
  const keyKey = base64(await digest(new TextEncoder().encode(publicKey)));
  const window = Math.floor(now / RATE_WINDOW_SECONDS) * RATE_WINDOW_SECONDS;
  for (const key of [`ip:${ipKey}`, `key:${keyKey}`]) {
    const limit = key.startsWith("ip:") ? RATE_LIMIT : 4;
    const result = await env.ACCOUNTS.prepare(`INSERT INTO notification_bootstrap_rate(rate_key,window_start,attempts)
      VALUES(?,?,1) ON CONFLICT(rate_key,window_start) DO UPDATE SET attempts=attempts+1
      WHERE attempts<?`).bind(key, window, limit).run();
    if (result.meta.changes !== 1) return fail(429, "notification_bootstrap_rate_limited");
  }
  await env.ACCOUNTS.prepare("DELETE FROM notification_bootstrap_rate WHERE window_start<?")
    .bind(window - RATE_WINDOW_SECONDS).run();
}

function identityResponse(installation: NotificationOnlyInstallation, status: number): Response {
  return json({
    version: 2,
    credential: {
      scope: "notification-only",
      installationId: installation.credentialId,
      authorizationEpoch: installation.authorizationEpoch,
    },
  }, status);
}

function revokedResponse(installationId: string): Response {
  return json({ version: 2, installation: { installationId, state: "revoked" } });
}

async function importKey(value: string): Promise<CryptoKey> {
  try {
    return await crypto.subtle.importKey(
      "spki", decode(value), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"],
    );
  } catch { return fail(400, "notification_key_invalid"); }
}

async function boundedBody(request: Request, maximum: number): Promise<Uint8Array> {
  const buffer = new Uint8Array(await request.arrayBuffer());
  if (buffer.length > maximum) return fail(413, "notification_body_too_large");
  return buffer;
}

function exact(value: Record<string, unknown>, keys: string[]) {
  if (Object.keys(value).length !== keys.length || keys.some((key) => !(key in value))) {
    fail(400, "notification_request_invalid");
  }
}
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return fail(400, "notification_request_invalid");
  return value as Record<string, unknown>;
}
function string(value: unknown): string {
  if (typeof value !== "string") return fail(400, "notification_request_invalid");
  return value;
}
function number(value: unknown): number {
  if (!Number.isSafeInteger(value) || Number(value) < 1) return fail(400, "notification_request_invalid");
  return Number(value);
}
function decode(value: string): Uint8Array {
  try {
    const result = decodeBase64URL(value);
    if (base64(result) !== value) return fail(400, "notification_proof_invalid");
    return result;
  } catch { return fail(400, "notification_proof_invalid"); }
}
