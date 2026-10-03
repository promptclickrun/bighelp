import { encodeSmallBase64URL as notificationBase64, decodeBase64URL, sha256Bytes as digest } from "./encoding.js";
import { privateJSON as response, readByteStream } from "./http-primitives.js";
export { encodeSmallBase64URL as notificationBase64 } from "./encoding.js";
import { DEVICE_AUTH_HEADERS, verifyDeviceRequest, type VerifiedDeviceRequest } from "./device-auth.js";
import { LoopdyLinkError, type PublicLinkDevice } from "./contracts.js";
import type { LinkEnv } from "./user-link.js";
import { NotificationIdentityError, verifyNotificationOnlyRequest } from "./notification-identity.js";
import {
  BuzzKitBackendError,
  buzzKitIdentity,
  buzzKitRecipientExternalId,
  deleteBuzzKitSubscriber,
  readBuzzKitReadiness,
  sendBuzzKitLiveActivity,
  sendBuzzKitSignInWake,
  sendBuzzKitRichNotification,
  sendBuzzKitSealedNotification,
  sendBuzzKitTestNotification,
  type BuzzKitAgentAvatar,
  type BuzzKitAssetMimeType,
  type BuzzKitRichNotificationEvent,
  type BuzzKitSealedNotificationEvent,
} from "./buzzkit.js";

export interface NotificationGrant {
  grantId: string;
  instanceId?: string;
  hostKeyId: string;
  hostPublicKey: string;
  authorizationEpoch: number;
  profile: string;
  eventTypes: string[];
  createdAt: number;
  expiresAt: number;
  revision: number;
  provider: "buzzkit";
  subscriberScope: "account" | "notification-instance";
  state: "issued" | "active" | "revoked";
}

export interface NotificationActivity {
  activityId: string;
  grantId: string;
  sessionReference: string;
  revision: number;
  leaseExpires: number;
  status: "active" | "revoked" | "ended";
}

export interface NotificationAsset {
  assetId: string;
  mimeType: BuzzKitAssetMimeType;
  data: Uint8Array;
  expiresAt: number;
}

export interface NotificationEgressSnapshot {
  ownerKind: "account" | "notification-instance";
  credentialId: string;
  authorizationEpoch: number;
  now: number;
  grant?: { grantId: string; revision: number; expiresAt: number };
  activity?: { activityId: string; sessionReference: string; leaseExpires: number };
}

export interface ManagedNotificationStateBinding {
  putNotificationAsset(input: NotificationAsset): Promise<NotificationAsset>;
  notificationAsset(input: { assetId: string; now: number }): Promise<NotificationAsset | null>;
  registerNotificationActivity(input: NotificationActivity & { timestamp: number }): Promise<NotificationActivity>;
  notificationActivity(input: { grantId: string; activityId: string; now: number }): Promise<NotificationActivity>;
  revokeNotificationActivity(input: { grantId: string; activityId: string; revision: number; timestamp: number }): Promise<NotificationActivity>;
  revokeNotificationGrantActivities(input: { grantId: string; timestamp: number }): Promise<void>;
  beginNotificationActivityUpdate(input: {
    grantId: string; activityId: string; updateId: string; timestamp: number;
  }): Promise<{ status: "send" | "duplicate" }>;
  completeNotificationActivityUpdate(input: {
    grantId: string; activityId: string; updateId: string; timestamp: number; terminal: boolean;
  }): Promise<void>;
  authorizeNotificationEgress(input: NotificationEgressSnapshot): Promise<void>;
  revokeNotificationCredential(input: {
    credentialId: string; authorizationEpoch: number;
  }): Promise<void>;
  revokeNotificationGrantAuthority(input: {
    grantId: string; credentialId: string; authorizationEpoch: number; revision: number;
  }): Promise<void>;
  retireDeletedAccountNotificationGrantAuthority(input: {
    grantId: string; credentialId: string; authorizationEpoch: number; revision: number;
  }): Promise<void>;
  retireNotificationScope(): Promise<void>;
}

interface GrantRow {
  grant_id: string;
  owner_kind: "account" | "notification-instance";
  owner_coordinate: string;
  credential_id: string;
  authorization_epoch: number;
  request_digest: string;
  public_json: string;
  revision: number;
  state: NotificationGrant["state"];
  expires_at: number;
}

interface NotificationPrincipal {
  ownerKind: "account" | "notification-instance";
  ownerCoordinate: string;
  credentialId: string;
  authorizationEpoch: number;
}

const ROOT = "/v1/notifications/host-grants";
const IDENTITY_PATH = `${ROOT}/buzzkit/identity`;
const STATUS_PATH = `${ROOT}/buzzkit/status`;
const ACCOUNT_BINDING_PATH = "/v1/notifications/installations/current/account-binding";
const ASSET_ROOT = "/v1/notifications/buzzkit/assets";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const PROFILE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const BASE64URL_32 = /^[A-Za-z0-9_-]{43}$/;
const EVENTS = new Set([
  "session.completed",
  "session.failed",
  "scheduled.completed",
  "scheduled.failed",
  "approval.required",
  "clarification.required",
  "subagent.completed",
  "subagent.failed",
]);
const CONTENT_KINDS = new Set(["reply", "failure", "scheduled", "approval", "clarification", "subagent"]);
const MAX_EVENT_BODY_BYTES = 800_000;
const MAX_AVATAR_BYTES = 524_288;
const MAX_NOTIFICATION_TEXT = 1_600;
/** Matches the plugin's sealed envelope limit so one alert still fits one push. */
const MAX_SEALED_BYTES = 2_300;
const ASSET_CAPABILITY_SECONDS = 1_200;

class NotificationError extends Error {
  constructor(readonly status: number, readonly code: string) {
    super(code);
  }
}

const fail = (status: number, code: string): never => { throw new NotificationError(status, code); };

function exact(value: Record<string, unknown>, keys: string[]) {
  if (Object.keys(value).length !== keys.length || keys.some((key) => !(key in value))) {
    fail(400, "notification_request_invalid");
  }
}

function integer(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) > 0;
}

function decode(value: string, code = "notification_key_invalid"): Uint8Array {
  try {
    if (!/^[A-Za-z0-9_-]+$/.test(value)) return fail(400, code);
    const result = decodeBase64URL(value, false);
    if (notificationBase64(result) !== value) return fail(400, code);
    return result;
  } catch { return fail(400, code); }
}

function decodeUTF8(value: string): string {
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(decode(value, "notification_asset_invalid"));
  } catch { return fail(404, "notification_asset_unknown"); }
}

export async function notificationSessionReference(profile: string, session: string): Promise<string> {
  return notificationBase64(await digest(new TextEncoder().encode(`${profile}\0${session}`)));
}

export async function canonicalNotificationHostRequest(
  method: string,
  path: string,
  grantId: string,
  timestamp: number,
  nonce: string,
  body: Uint8Array,
): Promise<string> {
  const hash = Array.from(await digest(body), (byte) => byte.toString(16).padStart(2, "0")).join("");
  return ["loopdy-notification-host-v1", method, path, grantId, String(timestamp), nonce, hash].join("\n");
}

function publicGrant(row: GrantRow): NotificationGrant {
  return { ...JSON.parse(row.public_json) as NotificationGrant, state: row.state, revision: row.revision };
}

function stateBinding(env: LinkEnv, ownerCoordinate: string): ManagedNotificationStateBinding {
  return env.USER_LINKS.getByName(ownerCoordinate) as unknown as ManagedNotificationStateBinding;
}

async function load(env: LinkEnv, id: string): Promise<GrantRow> {
  const row = await env.ACCOUNTS.prepare(`
    SELECT grant_id,'notification-instance' AS owner_kind,
      notification_coordinate AS owner_coordinate,installation_id AS credential_id,
      authorization_epoch,request_digest,public_json,revision,state,expires_at
    FROM notification_instance_grants WHERE grant_id=?
    UNION ALL
    SELECT grant_id,'account' AS owner_kind,account_coordinate AS owner_coordinate,
      device_id AS credential_id,authorization_epoch,request_digest,public_json,revision,state,expires_at
    FROM notification_grants WHERE grant_id=? LIMIT 1`)
    .bind(id, id).first<GrantRow>();
  if (!row) return fail(404, "notification_grant_unknown");
  return row;
}

async function mobile(
  env: LinkEnv,
  request: Request,
  raw: Uint8Array,
  now: number,
  allowRetiredAccountScope = false,
): Promise<NotificationPrincipal> {
  if (request.headers.has("x-loopdy-notification-installation")) {
    return verifyNotificationOnlyRequest(request, raw, env, now);
  }
  const auth = await verifyDeviceRequest(request, raw, env.ACCOUNTS, now, {
    maximumBodyCharacters: MAX_EVENT_BODY_BYTES,
  });
  await requireActiveMobile(env, auth);
  if (!allowRetiredAccountScope) {
    await requireNotificationScopeActive(env, "account", auth.accountCoordinate);
  }
  return {
    ownerKind: "account",
    ownerCoordinate: auth.accountCoordinate,
    credentialId: auth.deviceId,
    authorizationEpoch: auth.authorizationEpoch,
  };
}

async function requireNotificationScopeActive(
  env: LinkEnv,
  ownerKind: NotificationPrincipal["ownerKind"],
  ownerCoordinate: string,
): Promise<void> {
  if (ownerKind !== "account") return;
  const retirement = await env.ACCOUNTS.prepare(
    "SELECT account_coordinate FROM notification_account_scope_retirements WHERE account_coordinate=?",
  ).bind(ownerCoordinate).first();
  if (retirement) fail(410, "notification_account_scope_retired");
}

async function requireActiveMobile(env: LinkEnv, auth: VerifiedDeviceRequest): Promise<void> {
  const [revocation, catalog] = await Promise.all([
    env.ACCOUNTS.prepare(`SELECT device_id FROM notification_device_revocations
      WHERE device_id=? AND account_coordinate=? AND authorization_epoch=?`)
      .bind(auth.deviceId, auth.accountCoordinate, auth.authorizationEpoch).first(),
    env.USER_LINKS.getByName(auth.accountCoordinate).listDevices(),
  ]);
  const device = catalog.devices
    .find((candidate: PublicLinkDevice) => candidate.deviceId === auth.deviceId);
  if (revocation || !device || device.role !== "mobile" || device.lifecycle !== "active") {
    fail(403, "notification_mobile_required");
  }
}

async function accountBindingPrincipal(
  request: Request,
  raw: Uint8Array,
  env: LinkEnv,
  now: number,
): Promise<VerifiedDeviceRequest> {
  const translated = new Headers();
  for (const [target, source] of [
    [DEVICE_AUTH_HEADERS.deviceId, "x-loopdy-account-device-id"],
    [DEVICE_AUTH_HEADERS.timestamp, "x-loopdy-account-timestamp"],
    [DEVICE_AUTH_HEADERS.nonce, "x-loopdy-account-nonce"],
    [DEVICE_AUTH_HEADERS.authorizationEpoch, "x-loopdy-account-authorization-epoch"],
    [DEVICE_AUTH_HEADERS.signature, "x-loopdy-account-signature"],
  ] as const) {
    const value = request.headers.get(source);
    if (value) translated.set(target, value);
  }
  const accountRequest = new Request(request.url, { method: request.method, headers: translated });
  const auth = await verifyDeviceRequest(accountRequest, raw, env.ACCOUNTS, now, {
    maximumBodyCharacters: MAX_EVENT_BODY_BYTES,
  });
  await requireActiveMobile(env, auth);
  return auth;
}

async function bindWakeInstallation(
  request: Request,
  raw: Uint8Array,
  body: Record<string, unknown>,
  env: LinkEnv,
  now: number,
): Promise<Response> {
  if (request.method !== "POST") return fail(405, "notification_method_invalid");
  exact(body, ["version", "grantId"]);
  if (body.version !== 1 || typeof body.grantId !== "string" || !UUID.test(body.grantId)) {
    return fail(400, "notification_binding_invalid");
  }
  // Both signatures cover the exact same method, path, and body. Possession of
  // one credential cannot be replayed to bind an arbitrary account or install.
  const installation = await verifyNotificationOnlyRequest(request, raw, env, now);
  const account = await accountBindingPrincipal(request, raw, env, now);
  const row = await env.ACCOUNTS.prepare(`SELECT grant_id,'notification-instance' AS owner_kind,
      notification_coordinate AS owner_coordinate,installation_id AS credential_id,
      authorization_epoch,request_digest,public_json,revision,state,expires_at
    FROM notification_instance_grants
    WHERE grant_id=? AND notification_coordinate=? AND installation_id=?`)
    .bind(body.grantId, installation.ownerCoordinate, installation.credentialId)
    .first<GrantRow>();
  if (!row) return fail(403, "notification_grant_inactive");
  const grant = await active(env, row, now);

  const result = await env.ACCOUNTS.prepare(`INSERT INTO notification_account_installations(
      installation_id,notification_coordinate,account_coordinate,account_device_id,
      account_authorization_epoch,installation_authorization_epoch,bound_at)
    SELECT ?,?,?,?,?,?,?
    WHERE EXISTS(SELECT 1 FROM notification_installations
      WHERE installation_id=? AND notification_coordinate=? AND state='active' AND authorization_epoch=?)
      AND EXISTS(SELECT 1 FROM notification_instance_grants
        WHERE grant_id=? AND notification_coordinate=? AND installation_id=?
          AND authorization_epoch=? AND state='active' AND expires_at>?)
      AND EXISTS(SELECT 1 FROM device_directory d JOIN accounts a USING(account_coordinate)
        WHERE d.device_id=? AND d.account_coordinate=? AND d.status='active' AND a.status='active'
          AND d.authorization_epoch=? AND a.authorization_epoch=?)
    ON CONFLICT(installation_id) DO UPDATE SET
      notification_coordinate=excluded.notification_coordinate,
      account_coordinate=excluded.account_coordinate,
      account_device_id=excluded.account_device_id,
      account_authorization_epoch=excluded.account_authorization_epoch,
      installation_authorization_epoch=excluded.installation_authorization_epoch,
      bound_at=excluded.bound_at`)
    .bind(
      installation.credentialId, installation.ownerCoordinate, account.accountCoordinate,
      account.deviceId, account.authorizationEpoch, installation.authorizationEpoch, now,
      installation.credentialId, installation.ownerCoordinate, installation.authorizationEpoch,
      grant.grantId, installation.ownerCoordinate, installation.credentialId,
      installation.authorizationEpoch, now, account.deviceId, account.accountCoordinate,
      account.authorizationEpoch, account.authorizationEpoch,
    ).run();
  if (result.meta.changes !== 1) return fail(409, "notification_binding_conflict");
  const readback = await env.ACCOUNTS.prepare(`SELECT installation_id,notification_coordinate,
      account_coordinate,account_device_id,account_authorization_epoch,installation_authorization_epoch
    FROM notification_account_installations WHERE installation_id=?`)
    .bind(installation.credentialId).first<{
      installation_id: string; notification_coordinate: string; account_coordinate: string;
      account_device_id: string; account_authorization_epoch: number;
      installation_authorization_epoch: number;
    }>();
  if (!readback || readback.notification_coordinate !== installation.ownerCoordinate
      || readback.account_coordinate !== account.accountCoordinate
      || readback.account_device_id !== account.deviceId
      || readback.account_authorization_epoch !== account.authorizationEpoch
      || readback.installation_authorization_epoch !== installation.authorizationEpoch) {
    return fail(503, "notification_binding_unconfirmed");
  }
  return response({
    version: 2,
    binding: {
      installationId: installation.credentialId,
      grantId: grant.grantId,
      state: "active",
    },
  });
}

function owner(row: GrantRow, auth: NotificationPrincipal) {
  if (row.owner_kind !== auth.ownerKind || row.owner_coordinate !== auth.ownerCoordinate
      || row.credential_id !== auth.credentialId || row.authorization_epoch !== auth.authorizationEpoch) {
    fail(403, "notification_owner_mismatch");
  }
}

async function active(env: LinkEnv, row: GrantRow, now: number, allowIssued = false): Promise<NotificationGrant> {
  const grant = publicGrant(row);
  if (grant.provider !== "buzzkit" || grant.subscriberScope !== row.owner_kind
      || grant.state === "revoked" || (!allowIssued && grant.state !== "active") || grant.expiresAt <= now) {
    return fail(403, "notification_grant_inactive");
  }
  if (row.owner_kind === "account") {
    const directory = await env.ACCOUNTS.prepare(`SELECT d.status,d.authorization_epoch,a.status AS account_status,a.authorization_epoch AS account_epoch
      FROM device_directory d JOIN accounts a USING(account_coordinate) WHERE d.device_id=? AND d.account_coordinate=?`)
      .bind(row.credential_id, row.owner_coordinate)
      .first<{status:string; authorization_epoch:number; account_status:string; account_epoch:number}>();
    if (!directory || directory.status !== "active" || directory.account_status !== "active"
        || directory.authorization_epoch !== row.authorization_epoch || directory.account_epoch !== row.authorization_epoch) {
      fail(403, "notification_grant_inactive");
    }
  } else {
    const installation = await env.ACCOUNTS.prepare(`SELECT state,authorization_epoch FROM notification_installations
      WHERE installation_id=? AND notification_coordinate=?`)
      .bind(row.credential_id, row.owner_coordinate)
      .first<{state:string; authorization_epoch:number}>();
    if (!installation || installation.state !== "active" || installation.authorization_epoch !== row.authorization_epoch) {
      fail(403, "notification_grant_inactive");
    }
  }
  await requireNotificationScopeActive(env, row.owner_kind, row.owner_coordinate);
  return grant;
}

interface NotificationEgressAuthority {
  expires_at: number;
  revision: number;
  retired_account: string | null;
}

async function readNotificationEgressAuthority(
  env: LinkEnv,
  row: GrantRow,
): Promise<NotificationEgressAuthority | null> {
  if (row.owner_kind === "account") {
    return env.ACCOUNTS.prepare(`SELECT grant_row.expires_at,grant_row.revision,
        retirement.account_coordinate AS retired_account
      FROM notification_grants grant_row
      JOIN device_directory device
        ON device.device_id=grant_row.device_id
        AND device.account_coordinate=grant_row.account_coordinate
      JOIN accounts account ON account.account_coordinate=grant_row.account_coordinate
      LEFT JOIN notification_account_scope_retirements retirement
        ON retirement.account_coordinate=grant_row.account_coordinate
      LEFT JOIN notification_device_revocations revocation
        ON revocation.device_id=grant_row.device_id
        AND revocation.account_coordinate=grant_row.account_coordinate
      WHERE grant_row.grant_id=? AND grant_row.account_coordinate=? AND grant_row.device_id=?
        AND grant_row.authorization_epoch=? AND grant_row.state='active'
        AND device.status='active' AND device.authorization_epoch=grant_row.authorization_epoch
        AND account.status='active' AND account.authorization_epoch=grant_row.authorization_epoch
        AND revocation.device_id IS NULL`)
      .bind(row.grant_id, row.owner_coordinate, row.credential_id, row.authorization_epoch)
      .first<NotificationEgressAuthority>();
  }
  return env.ACCOUNTS.prepare(`SELECT grant_row.expires_at,grant_row.revision,
      NULL AS retired_account
    FROM notification_instance_grants grant_row
    JOIN notification_installations installation
      ON installation.installation_id=grant_row.installation_id
      AND installation.notification_coordinate=grant_row.notification_coordinate
    WHERE grant_row.grant_id=? AND grant_row.notification_coordinate=?
      AND grant_row.installation_id=? AND grant_row.authorization_epoch=?
      AND grant_row.state='active' AND installation.state='active'
      AND installation.authorization_epoch=grant_row.authorization_epoch`)
    .bind(row.grant_id, row.owner_coordinate, row.credential_id, row.authorization_epoch)
    .first<NotificationEgressAuthority>();
}

function assertNotificationEgressAuthority(
  authority: NotificationEgressAuthority | null,
  code = "notification_grant_inactive",
): asserts authority is NotificationEgressAuthority {
  const now = Math.floor(Date.now() / 1_000);
  if (authority?.retired_account) fail(410, "notification_account_scope_retired");
  if (!authority || authority.expires_at <= now) fail(410, code);
}

async function finalOwnerDecision(
  env: LinkEnv,
  principal: NotificationPrincipal,
  grant?: { grantId: string; revision: number; expiresAt: number },
  activity?: NotificationActivity,
): Promise<void> {
  try {
    await stateBinding(env, principal.ownerCoordinate).authorizeNotificationEgress({
      ownerKind: principal.ownerKind,
      credentialId: principal.credentialId,
      authorizationEpoch: principal.authorizationEpoch,
      now: Math.floor(Date.now() / 1_000),
      ...(grant ? { grant } : {}),
      ...(activity ? { activity: {
        activityId: activity.activityId,
        sessionReference: activity.sessionReference,
        leaseExpires: activity.leaseExpires,
      } } : {}),
    });
  } catch (error) {
    const code = error && typeof error === "object" && "code" in error
      ? String((error as { code: unknown }).code) : "";
    if (code === "notification_account_scope_retired") fail(410, code);
    if (code === "notification_activity_inactive") fail(410, code);
    if (["device_not_found", "notification_credentials_revoked", "notification_grant_inactive"].includes(code)) {
      fail(410, grant ? "notification_grant_inactive" : "notification_credentials_revoked");
    }
    throw error;
  }
}

async function requireNotificationEgressActive(env: LinkEnv, row: GrantRow): Promise<void> {
  const authority = await readNotificationEgressAuthority(env, row);
  assertNotificationEgressAuthority(authority);
  await finalOwnerDecision(env, {
    ownerKind: row.owner_kind,
    ownerCoordinate: row.owner_coordinate,
    credentialId: row.credential_id,
    authorizationEpoch: row.authorization_epoch,
  }, { grantId: row.grant_id, revision: authority.revision, expiresAt: authority.expires_at });
}

async function requireNotificationPrincipalEgressActive(
  env: LinkEnv,
  principal: NotificationPrincipal,
): Promise<void> {
  let active = false;
  if (principal.ownerKind === "notification-instance") {
    const installation = await env.ACCOUNTS.prepare(`SELECT 1 AS active
      FROM notification_installations
      WHERE installation_id=? AND notification_coordinate=? AND state='active'
        AND authorization_epoch=?`)
      .bind(principal.credentialId, principal.ownerCoordinate, principal.authorizationEpoch)
      .first<{ active: number }>();
    active = installation?.active === 1;
  } else {
    const directory = await env.ACCOUNTS.prepare(`SELECT 1 AS active
      FROM device_directory device
      JOIN accounts account USING(account_coordinate)
      LEFT JOIN notification_account_scope_retirements retirement
        ON retirement.account_coordinate=device.account_coordinate
      LEFT JOIN notification_device_revocations revocation
        ON revocation.device_id=device.device_id
        AND revocation.account_coordinate=device.account_coordinate
      WHERE device.device_id=? AND device.account_coordinate=?
        AND device.status='active' AND device.authorization_epoch=?
        AND account.status='active' AND account.authorization_epoch=?
        AND retirement.account_coordinate IS NULL AND revocation.device_id IS NULL`)
      .bind(principal.credentialId, principal.ownerCoordinate,
        principal.authorizationEpoch, principal.authorizationEpoch)
      .first<{ active: number }>();
    active = directory?.active === 1;
  }
  if (!active) fail(410, "notification_credentials_revoked");
  // This RPC is the one final serialized authority decision. D1 remains the
  // durable directory, while revocation is mirrored into this owning object
  // before directory cleanup can commit.
  await finalOwnerDecision(env, principal);
}

async function requireNotificationActivityEgressActive(
  env: LinkEnv,
  row: GrantRow,
  expected: NotificationActivity,
): Promise<void> {
  const authority = await readNotificationEgressAuthority(env, row);
  assertNotificationEgressAuthority(authority);
  await finalOwnerDecision(env, {
    ownerKind: row.owner_kind,
    ownerCoordinate: row.owner_coordinate,
    credentialId: row.credential_id,
    authorizationEpoch: row.authorization_epoch,
  }, {
    grantId: row.grant_id,
    revision: authority.revision,
    expiresAt: authority.expires_at,
  }, expected);
}

async function host(env: LinkEnv, request: Request, raw: Uint8Array, row: GrantRow, now: number) {
  const grant = publicGrant(row);
  const timestampText = request.headers.get("x-loopdy-timestamp") ?? "";
  const timestamp = Number(timestampText);
  const nonce = request.headers.get("x-loopdy-nonce") ?? "";
  const signature = request.headers.get("x-loopdy-signature") ?? "";
  if (request.headers.get("x-loopdy-host-key-id") !== grant.hostKeyId
      || !/^[1-9][0-9]{0,12}$/.test(timestampText) || !Number.isSafeInteger(timestamp)
      || Math.abs(timestamp - now) > 120 || !BASE64URL_32.test(nonce) || !/^[A-Za-z0-9_-]{86}$/.test(signature)) {
    fail(401, "notification_host_proof_invalid");
  }
  const key = await crypto.subtle.importKey(
    "raw", decode(grant.hostPublicKey), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"],
  );
  const transcript = await canonicalNotificationHostRequest(
    request.method, new URL(request.url).pathname, grant.grantId, timestamp, nonce, raw,
  );
  if (!await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" }, key, decode(signature), new TextEncoder().encode(transcript),
  )) fail(401, "notification_host_proof_invalid");
  const nonceTable = row.owner_kind === "account"
    ? "notification_host_nonces" : "notification_instance_host_nonces";
  await env.ACCOUNTS.prepare(`DELETE FROM ${nonceTable} WHERE expires_at<=?`).bind(now).run();
  const inserted = await env.ACCOUNTS.prepare(`INSERT INTO ${nonceTable}(grant_id,nonce,expires_at)
    SELECT ?,?,? WHERE (SELECT COUNT(*) FROM ${nonceTable} WHERE grant_id=?)<256 ON CONFLICT DO NOTHING`)
    .bind(grant.grantId, nonce, Math.max(now + 120, timestamp + 121), grant.grantId).run();
  if (inserted.meta.changes !== 1) fail(409, "notification_nonce_replayed_or_limited");
  await requireNotificationScopeActive(env, row.owner_kind, row.owner_coordinate);
}

function rawBody(request: Request): Promise<Uint8Array> {
  return readByteStream(request.body, MAX_EVENT_BODY_BYTES, () => fail(413, "notification_body_too_large"));
}

async function revoke(
  env: LinkEnv,
  row: GrantRow,
  acceptedAccountDeletion = false,
): Promise<NotificationGrant> {
  const table = row.owner_kind === "account" ? "notification_grants" : "notification_instance_grants";
  // Retire the monotonic owner record first. A stale D1 snapshot can no longer
  // seed active authority after this serialized Durable Object mutation.
  const owner = stateBinding(env, row.owner_coordinate);
  const retirement = {
    grantId: row.grant_id,
    credentialId: row.credential_id,
    authorizationEpoch: row.authorization_epoch,
    revision: row.revision + (row.state === "revoked" ? 0 : 1),
  };
  if (acceptedAccountDeletion && row.owner_kind === "account") {
    await owner.retireDeletedAccountNotificationGrantAuthority(retirement);
  } else {
    await owner.revokeNotificationGrantAuthority(retirement);
  }
  await env.ACCOUNTS.prepare(
    `UPDATE ${table} SET state='revoked',revision=revision+1 WHERE grant_id=? AND state!='revoked'`,
  ).bind(row.grant_id).run();
  return publicGrant(await load(env, row.grant_id));
}

export async function beginNotificationDeviceRevocation(
  env: LinkEnv,
  accountCoordinate: string,
  deviceId: string,
  expectedRevision: number,
  authorizationEpoch: number,
  now: number,
): Promise<void> {
  await env.ACCOUNTS.prepare(`INSERT INTO notification_device_revocations(
      device_id,account_coordinate,expected_revision,authorization_epoch,started_at)
    SELECT device_id,account_coordinate,?,?,? FROM device_directory
    WHERE device_id=? AND account_coordinate=? AND status='active' AND authorization_epoch=?
    ON CONFLICT(device_id) DO NOTHING`)
    .bind(expectedRevision, authorizationEpoch, now,
      deviceId, accountCoordinate, authorizationEpoch).run();
  const marker = await env.ACCOUNTS.prepare(`SELECT account_coordinate,expected_revision,authorization_epoch
    FROM notification_device_revocations WHERE device_id=?`)
    .bind(deviceId).first<{
      account_coordinate: string; expected_revision: number; authorization_epoch: number;
    }>();
  if (!marker || marker.account_coordinate !== accountCoordinate
      || marker.expected_revision !== expectedRevision
      || marker.authorization_epoch !== authorizationEpoch) {
    throw new LoopdyLinkError(
      "device_conflict", "Notification device revocation conflicts with durable state",
    );
  }
}

export async function completeNotificationDeviceRevocation(
  env: LinkEnv,
  accountCoordinate: string,
  deviceId: string,
  expectedRevision: number,
  authorizationEpoch: number,
): Promise<void> {
  // Retain the exact marker as the only prior-epoch authority. Ordinary device
  // authentication rejects its presence; only an idempotent matching DELETE can
  // use it to recover a lost response after cleanup completed.
  const completed = await env.ACCOUNTS.prepare(`SELECT 1 AS confirmed
    FROM notification_device_revocations revocation
    JOIN device_directory device
      ON device.device_id=revocation.device_id
      AND device.account_coordinate=revocation.account_coordinate
    WHERE revocation.device_id=? AND revocation.account_coordinate=?
      AND revocation.expected_revision=? AND revocation.authorization_epoch=?
      AND device.status='revoked' AND device.authorization_epoch=?`)
    .bind(deviceId, accountCoordinate, expectedRevision, authorizationEpoch,
      authorizationEpoch + 1).first();
  if (!completed) {
    throw new LoopdyLinkError(
      "device_conflict", "Notification device revocation was not confirmed",
    );
  }
}

async function revokeNotificationGrantsWithMode(
  env: LinkEnv,
  account: string,
  deviceId: string | undefined,
  acceptedAccountDeletion: boolean,
): Promise<void> {
  const rows = await env.ACCOUNTS.prepare(
    `SELECT grant_id,'account' AS owner_kind,account_coordinate AS owner_coordinate,
      device_id AS credential_id,authorization_epoch,request_digest,public_json,revision,state,expires_at
     FROM notification_grants WHERE account_coordinate=?${deviceId ? " AND device_id=?" : ""}`,
  ).bind(...(deviceId ? [account, deviceId] : [account])).all<GrantRow>();
  for (const row of rows.results) await revoke(env, row, acceptedAccountDeletion);
}

export async function revokeNotificationGrants(
  env: LinkEnv,
  account: string,
  deviceId?: string,
): Promise<void> {
  await revokeNotificationGrantsWithMode(env, account, deviceId, false);
}

export async function revokeNotificationInstallationGrants(
  env: LinkEnv,
  coordinate: string,
  installationId: string,
): Promise<void> {
  const rows = await env.ACCOUNTS.prepare(`SELECT grant_id,'notification-instance' AS owner_kind,
      notification_coordinate AS owner_coordinate,installation_id AS credential_id,
      authorization_epoch,request_digest,public_json,revision,state,expires_at
    FROM notification_instance_grants WHERE notification_coordinate=? AND installation_id=?`)
    .bind(coordinate, installationId).all<GrantRow>();
  for (const row of rows.results) await revoke(env, row);
  await deleteBuzzKitSubscriber(env, coordinate, "notification-instance");
}

async function retireAccountNotificationAuthorityWithMode(
  env: LinkEnv,
  account: string,
  now: number,
  acceptedAccountDeletion: boolean,
): Promise<void> {
  // Make the owner irrevocably retired before the D1 directory marker commits.
  // Final sends serialize behind this call even when they already read D1.
  await stateBinding(env, account).retireNotificationScope();
  await env.ACCOUNTS.prepare(`INSERT INTO notification_account_scope_retirements(
    account_coordinate,retired_at) VALUES (?,?) ON CONFLICT(account_coordinate) DO NOTHING`)
    .bind(account, now).run();
  await revokeNotificationGrantsWithMode(env, account, undefined, acceptedAccountDeletion);
  await deleteBuzzKitSubscriber(env, account, "account");
}

export async function retireAccountNotificationAuthority(
  env: LinkEnv,
  account: string,
  now: number,
): Promise<void> {
  await retireAccountNotificationAuthorityWithMode(env, account, now, false);
}

export async function retireAcceptedAccountNotificationAuthority(
  env: LinkEnv,
  account: string,
  now: number,
): Promise<void> {
  // beginAccountDeletion must already have atomically tombstoned this owner.
  // Only this deletion composition selects the tombstone-gated cleanup RPC.
  await retireAccountNotificationAuthorityWithMode(env, account, now, true);
}

async function serveAsset(request: Request, env: LinkEnv, now: number): Promise<Response | null> {
  const url = new URL(request.url);
  const path = url.pathname;
  if (!path.startsWith(`${ASSET_ROOT}/`)) return null;
  if (request.method !== "GET") return response({ version: 1, error: { code: "notification_method_invalid" } }, 405);
  const parts = path.slice(ASSET_ROOT.length + 1).split("/");
  const assetMatch = /^([A-Za-z0-9_-]{43})\.(png|jpg|webp|bin)$/.exec(parts[1] ?? "");
  if (parts.length !== 2 || !assetMatch) {
    return response({ version: 1, error: { code: "notification_asset_unknown" } }, 404);
  }
  const expiresText = url.searchParams.get("expires") ?? "";
  const capability = url.searchParams.get("capability") ?? "";
  const expires = Number(expiresText);
  if (url.hash || url.searchParams.size !== 2 || !/^[1-9][0-9]{0,12}$/.test(expiresText)
      || !Number.isSafeInteger(expires) || expires <= now
      || expires > now + ASSET_CAPABILITY_SECONDS || !BASE64URL_32.test(capability)) {
    return response({ version: 1, error: { code: "notification_asset_unknown" } }, 404);
  }
  const accountPath = parts[0]!;
  if (!await verifyAssetCapability(
    env, accountPath, assetMatch[1]!, assetMatch[2]!, expires, capability,
  )) {
    return response({ version: 1, error: { code: "notification_asset_unknown" } }, 404);
  }
  let accountCoordinate: string;
  try { accountCoordinate = decodeUTF8(accountPath); }
  catch { return response({ version: 1, error: { code: "notification_asset_unknown" } }, 404); }
  if (!/^[A-Za-z0-9_-]{22,256}$/.test(accountCoordinate)) {
    return response({ version: 1, error: { code: "notification_asset_unknown" } }, 404);
  }
  const asset = await stateBinding(env, accountCoordinate).notificationAsset({
    assetId: assetMatch[1]!,
    now,
  });
  if (!asset || asset.expiresAt <= now || asset.expiresAt < expires) {
    return response({ version: 1, error: { code: "notification_asset_unknown" } }, 404);
  }
  if (assetMatch[2] !== assetExtension(asset.mimeType)) {
    return response({ version: 1, error: { code: "notification_asset_unknown" } }, 404);
  }
  return new Response(asset.data, {
    status: 200,
    headers: {
      "content-type": asset.mimeType,
      "content-length": String(asset.data.byteLength),
      "cache-control": "private, no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

function richEvent(
  body: Record<string, unknown>,
  grant: NotificationGrant,
  now: number,
): BuzzKitRichNotificationEvent {
  exact(body, [
    "version", "eventId", "eventType", "sessionReference", "turnId", "occurredAt",
    "agent", "content", "sound",
  ]);
  const eventType = body.eventType;
  if (body.version !== 2 || typeof body.eventId !== "string"
      || !new RegExp(`^${grant.grantId}:[0-9a-f]{64}$`).test(body.eventId)
      || typeof eventType !== "string" || !EVENTS.has(eventType) || !grant.eventTypes.includes(eventType)
      || typeof body.sessionReference !== "string" || !BASE64URL_32.test(body.sessionReference)
      || typeof body.turnId !== "string" || !IDENTIFIER.test(body.turnId)
      || !integer(body.occurredAt) || body.occurredAt > now + 120 || body.occurredAt < now - 1_800
      || typeof body.sound !== "boolean") {
    return fail(400, "notification_event_invalid");
  }
  const agent = object(body.agent, "notification_event_invalid");
  exact(agent, ["id", "name", "avatar"]);
  const avatar = object(agent.avatar, "notification_event_invalid");
  exact(avatar, ["mimeType", "sha256", "data"]);
  const content = object(body.content, "notification_event_invalid");
  exact(content, ["kind", "text"]);
  if (typeof agent.id !== "string" || !PROFILE.test(agent.id)
      || !usefulText(agent.name, 80) || typeof avatar.mimeType !== "string"
      || !["image/png", "image/jpeg", "image/webp"].includes(avatar.mimeType)
      || typeof avatar.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(avatar.sha256)
      || typeof avatar.data !== "string" || avatar.data.length > 700_000
      || typeof content.kind !== "string" || !CONTENT_KINDS.has(content.kind)
      || !usefulText(content.text, MAX_NOTIFICATION_TEXT)) {
    return fail(422, "notification_rich_content_required");
  }
  const expectedKind = eventType === "approval.required" ? "approval"
    : eventType === "clarification.required" ? "clarification"
      : eventType.startsWith("scheduled.") ? "scheduled"
        : eventType.startsWith("subagent.") ? "subagent"
          : eventType === "session.failed" ? "failure" : "reply";
  if (content.kind !== expectedKind) return fail(422, "notification_rich_content_required");
  return {
    eventId: body.eventId,
    eventType: eventType as BuzzKitRichNotificationEvent["eventType"],
    grantId: grant.grantId,
    profile: grant.profile,
    sessionReference: body.sessionReference,
    turnId: body.turnId,
    occurredAt: body.occurredAt,
    agent: {
      id: agent.id,
      name: agent.name,
      avatar: avatar as unknown as BuzzKitAgentAvatar,
    },
    content: {
      kind: content.kind as BuzzKitRichNotificationEvent["content"]["kind"],
      text: content.text,
    },
    sound: body.sound,
  };
}

function assetExtension(mimeType: BuzzKitAssetMimeType): string {
  switch (mimeType) {
    case "image/png": return "png";
    case "image/jpeg": return "jpg";
    case "image/webp": return "webp";
    case "application/octet-stream": return "bin";
  }
}

/** Version 3: title, text and avatar sealed by the host for the recipient phone. */
function sealedEvent(
  body: Record<string, unknown>,
  grant: NotificationGrant,
  now: number,
): BuzzKitSealedNotificationEvent {
  exact(body, [
    "version", "eventId", "eventType", "sessionReference", "turnId", "occurredAt",
    "sealed", "avatar", "sound",
  ]);
  const eventType = body.eventType;
  if (body.version !== 3 || typeof body.eventId !== "string"
      || !new RegExp(`^${grant.grantId}:[0-9a-f]{64}$`).test(body.eventId)
      || typeof eventType !== "string" || !EVENTS.has(eventType) || !grant.eventTypes.includes(eventType)
      || typeof body.sessionReference !== "string" || !BASE64URL_32.test(body.sessionReference)
      || typeof body.turnId !== "string" || !IDENTIFIER.test(body.turnId)
      || !integer(body.occurredAt) || body.occurredAt > now + 120 || body.occurredAt < now - 1_800
      || typeof body.sound !== "boolean") {
    return fail(400, "notification_event_invalid");
  }
  const sealed = object(body.sealed, "notification_event_invalid");
  exact(sealed, [
    "v", "grantId", "eventId", "recipientKeyId", "senderKeyId", "issued",
    "ephemeralPublicKey", "salt", "nonce", "ciphertext", "tag", "signature",
  ]);
  const b64 = (value: unknown, length: number) => typeof value === "string"
    && value.length === length && /^[A-Za-z0-9_-]+$/.test(value);
  // Only the shape and routing fields are checked here; the phone checks the host's signature.
  if (sealed.v !== 2 || sealed.grantId !== grant.grantId || sealed.eventId !== body.eventId
      || !BASE64URL_32.test(String(sealed.recipientKeyId)) || sealed.senderKeyId !== grant.hostKeyId
      || sealed.issued !== body.occurredAt || !b64(sealed.ephemeralPublicKey, 87) || !b64(sealed.salt, 43)
      || !b64(sealed.nonce, 16) || !b64(sealed.tag, 22) || !b64(sealed.signature, 86)
      || typeof sealed.ciphertext !== "string" || !/^[A-Za-z0-9_-]{2,}$/.test(sealed.ciphertext)
      || new TextEncoder().encode(JSON.stringify(sealed)).length > MAX_SEALED_BYTES) {
    return fail(422, "notification_sealed_invalid");
  }
  const avatar = object(body.avatar, "notification_event_invalid");
  exact(avatar, ["sha256", "data"]);
  if (typeof avatar.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(avatar.sha256)
      || typeof avatar.data !== "string" || avatar.data.length > 700_000) {
    return fail(422, "notification_sealed_invalid");
  }
  return {
    eventId: body.eventId,
    eventType: eventType as BuzzKitSealedNotificationEvent["eventType"],
    grantId: grant.grantId,
    profile: grant.profile,
    sessionReference: body.sessionReference,
    sealed,
    avatar: { mimeType: "application/octet-stream", sha256: avatar.sha256, data: avatar.data },
    sound: body.sound,
  };
}

async function persistAvatar(
  request: Request,
  env: LinkEnv,
  accountCoordinate: string,
  avatar: { mimeType: BuzzKitAssetMimeType; sha256: string; data: string },
  now: number,
) {
  const prefix = `data:${avatar.mimeType};base64,`;
  if (!avatar.data.startsWith(prefix)) return fail(422, "notification_avatar_invalid");
  let data: Uint8Array;
  try { data = Uint8Array.from(atob(avatar.data.slice(prefix.length)), (value) => value.charCodeAt(0)); }
  catch { return fail(422, "notification_avatar_invalid"); }
  // A sealed avatar is the image plus its 16-byte authentication tag.
  const maximum = MAX_AVATAR_BYTES + (avatar.mimeType === "application/octet-stream" ? 16 : 0);
  if (data.length < 1 || data.length > maximum) return fail(422, "notification_avatar_too_large");
  const sha = Array.from(await digest(data), (byte) => byte.toString(16).padStart(2, "0")).join("");
  if (sha !== avatar.sha256) return fail(422, "notification_avatar_invalid");
  const assetId = notificationBase64(await digest(data));
  const asset = await stateBinding(env, accountCoordinate).putNotificationAsset({
    assetId,
    mimeType: avatar.mimeType,
    data,
    expiresAt: now + ASSET_CAPABILITY_SECONDS,
  });
  if (asset.assetId !== assetId || asset.expiresAt !== now + ASSET_CAPABILITY_SECONDS) {
    return fail(503, "notification_avatar_unconfirmed");
  }
  const configuredOrigin = env.BUZZKIT_ASSET_ORIGIN?.trim();
  const origin = configuredOrigin || new URL(request.url).origin;
  let parsed: URL;
  try { parsed = new URL(origin); } catch { return fail(503, "notification_asset_origin_invalid"); }
  if (parsed.protocol !== "https:" || parsed.origin !== origin || parsed.pathname !== "/") {
    return fail(503, "notification_asset_origin_invalid");
  }
  const extension = assetExtension(avatar.mimeType);
  const accountPath = notificationBase64(new TextEncoder().encode(accountCoordinate));
  const expires = now + ASSET_CAPABILITY_SECONDS;
  const capability = await signAssetCapability(
    env, accountPath, assetId, extension, expires,
  );
  return {
    url: `${origin}${ASSET_ROOT}/${accountPath}/${assetId}.${extension}?expires=${expires}&capability=${capability}`,
    mimeType: avatar.mimeType,
    sha256: avatar.sha256,
  };
}

async function assetCapabilityKey(env: LinkEnv): Promise<CryptoKey> {
  const secret = env.BUZZKIT_IDENTITY_SECRET?.trim() ?? "";
  if (!secret) return fail(503, "buzzkit_identity_unconfigured");
  return crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

function assetCapabilityTranscript(
  accountPath: string,
  assetId: string,
  extension: string,
  expires: number,
): Uint8Array {
  return new TextEncoder().encode([
    "loopdy-buzzkit-avatar-capability-v1", accountPath, assetId, extension, String(expires),
  ].join("\n"));
}

async function signAssetCapability(
  env: LinkEnv,
  accountPath: string,
  assetId: string,
  extension: string,
  expires: number,
): Promise<string> {
  const signature = await crypto.subtle.sign(
    "HMAC",
    await assetCapabilityKey(env),
    assetCapabilityTranscript(accountPath, assetId, extension, expires),
  );
  return notificationBase64(new Uint8Array(signature));
}

async function verifyAssetCapability(
  env: LinkEnv,
  accountPath: string,
  assetId: string,
  extension: string,
  expires: number,
  capability: string,
): Promise<boolean> {
  return crypto.subtle.verify(
    "HMAC",
    await assetCapabilityKey(env),
    decode(capability, "notification_asset_unknown"),
    assetCapabilityTranscript(accountPath, assetId, extension, expires),
  );
}

export async function handleNotificationRequest(
  request: Request,
  env: LinkEnv,
  now: number,
): Promise<Response | null> {
  const url = new URL(request.url);
  try {
    const assetResponse = await serveAsset(request, env, now);
    if (assetResponse) return assetResponse;
    if (!(url.pathname === ROOT || url.pathname.startsWith(`${ROOT}/`)
        || url.pathname === ACCOUNT_BINDING_PATH)) return null;
    if (url.search || url.hash) return fail(400, "notification_path_invalid");
    const raw = await rawBody(request);
    let body: Record<string, unknown> = {};
    if (raw.length) {
      try {
        const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(raw));
        if (!value || typeof value !== "object" || Array.isArray(value)) return fail(400, "notification_request_invalid");
        body = value as Record<string, unknown>;
      } catch { return fail(400, "notification_request_invalid"); }
    }

    if (url.pathname === ACCOUNT_BINDING_PATH) {
      return await bindWakeInstallation(request, raw, body, env, now);
    }

    if (url.pathname === IDENTITY_PATH) {
      if (!["GET", "DELETE"].includes(request.method) || raw.length) {
        return fail(405, "notification_method_invalid");
      }
      const auth = await mobile(env, request, raw, now, request.method === "DELETE");
      if (request.method === "DELETE") {
        if (auth.ownerKind !== "account") return fail(403, "notification_scope_invalid");
        await retireAccountNotificationAuthority(env, auth.ownerCoordinate, now);
        return response({ version: 1, identity: { scope: "account", state: "revoked" } });
      }
      const identity = await buzzKitIdentity(env, auth.ownerCoordinate, auth.ownerKind);
      // The identity hash is reusable provider authority. Let the serialized
      // installation owner make the final decision after every awaited proof
      // derivation so a concurrent revocation wins before this response leaves.
      await finalOwnerDecision(env, auth);
      return response({
        version: auth.ownerKind === "account" ? 1 : 2,
        identity,
      });
    }

    if (url.pathname === STATUS_PATH) {
      if (!["GET", "POST"].includes(request.method)) return fail(405, "notification_method_invalid");
      if (request.method === "GET" && raw.length) return fail(405, "notification_method_invalid");
      const auth = await mobile(env, request, raw, now);
      let currentDevice: { tokenHash: string; environment: "sandbox" | "production" } | undefined;
      if (request.method === "POST") {
        exact(body, ["version", "tokenHash", "environment"]);
        if (body.version !== 2 || typeof body.tokenHash !== "string" || !/^[0-9a-f]{64}$/.test(body.tokenHash)
            || !["sandbox", "production"].includes(String(body.environment))) {
          return fail(400, "notification_device_readback_invalid");
        }
        currentDevice = {
          tokenHash: body.tokenHash,
          environment: body.environment as "sandbox" | "production",
        };
      } else if (auth.ownerKind !== "account") {
        return fail(400, "notification_device_readback_required");
      }
      return response({
        version: currentDevice ? 2 : 1,
        readiness: await readBuzzKitReadiness(env, auth.ownerCoordinate, auth.ownerKind, currentDevice),
      });
    }

    if (url.pathname === `${ROOT}/buzzkit/test`) {
      if (request.method !== "POST") return fail(405, "notification_method_invalid");
      const auth = await mobile(env, request, raw, now);
      exact(body, ["version", "requestId"]);
      if (body.version !== 1 || typeof body.requestId !== "string" || !UUID.test(body.requestId)) {
        return fail(400, "notification_test_invalid");
      }
      return response({
        version: 1,
        test: await sendBuzzKitTestNotification(
          env, auth.ownerCoordinate, body.requestId, auth.ownerKind,
          () => requireNotificationPrincipalEgressActive(env, auth),
        ),
      });
    }

    if (url.pathname === ROOT) {
      if (!["GET", "POST"].includes(request.method)) return fail(405, "notification_method_invalid");
      const auth = await mobile(env, request, raw, now);
      const table = auth.ownerKind === "account" ? "notification_grants" : "notification_instance_grants";
      const coordinateColumn = auth.ownerKind === "account" ? "account_coordinate" : "notification_coordinate";
      const credentialColumn = auth.ownerKind === "account" ? "device_id" : "installation_id";
      if (request.method === "GET") {
        const rows = await env.ACCOUNTS.prepare(`SELECT grant_id,? AS owner_kind,
            ${coordinateColumn} AS owner_coordinate,${credentialColumn} AS credential_id,
            authorization_epoch,request_digest,public_json,revision,state,expires_at
          FROM ${table} WHERE ${coordinateColumn}=? ORDER BY created_at,grant_id`)
          .bind(auth.ownerKind, auth.ownerCoordinate).all<GrantRow>();
        return response({ version: 1, grants: rows.results.map(publicGrant) });
      }
      const legacy = body.version === 2 && auth.ownerKind === "account";
      exact(body, legacy
        ? ["version", "idempotencyKey", "hostPublicKey", "hostKeyId", "profile", "eventTypes", "expiresAt"]
        : ["version", "idempotencyKey", "instanceId", "hostPublicKey", "hostKeyId", "profile", "eventTypes", "expiresAt"]);
      if ((!legacy && body.version !== 3) || typeof body.idempotencyKey !== "string" || !UUID.test(body.idempotencyKey)
          || (!legacy && (typeof body.instanceId !== "string" || !UUID.test(body.instanceId)))
          || typeof body.hostPublicKey !== "string" || typeof body.hostKeyId !== "string"
          || typeof body.profile !== "string" || !PROFILE.test(body.profile) || !integer(body.expiresAt)
          || !Array.isArray(body.eventTypes)
          || (legacy
            ? body.eventTypes.length < 1 || body.eventTypes.length > EVENTS.size
            : body.eventTypes.length !== EVENTS.size)
          || new Set(body.eventTypes).size !== body.eventTypes.length || body.eventTypes.some((event) => !EVENTS.has(event))) {
        return fail(400, "notification_grant_invalid");
      }
      const key = decode(body.hostPublicKey);
      if (key.length !== 65 || key[0] !== 4 || notificationBase64(await digest(key)) !== body.hostKeyId) {
        fail(400, "notification_key_invalid");
      }
      await crypto.subtle.importKey("raw", key, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
      const requestDigest = notificationBase64(await digest(raw));
      const previous = await env.ACCOUNTS.prepare(`SELECT grant_id,? AS owner_kind,
          ${coordinateColumn} AS owner_coordinate,${credentialColumn} AS credential_id,
          authorization_epoch,request_digest,public_json,revision,state,expires_at
        FROM ${table} WHERE ${coordinateColumn}=? AND ${credentialColumn}=? AND idempotency_key=?`)
        .bind(auth.ownerKind, auth.ownerCoordinate, auth.credentialId, body.idempotencyKey).first<GrantRow>();
      if (previous) {
        if (previous.request_digest !== requestDigest) fail(409, "notification_idempotency_conflict");
        return response({ version: 1, grant: publicGrant(previous) });
      }
      if (body.expiresAt <= now || body.expiresAt > now + 2_592_000) {
        fail(400, "notification_grant_expiry_invalid");
      }
      const instanceFilter = legacy ? "" : " AND json_extract(public_json,'$.instanceId')=?";
      const existing = await env.ACCOUNTS.prepare(`SELECT grant_id,? AS owner_kind,
          ${coordinateColumn} AS owner_coordinate,${credentialColumn} AS credential_id,
          authorization_epoch,request_digest,public_json,revision,state,expires_at
        FROM ${table} WHERE ${coordinateColumn}=? AND ${credentialColumn}=?
          AND state IN ('issued','active') AND expires_at>?
          AND json_extract(public_json,'$.hostKeyId')=? AND json_extract(public_json,'$.profile')=?${instanceFilter}
        ORDER BY created_at DESC LIMIT 1`)
        .bind(...(legacy
          ? [auth.ownerKind, auth.ownerCoordinate, auth.credentialId, now, body.hostKeyId, body.profile]
          : [auth.ownerKind, auth.ownerCoordinate, auth.credentialId, now, body.hostKeyId, body.profile, body.instanceId]))
        .first<GrantRow>();
      if (existing) {
        const grant = publicGrant(existing);
        if (grant.hostPublicKey !== body.hostPublicKey || (!legacy && grant.instanceId !== body.instanceId)
            || JSON.stringify([...grant.eventTypes].sort()) !== JSON.stringify([...(body.eventTypes as string[])].sort())) {
          fail(409, "notification_sender_grant_conflict");
        }
        return response({ version: 1, grant });
      }
      const grant: NotificationGrant = {
        grantId: crypto.randomUUID(),
        ...(legacy ? {} : { instanceId: body.instanceId as string }),
        hostKeyId: body.hostKeyId,
        hostPublicKey: body.hostPublicKey,
        authorizationEpoch: auth.authorizationEpoch,
        profile: body.profile,
        eventTypes: body.eventTypes as string[],
        createdAt: now,
        expiresAt: body.expiresAt,
        revision: 1,
        provider: "buzzkit",
        subscriberScope: auth.ownerKind,
        state: "issued",
      };
      await env.ACCOUNTS.prepare(
        `UPDATE ${table} SET state='revoked',revision=revision+1 WHERE ${coordinateColumn}=? AND expires_at<=? AND state!='revoked'`,
      ).bind(auth.ownerCoordinate, now).run();
      await env.ACCOUNTS.prepare(
        `DELETE FROM ${table} WHERE ${coordinateColumn}=? AND expires_at<?`,
      ).bind(auth.ownerCoordinate, now - 86_400).run();
      let result: { meta: { changes: number } };
      if (auth.ownerKind === "account") {
        result = await env.ACCOUNTS.prepare(`INSERT INTO notification_grants(
            grant_id,account_coordinate,device_id,authorization_epoch,idempotency_key,request_digest,
            public_json,state,revision,created_at,expires_at)
          SELECT ?,?,?,?,?,?,?,'issued',1,?,?
          WHERE (SELECT COUNT(*) FROM notification_grants WHERE account_coordinate=?)<256
            AND NOT EXISTS(SELECT 1 FROM notification_account_scope_retirements
              WHERE account_coordinate=?)
            AND EXISTS(SELECT 1 FROM device_directory d JOIN accounts a USING(account_coordinate)
              WHERE d.device_id=? AND d.account_coordinate=? AND d.status='active' AND a.status='active'
                AND d.authorization_epoch=? AND a.authorization_epoch=?)
          ON CONFLICT DO NOTHING`)
          .bind(grant.grantId, auth.ownerCoordinate, auth.credentialId, auth.authorizationEpoch,
            body.idempotencyKey, requestDigest, JSON.stringify(grant), now, grant.expiresAt,
            auth.ownerCoordinate, auth.ownerCoordinate, auth.credentialId, auth.ownerCoordinate,
            auth.authorizationEpoch, auth.authorizationEpoch).run();
      } else {
        result = await env.ACCOUNTS.prepare(`INSERT INTO notification_instance_grants(
            grant_id,notification_coordinate,installation_id,authorization_epoch,idempotency_key,
            request_digest,public_json,state,revision,created_at,expires_at)
          SELECT ?,?,?,?,?,?,?,'issued',1,?,?
          WHERE (SELECT COUNT(*) FROM notification_instance_grants WHERE notification_coordinate=?)<256
            AND EXISTS(SELECT 1 FROM notification_installations WHERE installation_id=?
              AND notification_coordinate=? AND state='active' AND authorization_epoch=?)
          ON CONFLICT DO NOTHING`)
          .bind(grant.grantId, auth.ownerCoordinate, auth.credentialId, auth.authorizationEpoch,
            body.idempotencyKey, requestDigest, JSON.stringify(grant), now, grant.expiresAt,
            auth.ownerCoordinate, auth.credentialId, auth.ownerCoordinate, auth.authorizationEpoch).run();
      }
      if (result.meta.changes !== 1) return fail(409, "notification_grant_limit_or_conflict");
      return response({ version: 1, grant }, 201);
    }

    const parts = url.pathname.slice(ROOT.length + 1).split("/");
    const id = parts[0]!;
    if (!UUID.test(id)) return fail(404, "notification_grant_unknown");
    let row = await load(env, id);
    const activityId = parts[2];
    const isActivity = parts[1] === "live-activities" && typeof activityId === "string" && IDENTIFIER.test(activityId);
    const mobileRequest = (parts.length === 1 && request.method === "DELETE")
      || (isActivity && parts.length === 3 && ["PUT", "DELETE"].includes(request.method));
    if (mobileRequest) {
      const auth = await mobile(env, request, raw, now);
      owner(row, auth);
      if (parts.length === 1) {
        exact(body, ["version", "expectedRevision"]);
        if (body.version !== 2 || !integer(body.expectedRevision)
            || (body.expectedRevision !== row.revision
              && !(row.state === "revoked" && body.expectedRevision === row.revision - 1))) {
          fail(409, "notification_revision_stale");
        }
        return response({ version: 1, grant: await revoke(env, row) });
      }
      const grant = await active(env, row, now);
      if (request.method === "DELETE") {
        exact(body, ["version", "revision", "timestamp"]);
        if (body.version !== 2 || !integer(body.revision) || !integer(body.timestamp)) {
          return fail(400, "notification_activity_invalid");
        }
        const activity = await stateBinding(env, row.owner_coordinate).revokeNotificationActivity({
          grantId: grant.grantId,
          activityId: activityId!,
          revision: body.revision,
          timestamp: body.timestamp,
        });
        return response({ version: 1, activity });
      }
      exact(body, [
        "version", "profile", "sessionId", "sessionReference", "attributesType",
        "revision", "timestamp", "leaseExpires",
      ]);
      if (body.version !== 2 || body.profile !== grant.profile || typeof body.sessionId !== "string"
          || !IDENTIFIER.test(body.sessionId) || body.sessionReference !== await notificationSessionReference(grant.profile, body.sessionId)
          || body.attributesType !== "LoopdySessionActivityAttributes" || !integer(body.revision)
          || !integer(body.timestamp) || !integer(body.leaseExpires) || body.leaseExpires > grant.expiresAt) {
        return fail(400, "notification_activity_invalid");
      }
      const activity = await stateBinding(env, row.owner_coordinate).registerNotificationActivity({
        grantId: grant.grantId,
        activityId: activityId!,
        sessionReference: String(body.sessionReference),
        revision: body.revision,
        leaseExpires: body.leaseExpires,
        status: "active",
        timestamp: body.timestamp,
      });
      return response({ version: 1, activity });
    }

    await host(env, request, raw, row, now);
    if (parts.length === 2 && parts[1] === "claim" && request.method === "POST") {
      exact(body, ["version", "idempotencyKey"]);
      if (body.version !== 2 || typeof body.idempotencyKey !== "string" || !UUID.test(body.idempotencyKey)) {
        fail(400, "notification_request_invalid");
      }
      await active(env, row, now, true);
      const table = row.owner_kind === "account" ? "notification_grants" : "notification_instance_grants";
      await env.ACCOUNTS.prepare(`UPDATE ${table} SET state='active' WHERE grant_id=? AND state='issued'`)
        .bind(id).run();
      row = await load(env, id);
      return response({ version: 1, grant: await active(env, row, now) });
    }

    const grant = await active(env, row, now);
    if (parts.length === 1 && request.method === "GET") return response({ version: 1, grant });
    if (parts.length === 2 && parts[1] === "events" && request.method === "POST" && body.version === 3) {
      const event = sealedEvent(body, grant, now);
      const avatar = await persistAvatar(request, env, row.owner_coordinate, event.avatar, now);
      const receipt = await sendBuzzKitSealedNotification(
        env, row.owner_coordinate, event, avatar, row.owner_kind,
        () => requireNotificationEgressActive(env, row),
      );
      return response({ version: 1, ...receipt }, 202);
    }
    if (parts.length === 2 && parts[1] === "wake" && request.method === "POST") {
      exact(body, ["version", "reason"]);
      if (body.version !== 1 || body.reason !== "renew-sign-in") fail(400, "notification_request_invalid");
      const receipt = await sendBuzzKitSignInWake(
        env, row.owner_coordinate, grant.grantId, row.owner_kind, now,
        () => requireNotificationEgressActive(env, row),
      );
      return response({ version: 1, ...receipt }, 202);
    }
    if (parts.length === 2 && parts[1] === "events" && request.method === "POST") {
      const event = richEvent(body, grant, now);
      const avatar = await persistAvatar(request, env, row.owner_coordinate, event.agent.avatar, now);
      const receipt = await sendBuzzKitRichNotification(
        env, row.owner_coordinate, event, avatar, row.owner_kind,
        () => requireNotificationEgressActive(env, row),
      );
      return response({ version: 1, ...receipt }, 202);
    }
    if (isActivity && parts.length === 3 && request.method === "GET") {
      return response({
        version: 1,
        activity: await stateBinding(env, row.owner_coordinate).notificationActivity({
          grantId: grant.grantId,
          activityId: activityId!,
          now,
        }),
      });
    }
    if (isActivity && parts.length === 4 && parts[3] === "updates" && request.method === "POST") {
      exact(body, [
        "version", "updateId", "sessionReference", "phase", "currentAction", "progress",
        "completedSteps", "activeSubagentCount", "latestTool", "timestamp", "expires",
      ]);
      if (body.version !== 2 || typeof body.updateId !== "string" || !BASE64URL_32.test(body.updateId)
          || typeof body.sessionReference !== "string" || !BASE64URL_32.test(body.sessionReference)
          || !["thinking", "waiting", "using_tool", "delegating", "responding", "completed", "failed"].includes(String(body.phase))
          || !usefulText(body.currentAction, 96) || !boundedInteger(body.progress, 0, 100)
          || !boundedInteger(body.completedSteps, 0, 999) || !boundedInteger(body.activeSubagentCount, 0, 99)
          || !(body.latestTool === null || usefulText(body.latestTool, 64))
          || !integer(body.timestamp) || !integer(body.expires) || body.expires <= body.timestamp) {
        return fail(400, "notification_activity_invalid");
      }
      const activity = await stateBinding(env, row.owner_coordinate).notificationActivity({
        grantId: grant.grantId,
        activityId: activityId!,
        now,
      });
      if (activity.status !== "active" || activity.sessionReference !== body.sessionReference
          || activity.leaseExpires <= now) return fail(403, "notification_activity_inactive");
      const externalId = await buzzKitRecipientExternalId(env, row.owner_coordinate, row.owner_kind);
      const terminal = body.phase === "completed" || body.phase === "failed";
      const reservation = await stateBinding(env, row.owner_coordinate).beginNotificationActivityUpdate({
        grantId: grant.grantId,
        activityId: activity.activityId,
        updateId: body.updateId,
        timestamp: body.timestamp,
      });
      if (reservation.status === "duplicate") {
        return response({ version: 1, status: "duplicate", deliveryId: body.updateId }, 202);
      }
      const receipt = await sendBuzzKitLiveActivity(env, {
        externalId,
        activityId: activity.activityId,
        event: terminal ? "end" : "update",
        contentState: {
          phase: body.phase,
          currentAction: body.currentAction,
          progress: body.progress,
          completedSteps: body.completedSteps,
          activeSubagentCount: body.activeSubagentCount,
          latestTool: body.latestTool,
          timestamp: body.timestamp,
        },
        timestamp: body.timestamp,
        staleDate: new Date(Number(body.expires) * 1_000).toISOString(),
        // A finished card leaves the Lock Screen shortly after: its reply is already a
        // notification, and an end without a dismissal date stays for up to four hours.
        ...(terminal ? {
          dismissalDate: new Date(Math.min(Number(body.timestamp) + 30, Number(body.expires)) * 1_000).toISOString(),
        } : {}),
      }, () => requireNotificationActivityEgressActive(env, row, activity));
      await stateBinding(env, row.owner_coordinate).completeNotificationActivityUpdate({
        grantId: grant.grantId,
        activityId: activity.activityId,
        updateId: body.updateId,
        timestamp: body.timestamp,
        terminal,
      });
      return response({ version: 1, ...receipt }, 202);
    }
    return fail(404, "notification_route_unknown");
  } catch (error) {
    if (error instanceof NotificationError || error instanceof BuzzKitBackendError
        || error instanceof NotificationIdentityError) {
      return response({ version: 1, error: { code: error.code, message: error.code } }, error.status);
    }
    throw error;
  }
}

function object(value: unknown, code: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return fail(400, code);
  return value as Record<string, unknown>;
}

function usefulText(value: unknown, maximum: number): value is string {
  return typeof value === "string" && value.length >= 1 && value.length <= maximum
    && [...value].every((character) => {
      const scalar = character.codePointAt(0) ?? 0;
      return scalar > 0x1f && scalar !== 0x7f;
    });
}

function boundedInteger(value: unknown, minimum: number, maximum: number): value is number {
  return Number.isSafeInteger(value) && Number(value) >= minimum && Number(value) <= maximum;
}
