import {
  APNS_PAYLOAD_BYTES,
  apnsCollapseIdFor,
  apnsConfig,
  apnsIdFor,
  sendApns,
  type ApnsConfig,
  type ApnsPushType,
  type ApnsResult,
  type ApnsSecrets,
} from "./apns.js";
import {
  attachDeliveryMeta,
  BuzzKitBackendError,
  buzzKitConfigured,
  type BuzzKitEnvironment,
  type BuzzKitMessageReceipt,
  type ManagedMessage,
} from "./buzzkit.js";
import { claimPushSend, finishPushSend, handPushSendToBuzzKit, releasePushSend } from "./push-sends.js";
import {
  findPushTarget,
  markPushTargetInvalid,
  purgeExpiredPushState,
  pushTokenKeyConfigured,
  type PushTarget,
  type PushTargetEnv,
  type PushTargetLookup,
  type PushTargetKind,
} from "./push-targets.js";
import { emitRelayEvents, logPush, relayEvent, safeCode, type RelayEvent } from "./push-telemetry.js";

export type DeliveryMode = "off" | "shadow" | "on";
export type PushKind = "alert" | "wake" | "test" | "liveactivity";
type ExecCtx = Pick<ExecutionContext, "waitUntil">;

export interface DeliveryEnv extends PushTargetEnv, ApnsSecrets {
  DIRECT_APNS?: string;
  DIRECT_APNS_CANARY?: string;
  APNS_RETRY?: unknown;
  TELEMETRY?: unknown;
}

export interface DeliveryOwner {
  kind: "account" | "notification-instance";
  coordinate: string;
  /** For a notification installation, the installation ID. */
  credentialId: string;
}

/** One Live Activity update, kept in numbers so either route can send it. */
export interface LiveActivityMessage {
  event: "update" | "end";
  activityId: string;
  contentState: Record<string, unknown>;
  /** Unix seconds. */
  timestamp: number;
  staleDate: number;
  dismissalDate?: number;
}

export interface ApnsRetryMessage {
  v: 1;
  kind: "alert" | "wake" | "liveactivity";
  grantId: string;
  eventType: string;
  /** The full send key. It is also the D1 key and the source of the APNs ID. */
  dedupeKey: string;
  /** Alerts and wakes: the message in BuzzKit's shape. It holds no push token. */
  message?: { body: Record<string, unknown>; idempotencyKey: string; occurredAtMs?: number };
  live?: LiveActivityMessage & { updateId: string };
  /** Unix milliseconds of the first attempt. The push expires from here, not from each retry. */
  enqueuedAt: number;
}

/** What one direct push needs, built from the message the BuzzKit route would send. */
export interface DirectSpec {
  kind: PushKind;
  eventType: string;
  pushType: ApnsPushType;
  priority: 5 | 10;
  ttlSeconds: number;
  payload: object;
  collapseId?: string;
}

/** The wait before each queue delivery: the first, then after each failed one. */
export const RETRY_DELAYS_SECONDS = [5, 15, 45, 120, 300, 600] as const;
/** The queue's `max_retries`: six deliveries in all, then the dead-letter queue. */
export const MAX_QUEUE_RETRIES = 5;

const ALERT_PRIORITY = 10;

/** The direct path (database, provider token, both APNs tries) gives up after this. The host waits 12 s. */
export const DIRECT_DEADLINE_MS = 8_000;
/** After this many failed direct tries a message goes through BuzzKit. */
export const MAX_DIRECT_TRIES = 2;

/**
 * Whether waiting for another direct try is still worth it: it has failed fewer
 * than twice, and the next try would still land before the push expires.
 */
export function retryStillUseful(
  failedTries: number, nowSeconds: number, expirySeconds: number, nextDelaySeconds: number,
): boolean {
  return failedTries < MAX_DIRECT_TRIES && nowSeconds + nextDelaySeconds < expirySeconds;
}

// MARK: Circuit breaker

const BREAKER_THRESHOLD = 3;
const BREAKER_COOLDOWN_MS = 60_000;
/** Refusals that say something is wrong with this Worker's APNs setup, not with one token or message. */
const SETUP_REASONS = new Set([
  "bad_topic", "topic_disallowed", "missing_topic", "forbidden", "bad_certificate",
  "bad_certificate_environment", "provider_key_invalid",
]);
let breaker = { failureClass: "", count: 0, openUntil: 0 };

/** Closes the breaker. For tests. */
export function resetApnsBreaker(): void {
  breaker = { failureClass: "", count: 0, openUntil: 0 };
}

function breakerIsOpen(): boolean {
  return Date.now() < breaker.openUntil;
}

/**
 * After three setup failures in a row of the same kind, direct sends pause for a
 * minute in this isolate. Otherwise a bad key would add round trips to every send.
 */
function recordBreaker(result: ApnsResult): void {
  if (result.outcome === "sent") {
    breaker = { failureClass: "", count: 0, openUntil: 0 };
    return;
  }
  const failureClass = result.outcome === "provider_token" ? "provider_token"
    : result.outcome === "rejected" && SETUP_REASONS.has(result.reason) ? result.reason : null;
  if (!failureClass) return;
  breaker.count = breaker.failureClass === failureClass ? breaker.count + 1 : 1;
  breaker.failureClass = failureClass;
  if (breaker.count >= BREAKER_THRESHOLD) {
    breaker.openUntil = Date.now() + BREAKER_COOLDOWN_MS;
    breaker.count = 0;
  }
}

/** True while direct sends are paused. */
export function apnsBreakerOpen(): boolean {
  return breakerIsOpen();
}

export function deliveryMode(env: { DIRECT_APNS?: string }): DeliveryMode {
  const value = env.DIRECT_APNS?.trim().toLowerCase();
  return value === "on" || value === "shadow" ? value : "off";
}

function canaryInstallations(env: { DIRECT_APNS_CANARY?: string }): Set<string> {
  return new Set((env.DIRECT_APNS_CANARY ?? "").split(/[\s,]+/)
    .map((value) => value.trim().toLowerCase()).filter(Boolean));
}

/** The full key for one send: unique per installation, kind and the host's own key. */
export function sendKey(installationId: string, kind: PushKind, key: string): string {
  return `${installationId}|${kind}|${key}`;
}

function targetKindFor(kind: PushKind): PushTargetKind {
  return kind === "liveactivity" ? "liveactivity" : "alert";
}

export function hostToWorkerMs(occurredAtMs: number | undefined, nowMs = Date.now()): number | undefined {
  if (occurredAtMs === undefined) return undefined;
  return Math.min(86_400_000, Math.max(0, Math.round(nowMs - occurredAtMs)));
}

/** True for a sealed alert: only the phone can read its text. */
export function isSealedMessage(body: Record<string, unknown>): boolean {
  const loopdy = (body.data as { loopdy?: { sealed?: unknown } } | undefined)?.loopdy;
  return Boolean(loopdy && typeof loopdy.sealed === "object" && loopdy.sealed !== null);
}

// MARK: Payloads

/**
 * The payload BuzzKit would deliver for this message, built here so the phone
 * runs the same code for both routes. Returns null when it won't fit in a push.
 */
export async function messageSpec(
  kind: "alert" | "wake" | "test",
  eventType: string,
  message: { body: Record<string, unknown>; idempotencyKey?: string; occurredAtMs?: number },
  sentAt: number,
): Promise<DirectSpec | null> {
  const body = attachDeliveryMeta(message.body, "direct", sentAt, message.occurredAtMs);
  const data = body.data as Record<string, unknown>;
  const ttlSeconds = Number(body.ttlSeconds);
  let spec: DirectSpec;
  if (kind === "wake") {
    spec = {
      kind, eventType, pushType: "background", priority: 5, ttlSeconds,
      payload: { aps: { "content-available": 1 }, ...data },
      ...(typeof body.collapseId === "string" ? { collapseId: body.collapseId } : {}),
    };
  } else if (kind === "test") {
    spec = {
      kind, eventType, pushType: "alert", priority: ALERT_PRIORITY, ttlSeconds,
      payload: {
        aps: {
          alert: { title: body.title, body: body.body },
          sound: body.sound ?? "default",
          "mutable-content": 1,
        },
        ...data,
      },
    };
  } else {
    if (!message.idempotencyKey) return null;
    const level = body.interruptionLevel === "timeSensitive" ? "time-sensitive" : body.interruptionLevel;
    spec = {
      kind, eventType, pushType: "alert", priority: ALERT_PRIORITY, ttlSeconds,
      payload: {
        aps: {
          alert: { title: body.title, body: body.body },
          ...(body.sound ? { sound: body.sound } : {}),
          category: body.category,
          "mutable-content": 1,
          "thread-id": body.threadId,
          "interruption-level": level,
        },
        ...data,
        bk: {
          deepLink: body.deepLink,
          action: body.action,
          category: body.category,
          actions: body.actions,
          ...(body.imageUrl ? { image: body.imageUrl } : {}),
        },
      },
      collapseId: await apnsCollapseIdFor(message.idempotencyKey),
    };
  }
  if (!Number.isSafeInteger(ttlSeconds) || ttlSeconds < 1) return null;
  return new TextEncoder().encode(JSON.stringify(spec.payload)).length <= APNS_PAYLOAD_BYTES ? spec : null;
}

/** A Live Activity update as APNs wants it. Dates are Unix seconds. */
export function liveActivitySpec(live: LiveActivityMessage, nowSeconds: number): DirectSpec | null {
  const spec: DirectSpec = {
    kind: "liveactivity", eventType: "liveactivity", pushType: "liveactivity", priority: ALERT_PRIORITY,
    // An update is worthless once the card is stale.
    ttlSeconds: Math.min(3_600, Math.max(60, live.staleDate - nowSeconds)),
    payload: {
      aps: {
        timestamp: live.timestamp,
        event: live.event,
        "content-state": live.contentState,
        "stale-date": live.staleDate,
        ...(live.event === "end" && live.dismissalDate !== undefined
          ? { "dismissal-date": live.dismissalDate } : {}),
      },
    },
  };
  return new TextEncoder().encode(JSON.stringify(spec.payload)).length <= APNS_PAYLOAD_BYTES ? spec : null;
}

// MARK: Choosing

type Route = { via: "buzzkit" } | { via: "direct"; config: ApnsConfig; target: PushTarget };

/**
 * Direct only when the flag, the secrets, the owner and a live target all agree.
 * With the flag off nothing here touches the database.
 */
async function chooseRoute(
  env: DeliveryEnv,
  ctx: ExecCtx | undefined,
  owner: DeliveryOwner,
  kind: PushKind,
  eventType: string,
  activityId: string,
): Promise<Route> {
  const mode = deliveryMode(env);
  if (mode === "off" || owner.kind !== "notification-instance") return { via: "buzzkit" };
  const config = apnsConfig(env);
  if (!config || !pushTokenKeyConfigured(env)) {
    fallbackEvent(env, ctx, "apns_unconfigured");
    return { via: "buzzkit" };
  }
  const canary = canaryInstallations(env).has(owner.credentialId.toLowerCase());
  if (mode === "on" || canary) {
    if (breakerIsOpen()) {
      fallbackEvent(env, ctx, "apns_breaker_open");
      return { via: "buzzkit" };
    }
  }
  const nowSeconds = Math.floor(Date.now() / 1_000);
  let lookup: PushTargetLookup;
  try {
    lookup = await findPushTarget(
      env, { installationId: owner.credentialId, ownerCoordinate: owner.coordinate },
      targetKindFor(kind), activityId, nowSeconds,
    );
  } catch {
    // Whatever went wrong, the alert still goes out the way it always has.
    fallbackEvent(env, ctx, "target_lookup_failed");
    return { via: "buzzkit" };
  }
  if (mode === "shadow" && !canary) {
    // Say what would have happened, and send as before.
    if (lookup.status === "found") {
      emitRelayEvents(env, ctx, [relayEvent("push.shadow", { eventType, wouldUseDirect: true })]);
    }
    return { via: "buzzkit" };
  }
  if (lookup.status !== "found") {
    fallbackEvent(env, ctx, lookup.status === "unreadable" ? "target_unreadable" : "no_target");
    return { via: "buzzkit" };
  }
  // Without the person's muted topics the Worker can't honour them, as BuzzKit does.
  if (lookup.target.kind === "alert" && lookup.target.mutedTopics === null) {
    fallbackEvent(env, ctx, "target_incomplete");
    return { via: "buzzkit" };
  }
  return { via: "direct", config, target: lookup.target };
}

function fallbackEvent(env: DeliveryEnv, ctx: ExecCtx | undefined, reason: string): void {
  logPush("fallback_buzzkit", reason);
  emitRelayEvents(env, ctx, [relayEvent("push.fallback_buzzkit", { reason: safeCode(reason) })]);
}

// MARK: One direct attempt

export interface DirectAttemptInput {
  env: DeliveryEnv;
  owner: DeliveryOwner;
  config: ApnsConfig;
  target: PushTarget;
  spec: DirectSpec;
  apnsId: string;
  /** Unix seconds of the first attempt; the push expires at this plus its TTL. */
  startedAt: number;
  attempt: number;
  hostToWorkerMs?: number;
  deadlineAt?: number;
  authorize: () => Promise<void>;
}

/**
 * Sends one push and records what happened. A token APNs no longer accepts is
 * marked invalid here. Whether to queue, fall back or give up is the caller's.
 */
export async function directAttempt(input: DirectAttemptInput, events: RelayEvent[]): Promise<ApnsResult> {
  const { spec, target } = input;
  const result = await sendApns({
    config: input.config,
    environment: target.environment,
    tokenHex: target.token,
    pushType: spec.pushType,
    priority: spec.priority,
    expiration: input.startedAt + spec.ttlSeconds,
    apnsId: input.apnsId,
    ...(spec.collapseId ? { collapseId: spec.collapseId } : {}),
    payload: spec.payload,
    ...(input.deadlineAt !== undefined ? { deadlineAt: input.deadlineAt } : {}),
    authorize: input.authorize,
  });
  recordBreaker(result);
  events.push(relayEvent("push.sent", {
    eventType: spec.eventType,
    path: "direct",
    priority: spec.priority,
    result: safeCode(result.outcome === "sent" ? "sent" : result.reason),
    status: result.status,
    environment: target.environment,
    ...(input.hostToWorkerMs !== undefined ? { hostToWorkerMs: input.hostToWorkerMs } : {}),
    providerMs: Math.min(86_400_000, result.providerMs),
    attempt: input.attempt,
  }));
  if (result.outcome === "token_invalid") {
    try {
      await markPushTargetInvalid(input.env, input.owner.credentialId, target, Math.floor(Date.now() / 1_000));
    } catch { /* the next send finds the same answer from APNs */ }
    logPush("token_invalid", result.reason);
    events.push(relayEvent("push.token_invalid", { kind: target.kind, reason: safeCode(result.reason) }));
  } else if (result.outcome !== "sent") {
    logPush("not_sent", `${result.outcome}_${result.reason}`);
  }
  return result;
}

/** The reason a failed direct attempt goes to BuzzKit. */
export function fallbackReason(result: ApnsResult): string {
  switch (result.outcome) {
    case "token_invalid": return "token_invalid";
    case "provider_token": return "provider_token";
    case "retryable": return "no_queue";
    default: return `apns_${result.reason}`;
  }
}

interface DirectRun {
  env: DeliveryEnv;
  ctx?: ExecCtx;
  owner: DeliveryOwner;
  route: { config: ApnsConfig; target: PushTarget };
  spec: DirectSpec;
  dedupeKey: string;
  apnsId: string;
  authorize: () => Promise<void>;
  hostToWorkerMs?: number;
  /** Unix milliseconds the whole direct path must end by. */
  deadlineAt: number;
  /** Set when a transient failure may wait in the retry queue. */
  retry?: ApnsRetryMessage;
  /** Why a transient failure goes to BuzzKit instead of the queue. */
  noQueueReason: string;
}

type DirectOutcome =
  | { done: true; status: "accepted" | "duplicate"; providerStatus: "sent" | "queued" }
  | { done: false };

async function runDirect(run: DirectRun): Promise<DirectOutcome> {
  const { env, spec, dedupeKey } = run;
  const nowSeconds = Math.floor(Date.now() / 1_000);
  let claim: Awaited<ReturnType<typeof claimPushSend>>;
  try {
    claim = await claimPushSend(env, run.owner.credentialId, dedupeKey, run.apnsId, nowSeconds);
  } catch {
    fallbackEvent(env, run.ctx, "claim_failed");
    return { done: false };
  }
  if (claim.status === "duplicate") {
    return { done: true, status: "duplicate", providerStatus: claim.state === "sent" ? "sent" : "queued" };
  }
  // Another request is sending this message right now. Nothing has been sent that this
  // answer could stand for, so say "try again": the host retries a 503 and never drops
  // its grant for it.
  if (claim.status === "in_flight") throw new BuzzKitBackendError(503, "push_in_flight");
  // An earlier attempt gave this message to BuzzKit, which deduplicates by the same key.
  if (claim.status === "buzzkit") return { done: false };
  if (Math.random() < 1 / 16) {
    const purge = purgeExpiredPushState(env, nowSeconds).catch(() => undefined);
    try { run.ctx?.waitUntil(purge); } catch { /* nothing to wait for */ }
  }
  const events: RelayEvent[] = [];
  let outcome: DirectOutcome = { done: false };
  // Release the claim unless the message was sent, queued or handed to BuzzKit.
  let release = true;
  try {
    const result = await directAttempt({
      env, owner: run.owner, config: run.route.config, target: run.route.target, spec,
      apnsId: run.apnsId, startedAt: nowSeconds, attempt: 1, deadlineAt: run.deadlineAt,
      ...(run.hostToWorkerMs !== undefined ? { hostToWorkerMs: run.hostToWorkerMs } : {}),
      authorize: run.authorize,
    }, events);
    let fallback: string | null = null;
    if (result.outcome === "sent") {
      await finishPushSend(env, dedupeKey, "sent").catch(() => undefined);
      release = false;
      outcome = { done: true, status: "accepted", providerStatus: "sent" };
    } else if (result.outcome === "retryable" && run.retry) {
      if (retryStillUseful(1, nowSeconds, nowSeconds + spec.ttlSeconds, RETRY_DELAYS_SECONDS[0])
          && await enqueueRetry(env, run.retry, RETRY_DELAYS_SECONDS[0])) {
        await finishPushSend(env, dedupeKey, "queued").catch(() => undefined);
        release = false;
        events.push(relayEvent("push.retry", { attempt: 1, reason: safeCode(result.reason) }));
        logPush("retry", result.reason);
        outcome = { done: true, status: "accepted", providerStatus: "queued" };
      } else {
        fallback = "queue_unavailable";
      }
    } else if (result.outcome === "retryable") {
      fallback = run.noQueueReason;
    } else {
      fallback = fallbackReason(result);
    }
    if (fallback) {
      events.push(relayEvent("push.fallback_buzzkit", { reason: safeCode(fallback) }));
      logPush("fallback_buzzkit", fallback);
      // A repeat of this message goes to BuzzKit too, so the phone can't get it twice.
      if (await handPushSendToBuzzKit(env, dedupeKey).then(() => true, () => false)) release = false;
    }
    return outcome;
  } finally {
    if (release) await releasePushSend(env, dedupeKey).catch(() => undefined);
    emitRelayEvents(env, run.ctx, events);
  }
}

async function enqueueRetry(env: DeliveryEnv, message: ApnsRetryMessage, delaySeconds: number): Promise<boolean> {
  const queue = env.APNS_RETRY as { send?: (body: unknown, options?: { delaySeconds?: number }) => Promise<void> } | undefined;
  if (!queue || typeof queue.send !== "function") return false;
  try {
    await queue.send(message, { delaySeconds });
    return true;
  } catch {
    return false;
  }
}

// MARK: The BuzzKit route, timed

async function viaBuzzKit<T>(
  env: DeliveryEnv,
  ctx: ExecCtx | undefined,
  info: { eventType: string; priority: 5 | 10; hostToWorkerMs?: number },
  send: () => Promise<T>,
  outcome: (value: T) => string,
): Promise<T> {
  const startedAt = Date.now();
  const base = {
    eventType: info.eventType, path: "buzzkit", priority: info.priority,
    ...(info.hostToWorkerMs !== undefined ? { hostToWorkerMs: info.hostToWorkerMs } : {}),
    attempt: 1,
  };
  try {
    const result = await send();
    emitRelayEvents(env, ctx, [relayEvent("push.sent", {
      ...base, result: safeCode(outcome(result)), status: 200, providerMs: Date.now() - startedAt,
    })]);
    return result;
  } catch (error) {
    const code = error && typeof error === "object" && "code" in error
      ? String((error as { code: unknown }).code) : "error";
    const status = error && typeof error === "object" && "status" in error
      && Number.isSafeInteger((error as { status: unknown }).status)
      ? Number((error as { status: number }).status) : 0;
    emitRelayEvents(env, ctx, [relayEvent("push.sent", {
      ...base, result: safeCode(code), status, providerMs: Date.now() - startedAt,
    })]);
    throw error;
  }
}

// MARK: Public entry points

export interface DeliverMessageInput {
  env: DeliveryEnv;
  ctx?: ExecCtx;
  owner: DeliveryOwner;
  grantId: string;
  kind: "alert" | "wake";
  /** The event type for an alert, otherwise `wake`. */
  eventType: string;
  message: ManagedMessage;
  authorize: () => Promise<void>;
  /** The BuzzKit send for this same message. */
  sendViaBuzzKit: () => Promise<BuzzKitMessageReceipt>;
}

/** Delivers a sealed or rich alert, or the sign-in wake, by the best route. */
export async function deliverMessage(input: DeliverMessageInput): Promise<BuzzKitMessageReceipt> {
  const { env, ctx, owner, kind, eventType, message } = input;
  const deadlineAt = Date.now() + DIRECT_DEADLINE_MS;
  const priority = kind === "wake" ? 5 : ALERT_PRIORITY;
  const hostMs = hostToWorkerMs(message.occurredAtMs);
  const info = { eventType, priority, ...(hostMs !== undefined ? { hostToWorkerMs: hostMs } : {}) } as const;
  const route = await chooseRoute(env, ctx, owner, kind, eventType, "");
  if (route.via === "buzzkit") return viaBuzzKit(env, ctx, info, input.sendViaBuzzKit, (value) => value.status);

  const spec = await messageSpec(kind, eventType, message, Date.now());
  if (!spec) {
    fallbackEvent(env, ctx, "payload_too_large");
    return viaBuzzKit(env, ctx, info, input.sendViaBuzzKit, (value) => value.status);
  }
  const dedupeKey = sendKey(owner.credentialId, kind, message.idempotencyKey);
  const apnsId = await apnsIdFor(dedupeKey);
  // A topic this person turned off. Wakes ignore topics.
  const topic = message.body.topic;
  if (kind === "alert" && typeof topic === "string" && route.target.mutedTopics?.includes(topic)) {
    // BuzzKit holds the person's real settings, and the Worker's list may be out of date. While
    // BuzzKit is there, let it decide, so a stale list can never hide an alert someone wants.
    if (buzzKitConfigured(env as unknown as BuzzKitEnvironment)) {
      fallbackEvent(env, ctx, "topic_muted");
      return viaBuzzKit(env, ctx, info, input.sendViaBuzzKit, (value) => value.status);
    }
    return {
      status: "accepted", deliveryId: apnsId, providerStatus: "suppressed", counts: { total: 0, sent: 0 },
    };
  }
  // A rich alert's text is plain. It is never put on a queue.
  const sealed = kind === "wake" || isSealedMessage(message.body);
  const outcome = await runDirect({
    env, ctx, owner, route, spec, dedupeKey, apnsId, authorize: input.authorize, deadlineAt,
    ...(hostMs !== undefined ? { hostToWorkerMs: hostMs } : {}),
    noQueueReason: "plaintext_not_queued",
    ...(sealed ? { retry: {
      v: 1 as const, kind, grantId: input.grantId, eventType, dedupeKey,
      message: {
        body: message.body, idempotencyKey: message.idempotencyKey,
        ...(message.occurredAtMs !== undefined ? { occurredAtMs: message.occurredAtMs } : {}),
      },
      enqueuedAt: Date.now(),
    } } : {}),
  });
  if (!outcome.done) return viaBuzzKit(env, ctx, info, input.sendViaBuzzKit, (value) => value.status);
  return {
    status: outcome.status,
    deliveryId: apnsId,
    providerStatus: outcome.providerStatus,
    counts: outcome.providerStatus === "sent" ? { total: 1, sent: 1 } : null,
  };
}

export interface DeliverTestInput {
  env: DeliveryEnv;
  ctx?: ExecCtx;
  owner: DeliveryOwner;
  requestId: string;
  body: Record<string, unknown>;
  authorize: () => Promise<void>;
  sendViaBuzzKit: () => Promise<{ id: string; state: "accepted" | "failed"; providerStatus: string }>;
}

/** The test notification. A transient APNs failure falls back at once: the person is waiting. */
export async function deliverTest(
  input: DeliverTestInput,
): Promise<{ id: string; state: "accepted" | "failed"; providerStatus: string }> {
  const { env, ctx, owner } = input;
  const deadlineAt = Date.now() + DIRECT_DEADLINE_MS;
  const info = { eventType: "test", priority: ALERT_PRIORITY } as const;
  const route = await chooseRoute(env, ctx, owner, "test", "test", "");
  if (route.via === "buzzkit") return viaBuzzKit(env, ctx, info, input.sendViaBuzzKit, (value) => value.state);
  const spec = await messageSpec("test", "test", { body: input.body }, Date.now());
  if (!spec) {
    fallbackEvent(env, ctx, "payload_too_large");
    return viaBuzzKit(env, ctx, info, input.sendViaBuzzKit, (value) => value.state);
  }
  const dedupeKey = sendKey(owner.credentialId, "test", input.requestId);
  const apnsId = await apnsIdFor(dedupeKey);
  const outcome = await runDirect({
    env, ctx, owner, route, spec, dedupeKey, apnsId, authorize: input.authorize, deadlineAt,
    noQueueReason: "not_queued",
  });
  if (!outcome.done) return viaBuzzKit(env, ctx, info, input.sendViaBuzzKit, (value) => value.state);
  return { id: apnsId, state: "accepted", providerStatus: outcome.providerStatus };
}

export interface DeliverLiveActivityInput {
  env: DeliveryEnv;
  ctx?: ExecCtx;
  owner: DeliveryOwner;
  grantId: string;
  updateId: string;
  live: LiveActivityMessage;
  authorize: () => Promise<void>;
  sendViaBuzzKit: () => Promise<{ status: "accepted"; deliveryId: string }>;
}

/** One Live Activity update, by the best route. */
export async function deliverLiveActivity(
  input: DeliverLiveActivityInput,
): Promise<{ status: "accepted" | "duplicate"; deliveryId: string }> {
  const { env, ctx, owner, live } = input;
  const deadlineAt = Date.now() + DIRECT_DEADLINE_MS;
  const info = { eventType: "liveactivity", priority: ALERT_PRIORITY } as const;
  const route = await chooseRoute(env, ctx, owner, "liveactivity", "liveactivity", live.activityId);
  if (route.via === "buzzkit") return viaBuzzKit(env, ctx, info, input.sendViaBuzzKit, (value) => value.status);
  const nowSeconds = Math.floor(Date.now() / 1_000);
  const spec = liveActivitySpec(live, nowSeconds);
  if (!spec) {
    fallbackEvent(env, ctx, "payload_too_large");
    return viaBuzzKit(env, ctx, info, input.sendViaBuzzKit, (value) => value.status);
  }
  const dedupeKey = sendKey(owner.credentialId, "liveactivity", `${live.activityId}|${input.updateId}`);
  const apnsId = await apnsIdFor(dedupeKey);
  const outcome = await runDirect({
    env, ctx, owner, route, spec, dedupeKey, apnsId, authorize: input.authorize, deadlineAt,
    noQueueReason: "no_queue",
    retry: {
      v: 1, kind: "liveactivity", grantId: input.grantId, eventType: "liveactivity", dedupeKey,
      live: { ...live, updateId: input.updateId },
      enqueuedAt: Date.now(),
    },
  });
  if (!outcome.done) return viaBuzzKit(env, ctx, info, input.sendViaBuzzKit, (value) => value.status);
  return { status: outcome.status, deliveryId: apnsId };
}
