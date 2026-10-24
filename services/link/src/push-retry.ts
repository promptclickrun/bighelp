import { apnsConfig, apnsIdFor } from "./apns.js";
import {
  BuzzKitBackendError,
  buzzKitRecipientExternalId,
  sendBuzzKitLiveActivity,
  sendBuzzKitMessage,
} from "./buzzkit.js";
import {
  loadNotificationGrant,
  NotificationError,
  notificationStateBinding,
  requireActiveGrant,
  requireNotificationActivityEgressActive,
  requireNotificationEgressActive,
  type NotificationActivity,
} from "./notification-grants.js";
import {
  apnsBreakerOpen,
  directAttempt,
  fallbackReason,
  isSealedMessage,
  liveActivitySpec,
  MAX_QUEUE_RETRIES,
  messageSpec,
  RETRY_DELAYS_SECONDS,
  retryStillUseful,
  type ApnsRetryMessage,
  type DeliveryEnv,
  type DirectSpec,
} from "./push-delivery.js";
import { finishPushSend, handPushSendToBuzzKit, pushSendState, releasePushSend } from "./push-sends.js";
import { findPushTarget, purgeExpiredPushState } from "./push-targets.js";
import { emitRelayEvents, logPush, relayEvent, safeCode, type RelayEvent } from "./push-telemetry.js";
import type { LinkEnv } from "./user-link.js";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const CODE = /^[a-z][a-z0-9._]{0,63}$/;
const IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;

/** The retry message, or null when it isn't one this Worker wrote. */
export function parseRetryMessage(value: unknown): ApnsRetryMessage | null {
  if (!value || typeof value !== "object") return null;
  const body = value as Record<string, unknown>;
  if (body.v !== 1 || (body.kind !== "alert" && body.kind !== "wake" && body.kind !== "liveactivity")
      || typeof body.grantId !== "string" || !UUID.test(body.grantId)
      || typeof body.eventType !== "string" || !CODE.test(body.eventType)
      || typeof body.dedupeKey !== "string" || body.dedupeKey.length > 700
      || !Number.isSafeInteger(body.enqueuedAt) || Number(body.enqueuedAt) < 1) return null;
  if (body.kind === "liveactivity") {
    const live = body.live as Record<string, unknown> | undefined;
    if (!live || typeof live !== "object" || (live.event !== "update" && live.event !== "end")
        || typeof live.activityId !== "string" || !IDENTIFIER.test(live.activityId)
        || typeof live.updateId !== "string" || live.updateId.length > 128
        || !live.contentState || typeof live.contentState !== "object"
        || !Number.isSafeInteger(live.timestamp) || !Number.isSafeInteger(live.staleDate)
        || (live.dismissalDate !== undefined && !Number.isSafeInteger(live.dismissalDate))) return null;
    return body as unknown as ApnsRetryMessage;
  }
  const message = body.message as Record<string, unknown> | undefined;
  if (!message || typeof message !== "object" || !message.body || typeof message.body !== "object"
      || typeof message.idempotencyKey !== "string" || message.idempotencyKey.length > 300
      || (message.occurredAtMs !== undefined && !Number.isSafeInteger(message.occurredAtMs))) return null;
  // Only a sealed alert may wait on a queue: a rich alert's text is plain.
  if (body.kind === "alert" && !isSealedMessage(message.body as Record<string, unknown>)) return null;
  return body as unknown as ApnsRetryMessage;
}

/**
 * Sends the pushes that APNs could not take the first time. Every attempt asks
 * for egress authority again and opens the stored token again, so a phone that
 * signed out in the meantime gets nothing. The last attempt falls back to
 * BuzzKit, and a message nothing could deliver ends in the dead-letter queue.
 */
export async function handleApnsRetryBatch(
  batch: MessageBatch<unknown>,
  env: LinkEnv,
  ctx: ExecutionContext,
): Promise<void> {
  await purgeExpiredPushState(env, Math.floor(Date.now() / 1_000)).catch(() => undefined);
  for (const message of batch.messages) {
    const events: RelayEvent[] = [];
    try {
      await processOne(message, env, events);
    } catch {
      // Something unexpected (a database or provider hiccup). Try again later, or give up.
      logPush("retry_error", "unexpected");
      if (message.attempts > MAX_QUEUE_RETRIES) {
        events.push(relayEvent("push.dlq", { reason: "unexpected" }));
        logPush("dlq", "unexpected");
      }
      message.retry({ delaySeconds: backoff(message.attempts) });
    } finally {
      emitRelayEvents(env, ctx, events);
    }
  }
}

function backoff(attempts: number): number {
  return RETRY_DELAYS_SECONDS[Math.min(Math.max(attempts, 1), RETRY_DELAYS_SECONDS.length - 1)]!;
}

async function processOne(message: Message<unknown>, env: LinkEnv, events: RelayEvent[]): Promise<void> {
  const retry = parseRetryMessage(message.body);
  if (!retry) {
    logPush("retry_dropped", "message_invalid");
    message.ack();
    return;
  }
  const deliveryEnv = env as unknown as DeliveryEnv;
  const dedupeKey = retry.dedupeKey;
  const drop = async (reason: string): Promise<void> => {
    logPush("retry_dropped", reason);
    await releasePushSend(deliveryEnv, dedupeKey).catch(() => undefined);
    message.ack();
  };
  const nowSeconds = Math.floor(Date.now() / 1_000);
  const finalAttempt = message.attempts > MAX_QUEUE_RETRIES;

  // The grant and installation must still be live before any token is opened.
  let row: Awaited<ReturnType<typeof loadNotificationGrant>>;
  try {
    row = await loadNotificationGrant(env, retry.grantId);
    await requireActiveGrant(env, row, nowSeconds);
  } catch (error) {
    if (error instanceof NotificationError) return drop("grant_inactive");
    throw error;
  }
  if (row.owner_kind !== "notification-instance" || !dedupeKey.startsWith(`${row.credential_id}|`)) {
    return drop("owner_invalid");
  }
  const owner = { kind: row.owner_kind, coordinate: row.owner_coordinate, credentialId: row.credential_id };
  const sendState = await pushSendState(deliveryEnv, dedupeKey).catch(() => null);
  if (sendState === "sent") {
    message.ack();
    return;
  }

  let activity: NotificationActivity | undefined;
  if (retry.kind === "liveactivity" && retry.live) {
    try {
      activity = await notificationStateBinding(env, row.owner_coordinate).notificationActivity({
        grantId: retry.grantId, activityId: retry.live.activityId, now: nowSeconds,
      });
    } catch { return drop("activity_unknown"); }
    if (activity.status !== "active" || activity.leaseExpires <= nowSeconds) return drop("activity_inactive");
  }
  const authorize = activity
    ? () => requireNotificationActivityEgressActive(env, row, activity!)
    : () => requireNotificationEgressActive(env, row);

  const startedAt = Math.floor(retry.enqueuedAt / 1_000);
  let spec: DirectSpec | null;
  if (retry.kind === "liveactivity" && retry.live) {
    spec = liveActivitySpec(retry.live, startedAt);
  } else if (retry.message) {
    spec = await messageSpec(retry.kind as "alert" | "wake", retry.eventType, retry.message, Date.now());
  } else {
    spec = null;
  }
  if (!spec) return drop("payload_invalid");
  const expiry = startedAt + spec.ttlSeconds;
  if (expiry <= nowSeconds) return drop("expired");

  const fallBack = async (reason: string): Promise<void> => {
    events.push(relayEvent("push.fallback_buzzkit", { reason: safeCode(reason) }));
    logPush("fallback_buzzkit", reason);
    // A repeat of this message goes to BuzzKit too, which deduplicates by the same key.
    await handPushSendToBuzzKit(deliveryEnv, dedupeKey).catch(() => undefined);
    try {
      let status: string;
      if (retry.kind === "liveactivity" && retry.live) {
        const live = retry.live;
        await sendBuzzKitLiveActivity(env, {
          externalId: await buzzKitRecipientExternalId(env, row.owner_coordinate, row.owner_kind),
          activityId: live.activityId,
          event: live.event,
          contentState: live.contentState,
          timestamp: live.timestamp,
          staleDate: new Date(live.staleDate * 1_000).toISOString(),
          ...(live.event === "end" && live.dismissalDate !== undefined
            ? { dismissalDate: new Date(live.dismissalDate * 1_000).toISOString() } : {}),
        }, authorize);
        status = "accepted";
      } else {
        const sent = await sendBuzzKitMessage(
          env, row.owner_coordinate, row.owner_kind, retry.message!, authorize,
        );
        status = sent.status;
      }
      events.push(relayEvent("push.sent", {
        eventType: spec!.eventType, path: "buzzkit", priority: spec!.priority,
        result: safeCode(status), status: 200, attempt: message.attempts + 1,
      }));
      await finishPushSend(deliveryEnv, dedupeKey, "sent").catch(() => undefined);
      message.ack();
    } catch (error) {
      if (error instanceof NotificationError) return drop("egress_denied");
      const code = error instanceof BuzzKitBackendError ? error.code : "error";
      if (finalAttempt) {
        events.push(relayEvent("push.dlq", { reason: safeCode(code) }));
        logPush("dlq", code);
        await releasePushSend(deliveryEnv, dedupeKey).catch(() => undefined);
        message.retry();
      } else if (nowSeconds + backoff(message.attempts) >= expiry) {
        // The push would be stale by the next try.
        return drop("expired");
      } else {
        message.retry({ delaySeconds: backoff(message.attempts) });
      }
    }
  };

  // A repeat from the host already gave this message to BuzzKit.
  if (sendState === "buzzkit") return fallBack("already_with_buzzkit");
  if (apnsBreakerOpen()) return fallBack("apns_breaker_open");

  const config = apnsConfig(env);
  if (!config) return fallBack("apns_unconfigured");
  const lookup = await findPushTarget(
    env, { installationId: owner.credentialId, ownerCoordinate: owner.coordinate }, spec.kind === "liveactivity"
      ? "liveactivity" : "alert", retry.live?.activityId ?? "", nowSeconds,
  );
  if (lookup.status !== "found") return fallBack(lookup.status === "unreadable" ? "target_unreadable" : "no_target");
  const target = lookup.target;
  if (target.kind === "alert" && target.mutedTopics === null) return fallBack("target_incomplete");
  // The person may have muted this topic while the message waited.
  const topic = retry.message?.body.topic;
  if (retry.kind === "alert" && typeof topic === "string" && target.mutedTopics?.includes(topic)) {
    await finishPushSend(deliveryEnv, dedupeKey, "sent").catch(() => undefined);
    message.ack();
    return;
  }

  let result;
  try {
    result = await directAttempt({
      env: deliveryEnv, owner, config, target, spec, apnsId: await apnsIdFor(dedupeKey), startedAt,
      attempt: message.attempts + 1, authorize,
    }, events);
  } catch (error) {
    if (error instanceof NotificationError) return drop("egress_denied");
    throw error;
  }
  if (result.outcome === "sent") {
    await finishPushSend(deliveryEnv, dedupeKey, "sent").catch(() => undefined);
    message.ack();
    return;
  }
  if (result.outcome === "retryable") {
    // The first try was inline, so this was the second failure or later. One more wait is only
    // worth it if the push would still be fresh, and the rule keeps it to two tries in all.
    const delay = backoff(message.attempts);
    if (retryStillUseful(message.attempts + 1, nowSeconds, expiry, delay)) {
      events.push(relayEvent("push.retry", { attempt: message.attempts + 1, reason: safeCode(result.reason) }));
      logPush("retry", result.reason);
      message.retry({ delaySeconds: delay });
      return;
    }
    return fallBack("retries_exhausted");
  }
  return fallBack(fallbackReason(result));
}
