// src/index.ts
var JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store"
};
var HSTS_VALUE = "max-age=31536000; includeSubDomains";
function response(value, status = 200, secureTransport = false) {
  const headers = secureTransport ? { ...JSON_HEADERS, "strict-transport-security": HSTS_VALUE } : JSON_HEADERS;
  return new Response(relayCanonicalJson(value), { status, headers });
}
__name(response, "response");
function errorResponse(code, message, status, secureTransport = false) {
  return response({ version: 1, error: code, message }, status, secureTransport);
}
__name(errorResponse, "errorResponse");
function nowSeconds() {
  return Math.floor(Date.now() / 1e3);
}
__name(nowSeconds, "nowSeconds");
function payloadHash(value) {
  return Array.from(
    relaySha256(new TextEncoder().encode(relayCanonicalJson(value))),
    (byte) => byte.toString(16).padStart(2, "0")
  ).join("");
}
__name(payloadHash, "payloadHash");
function storageKeys(env) {
  return parseStorageKeys(requiredSecret(env.STORAGE_ENCRYPTION_KEYS, "STORAGE_ENCRYPTION_KEYS"));
}
__name(storageKeys, "storageKeys");
function requiredSecret(value, name) {
  if (!value) throw new Error(`${name} is not configured`);
  return value;
}
__name(requiredSecret, "requiredSecret");
function managementRequest(auth, identity, responseBody, now) {
  return {
    tenantId: auth.tenantId,
    nonce: auth.nonce,
    idempotencyKey: identity.idempotencyKey,
    route: identity.route,
    bodyDigest: identity.bodyDigest,
    response: responseBody,
    now
  };
}
__name(managementRequest, "managementRequest");
function assertBodyTimestamp(value, field, now) {
  const timestamp2 = Number(value);
  if (!Number.isSafeInteger(timestamp2) || Math.abs(timestamp2 - now) > RELAY_LIMITS.nonceWindowSeconds)
    throw new StorageConflictError("stale_timestamp", `${field} is outside the relay clock window`);
  return timestamp2;
}
__name(assertBodyTimestamp, "assertBodyTimestamp");
function assertLease(expires, field, now, maximumSeconds) {
  const lease = Number(expires);
  if (!Number.isSafeInteger(lease) || lease <= now || lease - now > maximumSeconds)
    throw new StorageConflictError("invalid_expiry", `${field} is outside the relay lease window`);
  return lease;
}
__name(assertLease, "assertLease");
async function readBoundedRequestBody(request, maximumBytes = RELAY_LIMITS.requestBytes) {
  const contentLength = request.headers.get("content-length");
  if (contentLength !== null && (!/^\d+$/.test(contentLength) || Number(contentLength) > maximumBytes)) {
    throw new RelaySchemaError("body_too_large", "Relay request exceeds the size limit");
  }
  const reader = request.body?.getReader();
  if (!reader) return "";
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      total += next.value.byteLength;
      if (total > maximumBytes) {
        await reader.cancel("Relay request exceeds bounded limit");
        throw new RelaySchemaError("body_too_large", "Relay request exceeds the size limit");
      }
      chunks.push(next.value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes3 = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes3.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes3);
}
__name(readBoundedRequestBody, "readBoundedRequestBody");
async function enqueueDelivery(env, tenantId, deliveryId, now) {
  await env.DELIVERY_QUEUE.send(queueCoordinates(tenantId, deliveryId));
  await markDeliveryQueued(env.DB, tenantId, deliveryId, now);
}
__name(enqueueDelivery, "enqueueDelivery");
async function handleFetch(request, env, ctx) {
  const url2 = new URL(request.url);
  const secureTransport = url2.protocol === "https:";
  const respond = /* @__PURE__ */ __name((value, status = 200) => response(value, status, secureTransport), "respond");
  const respondError = /* @__PURE__ */ __name((code, message, status) => errorResponse(code, message, status, secureTransport), "respondError");
  if (!secureTransport) return respondError("https_required", "Relay requests must use HTTPS", 426);
  if (request.method === "GET" && url2.pathname === "/health" && !url2.search && !url2.hash) {
    return respond(RelayHealthResponseV1.parse({ version: 1, status: "ok" }));
  }
  if (request.method !== "POST")
    return respondError("method_not_allowed", "Method is not supported", 405);
  let pathName;
  try {
    pathName = routePath(url2.pathname);
  } catch {
    return respondError("not_found", "Relay route is not found", 404);
  }
  if (request.headers.get("content-type") !== "application/json") {
    return respondError("invalid_content_type", "Relay requests must use application/json", 415);
  }
  let body;
  try {
    body = await readBoundedRequestBody(request);
  } catch (error51) {
    if (error51 instanceof RelaySchemaError && error51.code === "body_too_large")
      return respondError(error51.code, error51.message, 413);
    return respondError("invalid_body", "Relay request body could not be read", 400);
  }
  let parsed;
  try {
    const raw = parseCanonicalJson(body);
    parsed = parseRouteRequest(url2.pathname, raw);
  } catch (error51) {
    return respondError(
      "invalid_schema",
      error51 instanceof Error ? error51.message : "Relay request is invalid",
      400
    );
  }
  let auth;
  try {
    auth = await authenticateRelayRequest(request, {
      registry: parseTenantRegistry(requiredSecret(env.RELAY_TENANTS, "RELAY_TENANTS")),
      now: nowSeconds(),
      body
    });
  } catch (error51) {
    if (error51 instanceof Error && "status" in error51 && typeof error51.status === "number") {
      const authError = error51;
      return respondError(authError.code, authError.message, authError.status);
    }
    return respondError("invalid_credentials", "Relay credentials are invalid", 401);
  }
  const now = nowSeconds();
  try {
    await ensureTenant(env.DB, auth.tenantId, now);
    const idempotencyKey2 = String(parsed.idempotency_key);
    const existing = await readIdempotency(env.DB, auth.tenantId, idempotencyKey2);
    if (existing && (existing.route !== url2.pathname || existing.bodyDigest !== auth.bodyDigest)) {
      return respondError(
        "idempotency_conflict",
        "Idempotency key was used for another request",
        409
      );
    }
    if (existing?.response) return respond(existing.response);
    if (existing)
      return respondError("idempotency_in_progress", "Request is still in progress", 409);
    let result;
    try {
      result = await applyRoute(pathName, parsed, auth, env, now, ctx, {
        idempotencyKey: idempotencyKey2,
        route: url2.pathname,
        bodyDigest: auth.bodyDigest
      });
    } catch (error51) {
      if (pathName !== "delivery") {
        const authoritative = await readIdempotency(env.DB, auth.tenantId, idempotencyKey2);
        if (authoritative && (authoritative.route !== url2.pathname || authoritative.bodyDigest !== auth.bodyDigest))
          throw new StorageConflictError(
            "idempotency_conflict",
            "Idempotency key was used for another request"
          );
        if (authoritative?.response) return respond(authoritative.response);
        const nonce = await env.DB.prepare(
          "SELECT 1 AS used FROM request_nonces WHERE tenant_id = ? AND nonce = ?"
        ).bind(auth.tenantId, auth.nonce).first();
        if (nonce)
          throw new StorageConflictError(
            "replayed_nonce",
            "Relay request nonce has already been used"
          );
      }
      throw error51;
    }
    return respond(result.body, result.status);
  } catch (error51) {
    if (error51 instanceof StorageConflictError) return respondError(error51.code, error51.message, 409);
    return respondError("relay_unavailable", "Relay request could not be accepted", 503);
  }
}
__name(handleFetch, "handleFetch");
async function applyRoute(pathName, body, auth, env, now, ctx, requestIdentity) {
  const keys = storageKeys(env);
  if (pathName !== "tenant_revoke" && pathName !== "tenant_delete")
    await assertTenantActive(env.DB, auth.tenantId);
  switch (pathName) {
    case "device_register": {
      assertBodyTimestamp(body.issued, "issued", now);
      assertLease(body.lease_expires, "lease_expires", now, RELAY_LIMITS.deviceLeaseSeconds);
      if (!auth.tenant.allowed_topics.includes(String(body.topic)))
        throw new StorageConflictError(
          "topic_not_allowed",
          "Device topic is not allowed for this tenant"
        );
      const registration = RelayDeviceRegistrationResponseV1.parse({
        version: 1,
        status: "accepted",
        tenant_id: auth.tenantId,
        device_id: body.device_id,
        recipient_key_id: body.recipient_key_id,
        revision: body.revision,
        lease_expires: body.lease_expires,
        sender_key_revision: auth.tenant.sender_key_revision,
        current_sender_key: auth.tenant.current,
        previous_sender_key: auth.tenant.previous
      });
      await registerDevice(env.DB, {
        tenant: auth.tenant,
        body,
        keys,
        now,
        request: managementRequest(auth, requestIdentity, registration, now)
      });
      return { body: registration, status: 201 };
    }
    case "sender_key_acknowledgement": {
      if (body.sender_key_revision !== auth.tenant.sender_key_revision)
        throw new StorageConflictError("sender_key_revision", "Sender key revision is stale");
      for (const keyId2 of body.acknowledged_sender_key_ids) {
        if (!senderKey(auth.tenant, keyId2, now))
          throw new StorageConflictError("sender_key", "Sender key is not active");
      }
      const accepted = RelayAcceptedResponseV1.parse({
        version: 1,
        status: "accepted",
        id: body.device_id,
        revision: body.revision
      });
      await acknowledgeSenderKeys(
        env.DB,
        auth.tenantId,
        body,
        managementRequest(auth, requestIdentity, accepted, now),
        now
      );
      return {
        body: accepted,
        status: 200
      };
    }
    case "device_revoke": {
      const revoked = RelayRevokedResponseV1.parse({
        version: 1,
        status: "revoked",
        id: body.device_id,
        revision: body.revision
      });
      await revokeDevice(
        env.DB,
        auth.tenantId,
        String(body.device_id),
        Number(body.revision),
        now,
        managementRequest(auth, requestIdentity, revoked, now)
      );
      return {
        body: revoked,
        status: 200
      };
    }
    case "tenant_revoke": {
      if (body.tenant_id !== auth.tenantId)
        throw new StorageConflictError(
          "tenant_mismatch",
          "Tenant coordinate does not match credentials"
        );
      const revoked = RelayRevokedResponseV1.parse({
        version: 1,
        status: "revoked",
        id: auth.tenantId,
        revision: body.revision
      });
      await revokeTenant(
        env.DB,
        auth.tenantId,
        Number(body.revision),
        now,
        managementRequest(auth, requestIdentity, revoked, now)
      );
      return {
        body: revoked,
        status: 200
      };
    }
    case "tenant_delete": {
      if (body.tenant_id !== auth.tenantId)
        throw new StorageConflictError(
          "tenant_mismatch",
          "Tenant coordinate does not match credentials"
        );
      const deleted = RelayDeletedResponseV1.parse({
        version: 1,
        status: "deleted",
        id: auth.tenantId,
        revision: body.revision
      });
      await deleteTenant(
        env.DB,
        auth.tenantId,
        Number(body.revision),
        now,
        managementRequest(auth, requestIdentity, deleted, now)
      );
      return {
        body: deleted,
        status: 200
      };
    }
    case "live_activity_register": {
      assertBodyTimestamp(body.timestamp, "timestamp", now);
      assertLease(body.lease_expires, "lease_expires", now, RELAY_LIMITS.liveActivityLeaseSeconds);
      if (!auth.tenant.allowed_topics.includes(String(body.topic)))
        throw new StorageConflictError(
          "topic_not_allowed",
          "Live Activity topic is not allowed for this tenant"
        );
      const accepted = RelayAcceptedResponseV1.parse({
        version: 1,
        status: "accepted",
        id: body.activity_id,
        revision: body.revision
      });
      await registerLiveActivity(
        env.DB,
        auth.tenantId,
        body,
        keys,
        now,
        managementRequest(auth, requestIdentity, accepted, now)
      );
      return {
        body: accepted,
        status: 201
      };
    }
    case "live_activity_revoke": {
      assertBodyTimestamp(body.timestamp, "timestamp", now);
      const revoked = RelayRevokedResponseV1.parse({
        version: 1,
        status: "revoked",
        id: body.activity_id,
        revision: body.revision
      });
      await revokeActivity(
        env.DB,
        auth.tenantId,
        String(body.activity_id),
        Number(body.revision),
        now,
        managementRequest(auth, requestIdentity, revoked, now)
      );
      return {
        body: revoked,
        status: 200
      };
    }
    case "delivery":
      return applyDelivery(body, auth, env, keys, now, ctx, requestIdentity);
  }
}
__name(applyRoute, "applyRoute");
async function applyDelivery(body, auth, env, keys, now, ctx, requestIdentity) {
  const recordResponse = /* @__PURE__ */ __name(async (value) => {
    try {
      await recordRequestAtomically(env.DB, {
        tenantId: auth.tenantId,
        nonce: auth.nonce,
        idempotencyKey: requestIdentity.idempotencyKey,
        route: requestIdentity.route,
        bodyDigest: requestIdentity.bodyDigest,
        response: value,
        now
      });
      return value;
    } catch {
      const authoritative = await readIdempotency(
        env.DB,
        auth.tenantId,
        requestIdentity.idempotencyKey
      );
      if (authoritative && (authoritative.route !== requestIdentity.route || authoritative.bodyDigest !== requestIdentity.bodyDigest))
        throw new StorageConflictError(
          "idempotency_conflict",
          "Idempotency key was used for another request"
        );
      if (authoritative?.response) return authoritative.response;
      throw new StorageConflictError("idempotency_in_progress", "Request is still in progress");
    }
  }, "recordResponse");
  if ("envelope" in body) {
    const deviceId = String(body.device_id);
    const device = await getDevice(env.DB, auth.tenantId, deviceId);
    if (!device || device.revoked_at !== null || device.lease_expires <= now)
      throw new StorageConflictError("device_unavailable", "Relay device is unavailable");
    const envelope = body.envelope;
    if (Number(envelope.expires) <= now)
      throw new StorageConflictError("delivery_expired", "Signed alert delivery has expired");
    assertBodyTimestamp(envelope.issued, "issued", now);
    assertLease(envelope.expires, "expires", now, RELAY_LIMITS.deliveryTtlSeconds);
    if (envelope.recipient_key_id !== device.recipient_key_id)
      throw new StorageConflictError(
        "recipient_key",
        "Envelope recipient key does not match device"
      );
    const key = senderKeyForIssuedEnvelope(
      auth.tenant,
      String(envelope.sender_key_id),
      Number(envelope.issued)
    );
    if (!key) throw new StorageConflictError("sender_key", "Envelope sender key is not active");
    await verifyPluginEnvelope(envelope, key.public_key, { tenantId: auth.tenantId, deviceId });
    const deliveryId2 = String(envelope.delivery_id);
    const accepted2 = RelayAcceptedResponseV1.parse({
      version: 1,
      status: "accepted",
      id: deliveryId2,
      revision: device.revision
    });
    const existingDelivery2 = await getDelivery(env.DB, auth.tenantId, deliveryId2);
    if (existingDelivery2) {
      if (existingDelivery2.payload_hash !== payloadHash(envelope) || existingDelivery2.device_id !== deviceId || existingDelivery2.kind !== "alert")
        throw new StorageConflictError(
          "delivery_conflict",
          "Delivery coordinates were reused for another payload"
        );
      const authoritative = await readIdempotency(
        env.DB,
        auth.tenantId,
        requestIdentity.idempotencyKey
      );
      if (authoritative?.response) return { body: authoritative.response, status: 202 };
      const recorded = await recordResponse({ ...accepted2, status: "duplicate" });
      return {
        body: recorded,
        status: 200
      };
    }
    try {
      const admitted = await admitDeliveryAtomically(env.DB, {
        tenantId: auth.tenantId,
        nonce: auth.nonce,
        idempotencyKey: requestIdentity.idempotencyKey,
        route: requestIdentity.route,
        bodyDigest: requestIdentity.bodyDigest,
        response: accepted2,
        deliveryId: deliveryId2,
        deviceId,
        kind: "alert",
        activityId: null,
        revision: device.revision,
        issued: Number(envelope.issued),
        expires: Number(envelope.expires),
        payload: envelope,
        ...body.sound === false ? { sound: false } : {},
        keys,
        now,
        routine: false
      });
      ctx.waitUntil(
        enqueueDelivery(env, auth.tenantId, admitted.delivery.delivery_id, now).catch(
          () => void 0
        )
      );
      return { body: accepted2, status: 202 };
    } catch {
      const existingAfter = await getDelivery(env.DB, auth.tenantId, deliveryId2);
      if (existingAfter) {
        if (existingAfter.payload_hash !== payloadHash(envelope) || existingAfter.device_id !== deviceId || existingAfter.kind !== "alert")
          throw new StorageConflictError(
            "delivery_conflict",
            "Delivery coordinates were reused for another payload"
          );
        const authoritative2 = await readIdempotency(
          env.DB,
          auth.tenantId,
          requestIdentity.idempotencyKey
        );
        if (authoritative2?.response) return { body: authoritative2.response, status: 202 };
        const duplicate = { ...accepted2, status: "duplicate" };
        const recorded = await recordResponse(duplicate);
        return { body: recorded, status: 200 };
      }
      const currentDevice = await getDevice(env.DB, auth.tenantId, deviceId);
      if (!currentDevice || currentDevice.revoked_at !== null || currentDevice.lease_expires <= now)
        throw new StorageConflictError("device_unavailable", "Relay device is unavailable");
      if (currentDevice.revision !== device.revision)
        throw new StorageConflictError(
          "device_revision",
          "Delivery device revision changed during admission"
        );
      const authoritative = await readIdempotency(
        env.DB,
        auth.tenantId,
        requestIdentity.idempotencyKey
      );
      if (authoritative && (authoritative.route !== requestIdentity.route || authoritative.bodyDigest !== requestIdentity.bodyDigest))
        throw new StorageConflictError(
          "idempotency_conflict",
          "Idempotency key was used for another request"
        );
      if (authoritative?.response) return { body: authoritative.response, status: 202 };
      const nonce = await env.DB.prepare(
        "SELECT 1 AS used FROM request_nonces WHERE tenant_id = ? AND nonce = ?"
      ).bind(auth.tenantId, auth.nonce).first();
      if (nonce)
        throw new StorageConflictError(
          "replayed_nonce",
          "Relay request nonce has already been used"
        );
      const usage = await countUsage(env.DB, auth.tenantId, now);
      const globalUsage = await countGlobalUsage(env.DB, now);
      if (usage.accepted >= RELAY_LIMITS.hardAcceptedPerDay || globalUsage.accepted >= RELAY_LIMITS.hardAcceptedPerDay)
        throw new StorageConflictError(
          "daily_quota",
          "Relay daily accepted-delivery limit reached"
        );
      throw new Error("Delivery admission failed");
    }
  }
  const state = sanitizeLiveActivityState(body.state);
  if (Number(state.expires) <= now)
    throw new StorageConflictError("delivery_expired", "Live Activity delivery has expired");
  assertBodyTimestamp(state.timestamp, "timestamp", now);
  assertLease(state.expires, "expires", now, RELAY_LIMITS.liveActivityTtlSeconds);
  const activityId = String(state.activity_id);
  const activity = await getActivity(env.DB, auth.tenantId, activityId);
  if (!activity || activity.device_id !== body.device_id || activity.status !== "active" || activity.lease_expires <= now)
    throw new StorageConflictError("activity_unavailable", "Live Activity is unavailable");
  const stateHash = Array.from(
    relaySha256(new TextEncoder().encode(relayCanonicalJson(state))),
    (byte) => byte.toString(16).padStart(2, "0")
  ).join("");
  const deliveryId = String(body.delivery_id);
  const routine = isRoutineLiveActivity(state);
  const accepted = RelayAcceptedResponseV1.parse({
    version: 1,
    status: "accepted",
    id: deliveryId,
    revision: activity.revision
  });
  const existingDelivery = await getDelivery(env.DB, auth.tenantId, deliveryId);
  if (existingDelivery) {
    if (existingDelivery.payload_hash !== payloadHash(state) || existingDelivery.activity_id !== activityId || existingDelivery.kind !== "live_activity")
      throw new StorageConflictError(
        "delivery_conflict",
        "Delivery coordinates were reused for another payload"
      );
    const authoritative = await readIdempotency(
      env.DB,
      auth.tenantId,
      requestIdentity.idempotencyKey
    );
    if (authoritative?.response) return { body: authoritative.response, status: 202 };
    const recorded = await recordResponse({ ...accepted, status: "duplicate" });
    return {
      body: recorded,
      status: 200
    };
  }
  const unchanged = activity.state_hash === stateHash || routine && activity.state_timestamp !== null && Number(state.timestamp) > activity.state_timestamp && Number(state.timestamp) - activity.state_timestamp < RELAY_LIMITS.routineLiveActivityIntervalSeconds;
  if (!unchanged && activity.state_timestamp !== null && Number(state.timestamp) <= activity.state_timestamp)
    throw new StorageConflictError("state_timestamp", "Live Activity state timestamp is stale");
  if (unchanged) {
    const recorded = await recordResponse(accepted);
    return { body: recorded, status: 202 };
  }
  try {
    const admitted = await admitDeliveryAtomically(env.DB, {
      tenantId: auth.tenantId,
      nonce: auth.nonce,
      idempotencyKey: requestIdentity.idempotencyKey,
      route: requestIdentity.route,
      bodyDigest: requestIdentity.bodyDigest,
      response: accepted,
      deliveryId,
      deviceId: String(body.device_id),
      kind: "live_activity",
      activityId,
      revision: activity.revision,
      issued: Number(state.timestamp),
      expires: Number(state.expires),
      payload: state,
      keys,
      now,
      routine,
      stateHash,
      stateTimestamp: Number(state.timestamp)
    });
    ctx.waitUntil(
      enqueueDelivery(env, auth.tenantId, admitted.delivery.delivery_id, now).catch(
        () => void 0
      )
    );
    return { body: accepted, status: 202 };
  } catch {
    const existingAfter = await getDelivery(env.DB, auth.tenantId, deliveryId);
    if (existingAfter) {
      if (existingAfter.payload_hash !== payloadHash(state) || existingAfter.activity_id !== activityId || existingAfter.kind !== "live_activity")
        throw new StorageConflictError(
          "delivery_conflict",
          "Delivery coordinates were reused for another payload"
        );
      const authoritative2 = await readIdempotency(
        env.DB,
        auth.tenantId,
        requestIdentity.idempotencyKey
      );
      if (authoritative2?.response) return { body: authoritative2.response, status: 202 };
      const duplicate = { ...accepted, status: "duplicate" };
      const recorded = await recordResponse(duplicate);
      return { body: recorded, status: 200 };
    }
    const currentActivity = await getActivity(env.DB, auth.tenantId, activityId);
    if (currentActivity?.status !== "active")
      throw new StorageConflictError("activity_unavailable", "Live Activity is unavailable");
    if (currentActivity.revision !== activity.revision)
      throw new StorageConflictError(
        "activity_revision",
        "Live Activity revision changed during admission"
      );
    const authoritative = await readIdempotency(
      env.DB,
      auth.tenantId,
      requestIdentity.idempotencyKey
    );
    if (authoritative && (authoritative.route !== requestIdentity.route || authoritative.bodyDigest !== requestIdentity.bodyDigest))
      throw new StorageConflictError(
        "idempotency_conflict",
        "Idempotency key was used for another request"
      );
    if (authoritative?.response) return { body: authoritative.response, status: 202 };
    const nonce = await env.DB.prepare(
      "SELECT 1 AS used FROM request_nonces WHERE tenant_id = ? AND nonce = ?"
    ).bind(auth.tenantId, auth.nonce).first();
    if (nonce)
      throw new StorageConflictError("replayed_nonce", "Relay request nonce has already been used");
    const currentUsage = await countUsage(env.DB, auth.tenantId, now);
    const currentGlobalUsage = await countGlobalUsage(env.DB, now);
    if (routine && (currentUsage.accepted >= RELAY_LIMITS.hardAcceptedPerDay || currentUsage.accepted >= RELAY_LIMITS.expectedAcceptedPerDay || currentUsage.routine >= RELAY_LIMITS.routineLiveActivityPerDay || currentGlobalUsage.accepted >= RELAY_LIMITS.hardAcceptedPerDay || currentGlobalUsage.accepted >= RELAY_LIMITS.expectedAcceptedPerDay || currentGlobalUsage.routine >= RELAY_LIMITS.routineLiveActivityPerDay)) {
      const recorded = await recordResponse(accepted);
      return { body: recorded, status: 202 };
    }
    if (currentUsage.accepted >= RELAY_LIMITS.hardAcceptedPerDay || currentGlobalUsage.accepted >= RELAY_LIMITS.hardAcceptedPerDay)
      throw new StorageConflictError("daily_quota", "Relay daily accepted-delivery limit reached");
    if (currentActivity.state_hash === stateHash || routine && currentActivity.state_timestamp !== null && Number(state.timestamp) > currentActivity.state_timestamp && Number(state.timestamp) - currentActivity.state_timestamp < RELAY_LIMITS.routineLiveActivityIntervalSeconds) {
      const recorded = await recordResponse(accepted);
      return { body: recorded, status: 202 };
    }
    if (currentActivity.state_timestamp !== null && Number(state.timestamp) <= currentActivity.state_timestamp)
      throw new StorageConflictError("state_timestamp", "Live Activity state timestamp is stale");
    throw new Error("Live Activity admission failed");
  }
}
__name(applyDelivery, "applyDelivery");
async function processQueueMessage(message, env, now) {
  const coordinate = message.body;
  if (!coordinate || typeof coordinate.tenantId !== "string" || typeof coordinate.deliveryId !== "string") {
    message.ack();
    return;
  }
  const leaseId = crypto.randomUUID();
  let row;
  try {
    row = await claimDelivery(env.DB, coordinate.tenantId, coordinate.deliveryId, leaseId, now);
  } catch {
    message.retry({ delaySeconds: retryDelaySeconds(1) });
    return;
  }
  if (!row) {
    message.ack();
    return;
  }
  const fail = /* @__PURE__ */ __name(async (state, reason, settledAt = now) => {
    await completeDelivery(env.DB, row, state, reason, settledAt);
    message.ack();
  }, "fail");
  try {
    if (row.expires <= now) return fail("failed", "expired");
    const device = await getDevice(env.DB, row.tenant_id, row.device_id);
    if (!device || device.revoked_at !== null || device.lease_expires <= now)
      return fail("cancelled", "device_unavailable");
    if (row.kind === "alert" && device.revision !== row.revision)
      return fail("cancelled", "device_unavailable");
    const keys = storageKeys(env);
    const decodedPayload = await decodeDeliveryPayload(row, keys);
    const payload = decodedPayload.payload;
    let token;
    let environment;
    let topic;
    let pushPayload;
    let pushType;
    if (row.kind === "alert") {
      token = new TextDecoder().decode(await encryptedToken(device.token_ciphertext, keys));
      environment = device.environment;
      topic = device.topic;
      if (isLoopdyLinkWake(payload)) {
        pushType = "background";
        pushPayload = RelayLinkWakePushPayloadV1.parse({
          aps: { "content-available": 1 },
          loopdy_link: { version: 1, type: "wake" }
        });
      } else {
        pushType = "alert";
        pushPayload = RelayAlertPushPayloadV1.parse({
          aps: {
            alert: { title: "Loopdy", body: "Open Loopdy to review this request." },
            category: "LOOPDY_REVIEW",
            "mutable-content": 1,
            ...decodedPayload.sound === false ? {} : { sound: "default" }
          },
          loopdy: {
            version: 1,
            tenant_id: row.tenant_id,
            device_id: row.device_id,
            envelope: payload
          }
        });
      }
    } else {
      const activity = row.activity_id ? await getActivity(env.DB, row.tenant_id, row.activity_id) : null;
      if (activity?.status !== "active" || activity.revision !== row.revision || activity.lease_expires <= now || activity.state_hash !== row.payload_hash)
        return fail("cancelled", "activity_superseded");
      token = new TextDecoder().decode(await encryptedToken(activity.token_ciphertext, keys));
      environment = activity.environment;
      topic = activity.topic;
      pushType = "liveactivity";
      const terminal = payload.phase === "completed" || payload.phase === "failed";
      pushPayload = RelayActivityKitPushPayloadV1.parse({
        aps: {
          timestamp: payload.timestamp,
          event: terminal ? "end" : "update",
          "content-state": {
            phase: activityKitPhase(String(payload.phase)),
            currentAction: payload.current_action ?? liveActivityAction(String(payload.phase)),
            progress: payload.progress,
            completedSteps: payload.completed_steps ?? 0,
            activeSubagentCount: payload.active_subagent_count ?? payload.active_session_count,
            latestTool: payload.latest_tool ?? null,
            timestamp: payload.timestamp
          },
          "stale-date": payload.expires,
          ...terminal ? { "dismissal-date": payload.expires } : {}
        }
      });
    }
    const sendNow = nowSeconds();
    if (row.expires <= sendNow) return fail("failed", "expired", sendNow);
    if (row.kind === "alert") {
      const currentDevice = await getDevice(env.DB, row.tenant_id, row.device_id);
      if (!currentDevice || currentDevice.revoked_at !== null || currentDevice.revision !== row.revision || currentDevice.lease_expires <= sendNow)
        return fail("cancelled", "device_unavailable", sendNow);
      const tenantConfig = parseTenantRegistry(
        requiredSecret(env.RELAY_TENANTS, "RELAY_TENANTS")
      ).get(row.tenant_id);
      if (!tenantConfig?.allowed_topics.includes(currentDevice.topic))
        return fail("cancelled", "topic_not_allowed", sendNow);
    } else if (row.activity_id) {
      const currentActivity = await getActivity(env.DB, row.tenant_id, row.activity_id);
      if (currentActivity?.status !== "active" || currentActivity.revision !== row.revision || currentActivity.lease_expires <= sendNow || currentActivity.state_hash !== row.payload_hash)
        return fail("cancelled", "activity_superseded", sendNow);
      const tenantConfig = parseTenantRegistry(
        requiredSecret(env.RELAY_TENANTS, "RELAY_TENANTS")
      ).get(row.tenant_id);
      if (!tenantConfig?.allowed_topics.includes(currentActivity.topic))
        return fail("cancelled", "topic_not_allowed", sendNow);
    }
    const currentDelivery = await getDelivery(env.DB, row.tenant_id, row.delivery_id);
    if (currentDelivery?.state !== "sending" || currentDelivery?.lease_id !== row.lease_id || currentDelivery?.lease_expires === null || currentDelivery?.lease_expires === void 0 || (currentDelivery?.lease_expires ?? 0) <= sendNow)
      return fail("cancelled", "delivery_lease_lost", sendNow);
    if (!await renewDeliveryLease(env.DB, row, sendNow))
      return fail("cancelled", "delivery_lease_lost", sendNow);
    const result = await sendApns({
      environment,
      tokenHex: token,
      topic,
      pushType,
      priority: pushType === "background" || pushType === "alert" && decodedPayload.sound === false ? 5 : 10,
      payload: pushPayload,
      credentials: {
        teamId: requiredSecret(env.APNS_TEAM_ID, "APNS_TEAM_ID"),
        keyId: requiredSecret(env.APNS_KEY_ID, "APNS_KEY_ID"),
        privateKeyPem: requiredSecret(env.APNS_PRIVATE_KEY, "APNS_PRIVATE_KEY")
      },
      nowSeconds: sendNow,
      tenantId: row.tenant_id,
      deliveryId: row.delivery_id
    });
    if (result.kind === "success") {
      if (row.kind === "live_activity" && row.activity_id && (payload.phase === "completed" || payload.phase === "failed"))
        await completeDeliveryAndEndActivity(env.DB, row, sendNow, row.payload_hash);
      else await completeDelivery(env.DB, row, "delivered", null, sendNow);
      message.ack();
      return;
    }
    if (result.kind === "invalid_token") {
      if (row.kind === "alert")
        await revokeDeviceForInvalidToken(
          env.DB,
          row.tenant_id,
          row.device_id,
          row.revision,
          device.token_ciphertext,
          sendNow
        );
      else if (row.activity_id)
        await revokeActivity(
          env.DB,
          row.tenant_id,
          row.activity_id,
          row.revision,
          sendNow,
          void 0,
          row.payload_hash
        );
      return fail("failed", result.reason ?? "invalid_token", sendNow);
    }
    if (result.kind === "retry" && canRetryQueue(row.attempts)) {
      await retryDelivery(
        env.DB,
        row,
        result.reason ?? "apns_retryable",
        sendNow + retryDelaySeconds(row.attempts),
        sendNow
      );
      message.retry({ delaySeconds: retryDelaySeconds(row.attempts) });
      return;
    }
    return fail("failed", result.reason ?? "apns_terminal", sendNow);
  } catch {
    const failureNow = nowSeconds();
    if (canRetryQueue(row.attempts)) {
      await retryDelivery(
        env.DB,
        row,
        "relay_delivery_error",
        failureNow + retryDelaySeconds(row.attempts),
        failureNow
      );
      message.retry({ delaySeconds: retryDelaySeconds(row.attempts) });
      return;
    }
    await completeDelivery(env.DB, row, "failed", "relay_delivery_error", failureNow);
    message.ack();
  }
}
__name(processQueueMessage, "processQueueMessage");
function liveActivityAction(phase) {
  switch (phase) {
    case "waiting":
      return "Your agent is waiting for your answer";
    case "using_tool":
      return "Your agent is using a tool";
    case "delegating":
      return "Your agent is coordinating delegated work";
    case "responding":
      return "Your agent is writing the response";
    case "completed":
      return "Your agent finished the response";
    case "failed":
      return "Your agent could not finish the response";
    default:
      return "Your agent is working on your request";
  }
}
__name(liveActivityAction, "liveActivityAction");
function activityKitPhase(phase) {
  return phase === "running" ? "thinking" : phase;
}
__name(activityKitPhase, "activityKitPhase");
function isLoopdyLinkWake(payload) {
  return payload.version === 1 && payload.kind === "link_wake" && Object.keys(payload).length === 2;
}
__name(isLoopdyLinkWake, "isLoopdyLinkWake");
async function handleQueue(batch, env) {
  for (const message of batch.messages) await processQueueMessage(message, env, nowSeconds());
}
__name(handleQueue, "handleQueue");
async function handleScheduled(env) {
  const now = nowSeconds();
  await purgeExpiredNonces(env.DB, now);
  await cleanupExpiredMaterial(env.DB, now);
  await rewrapStorageMaterial(env.DB, storageKeys(env), now);
  const rows = await dueDeliveries(env.DB, now, 50);
  let republished = 0;
  for (const row of rows) {
    if (republished >= RELAY_LIMITS.maxCronRepublish) break;
    if (await recoverDelivery(env.DB, row, now)) {
      republished += 1;
      try {
        await env.DELIVERY_QUEUE.send(
          queueCoordinates(row.tenant_id, row.delivery_id)
        );
        await markRecoveredDeliveryQueued(env.DB, row, now);
      } catch {
        await retryRecoveryAfterPublishFailure(env.DB, row, now);
      }
    }
  }
}
__name(handleScheduled, "handleScheduled");
var worker = {
  fetch(request, env, ctx) {
    return handleFetch(request, env, ctx);
  },
  queue(batch, env) {
    return handleQueue(batch, env);
  },
  scheduled(_controller, env, ctx) {
    ctx.waitUntil(handleScheduled(env));
  }
};
var index_default = worker;
export {
  LoopdyLinkEnrollment,
  index_default as default,
  handleFetch,
  handleQueue,
  handleScheduled,
  processQueueMessage,
  readBoundedRequestBody
};
//# sourceMappingURL=index.js.map
