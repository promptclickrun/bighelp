// src/queue.ts
function queueCoordinates(tenantId, deliveryId) {
  return { tenantId, deliveryId };
}
__name(queueCoordinates, "queueCoordinates");
function retryDelaySeconds(attempt) {
  const safeAttempt = Math.max(1, Math.floor(attempt));
  return Math.min(60, 2 ** Math.min(5, safeAttempt));
}
__name(retryDelaySeconds, "retryDelaySeconds");
var INVALID_TOKEN_REASONS = /* @__PURE__ */ new Set(["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"]);
function classifyApnsResponse(status, reason) {
  if (status >= 200 && status < 300) return { kind: "success" };
  if (status === 408 || status === 425 || status === 429 || status >= 500) return { kind: "retry" };
  if (INVALID_TOKEN_REASONS.has(reason ?? "")) return { kind: "invalid_token" };
  return { kind: "terminal" };
}
__name(classifyApnsResponse, "classifyApnsResponse");
function canRetryQueue(attempts) {
  return attempts < RELAY_LIMITS.maxQueueRetries + 1;
}
__name(canRetryQueue, "canRetryQueue");

