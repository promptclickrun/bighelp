import { encodeSmallBase64URL as base64URL, sha256Bytes as sha256 } from "./encoding.js";
import { readByteStream } from "./http-primitives.js";

const DEFAULT_API_URL = "https://api.buzzkit.dev";
const MAX_RESPONSE_BYTES = 65_536;
const MAX_APNS_PAYLOAD_BYTES = 3_800;
const ACCOUNT_EXTERNAL_ID_DOMAIN = "loopdy-buzzkit-account-v1\0";
const NOTIFICATION_EXTERNAL_ID_DOMAIN = "loopdy-buzzkit-notification-instance-v1\0";
const REQUIRED_IDENTITY_SECRET_GENERATION = "notification-instance-v2";

export type BuzzKitIdentityScope = "account" | "notification-instance";
export type BuzzKitEgressAuthorization = () => Promise<void>;

export interface BuzzKitEnvironment {
  BUZZKIT_API_KEY?: string;
  BUZZKIT_IDENTITY_SECRET?: string;
  BUZZKIT_IDENTITY_SECRET_GENERATION?: string;
  BUZZKIT_TENANT?: string;
  BUZZKIT_API_URL?: string;
  BUZZKIT_ASSET_ORIGIN?: string;
  ACCOUNTS?: D1Database;
  USER_LINKS?: {
    getByName(ownerCoordinate: string): {
      authorizeNotificationEgress(input: {
        ownerKind: "notification-instance";
        credentialId: string;
        authorizationEpoch: number;
        now: number;
        grant: { grantId: string; revision: number; expiresAt: number };
      }): Promise<void>;
    };
  };
}

export interface BuzzKitIdentity {
  externalId: string;
  identityHash: string;
}

export interface BuzzKitAgentAvatar {
  mimeType: "image/png" | "image/jpeg" | "image/webp";
  sha256: string;
  data: string;
}

/** An avatar image, or a sealed avatar only the recipient phone can open. */
export type BuzzKitAssetMimeType = BuzzKitAgentAvatar["mimeType"] | "application/octet-stream";

/**
 * An alert sealed end to end by the host for the recipient phone. The title, text
 * and avatar are opaque here; the phone's notification extension opens them.
 */
export interface BuzzKitSealedNotificationEvent {
  eventId: string;
  eventType: BuzzKitRichNotificationEvent["eventType"];
  grantId: string;
  profile: string;
  sessionReference: string;
  sealed: Record<string, unknown>;
  avatar: { mimeType: "application/octet-stream"; sha256: string; data: string };
  sound: boolean;
}

export interface BuzzKitRichNotificationEvent {
  eventId: string;
  eventType: "session.completed" | "session.failed" | "scheduled.completed" | "scheduled.failed"
    | "approval.required" | "clarification.required" | "subagent.completed" | "subagent.failed";
  grantId: string;
  profile: string;
  sessionReference: string;
  turnId: string;
  occurredAt: number;
  agent: {
    id: string;
    name: string;
    avatar: BuzzKitAgentAvatar;
  };
  content: {
    kind: "reply" | "failure" | "scheduled" | "approval" | "clarification" | "subagent";
    text: string;
  };
  sound: boolean;
}

export interface BuzzKitNotificationAssetReference {
  url: string;
  mimeType: BuzzKitAssetMimeType;
  sha256: string;
}

export interface BuzzKitMessageReceipt {
  status: "accepted" | "duplicate";
  deliveryId: string;
  providerStatus: string;
  counts: Record<string, number> | null;
}

export type BuzzKitWakeReceipt = BuzzKitMessageReceipt;

export interface BuzzKitWakeSource {
  hostDeviceId: string;
  authorizationEpoch: number;
  authorizeEgress: () => void;
}

export interface BuzzKitLiveActivityInput {
  externalId: string;
  activityId: string;
  event: "update" | "end";
  contentState: Record<string, unknown>;
  timestamp: number;
  staleDate?: string;
  dismissalDate?: string;
  alert?: { title: string; body: string; sound: string };
}

export interface BuzzKitLiveActivityReceipt {
  status: "accepted";
  deliveryId: string;
}

export interface BuzzKitReadiness {
  configured: true;
  pushCredentials: Array<{
    environment: "sandbox" | "production" | null;
    status: "unvalidated" | "active" | "invalid";
    validatedAt: string | null;
    lastError: string | null;
  }>;
  subscriber: {
    identified: boolean;
    verified: boolean;
    activeIOSPushEnvironments: Array<"sandbox" | "production" | null>;
    currentDevice?: {
      matched: boolean;
      environment: "sandbox" | "production";
      enabled: boolean;
      active: boolean;
      subscriptionId: string | null;
    };
  };
  topicSlugs: string[];
}

export const LOOPDY_BUZZKIT_TOPICS = [
  { slug: "chat-replies-completions", name: "Chat replies and completions" },
  { slug: "scheduled-tasks-deliveries", name: "Scheduled tasks and deliveries" },
  { slug: "questions-approvals", name: "Questions and Approvals" },
  { slug: "subagent-completions", name: "Subagent Completions" },
] as const;

export class BuzzKitBackendError extends Error {
  constructor(readonly status: number, readonly code: string) {
    super(code);
    this.name = "BuzzKitBackendError";
  }
}

export async function buzzKitIdentity(
  env: BuzzKitEnvironment,
  ownerCoordinate: string,
  scope: BuzzKitIdentityScope = "account",
): Promise<BuzzKitIdentity> {
  requireIdentitySecretGeneration(env);
  if (scope === "account") {
    throw new BuzzKitBackendError(410, "buzzkit_account_identity_retired");
  }
  const secret = requiredSecret(env.BUZZKIT_IDENTITY_SECRET, "buzzkit_identity_unconfigured");
  const externalId = await deriveBuzzKitExternalId(ownerCoordinate, scope);
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(externalId));
  return { externalId, identityHash: hex(new Uint8Array(signature)) };
}

export async function sendBuzzKitTestNotification(
  env: BuzzKitEnvironment,
  ownerCoordinate: string,
  requestId: string,
  scope: BuzzKitIdentityScope,
  authorizeEgress: BuzzKitEgressAuthorization,
): Promise<{ id: string; state: "accepted" | "failed"; providerStatus: string }> {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(requestId)) {
    throw new BuzzKitBackendError(400, "notification_test_invalid");
  }
  const externalId = await buzzKitRecipientExternalId(env, ownerCoordinate, scope);
  await authorizeEgress();
  const created = await buzzKitRequest(env, "/v1/messages", {
    method: "POST",
    idempotencyKey: `loopdy-test:${externalId}:${requestId}`,
    body: {
      to: externalId,
      title: "Loopdy test notification",
      body: "This is your requested BuzzKit notification test.",
      data: { loopdy_test: { version: 1, requestId } },
      channel: "push",
      sound: "default",
      ttlSeconds: 300,
    },
  });
  const messageId = requiredIdentifier(requiredObject(created.data, "buzzkit_response_invalid").id, "buzzkit_response_invalid");
  const readback = await buzzKitRequest(env, `/v1/messages/${encodeURIComponent(messageId)}`, { method: "GET" });
  const message = requiredObject(readback.data, "buzzkit_response_invalid");
  if (message.id !== messageId) throw new BuzzKitBackendError(502, "buzzkit_readback_mismatch");
  const providerStatus = requiredIdentifier(message.status, "buzzkit_response_invalid");
  const counts = message.counts && typeof message.counts === "object" ? message.counts as Record<string, unknown> : null;
  const failed = providerStatus === "completed" && counts?.sent === 0 && counts?.delivered === 0;
  return { id: messageId, state: failed ? "failed" : "accepted", providerStatus };
}

export async function sendBuzzKitRichNotification(
  env: BuzzKitEnvironment,
  ownerCoordinate: string,
  event: BuzzKitRichNotificationEvent,
  avatar: BuzzKitNotificationAssetReference,
  scope: BuzzKitIdentityScope,
  authorizeEgress: BuzzKitEgressAuthorization,
): Promise<BuzzKitMessageReceipt> {
  const externalId = await buzzKitRecipientExternalId(env, ownerCoordinate, scope);
  const presentation = presentationFor(event.eventType);
  const deepLink = `loopdy:///dashboard?eventId=${encodeURIComponent(event.eventId)}`;
  const data = {
    loopdy: {
      version: 2,
      eventId: event.eventId,
      eventType: event.eventType,
      grantId: event.grantId,
      profile: event.profile,
      sessionReference: event.sessionReference,
      turnId: event.turnId,
      occurredAt: event.occurredAt,
      contentKind: event.content.kind,
      agent: {
        id: event.agent.id,
        name: event.agent.name,
        avatar: { url: avatar.url, mimeType: avatar.mimeType, sha256: avatar.sha256 },
      },
    },
  };
  const body: Record<string, unknown> = {
    to: externalId,
    topic: presentation.topic,
    title: event.agent.name,
    body: event.content.text,
    data,
    imageUrl: avatar.url,
    deepLink,
    action: { name: "open_loopdy_managed_event", data: { eventId: event.eventId } },
    category: presentation.category,
    actions: presentation.actions,
    threadId: event.sessionReference,
    sound: event.sound ? "default" : undefined,
    priority: "high",
    interruptionLevel: presentation.interruptionLevel,
    ttlSeconds: presentation.ttlSeconds,
  };
  return sendManagedMessage(env, body, event.eventId, authorizeEgress);
}

/**
 * Sends a sealed alert. BuzzKit and this service only see a neutral placeholder;
 * the phone replaces it with the host's title, text and avatar.
 */
export async function sendBuzzKitSealedNotification(
  env: BuzzKitEnvironment,
  ownerCoordinate: string,
  event: BuzzKitSealedNotificationEvent,
  avatar: BuzzKitNotificationAssetReference,
  scope: BuzzKitIdentityScope,
  authorizeEgress: BuzzKitEgressAuthorization,
): Promise<BuzzKitMessageReceipt> {
  const externalId = await buzzKitRecipientExternalId(env, ownerCoordinate, scope);
  const presentation = presentationFor(event.eventType);
  const body: Record<string, unknown> = {
    to: externalId,
    topic: presentation.topic,
    title: "bighelp",
    body: presentation.placeholder,
    data: {
      loopdy: {
        version: 2,
        eventId: event.eventId,
        eventType: event.eventType,
        grantId: event.grantId,
        agent: { id: event.profile },
        // The chat, so the phone can stay quiet while you're reading it. It also
        // arrives as the thread, but the phone's grouping replaces that.
        sessionReference: event.sessionReference,
        sealed: event.sealed,
        avatar: { url: avatar.url },
      },
    },
    deepLink: `loopdy:///dashboard?eventId=${encodeURIComponent(event.eventId)}`,
    action: { name: "open_loopdy_managed_event", data: { eventId: event.eventId } },
    category: presentation.category,
    actions: presentation.actions,
    threadId: event.sessionReference,
    sound: event.sound ? "default" : undefined,
    priority: "high",
    interruptionLevel: presentation.interruptionLevel,
    ttlSeconds: presentation.ttlSeconds,
  };
  return sendManagedMessage(env, body, event.eventId, authorizeEgress);
}

/** How often a host may wake the phone; repeats inside a window are one send. */
export const SIGN_IN_WAKE_WINDOW_SECONDS = 21_600;

/**
 * A data-only wake asking the phone to renew its sign-in to this host before a
 * rotating sign-in (the Nous Portal's lasts a day) runs out while bighelp is
 * closed. It carries no content, makes no sound and shows nothing.
 */
export async function sendBuzzKitSignInWake(
  env: BuzzKitEnvironment,
  ownerCoordinate: string,
  grantId: string,
  scope: BuzzKitIdentityScope,
  now: number,
  authorizeEgress: BuzzKitEgressAuthorization,
): Promise<BuzzKitMessageReceipt> {
  const externalId = await buzzKitRecipientExternalId(env, ownerCoordinate, scope);
  const window = Math.floor(now / SIGN_IN_WAKE_WINDOW_SECONDS);
  return sendManagedMessage(env, {
    to: externalId,
    data: { bighelp_wake: { version: 1, type: "renew-sign-in", grantId } },
    collapseId: "bighelp-renew-sign-in",
    priority: "normal",
    ttlSeconds: SIGN_IN_WAKE_WINDOW_SECONDS,
    policy: "ignore",
    apns: { payload: { aps: { "content-available": 1 } } },
  }, `bighelp-renew-${grantId}-${window}`, authorizeEgress);
}

async function sendManagedMessage(
  env: BuzzKitEnvironment,
  body: Record<string, unknown>,
  idempotencyKey: string,
  authorizeEgress: BuzzKitEgressAuthorization,
): Promise<BuzzKitMessageReceipt> {
  for (const key of Object.keys(body)) if (body[key] === undefined) delete body[key];
  assertAPNsBudget(body);
  await authorizeEgress();
  const created = await buzzKitRequest(env, "/v1/messages", {
    method: "POST",
    body,
    idempotencyKey,
  });
  const message = requiredObject(created.data, "buzzkit_response_invalid");
  const messageId = requiredIdentifier(message.id, "buzzkit_response_invalid");
  const readback = await buzzKitRequest(env, `/v1/messages/${encodeURIComponent(messageId)}`, {
    method: "GET",
  });
  const confirmed = requiredObject(readback.data, "buzzkit_response_invalid");
  if (confirmed.id !== messageId) throw new BuzzKitBackendError(502, "buzzkit_readback_mismatch");
  const providerStatus = requiredIdentifier(confirmed.status, "buzzkit_response_invalid");
  return {
    status: created.replayed ? "duplicate" : "accepted",
    deliveryId: messageId,
    providerStatus,
    counts: numericRecord(confirmed.counts),
  };
}

/**
 * Send an installation-scoped, data-only wake hint. The encrypted Link frame remains
 * authoritative and durable; this payload carries no chat content or device
 * token and only asks the account's migrated Loopdy installation to reconnect
 * and drain it.
 */
export async function sendBuzzKitLinkWake(
  env: BuzzKitEnvironment,
  accountCoordinate: string,
  frameId: string,
  source: BuzzKitWakeSource,
): Promise<BuzzKitWakeReceipt[]> {
  if (!/^[A-Za-z0-9_-]{16,128}$/.test(frameId)
      || !/^[A-Za-z0-9_-]{1,96}$/.test(source.hostDeviceId)
      || !Number.isSafeInteger(source.authorizationEpoch) || source.authorizationEpoch < 1) {
    throw new BuzzKitBackendError(422, "link_wake_invalid");
  }
  const receipts: BuzzKitWakeReceipt[] = [];
  let hasTerminalZeroRecipient = false;
  for (const recipient of await linkWakeRecipients(env, accountCoordinate)) {
    const externalId = await buzzKitRecipientExternalId(
      env, recipient.ownerCoordinate, "notification-instance",
    );
    const body: Record<string, unknown> = {
      to: externalId,
      data: { loopdy_link: { version: 2, type: "wake", frameId } },
      collapseId: "loopdy-link-wake",
      priority: "normal",
      ttlSeconds: 300,
      policy: "ignore",
      apns: { payload: { aps: { "content-available": 1 } } },
    };
    if (!await linkWakeRecipientActive(env, accountCoordinate, recipient, source)) continue;
    // Repeat the aggregate D1 read so recipient, account, and source-host
    // authority have a common final observation before this provider POST.
    if (!await linkWakeRecipientActive(env, accountCoordinate, recipient, source)) continue;
    const recipientOwner = env.USER_LINKS?.getByName(recipient.ownerCoordinate);
    if (!recipientOwner) {
      throw new BuzzKitBackendError(503, "link_wake_recipient_unavailable");
    }
    // D1 discovers the candidate, but the recipient's serialized owner is the
    // final installation/grant authority. This RPC must remain the last awaited
    // operation before the provider request.
    await recipientOwner.authorizeNotificationEgress({
      ownerKind: "notification-instance",
      credentialId: recipient.installationId,
      authorizationEpoch: recipient.authorizationEpoch,
      now: Math.floor(Date.now() / 1_000),
      grant: {
        grantId: recipient.grantId,
        revision: recipient.grantRevision,
        expiresAt: recipient.grantExpiresAt,
      },
    });
    // The source UserLink decision is synchronous, preserving both authorities
    // immediately adjacent to the provider POST without another await.
    source.authorizeEgress();
    const created = await buzzKitRequest(env, "/v1/messages", {
      method: "POST",
      body,
      idempotencyKey: `loopdy-link-wake-${externalId}-${frameId}`,
    });
    const message = requiredObject(created.data, "buzzkit_response_invalid");
    const messageId = requiredIdentifier(message.id, "buzzkit_response_invalid");
    const readback = await buzzKitRequest(env, `/v1/messages/${encodeURIComponent(messageId)}`, {
      method: "GET",
    });
    const confirmed = requiredObject(readback.data, "buzzkit_response_invalid");
    if (confirmed.id !== messageId) throw new BuzzKitBackendError(502, "buzzkit_readback_mismatch");
    const providerStatus = requiredIdentifier(confirmed.status, "buzzkit_response_invalid");
    const counts = numericRecord(confirmed.counts);
    if ((providerStatus === "completed" || providerStatus === "canceled") && counts?.total === 0) {
      hasTerminalZeroRecipient = true;
    }
    receipts.push({
      status: created.replayed ? "duplicate" : "accepted",
      deliveryId: messageId,
      providerStatus,
      counts,
    });
  }
  // Finish fan-out before failing so one stale installation cannot prevent an
  // already accepted or later installation-scoped wake from reaching BuzzKit.
  if (hasTerminalZeroRecipient) {
    throw new BuzzKitBackendError(503, "buzzkit_wake_zero_recipients");
  }
  if (receipts.length === 0) {
    throw new BuzzKitBackendError(503, "link_wake_recipient_unavailable");
  }
  return receipts;
}

export async function sendBuzzKitLiveActivity(
  env: BuzzKitEnvironment,
  input: BuzzKitLiveActivityInput,
  authorizeEgress: BuzzKitEgressAuthorization,
): Promise<BuzzKitLiveActivityReceipt> {
  const body: Record<string, unknown> = {
    to: input.externalId,
    event: input.event,
    activityId: input.activityId,
    contentState: input.contentState,
    timestamp: input.timestamp,
    priority: "high",
    ...(input.staleDate ? { staleDate: input.staleDate } : {}),
    ...(input.dismissalDate ? { dismissalDate: input.dismissalDate } : {}),
    ...(input.alert ? { alert: input.alert } : {}),
  };
  await authorizeEgress();
  const response = await buzzKitRequest(env, "/v1/live-activities/send", { method: "POST", body });
  const value = requiredObject(response.data, "buzzkit_response_invalid");
  if (!Array.isArray(value.results) || value.results.length < 1) {
    throw new BuzzKitBackendError(502, "buzzkit_live_activity_unconfirmed");
  }
  const results = value.results.map((candidate) => requiredObject(candidate, "buzzkit_response_invalid"));
  const rejected = results.find((result) => result.ok !== true);
  if (rejected) {
    const code = typeof rejected.code === "string" ? rejected.code : "buzzkit_live_activity_rejected";
    throw new BuzzKitBackendError(502, safeCode(code));
  }
  const receiptIDs = results.map((result) => requiredIdentifier(result.id, "buzzkit_response_invalid"));
  return { status: "accepted", deliveryId: receiptIDs.join(",") };
}

export async function readBuzzKitReadiness(
  env: BuzzKitEnvironment,
  ownerCoordinate: string,
  scope: BuzzKitIdentityScope,
  currentDevice?: { tokenHash: string; environment: "sandbox" | "production" },
): Promise<BuzzKitReadiness> {
  requiredSecret(env.BUZZKIT_API_KEY, "buzzkit_server_key_unconfigured");
  requiredSecret(env.BUZZKIT_IDENTITY_SECRET, "buzzkit_identity_unconfigured");
  if (currentDevice && !/^[0-9a-f]{64}$/.test(currentDevice.tokenHash)) {
    throw new BuzzKitBackendError(422, "buzzkit_device_token_hash_invalid");
  }
  const response = await buzzKitRequest(env, "/v1/credentials?limit=100", { method: "GET" });
  const data = requiredObject(response.data, "buzzkit_response_invalid");
  const items = Array.isArray(data.items) ? data.items : [];
  const pushCredentials = items.flatMap((candidate) => {
    if (!candidate || typeof candidate !== "object") return [];
    const row = candidate as Record<string, unknown>;
    if (row.channel !== "push" || row.provider !== "apns") return [];
    if (!["unvalidated", "active", "invalid"].includes(String(row.status))) return [];
    const environment: "sandbox" | "production" | null =
      row.environment === "sandbox" || row.environment === "production"
        ? row.environment : null;
    return [{
      environment,
      status: row.status as "unvalidated" | "active" | "invalid",
      validatedAt: typeof row.validatedAt === "string" ? row.validatedAt : null,
      lastError: typeof row.lastError === "string" ? row.lastError.slice(0, 256) : null,
    }];
  });
  const externalId = await buzzKitRecipientExternalId(env, ownerCoordinate, scope);
  const subscriberResponse = await optionalBuzzKitRead(
    env,
    `/v1/subscribers/${encodeURIComponent(externalId)}`,
    { method: "GET" },
  );
  const subscriber = subscriberResponse
    ? requiredObject(subscriberResponse.data, "buzzkit_subscriber_invalid") : null;
  if (subscriber && (subscriber.externalId !== externalId || typeof subscriber.verified !== "boolean")) {
    throw new BuzzKitBackendError(502, "buzzkit_subscriber_invalid");
  }
  const subscriptions = subscriber && Array.isArray(subscriber.subscriptions) ? subscriber.subscriptions : [];
  const activeIOSPushEnvironments = subscriptions.flatMap((candidate) => {
    if (!candidate || typeof candidate !== "object") return [];
    const row = candidate as Record<string, unknown>;
    if (row.channel !== "push" || row.platform !== "ios" || row.enabled !== true
        || row.active === false || row.status !== "active" || row.deletedAt != null) return [];
    const environment = subscriptionEnvironment(row.environment);
    if (environment === null) return [];
    return [environment];
  });
  const requestedDevice = currentDevice;
  const exactMatches: Record<string, unknown>[] = [];
  for (const candidate of requestedDevice ? subscriptions : []) {
    if (!candidate || typeof candidate !== "object") continue;
    const row = candidate as Record<string, unknown>;
    const token = typeof row.token === "string" ? row.token
      : typeof row.endpoint === "string" ? row.endpoint : null;
    if (row.channel !== "push" || row.platform !== "ios"
        || subscriptionEnvironment(row.environment) !== requestedDevice!.environment || token === null) continue;
    const hash = Array.from(await sha256(token), (byte) => byte.toString(16).padStart(2, "0")).join("");
    if (hash === requestedDevice!.tokenHash) exactMatches.push(row);
  }
  if (exactMatches.length > 1) {
    throw new BuzzKitBackendError(502, "buzzkit_device_subscription_ambiguous");
  }
  const exactDevice = exactMatches[0];
  const topicSlugs: string[] = [];
  for (const expected of LOOPDY_BUZZKIT_TOPICS) {
    const topicResponse = await optionalBuzzKitRead(
      env,
      `/v1/topics/${encodeURIComponent(expected.slug)}`,
      { method: "GET" },
    );
    if (!topicResponse) continue;
    const topic = requiredObject(topicResponse.data, "buzzkit_topic_invalid");
    const channels = topic.channels;
    const offersPush = Array.isArray(channels)
      ? channels.includes("push")
      : !!channels && typeof channels === "object" && "push" in channels;
    if (topic.slug !== expected.slug || topic.name !== expected.name || !offersPush) {
      throw new BuzzKitBackendError(502, "buzzkit_topic_invalid");
    }
    topicSlugs.push(expected.slug);
  }
  return {
    configured: true,
    pushCredentials,
    subscriber: {
      identified: subscriber !== null,
      verified: subscriber?.verified === true,
      activeIOSPushEnvironments,
      ...(requestedDevice ? { currentDevice: {
        matched: exactDevice !== undefined,
        environment: requestedDevice.environment,
        enabled: exactDevice?.enabled === true,
        active: exactDevice !== undefined && exactDevice.active !== false
          && exactDevice.status === "active" && exactDevice.deletedAt == null,
        subscriptionId: typeof exactDevice?.id === "string" ? exactDevice.id : null,
      } } : {}),
    },
    topicSlugs,
  };
}

/** BuzzKit omits `environment` for production subscriptions on the wire. */
function subscriptionEnvironment(value: unknown): "sandbox" | "production" | null {
  if (value === "sandbox") return "sandbox";
  if (value === "production" || value === null || value === undefined) return "production";
  return null;
}

export async function deleteBuzzKitSubscriber(
  env: BuzzKitEnvironment,
  ownerCoordinate: string,
  scope: BuzzKitIdentityScope,
): Promise<void> {
  const externalId = await buzzKitRecipientExternalId(env, ownerCoordinate, scope);
  try {
    await buzzKitRequest(env, `/v1/subscribers/${encodeURIComponent(externalId)}`, {
      method: "DELETE",
    });
  } catch (error) {
    if (!(error instanceof BuzzKitBackendError && error.code === "buzzkit_not_found")) throw error;
  }
  const readback = await optionalBuzzKitRead(
    env,
    `/v1/subscribers/${encodeURIComponent(externalId)}`,
    { method: "GET" },
  );
  if (readback !== null) {
    throw new BuzzKitBackendError(502, "buzzkit_subscriber_revocation_unconfirmed");
  }
}

interface LinkWakeRecipientRow {
  owner_coordinate: string;
  installation_id: string;
  installation_authorization_epoch: number;
  grant_id: string;
  grant_revision: number;
  grant_expires_at: number;
}

interface LinkWakeRecipient {
  ownerCoordinate: string;
  installationId: string;
  authorizationEpoch: number;
  grantId: string;
  grantRevision: number;
  grantExpiresAt: number;
}

async function linkWakeRecipients(
  env: BuzzKitEnvironment,
  accountCoordinate: string,
): Promise<LinkWakeRecipient[]> {
  const recipients = await activeLinkWakeRecipients(env, accountCoordinate);
  if (recipients.length === 0 || recipients.length > 256
      || recipients.some((recipient) => !/^[A-Za-z0-9_-]{22,256}$/.test(recipient.ownerCoordinate)
        || !/^[A-Za-z0-9_-]{16,128}$/.test(recipient.installationId)
        || !/^[A-Za-z0-9_-]{16,128}$/.test(recipient.grantId)
        || !Number.isSafeInteger(recipient.authorizationEpoch) || recipient.authorizationEpoch < 1
        || !Number.isSafeInteger(recipient.grantRevision) || recipient.grantRevision < 1
        || !Number.isSafeInteger(recipient.grantExpiresAt) || recipient.grantExpiresAt < 1)) {
    throw new BuzzKitBackendError(503, "link_wake_recipient_unavailable");
  }
  return recipients;
}

async function linkWakeRecipientActive(
  env: BuzzKitEnvironment,
  accountCoordinate: string,
  recipient: LinkWakeRecipient,
  source: BuzzKitWakeSource,
): Promise<boolean> {
  return (await activeLinkWakeRecipients(env, accountCoordinate, recipient, source))
    .some((candidate) => candidate.ownerCoordinate === recipient.ownerCoordinate
      && candidate.installationId === recipient.installationId
      && candidate.authorizationEpoch === recipient.authorizationEpoch
      && candidate.grantId === recipient.grantId
      && candidate.grantRevision === recipient.grantRevision
      && candidate.grantExpiresAt === recipient.grantExpiresAt);
}

async function activeLinkWakeRecipients(
  env: BuzzKitEnvironment,
  accountCoordinate: string,
  recipient?: LinkWakeRecipient,
  source?: BuzzKitWakeSource,
): Promise<LinkWakeRecipient[]> {
  if (!env.ACCOUNTS) {
    throw new BuzzKitBackendError(503, "link_wake_recipient_unavailable");
  }
  // Wake authority is one aggregate D1 observation: recipient installation and
  // exact grant, bound account/device, and the source host that admitted the frame.
  const rows = await env.ACCOUNTS.prepare(`
    SELECT binding.notification_coordinate AS owner_coordinate,
      binding.installation_id,
      binding.installation_authorization_epoch,
      grant_row.grant_id,
      grant_row.revision AS grant_revision,
      grant_row.expires_at AS grant_expires_at
    FROM notification_account_installations binding
    JOIN notification_installations installation
      ON installation.installation_id=binding.installation_id
      AND installation.notification_coordinate=binding.notification_coordinate
    JOIN notification_instance_grants grant_row
      ON grant_row.notification_coordinate=binding.notification_coordinate
      AND grant_row.installation_id=binding.installation_id
      AND grant_row.authorization_epoch=binding.installation_authorization_epoch
      AND grant_row.state='active'
      AND grant_row.grant_id=(
        SELECT candidate.grant_id FROM notification_instance_grants candidate
        WHERE candidate.notification_coordinate=binding.notification_coordinate
          AND candidate.installation_id=binding.installation_id
          AND candidate.authorization_epoch=binding.installation_authorization_epoch
          AND candidate.state='active'
        ORDER BY candidate.expires_at DESC,candidate.grant_id
        LIMIT 1
      )
    JOIN device_directory device
      ON device.device_id=binding.account_device_id
      AND device.account_coordinate=binding.account_coordinate
    JOIN accounts account ON account.account_coordinate=binding.account_coordinate
    LEFT JOIN notification_installation_revocation_cleanup installation_revocation
      ON installation_revocation.installation_id=binding.installation_id
      AND installation_revocation.notification_coordinate=binding.notification_coordinate
      AND installation_revocation.authorization_epoch=binding.installation_authorization_epoch
    LEFT JOIN notification_device_revocations binding_revocation
      ON binding_revocation.device_id=binding.account_device_id
      AND binding_revocation.account_coordinate=binding.account_coordinate
    WHERE binding.account_coordinate=?
      ${recipient ? `AND binding.installation_id=?
        AND binding.notification_coordinate=?
        AND binding.installation_authorization_epoch=?
        AND grant_row.grant_id=? AND grant_row.revision=? AND grant_row.expires_at=?` : ""}
      AND installation.state='active'
      AND installation.authorization_epoch=binding.installation_authorization_epoch
      AND installation_revocation.installation_id IS NULL
      AND device.status='active' AND account.status='active'
      AND device.authorization_epoch=binding.account_authorization_epoch
      AND account.authorization_epoch=binding.account_authorization_epoch
      AND binding_revocation.device_id IS NULL
      ${source ? `AND EXISTS (
        SELECT 1 FROM device_directory source_device
        JOIN accounts source_account USING(account_coordinate)
        LEFT JOIN notification_device_revocations source_revocation
          ON source_revocation.device_id=source_device.device_id
          AND source_revocation.account_coordinate=source_device.account_coordinate
        WHERE source_device.device_id=? AND source_device.account_coordinate=?
          AND source_device.status='active' AND source_account.status='active'
          AND source_device.authorization_epoch=? AND source_account.authorization_epoch=?
          AND source_revocation.device_id IS NULL
      )` : ""}
    ORDER BY binding.notification_coordinate
    LIMIT ${recipient ? 1 : 257}`)
    .bind(
      accountCoordinate,
      ...(recipient ? [
        recipient.installationId,
        recipient.ownerCoordinate,
        recipient.authorizationEpoch,
        recipient.grantId,
        recipient.grantRevision,
        recipient.grantExpiresAt,
      ] : []),
      ...(source ? [
        source.hostDeviceId,
        accountCoordinate,
        source.authorizationEpoch,
        source.authorizationEpoch,
      ] : []),
    )
    .all<LinkWakeRecipientRow>();
  const now = Math.floor(Date.now() / 1_000);
  return rows.results
    .filter((row: LinkWakeRecipientRow) => row.grant_expires_at > now)
    .map((row: LinkWakeRecipientRow) => ({
      ownerCoordinate: row.owner_coordinate,
      installationId: row.installation_id,
      authorizationEpoch: row.installation_authorization_epoch,
      grantId: row.grant_id,
      grantRevision: row.grant_revision,
      grantExpiresAt: row.grant_expires_at,
    }));
}

async function optionalBuzzKitRead(
  env: BuzzKitEnvironment,
  path: string,
  input: { method: "GET" },
): Promise<{ data: unknown; replayed: boolean } | null> {
  try {
    return await buzzKitRequest(env, path, input);
  } catch (error) {
    if (error instanceof BuzzKitBackendError && error.code === "buzzkit_not_found") return null;
    throw error;
  }
}

function presentationFor(eventType: BuzzKitRichNotificationEvent["eventType"]) {
  switch (eventType) {
    case "session.completed":
    case "session.failed":
      return {
        topic: "chat-replies-completions", category: "LOOPDY_AGENT_UPDATE",
        actions: [{ id: "open", title: "Open", foreground: true }],
        interruptionLevel: "active", ttlSeconds: 900,
        placeholder: eventType === "session.failed" ? "A chat needs a look" : "New reply",
      };
    case "scheduled.completed":
    case "scheduled.failed":
      return {
        topic: "scheduled-tasks-deliveries", category: "LOOPDY_AGENT_UPDATE",
        actions: [{ id: "open", title: "Open", foreground: true }],
        interruptionLevel: "active", ttlSeconds: 900,
        placeholder: eventType === "scheduled.failed" ? "A scheduled task needs a look" : "A scheduled task finished",
      };
    case "approval.required":
    case "clarification.required":
      return {
        topic: "questions-approvals", category: "LOOPDY_REVIEW",
        actions: eventType === "approval.required"
          ? [{ id: "review", title: "Review", foreground: true }]
          : [{ id: "reply", title: "Reply", foreground: true, input: true, placeholder: "Reply to the agent" }],
        interruptionLevel: "timeSensitive", ttlSeconds: eventType === "approval.required" ? 60 : 300,
        placeholder: eventType === "approval.required" ? "Approval needed" : "Your agent has a question",
      };
    case "subagent.completed":
    case "subagent.failed":
      return {
        topic: "subagent-completions", category: "LOOPDY_AGENT_UPDATE",
        actions: [{ id: "open", title: "Open", foreground: true }],
        interruptionLevel: "active", ttlSeconds: 900,
        placeholder: eventType === "subagent.failed" ? "A helper needs a look" : "A helper finished",
      };
  }
}

function assertAPNsBudget(message: Record<string, unknown>): void {
  const estimate = {
    aps: {
      alert: { title: message.title, body: message.body },
      sound: message.sound,
      category: message.category,
      "mutable-content": 1,
      "thread-id": message.threadId,
    },
    ...(message.data as Record<string, unknown>),
    bk: {
      messageId: "msg_" + "x".repeat(96),
      image: message.imageUrl,
      deepLink: message.deepLink,
      action: message.action,
      category: message.category,
      actions: message.actions,
    },
  };
  if (new TextEncoder().encode(JSON.stringify(estimate)).length > MAX_APNS_PAYLOAD_BYTES) {
    throw new BuzzKitBackendError(422, "buzzkit_apns_payload_too_large");
  }
}

async function buzzKitRequest(
  env: BuzzKitEnvironment,
  path: string,
  input: { method: "GET" | "POST" | "DELETE"; body?: Record<string, unknown>; idempotencyKey?: string },
): Promise<{ data: unknown; replayed: boolean }> {
  requireIdentitySecretGeneration(env);
  const apiKey = requiredSecret(env.BUZZKIT_API_KEY, "buzzkit_server_key_unconfigured");
  const base = (env.BUZZKIT_API_URL ?? DEFAULT_API_URL).trim().replace(/\/$/, "");
  let url: URL;
  try { url = new URL(path, `${base}/`); } catch { throw new BuzzKitBackendError(503, "buzzkit_api_url_invalid"); }
  if (url.protocol !== "https:" || `${url.origin}${url.pathname}${url.search}` !== `${base}${path}`) {
    throw new BuzzKitBackendError(503, "buzzkit_api_url_invalid");
  }
  const headers = new Headers({
    Authorization: `Bearer ${apiKey}`,
    Accept: "application/json",
    "User-Agent": "Loopdy-Link-BuzzKit/1.0",
  });
  const tenant = env.BUZZKIT_TENANT?.trim();
  if (tenant) {
    if (!/^[a-z0-9][a-z0-9-]{0,62}$/.test(tenant)) throw new BuzzKitBackendError(503, "buzzkit_tenant_invalid");
    headers.set("BuzzKit-Tenant", tenant);
  }
  if (input.body) headers.set("Content-Type", "application/json");
  if (input.idempotencyKey) headers.set("Idempotency-Key", input.idempotencyKey);
  let response: Response;
  try {
    response = await fetch(url, {
      method: input.method,
      headers,
      body: input.body ? JSON.stringify(input.body) : undefined,
      signal: AbortSignal.timeout(12_000),
      redirect: "manual",
    });
  } catch {
    throw new BuzzKitBackendError(503, "buzzkit_transport_unavailable");
  }
  const bytes = await boundedResponse(response);
  let envelope: Record<string, unknown>;
  try {
    const parsed: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes));
    envelope = requiredObject(parsed, "buzzkit_response_invalid");
  } catch (error) {
    if (error instanceof BuzzKitBackendError) throw error;
    throw new BuzzKitBackendError(502, "buzzkit_response_invalid");
  }
  if (!response.ok || envelope.success !== true) {
    const vendor = envelope.error && typeof envelope.error === "object"
      ? (envelope.error as Record<string, unknown>).code : null;
    const retryable = response.status === 429 || response.status >= 500;
    throw new BuzzKitBackendError(retryable ? 503 : 422,
      `buzzkit_${safeCode(typeof vendor === "string" ? vendor : "request_rejected")}`);
  }
  return { data: envelope.data, replayed: response.headers.get("Idempotent-Replayed") === "true" };
}

function boundedResponse(response: Response): Promise<Uint8Array> {
  return readByteStream(response.body, MAX_RESPONSE_BYTES, () => {
    throw new BuzzKitBackendError(502, "buzzkit_response_too_large");
  });
}

function requiredSecret(value: string | undefined, code: string): string {
  const trimmed = value?.trim() ?? "";
  if (!trimmed) throw new BuzzKitBackendError(503, code);
  return trimmed;
}

function requireIdentitySecretGeneration(env: BuzzKitEnvironment): void {
  if (env.BUZZKIT_IDENTITY_SECRET_GENERATION?.trim() !== REQUIRED_IDENTITY_SECRET_GENERATION) {
    throw new BuzzKitBackendError(503, "buzzkit_identity_generation_unconfigured");
  }
}

export async function buzzKitRecipientExternalId(
  env: BuzzKitEnvironment,
  ownerCoordinate: string,
  scope: BuzzKitIdentityScope,
): Promise<string> {
  requireIdentitySecretGeneration(env);
  return deriveBuzzKitExternalId(ownerCoordinate, scope);
}

async function deriveBuzzKitExternalId(
  ownerCoordinate: string,
  scope: BuzzKitIdentityScope,
): Promise<string> {
  const domain = scope === "account" ? ACCOUNT_EXTERNAL_ID_DOMAIN : NOTIFICATION_EXTERNAL_ID_DOMAIN;
  const prefix = scope === "account" ? "acct_" : "notify_";
  return `${prefix}${base64URL(await sha256(`${domain}${ownerCoordinate}`))}`;
}

function requiredObject(value: unknown, code: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new BuzzKitBackendError(502, code);
  return value as Record<string, unknown>;
}

function requiredIdentifier(value: unknown, code: string): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(value)) {
    throw new BuzzKitBackendError(502, code);
  }
  return value;
}

function numericRecord(value: unknown): Record<string, number> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const result: Record<string, number> = {};
  for (const [key, item] of Object.entries(value)) {
    if (!Number.isSafeInteger(item) || Number(item) < 0) return null;
    result[key] = Number(item);
  }
  return result;
}

function safeCode(value: string): string {
  const candidate = value.toLowerCase().replace(/[^a-z0-9_-]/g, "_").slice(0, 96);
  return candidate || "request_rejected";
}

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
