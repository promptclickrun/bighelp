// src/link-enrollment.ts
import { WorkerEntrypoint } from "cloudflare:workers";
var LoopdyLinkEnrollmentError = class extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
    this.name = "LoopdyLinkEnrollmentError";
  }
  code;
  static {
    __name(this, "LoopdyLinkEnrollmentError");
  }
};
async function enrollLoopdyLinkDevice(env, input, now = Math.floor(Date.now() / 1e3)) {
  assertExactKeys(input, [
    "deviceId",
    "revision",
    "pushToken",
    "recipientPublicKey",
    "recipientKeyId",
    "environment",
    "topic"
  ]);
  const tenant = requiredLinkTenant(env);
  const leaseExpires = now + 2592e3;
  let registration;
  try {
    registration = RelayDeviceRegistrationRequestV1.parse({
      version: 1,
      device_id: input.deviceId,
      revision: input.revision,
      issued: now,
      lease_expires: leaseExpires,
      provider: "relay",
      recipient_public_key: input.recipientPublicKey,
      recipient_key_id: input.recipientKeyId,
      push_token: input.pushToken,
      environment: input.environment,
      topic: input.topic,
      label: "",
      groups: [],
      idempotency_key: crypto.randomUUID()
    });
  } catch {
    throw new LoopdyLinkEnrollmentError(
      "link_enrollment_invalid",
      "Loopdy Link APNs enrollment is invalid"
    );
  }
  if (!tenant.allowed_topics.includes(registration.topic)) {
    throw new LoopdyLinkEnrollmentError(
      "link_topic_not_allowed",
      "Loopdy Link APNs topic is not allowed"
    );
  }
  await ensureTenant(env.DB, tenant.tenant_id, now);
  const existing = await getDevice(env.DB, tenant.tenant_id, registration.device_id);
  if (existing && existing.revoked_at === null && existing.revision === registration.revision) {
    return enrollmentResult("duplicate", input, leaseExpires, tenant);
  }
  if (existing && existing.revision >= registration.revision) {
    throw new LoopdyLinkEnrollmentError(
      "link_revision_stale",
      "Loopdy Link APNs revision is stale"
    );
  }
  try {
    await registerDevice(env.DB, {
      tenant,
      body: registration,
      keys: parseStorageKeys(env.STORAGE_ENCRYPTION_KEYS),
      now
    });
  } catch (error51) {
    if (error51 instanceof StorageConflictError) {
      throw new LoopdyLinkEnrollmentError(error51.code, error51.message);
    }
    throw error51;
  }
  return enrollmentResult("accepted", input, leaseExpires, tenant);
}
__name(enrollLoopdyLinkDevice, "enrollLoopdyLinkDevice");
async function revokeLoopdyLinkDevice(env, input, now = Math.floor(Date.now() / 1e3)) {
  assertExactKeys(input, ["deviceId", "revision"]);
  if (typeof input.deviceId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,179}$/.test(input.deviceId) || !Number.isSafeInteger(input.revision) || input.revision < 1) {
    throw new LoopdyLinkEnrollmentError(
      "link_enrollment_invalid",
      "Loopdy Link APNs revocation is invalid"
    );
  }
  const tenant = requiredLinkTenant(env);
  await ensureTenant(env.DB, tenant.tenant_id, now);
  const existing = await getDevice(env.DB, tenant.tenant_id, input.deviceId);
  if (existing?.revoked_at !== null && existing && existing.revision >= input.revision) {
    return { status: "duplicate", deviceId: input.deviceId, revision: existing.revision };
  }
  if (existing && input.revision <= existing.revision) {
    throw new LoopdyLinkEnrollmentError(
      "link_revision_stale",
      "Loopdy Link APNs revision is stale"
    );
  }
  try {
    await revokeDevice(env.DB, tenant.tenant_id, input.deviceId, input.revision, now);
  } catch (error51) {
    if (error51 instanceof StorageConflictError) {
      throw new LoopdyLinkEnrollmentError(error51.code, error51.message);
    }
    throw error51;
  }
  return { status: "revoked", deviceId: input.deviceId, revision: input.revision };
}
__name(revokeLoopdyLinkDevice, "revokeLoopdyLinkDevice");
async function acknowledgeLoopdyLinkSenderKeys(env, input, now = Math.floor(Date.now() / 1e3)) {
  assertExactKeys(input, ["deviceId", "revision", "senderKeyRevision", "acknowledgedSenderKeyIds"]);
  const tenant = requiredLinkTenant(env);
  const keyIds = input.acknowledgedSenderKeyIds;
  if (typeof input.deviceId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,179}$/.test(input.deviceId) || !Number.isSafeInteger(input.revision) || input.revision < 1 || input.senderKeyRevision !== tenant.sender_key_revision || !Array.isArray(keyIds) || keyIds.length < 1 || keyIds.length > 2 || new Set(keyIds).size !== keyIds.length || keyIds.some((keyId2) => typeof keyId2 !== "string" || !senderKey(tenant, keyId2, now))) {
    throw new LoopdyLinkEnrollmentError(
      "link_sender_key_invalid",
      "Loopdy Link sender-key acknowledgement is invalid"
    );
  }
  await ensureTenant(env.DB, tenant.tenant_id, now);
  const existing = await getDevice(env.DB, tenant.tenant_id, input.deviceId);
  const acknowledged = [...keyIds].sort();
  if (existing?.revision === input.revision) {
    let stored;
    try {
      stored = JSON.parse(existing.acknowledged_sender_key_ids_json);
    } catch {
      stored = null;
    }
    if (existing.revoked_at === null && existing.sender_key_revision === input.senderKeyRevision && Array.isArray(stored) && JSON.stringify([...stored].sort()) === JSON.stringify(acknowledged)) {
      return acknowledgementResult("duplicate", input, acknowledged);
    }
  }
  if (!existing || existing.revoked_at !== null) {
    throw new LoopdyLinkEnrollmentError(
      "link_device_unavailable",
      "Loopdy Link APNs device is unavailable"
    );
  }
  if (existing.revision >= input.revision) {
    throw new LoopdyLinkEnrollmentError(
      "link_revision_stale",
      "Loopdy Link APNs revision is stale"
    );
  }
  try {
    await acknowledgeSenderKeys(
      env.DB,
      tenant.tenant_id,
      {
        version: 1,
        device_id: input.deviceId,
        revision: input.revision,
        sender_key_revision: input.senderKeyRevision,
        acknowledged_sender_key_ids: acknowledged
      },
      void 0,
      now
    );
  } catch (error51) {
    if (error51 instanceof StorageConflictError) {
      throw new LoopdyLinkEnrollmentError(error51.code, error51.message);
    }
    throw error51;
  }
  return acknowledgementResult("accepted", input, acknowledged);
}
__name(acknowledgeLoopdyLinkSenderKeys, "acknowledgeLoopdyLinkSenderKeys");
async function wakeLoopdyLinkDevice(env, input, now = Math.floor(Date.now() / 1e3)) {
  assertExactKeys(input, ["deviceId", "frameId"]);
  if (typeof input.deviceId !== "string" || !/^[A-Za-z0-9_-]{1,96}$/.test(input.deviceId) || typeof input.frameId !== "string" || !/^[A-Za-z0-9_-]{16,128}$/.test(input.frameId)) {
    throw new LoopdyLinkEnrollmentError(
      "link_wake_invalid",
      "Loopdy Link wake coordinates are invalid"
    );
  }
  const tenant = requiredLinkTenant(env);
  await ensureTenant(env.DB, tenant.tenant_id, now);
  const device = await getDevice(env.DB, tenant.tenant_id, input.deviceId);
  if (!device || device.revoked_at !== null || device.lease_expires <= now) {
    throw new LoopdyLinkEnrollmentError(
      "link_device_unavailable",
      "Loopdy Link APNs device is unavailable"
    );
  }
  const deliveryId = `link-wake-${digestBase64Url(
    `${tenant.tenant_id}\0${input.deviceId}\0${input.frameId}`
  )}`;
  const payload = { version: 1, kind: "link_wake" };
  const result = { deviceId: input.deviceId, deliveryId };
  const existing = await getDelivery(env.DB, tenant.tenant_id, deliveryId);
  if (existing) {
    assertMatchingWake(existing, input.deviceId, payload);
    if (existing.state === "pending_enqueue") {
      await enqueueWake(env, tenant.tenant_id, deliveryId, now);
    }
    return { status: "duplicate", ...result };
  }
  try {
    await admitDeliveryAtomically(env.DB, {
      tenantId: tenant.tenant_id,
      nonce: deliveryId,
      idempotencyKey: deliveryId,
      route: "private/loopdy-link/wake",
      bodyDigest: digestBase64Url(relayCanonicalJson(input)),
      response: { version: 1, status: "accepted", id: deliveryId, revision: device.revision },
      deliveryId,
      deviceId: input.deviceId,
      kind: "alert",
      activityId: null,
      revision: device.revision,
      issued: now,
      expires: now + 300,
      payload,
      sound: false,
      keys: parseStorageKeys(env.STORAGE_ENCRYPTION_KEYS),
      now,
      routine: false
    });
  } catch (error51) {
    const concurrent = await getDelivery(env.DB, tenant.tenant_id, deliveryId);
    if (!concurrent) throw error51;
    assertMatchingWake(concurrent, input.deviceId, payload);
    if (concurrent.state === "pending_enqueue") {
      await enqueueWake(env, tenant.tenant_id, deliveryId, now);
    }
    return { status: "duplicate", ...result };
  }
  await enqueueWake(env, tenant.tenant_id, deliveryId, now);
  return { status: "accepted", ...result };
}
__name(wakeLoopdyLinkDevice, "wakeLoopdyLinkDevice");
async function registerLoopdyLinkLiveActivity(env, input, now = Math.floor(Date.now() / 1e3)) {
  assertExactKeys(input, [
    "deviceId",
    "activityId",
    "sessionReference",
    "pushToken",
    "environment",
    "topic",
    "revision",
    "timestamp",
    "leaseExpires"
  ]);
  const tenant = requiredLinkTenant(env);
  let body;
  try {
    body = RelayLiveActivityRegistrationRequestV1.parse({
      version: 1,
      activity_id: input.activityId,
      device_id: input.deviceId,
      session_ref: input.sessionReference,
      push_token: input.pushToken,
      environment: input.environment,
      topic: input.topic,
      revision: input.revision,
      timestamp: input.timestamp,
      lease_expires: input.leaseExpires,
      idempotency_key: crypto.randomUUID()
    });
  } catch {
    throw new LoopdyLinkEnrollmentError(
      "link_live_activity_invalid",
      "Loopdy Link Live Activity registration is invalid"
    );
  }
  if (Math.abs(body.timestamp - now) > 300 || !tenant.allowed_topics.includes(body.topic)) {
    throw new LoopdyLinkEnrollmentError(
      "link_live_activity_invalid",
      "Loopdy Link Live Activity registration is invalid"
    );
  }
  await ensureTenant(env.DB, tenant.tenant_id, now);
  const existing = await getActivity(env.DB, tenant.tenant_id, input.activityId);
  if (existing?.status === "active" && existing.revision === input.revision && existing.device_id === input.deviceId && existing.session_ref === input.sessionReference) {
    return { status: "duplicate", activityId: input.activityId, revision: input.revision };
  }
  try {
    await registerLiveActivity(
      env.DB,
      tenant.tenant_id,
      body,
      parseStorageKeys(env.STORAGE_ENCRYPTION_KEYS),
      now
    );
  } catch (error51) {
    if (error51 instanceof StorageConflictError) {
      throw new LoopdyLinkEnrollmentError(error51.code, error51.message);
    }
    throw error51;
  }
  return { status: "accepted", activityId: input.activityId, revision: input.revision };
}
__name(registerLoopdyLinkLiveActivity, "registerLoopdyLinkLiveActivity");
async function revokeLoopdyLinkLiveActivity(env, input, now = Math.floor(Date.now() / 1e3)) {
  assertExactKeys(input, ["deviceId", "activityId", "revision", "timestamp"]);
  let body;
  try {
    body = RelayLiveActivityRevokeRequestV1.parse({
      version: 1,
      activity_id: input.activityId,
      revision: input.revision,
      timestamp: input.timestamp,
      idempotency_key: crypto.randomUUID()
    });
  } catch {
    throw new LoopdyLinkEnrollmentError(
      "link_live_activity_invalid",
      "Loopdy Link Live Activity revocation is invalid"
    );
  }
  if (Math.abs(body.timestamp - now) > 300) {
    throw new LoopdyLinkEnrollmentError(
      "link_live_activity_invalid",
      "Loopdy Link Live Activity revocation is invalid"
    );
  }
  const tenant = requiredLinkTenant(env);
  await ensureTenant(env.DB, tenant.tenant_id, now);
  const existing = await getActivity(env.DB, tenant.tenant_id, input.activityId);
  if (existing && existing.device_id !== input.deviceId) {
    throw new LoopdyLinkEnrollmentError(
      "link_live_activity_conflict",
      "Loopdy Link Live Activity belongs to another device"
    );
  }
  if (existing && existing.status !== "active" && existing.revision >= input.revision) {
    return { status: "duplicate", activityId: input.activityId, revision: input.revision };
  }
  try {
    await revokeActivity(env.DB, tenant.tenant_id, input.activityId, input.revision, now);
  } catch (error51) {
    if (error51 instanceof StorageConflictError) {
      throw new LoopdyLinkEnrollmentError(error51.code, error51.message);
    }
    throw error51;
  }
  return { status: "revoked", activityId: input.activityId, revision: input.revision };
}
__name(revokeLoopdyLinkLiveActivity, "revokeLoopdyLinkLiveActivity");
async function updateLoopdyLinkLiveActivity(env, input, now = Math.floor(Date.now() / 1e3)) {
  assertExactKeys(input, [
    "deviceId",
    "updateId",
    "activityId",
    "sessionReference",
    "phase",
    "currentAction",
    "progress",
    "completedSteps",
    "activeSubagentCount",
    "latestTool",
    "timestamp",
    "expires"
  ]);
  let state;
  try {
    state = RelayLiveActivityDeliveryRequestV1.shape.state.parse({
      version: 1,
      kind: "live_activity",
      activity_id: input.activityId,
      session_ref: input.sessionReference,
      phase: input.phase,
      current_action: input.currentAction,
      progress: input.progress,
      active_session_count: input.activeSubagentCount,
      completed_steps: input.completedSteps,
      active_subagent_count: input.activeSubagentCount,
      latest_tool: input.latestTool,
      timestamp: input.timestamp,
      expires: input.expires
    });
  } catch {
    throw new LoopdyLinkEnrollmentError(
      "link_live_activity_invalid",
      "Loopdy Link Live Activity update is invalid"
    );
  }
  if (!/^[A-Za-z0-9_-]{16,128}$/.test(input.updateId) || Math.abs(state.timestamp - now) > 300) {
    throw new LoopdyLinkEnrollmentError(
      "link_live_activity_invalid",
      "Loopdy Link Live Activity update is invalid"
    );
  }
  const tenant = requiredLinkTenant(env);
  await ensureTenant(env.DB, tenant.tenant_id, now);
  const activity = await getActivity(env.DB, tenant.tenant_id, input.activityId);
  if (activity?.status !== "active" || activity.device_id !== input.deviceId || activity.session_ref !== input.sessionReference || activity.lease_expires <= now) {
    throw new LoopdyLinkEnrollmentError(
      "link_activity_unavailable",
      "Loopdy Link Live Activity is unavailable"
    );
  }
  const deliveryId = `link-live-${digestBase64Url(
    `${tenant.tenant_id}\0${input.deviceId}\0${input.activityId}\0${input.updateId}`
  )}`;
  const stateHash = digestHex(relayCanonicalJson(state));
  const existing = await getDelivery(env.DB, tenant.tenant_id, deliveryId);
  if (existing) {
    if (existing.device_id !== input.deviceId || existing.activity_id !== input.activityId || existing.kind !== "live_activity" || existing.payload_hash !== stateHash) {
      throw new LoopdyLinkEnrollmentError(
        "link_live_activity_conflict",
        "Loopdy Link Live Activity update coordinates conflict"
      );
    }
    if (existing.state === "pending_enqueue") {
      await enqueueWake(env, tenant.tenant_id, deliveryId, now);
    }
    return { status: "duplicate", activityId: input.activityId, deliveryId };
  }
  const response2 = { version: 1, status: "accepted", id: deliveryId, revision: activity.revision };
  try {
    await admitDeliveryAtomically(env.DB, {
      tenantId: tenant.tenant_id,
      nonce: deliveryId,
      idempotencyKey: deliveryId,
      route: "private/loopdy-link/live-activity",
      bodyDigest: digestBase64Url(relayCanonicalJson(input)),
      response: response2,
      deliveryId,
      deviceId: input.deviceId,
      kind: "live_activity",
      activityId: input.activityId,
      revision: activity.revision,
      issued: state.timestamp,
      expires: state.expires,
      payload: state,
      keys: parseStorageKeys(env.STORAGE_ENCRYPTION_KEYS),
      now,
      routine: ["thinking", "using_tool", "delegating", "responding"].includes(state.phase),
      stateHash,
      stateTimestamp: state.timestamp
    });
  } catch (error51) {
    const concurrent = await getDelivery(env.DB, tenant.tenant_id, deliveryId);
    if (!concurrent) throw error51;
    if (concurrent.payload_hash !== stateHash) throw error51;
    if (concurrent.state === "pending_enqueue") {
      await enqueueWake(env, tenant.tenant_id, deliveryId, now);
    }
    return { status: "duplicate", activityId: input.activityId, deliveryId };
  }
  await enqueueWake(env, tenant.tenant_id, deliveryId, now);
  return { status: "accepted", activityId: input.activityId, deliveryId };
}
__name(updateLoopdyLinkLiveActivity, "updateLoopdyLinkLiveActivity");
var LoopdyLinkEnrollment = class extends WorkerEntrypoint {
  static {
    __name(this, "LoopdyLinkEnrollment");
  }
  async enrollDevice(input) {
    return enrollLoopdyLinkDevice(this.env, input);
  }
  async revokeDevice(input) {
    return revokeLoopdyLinkDevice(this.env, input);
  }
  async acknowledgeSenderKeys(input) {
    return acknowledgeLoopdyLinkSenderKeys(this.env, input);
  }
  async wakeDevice(input) {
    return wakeLoopdyLinkDevice(this.env, input);
  }
  async registerLiveActivity(input) {
    return registerLoopdyLinkLiveActivity(this.env, input);
  }
  async updateLiveActivity(input) {
    return updateLoopdyLinkLiveActivity(this.env, input);
  }
  async revokeLiveActivity(input) {
    return revokeLoopdyLinkLiveActivity(this.env, input);
  }
};
function acknowledgementResult(status, input, acknowledgedSenderKeyIds) {
  return {
    status,
    deviceId: input.deviceId,
    revision: input.revision,
    senderKeyRevision: input.senderKeyRevision,
    acknowledgedSenderKeyIds
  };
}
__name(acknowledgementResult, "acknowledgementResult");
async function enqueueWake(env, tenantId, deliveryId, now) {
  await env.DELIVERY_QUEUE.send(queueCoordinates(tenantId, deliveryId));
  await markDeliveryQueued(env.DB, tenantId, deliveryId, now);
}
__name(enqueueWake, "enqueueWake");
function assertMatchingWake(delivery, deviceId, payload) {
  if (delivery.device_id !== deviceId || delivery.kind !== "alert" || delivery.payload_hash !== digestHex(relayCanonicalJson(payload))) {
    throw new LoopdyLinkEnrollmentError(
      "link_wake_conflict",
      "Loopdy Link wake coordinates conflict with stored state"
    );
  }
}
__name(assertMatchingWake, "assertMatchingWake");
function digestBase64Url(value) {
  return relayBase64UrlEncode(relaySha256(new TextEncoder().encode(value)));
}
__name(digestBase64Url, "digestBase64Url");
function digestHex(value) {
  return Array.from(
    relaySha256(new TextEncoder().encode(value)),
    (byte) => byte.toString(16).padStart(2, "0")
  ).join("");
}
__name(digestHex, "digestHex");
function requiredLinkTenant(env) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,179}$/.test(env.LINK_RELAY_TENANT_ID)) {
    throw new LoopdyLinkEnrollmentError(
      "link_configuration_invalid",
      "Loopdy Link relay tenant is invalid"
    );
  }
  const tenant = parseTenantRegistry(env.RELAY_TENANTS).get(env.LINK_RELAY_TENANT_ID);
  if (!tenant) {
    throw new LoopdyLinkEnrollmentError(
      "link_configuration_invalid",
      "Loopdy Link relay tenant is not configured"
    );
  }
  return tenant;
}
__name(requiredLinkTenant, "requiredLinkTenant");
function enrollmentResult(status, input, leaseExpires, tenant) {
  return {
    status,
    deviceId: input.deviceId,
    revision: input.revision,
    leaseExpires,
    senderKeyRevision: tenant.sender_key_revision,
    currentSenderKey: tenant.current,
    previousSenderKey: tenant.previous
  };
}
__name(enrollmentResult, "enrollmentResult");
function assertExactKeys(value, allowed) {
  const allowedSet = new Set(allowed);
  if (Object.keys(value).some((key) => !allowedSet.has(key))) {
    throw new LoopdyLinkEnrollmentError(
      "link_enrollment_invalid",
      "Loopdy Link enrollment contains unsupported fields"
    );
  }
}
__name(assertExactKeys, "assertExactKeys");

