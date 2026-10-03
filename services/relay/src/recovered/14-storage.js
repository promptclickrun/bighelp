// src/storage.ts
var StorageConflictError = class extends Error {
  static {
    __name(this, "StorageConflictError");
  }
  code;
  constructor(code, message) {
    super(message);
    this.name = "StorageConflictError";
    this.code = code;
  }
};
async function first(db, sql, ...values) {
  return db.prepare(sql).bind(...values).first();
}
__name(first, "first");
async function run(db, sql, ...values) {
  return db.prepare(sql).bind(...values).run();
}
__name(run, "run");
async function ensureTenant(db, tenantId, now) {
  await run(
    db,
    "INSERT OR IGNORE INTO tenants (tenant_id, revision, state, updated_at) VALUES (?, 1, 'active', ?)",
    tenantId,
    now
  );
}
__name(ensureTenant, "ensureTenant");
async function assertTenantActive(db, tenantId) {
  const tenant = await first(
    db,
    "SELECT state FROM tenants WHERE tenant_id = ?",
    tenantId
  );
  if (tenant?.state !== "active")
    throw new StorageConflictError("tenant_inactive", "Relay tenant is not active");
}
__name(assertTenantActive, "assertTenantActive");
async function purgeExpiredNonces(db, now, limit = 500) {
  await run(
    db,
    "DELETE FROM request_nonces WHERE rowid IN (SELECT rowid FROM request_nonces WHERE expires_at <= ? LIMIT ?)",
    now,
    Math.max(1, Math.min(500, limit))
  );
}
__name(purgeExpiredNonces, "purgeExpiredNonces");
async function cleanupExpiredMaterial(db, now, limit = 50) {
  const bounded = Math.max(1, Math.min(50, limit));
  await db.batch([
    db.prepare(
      "UPDATE devices SET token_ciphertext = '', token_key_version = '' WHERE rowid IN (SELECT rowid FROM devices WHERE (lease_expires <= ? OR revoked_at IS NOT NULL) AND (token_ciphertext <> '' OR token_key_version <> '') LIMIT ?)"
    ).bind(now, bounded),
    db.prepare(
      "UPDATE live_activities SET token_ciphertext = '', token_key_version = '', state_json = NULL, state_hash = NULL, state_timestamp = NULL WHERE rowid IN (SELECT rowid FROM live_activities WHERE (lease_expires <= ? OR status <> 'active') AND (token_ciphertext <> '' OR token_key_version <> '' OR state_json IS NOT NULL) LIMIT ?)"
    ).bind(now, bounded),
    db.prepare(
      "UPDATE deliveries SET payload_ciphertext = '', payload_key_version = '' WHERE rowid IN (SELECT rowid FROM deliveries WHERE expires <= ? AND (payload_ciphertext <> '' OR payload_key_version <> '') LIMIT ?)"
    ).bind(now, bounded),
    db.prepare(
      "DELETE FROM deliveries WHERE rowid IN (SELECT rowid FROM deliveries WHERE expires <= ? AND state IN ('delivered', 'failed', 'cancelled') LIMIT ?)"
    ).bind(now, bounded),
    db.prepare(
      "DELETE FROM idempotency_keys WHERE rowid IN (SELECT rowid FROM idempotency_keys WHERE created_at < ? LIMIT ?)"
    ).bind(now - RELAY_LIMITS.idempotencyRetentionSeconds, bounded),
    db.prepare(
      "DELETE FROM service_daily_usage WHERE rowid IN (SELECT rowid FROM service_daily_usage WHERE usage_day < ? LIMIT ?)"
    ).bind(new Date((now - 2592e3) * 1e3).toISOString().slice(0, 10), bounded),
    db.prepare(
      "DELETE FROM daily_usage WHERE rowid IN (SELECT rowid FROM daily_usage WHERE usage_day < ? LIMIT ?)"
    ).bind(new Date((now - 2592e3) * 1e3).toISOString().slice(0, 10), bounded)
  ]);
}
__name(cleanupExpiredMaterial, "cleanupExpiredMaterial");
async function rewrapStorageMaterial(db, keys, now, limit = 50) {
  const current = currentStorageKeyVersion(keys);
  const bounded = Math.max(1, Math.min(50, limit));
  let changed = 0;
  const devices = await db.prepare(
    "SELECT tenant_id, device_id, token_ciphertext, token_key_version FROM devices WHERE token_ciphertext <> '' AND token_key_version <> ? AND lease_expires > ? ORDER BY rowid ASC LIMIT ?"
  ).bind(current, now, bounded).all();
  for (const row of devices.results) {
    try {
      const next = await encryptAtRest(
        current,
        await decryptAtRest(decodeEncrypted(row.token_ciphertext), keys),
        keys
      );
      const result = await run(
        db,
        "UPDATE devices SET token_ciphertext = ?, token_key_version = ?, updated_at = ? WHERE tenant_id = ? AND device_id = ? AND token_key_version = ? AND token_ciphertext = ?",
        encodeEncrypted(next),
        current,
        now,
        row.tenant_id,
        row.device_id,
        row.token_key_version,
        row.token_ciphertext
      );
      changed += result.meta.changes;
    } catch {
    }
  }
  const activities = await db.prepare(
    `SELECT tenant_id, activity_id, token_ciphertext, token_key_version, state_json FROM live_activities WHERE status = 'active' AND lease_expires > ? AND ((token_ciphertext <> '' AND token_key_version <> ?) OR (state_json IS NOT NULL AND (instr(state_json, '"keyVersion":"' || ? || '"') = 0 OR instr(state_json, '"nonce":') = 0))) ORDER BY rowid ASC LIMIT ?`
  ).bind(now, current, current, bounded).all();
  for (const row of activities.results) {
    if (row.token_ciphertext !== "" && row.token_key_version !== current) {
      try {
        const next = await encryptAtRest(
          current,
          await decryptAtRest(decodeEncrypted(row.token_ciphertext), keys),
          keys
        );
        const result = await run(
          db,
          "UPDATE live_activities SET token_ciphertext = ?, token_key_version = ?, updated_at = ? WHERE tenant_id = ? AND activity_id = ? AND token_key_version = ? AND token_ciphertext = ?",
          encodeEncrypted(next),
          current,
          now,
          row.tenant_id,
          row.activity_id,
          row.token_key_version,
          row.token_ciphertext
        );
        changed += result.meta.changes;
      } catch {
      }
    }
    if (row.state_json) {
      try {
        const next = await encryptAtRest(
          current,
          await decodeStoredState(row.state_json, keys),
          keys
        );
        const result = await run(
          db,
          "UPDATE live_activities SET state_json = ?, updated_at = ? WHERE tenant_id = ? AND activity_id = ? AND state_json = ?",
          encodeEncrypted(next),
          now,
          row.tenant_id,
          row.activity_id,
          row.state_json
        );
        changed += result.meta.changes;
      } catch {
      }
    }
  }
  const deliveries = await db.prepare(
    "SELECT tenant_id, delivery_id, payload_ciphertext, payload_key_version FROM deliveries WHERE payload_ciphertext <> '' AND payload_key_version <> ? AND expires > ? ORDER BY rowid ASC LIMIT ?"
  ).bind(current, now, bounded).all();
  for (const row of deliveries.results) {
    try {
      const next = await encryptAtRest(
        current,
        await decryptAtRest(decodeEncrypted(row.payload_ciphertext), keys),
        keys
      );
      const result = await run(
        db,
        "UPDATE deliveries SET payload_ciphertext = ?, payload_key_version = ?, updated_at = ? WHERE tenant_id = ? AND delivery_id = ? AND payload_key_version = ? AND payload_ciphertext = ?",
        encodeEncrypted(next),
        current,
        now,
        row.tenant_id,
        row.delivery_id,
        row.payload_key_version,
        row.payload_ciphertext
      );
      changed += result.meta.changes;
    } catch {
    }
  }
  return changed;
}
__name(rewrapStorageMaterial, "rewrapStorageMaterial");
function requestMutationStatements(db, input) {
  return [
    db.prepare(
      "INSERT INTO request_nonces (tenant_id, nonce, expires_at, created_at) VALUES (?, ?, ?, ?)"
    ).bind(input.tenantId, input.nonce, input.now + RELAY_LIMITS.nonceWindowSeconds, input.now),
    db.prepare(
      "INSERT INTO idempotency_keys (tenant_id, idempotency_key, route, body_digest, response_json, created_at) VALUES (?, ?, ?, ?, ?, ?)"
    ).bind(
      input.tenantId,
      input.idempotencyKey,
      input.route,
      input.bodyDigest,
      relayCanonicalJson(input.response),
      input.now
    )
  ];
}
__name(requestMutationStatements, "requestMutationStatements");
async function runManagementMutationAtomically(db, input, mutation) {
  return db.batch([...requestMutationStatements(db, input), ...mutation]);
}
__name(runManagementMutationAtomically, "runManagementMutationAtomically");
async function readIdempotency(db, tenantId, key) {
  const row = await first(
    db,
    "SELECT route, body_digest, response_json FROM idempotency_keys WHERE tenant_id = ? AND idempotency_key = ?",
    tenantId,
    key
  );
  if (!row) return null;
  let response2 = null;
  if (row.response_json) {
    const parsed = JSON.parse(row.response_json);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed))
      response2 = parsed;
  }
  return { route: row.route, bodyDigest: row.body_digest, response: response2 };
}
__name(readIdempotency, "readIdempotency");
async function recordRequestAtomically(db, input) {
  await db.batch([
    db.prepare(
      "INSERT INTO request_nonces (tenant_id, nonce, expires_at, created_at) VALUES (?, ?, ?, ?)"
    ).bind(input.tenantId, input.nonce, input.now + RELAY_LIMITS.nonceWindowSeconds, input.now),
    db.prepare(
      "INSERT INTO idempotency_keys (tenant_id, idempotency_key, route, body_digest, response_json, created_at) VALUES (?, ?, ?, ?, ?, ?)"
    ).bind(
      input.tenantId,
      input.idempotencyKey,
      input.route,
      input.bodyDigest,
      relayCanonicalJson(input.response),
      input.now
    )
  ]);
}
__name(recordRequestAtomically, "recordRequestAtomically");
function encodeEncrypted(value) {
  return relayCanonicalJson(value);
}
__name(encodeEncrypted, "encodeEncrypted");
function decodeEncrypted(value) {
  const parsed = JSON.parse(value);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
    throw new Error("Stored ciphertext is invalid");
  const candidate = parsed;
  if (typeof candidate.keyVersion !== "string" || typeof candidate.nonce !== "string" || typeof candidate.ciphertext !== "string")
    throw new Error("Stored ciphertext is invalid");
  return candidate;
}
__name(decodeEncrypted, "decodeEncrypted");
async function decodeStoredState(value, keys) {
  try {
    return await decryptAtRest(decodeEncrypted(value), keys);
  } catch {
    const parsed = JSON.parse(value);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
      throw new Error("Stored Live Activity state is invalid");
    const candidate = parsed;
    if (typeof candidate.keyVersion === "string" && typeof candidate.nonce === "string" && typeof candidate.ciphertext === "string")
      throw new Error("Stored Live Activity state could not be decrypted");
    return new TextEncoder().encode(relayCanonicalJson(parsed));
  }
}
__name(decodeStoredState, "decodeStoredState");
async function encryptedToken(value, keys) {
  return decryptAtRest(decodeEncrypted(value), keys);
}
__name(encryptedToken, "encryptedToken");
async function registerDevice(db, input) {
  await assertTenantActive(db, input.tenant.tenant_id);
  const existing = await getDevice(db, input.tenant.tenant_id, input.body.device_id);
  const tombstone = await first(
    db,
    "SELECT revision FROM device_tombstones WHERE tenant_id = ? AND device_id = ?",
    input.tenant.tenant_id,
    input.body.device_id
  );
  if (tombstone && input.body.revision <= tombstone.revision)
    throw new StorageConflictError("stale_revision", "Device revision is revoked or stale");
  if (existing && input.body.revision <= existing.revision)
    throw new StorageConflictError("stale_revision", "Device revision is stale");
  const keyVersion = currentStorageKeyVersion(input.keys);
  const registrationGuard = `${input.tenant.tenant_id}:${input.body.device_id}:register`;
  const tombstoneGuard = `${registrationGuard}:tombstone`;
  const tenantGuard = `${registrationGuard}:tenant`;
  const token = await encryptAtRest(
    keyVersion,
    new TextEncoder().encode(input.body.push_token),
    input.keys
  );
  const mutation = [
    db.prepare(
      `INSERT INTO devices (tenant_id, device_id, revision, lease_expires, recipient_key_id, recipient_public_key, token_ciphertext, token_key_version, environment, topic, label, groups_json, acknowledged_sender_key_ids_json, sender_key_revision, revoked_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', '[]', '[]', ?, NULL, ?)
    ON CONFLICT (tenant_id, device_id) DO UPDATE SET revision = excluded.revision, lease_expires = excluded.lease_expires, recipient_key_id = excluded.recipient_key_id, recipient_public_key = excluded.recipient_public_key, token_ciphertext = excluded.token_ciphertext, token_key_version = excluded.token_key_version, environment = excluded.environment, topic = excluded.topic, label = '', groups_json = '[]', revoked_at = NULL, updated_at = excluded.updated_at
    WHERE excluded.revision > devices.revision`
    ).bind(
      input.tenant.tenant_id,
      input.body.device_id,
      input.body.revision,
      input.body.lease_expires,
      input.body.recipient_key_id,
      input.body.recipient_public_key,
      encodeEncrypted(token),
      token.keyVersion,
      input.body.environment,
      input.body.topic,
      input.tenant.sender_key_revision,
      input.now
    ),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN changes() = 1 THEN ? ELSE NULL END)"
    ).bind(registrationGuard),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN NOT EXISTS (SELECT 1 FROM device_tombstones WHERE tenant_id = ? AND device_id = ? AND revision >= ?) THEN ? ELSE NULL END)"
    ).bind(input.tenant.tenant_id, input.body.device_id, input.body.revision, tombstoneGuard),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN EXISTS (SELECT 1 FROM tenants WHERE tenant_id = ? AND state = 'active') THEN ? ELSE NULL END)"
    ).bind(input.tenant.tenant_id, tenantGuard),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?) AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?) AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?) THEN ? ELSE NULL END)"
    ).bind(registrationGuard, tombstoneGuard, tenantGuard, `${registrationGuard}:commit`),
    db.prepare(
      "DELETE FROM device_tombstones WHERE tenant_id = ? AND device_id = ? AND revision < ?"
    ).bind(input.tenant.tenant_id, input.body.device_id, input.body.revision),
    db.prepare("DELETE FROM admission_guards WHERE guard_id IN (?, ?, ?, ?)").bind(registrationGuard, tombstoneGuard, tenantGuard, `${registrationGuard}:commit`)
  ];
  try {
    if (input.request) await runManagementMutationAtomically(db, input.request, mutation);
    else await db.batch(mutation);
  } catch (error51) {
    const current = await getDevice(db, input.tenant.tenant_id, input.body.device_id);
    const latestTombstone = await first(
      db,
      "SELECT revision FROM device_tombstones WHERE tenant_id = ? AND device_id = ?",
      input.tenant.tenant_id,
      input.body.device_id
    );
    if (current && current.revision >= input.body.revision || latestTombstone && latestTombstone.revision >= input.body.revision)
      throw new StorageConflictError("stale_revision", "Device revision is stale");
    throw error51;
  }
  const row = await getDevice(db, input.tenant.tenant_id, input.body.device_id);
  if (!row) throw new Error("Device registration was not persisted");
  return row;
}
__name(registerDevice, "registerDevice");
async function getDevice(db, tenantId, deviceId) {
  return first(
    db,
    "SELECT * FROM devices WHERE tenant_id = ? AND device_id = ?",
    tenantId,
    deviceId
  );
}
__name(getDevice, "getDevice");
async function acknowledgeSenderKeys(db, tenantId, body, request, now = Math.floor(Date.now() / 1e3)) {
  const existing = await getDevice(db, tenantId, body.device_id);
  if (!existing || existing.revoked_at !== null)
    throw new StorageConflictError("device_not_active", "Device is not active");
  if (existing.revision >= body.revision)
    throw new StorageConflictError(
      "device_revision",
      "Sender-key acknowledgement revision is stale"
    );
  const mutation = [
    db.prepare(
      "UPDATE devices SET revision = ?, acknowledged_sender_key_ids_json = ?, sender_key_revision = ?, updated_at = ? WHERE tenant_id = ? AND device_id = ? AND revoked_at IS NULL AND revision < ? AND EXISTS (SELECT 1 FROM tenants WHERE tenant_id = ? AND state = 'active')"
    ).bind(
      body.revision,
      relayCanonicalJson(body.acknowledged_sender_key_ids),
      body.sender_key_revision,
      now,
      tenantId,
      body.device_id,
      body.revision,
      tenantId
    ),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN changes() = 1 THEN ? ELSE NULL END)"
    ).bind(`${tenantId}:${body.device_id}:ack`),
    db.prepare("DELETE FROM admission_guards WHERE guard_id = ?").bind(`${tenantId}:${body.device_id}:ack`)
  ];
  let batchResults;
  try {
    batchResults = request ? await runManagementMutationAtomically(db, request, mutation) : await db.batch(mutation);
  } catch (error51) {
    const current = await getDevice(db, tenantId, body.device_id);
    if (current && current.revision >= body.revision)
      throw new StorageConflictError(
        "device_revision",
        "Sender-key acknowledgement revision is stale"
      );
    throw error51;
  }
  const result = batchResults[request ? 2 : 0];
  if (result?.meta.changes !== 1)
    throw new StorageConflictError("device_not_active", "Device is not active");
}
__name(acknowledgeSenderKeys, "acknowledgeSenderKeys");
async function revokeDevice(db, tenantId, deviceId, revision2, now, request) {
  const existing = await getDevice(db, tenantId, deviceId);
  if (existing && revision2 < existing.revision)
    throw new StorageConflictError("stale_revision", "Device revision is stale");
  if (existing && existing.revoked_at !== null && revision2 <= existing.revision)
    throw new StorageConflictError("stale_revision", "Device revision is revoked or stale");
  const tombstone = await first(
    db,
    "SELECT revision FROM device_tombstones WHERE tenant_id = ? AND device_id = ?",
    tenantId,
    deviceId
  );
  if (tombstone && revision2 < tombstone.revision)
    throw new StorageConflictError("stale_revision", "Device revision is stale");
  if (tombstone && revision2 <= tombstone.revision)
    throw new StorageConflictError("stale_revision", "Device revision is stale");
  const mutationGuard = `${tenantId}:${deviceId}:revoke:${revision2}`;
  const mutation = [
    db.prepare(
      "UPDATE devices SET revision = ?, revoked_at = ?, token_ciphertext = '', token_key_version = '', updated_at = ? WHERE tenant_id = ? AND device_id = ? AND revision <= ? AND (revoked_at IS NULL OR revision < ?) AND EXISTS (SELECT 1 FROM tenants WHERE tenant_id = ? AND state = 'active')"
    ).bind(revision2, now, now, tenantId, deviceId, revision2, revision2, tenantId),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN changes() = 1 OR (NOT EXISTS (SELECT 1 FROM devices WHERE tenant_id = ? AND device_id = ?) AND NOT EXISTS (SELECT 1 FROM device_tombstones WHERE tenant_id = ? AND device_id = ? AND revision >= ?) AND EXISTS (SELECT 1 FROM tenants WHERE tenant_id = ? AND state = 'active')) THEN ? ELSE NULL END)"
    ).bind(tenantId, deviceId, tenantId, deviceId, revision2, tenantId, mutationGuard),
    db.prepare(
      "INSERT INTO device_tombstones (tenant_id, device_id, revision, revoked_at) SELECT ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?) ON CONFLICT (tenant_id, device_id) DO UPDATE SET revision = MAX(device_tombstones.revision, excluded.revision), revoked_at = excluded.revoked_at"
    ).bind(tenantId, deviceId, revision2, now, mutationGuard),
    db.prepare(
      "UPDATE deliveries SET state = 'cancelled', lease_id = NULL, lease_expires = NULL, payload_ciphertext = '', payload_key_version = '', updated_at = ? WHERE tenant_id = ? AND device_id = ? AND state IN ('pending_enqueue', 'queued', 'sending') AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?)"
    ).bind(now, tenantId, deviceId, mutationGuard),
    db.prepare(
      "UPDATE live_activities SET status = 'revoked', token_ciphertext = '', token_key_version = '', state_json = NULL, state_hash = NULL, state_timestamp = NULL, updated_at = ? WHERE tenant_id = ? AND device_id = ? AND status = 'active' AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?)"
    ).bind(now, tenantId, deviceId, mutationGuard),
    db.prepare("DELETE FROM admission_guards WHERE guard_id = ?").bind(mutationGuard)
  ];
  try {
    if (request) await runManagementMutationAtomically(db, request, mutation);
    else await db.batch(mutation);
  } catch (error51) {
    const current = await getDevice(db, tenantId, deviceId);
    if (current && (current.revision >= revision2 || current.revoked_at !== null))
      throw new StorageConflictError("stale_revision", "Device revision is stale");
    throw error51;
  }
}
__name(revokeDevice, "revokeDevice");
async function revokeTenant(db, tenantId, revision2, now, request) {
  const existing = await first(
    db,
    "SELECT revision, state FROM tenants WHERE tenant_id = ?",
    tenantId
  );
  if (existing && (existing.state === "active" && existing.revision > revision2 || existing.state === "revoked" && existing.revision >= revision2 || existing.state === "deleted"))
    throw new StorageConflictError("stale_revision", "Tenant revision is stale");
  const mutationGuard = `${tenantId}:tenant-revoke:${revision2}`;
  const mutation = [
    db.prepare(
      "UPDATE tenants SET revision = ?, state = 'revoked', updated_at = ? WHERE tenant_id = ? AND ((state = 'active' AND revision <= ?) OR (state = 'revoked' AND revision < ?))"
    ).bind(revision2, now, tenantId, revision2, revision2),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN changes() = 1 THEN ? ELSE NULL END)"
    ).bind(mutationGuard),
    db.prepare(
      "UPDATE devices SET revoked_at = ?, token_ciphertext = '', token_key_version = '', updated_at = ? WHERE tenant_id = ? AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?)"
    ).bind(now, now, tenantId, mutationGuard),
    db.prepare(
      "UPDATE deliveries SET state = 'cancelled', lease_id = NULL, lease_expires = NULL, payload_ciphertext = '', payload_key_version = '', updated_at = ? WHERE tenant_id = ? AND state IN ('pending_enqueue', 'queued', 'sending') AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?)"
    ).bind(now, tenantId, mutationGuard),
    db.prepare(
      "UPDATE live_activities SET status = 'revoked', token_ciphertext = '', token_key_version = '', state_json = NULL, state_hash = NULL, state_timestamp = NULL, updated_at = ? WHERE tenant_id = ? AND status = 'active' AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?)"
    ).bind(now, tenantId, mutationGuard),
    db.prepare("DELETE FROM admission_guards WHERE guard_id = ?").bind(mutationGuard)
  ];
  try {
    if (request) await runManagementMutationAtomically(db, request, mutation);
    else await db.batch(mutation);
  } catch (error51) {
    const current = await first(
      db,
      "SELECT revision, state FROM tenants WHERE tenant_id = ?",
      tenantId
    );
    if (current && (current.revision >= revision2 || current.state !== "active"))
      throw new StorageConflictError("stale_revision", "Tenant revision is stale");
    throw error51;
  }
}
__name(revokeTenant, "revokeTenant");
async function deleteTenant(db, tenantId, revision2, now, request) {
  const existing = await first(
    db,
    "SELECT revision, state FROM tenants WHERE tenant_id = ?",
    tenantId
  );
  if (existing && (existing.state === "active" && existing.revision > revision2 || existing.state === "revoked" && existing.revision >= revision2 || existing.state === "deleted" && existing.revision >= revision2))
    throw new StorageConflictError("stale_revision", "Tenant revision is stale");
  const mutationGuard = `${tenantId}:tenant-delete:${revision2}`;
  const mutation = [
    db.prepare(
      "UPDATE tenants SET revision = ?, state = 'deleted', updated_at = ? WHERE tenant_id = ? AND ((state = 'active' AND revision <= ?) OR (state = 'revoked' AND revision < ?))"
    ).bind(revision2, now, tenantId, revision2, revision2),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN changes() = 1 THEN ? ELSE NULL END)"
    ).bind(mutationGuard),
    db.prepare(
      "DELETE FROM deliveries WHERE tenant_id = ? AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?)"
    ).bind(tenantId, mutationGuard),
    db.prepare(
      "DELETE FROM live_activities WHERE tenant_id = ? AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?)"
    ).bind(tenantId, mutationGuard),
    db.prepare(
      "DELETE FROM devices WHERE tenant_id = ? AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?)"
    ).bind(tenantId, mutationGuard),
    db.prepare(
      "DELETE FROM device_tombstones WHERE tenant_id = ? AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?)"
    ).bind(tenantId, mutationGuard),
    db.prepare(
      "DELETE FROM activity_tombstones WHERE tenant_id = ? AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?)"
    ).bind(tenantId, mutationGuard),
    db.prepare(
      "DELETE FROM daily_usage WHERE tenant_id = ? AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?)"
    ).bind(tenantId, mutationGuard),
    request ? db.prepare(
      "DELETE FROM request_nonces WHERE tenant_id = ? AND nonce <> ? AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?)"
    ).bind(tenantId, request.nonce, mutationGuard) : db.prepare(
      "DELETE FROM request_nonces WHERE tenant_id = ? AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?)"
    ).bind(tenantId, mutationGuard),
    request ? db.prepare(
      "DELETE FROM idempotency_keys WHERE tenant_id = ? AND idempotency_key <> ? AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?)"
    ).bind(tenantId, request.idempotencyKey, mutationGuard) : db.prepare(
      "DELETE FROM idempotency_keys WHERE tenant_id = ? AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?)"
    ).bind(tenantId, mutationGuard),
    db.prepare("DELETE FROM admission_guards WHERE guard_id = ?").bind(mutationGuard)
  ];
  try {
    if (request) await runManagementMutationAtomically(db, request, mutation);
    else await db.batch(mutation);
  } catch (error51) {
    const current = await first(
      db,
      "SELECT revision, state FROM tenants WHERE tenant_id = ?",
      tenantId
    );
    if (current && (current.revision >= revision2 || current.state === "deleted"))
      throw new StorageConflictError("stale_revision", "Tenant revision is stale");
    throw error51;
  }
}
__name(deleteTenant, "deleteTenant");
async function registerLiveActivity(db, tenantId, body, keys, now, request) {
  await assertTenantActive(db, tenantId);
  const device = await getDevice(db, tenantId, body.device_id);
  if (!device || device.revoked_at !== null || device.lease_expires <= now)
    throw new StorageConflictError("device_revision", "Live Activity device is unavailable");
  const tombstone = await first(
    db,
    "SELECT revision FROM activity_tombstones WHERE tenant_id = ? AND activity_id = ?",
    tenantId,
    body.activity_id
  );
  const existing = await getActivity(db, tenantId, body.activity_id);
  if (tombstone && body.revision <= tombstone.revision)
    throw new StorageConflictError("stale_revision", "Live Activity revision is revoked or stale");
  if (existing && existing.revision >= body.revision)
    throw new StorageConflictError("stale_revision", "Live Activity revision is stale");
  if (existing && existing.state_timestamp !== null && Number(body.timestamp ?? now) <= existing.state_timestamp)
    throw new StorageConflictError("state_timestamp", "Live Activity state timestamp is stale");
  const keyVersion = currentStorageKeyVersion(keys);
  const registrationGuard = `${tenantId}:${body.activity_id}:register`;
  const tombstoneGuard = `${registrationGuard}:tombstone`;
  const deviceGuard = `${registrationGuard}:device`;
  const tenantGuard = `${registrationGuard}:tenant`;
  const token = await encryptAtRest(keyVersion, new TextEncoder().encode(body.push_token), keys);
  const mutation = [
    db.prepare(
      `INSERT INTO live_activities (tenant_id, activity_id, device_id, revision, lease_expires, token_ciphertext, token_key_version, environment, topic, session_ref, state_json, state_hash, state_timestamp, status, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, 'active', ?)
    ON CONFLICT (tenant_id, activity_id) DO UPDATE SET device_id = excluded.device_id, revision = excluded.revision, lease_expires = excluded.lease_expires, token_ciphertext = excluded.token_ciphertext, token_key_version = excluded.token_key_version, environment = excluded.environment, topic = excluded.topic, session_ref = excluded.session_ref, status = 'active', updated_at = excluded.updated_at
    WHERE excluded.revision > live_activities.revision
      AND (live_activities.state_timestamp IS NULL OR ? > live_activities.state_timestamp)`
    ).bind(
      tenantId,
      body.activity_id,
      body.device_id,
      body.revision,
      body.lease_expires,
      encodeEncrypted(token),
      token.keyVersion,
      body.environment,
      body.topic,
      body.session_ref,
      now,
      Number(body.timestamp ?? now)
    ),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN changes() = 1 THEN ? ELSE NULL END)"
    ).bind(registrationGuard),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN EXISTS (SELECT 1 FROM devices WHERE tenant_id = ? AND device_id = ? AND revoked_at IS NULL AND lease_expires > ?) THEN ? ELSE NULL END)"
    ).bind(tenantId, body.device_id, now, deviceGuard),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN NOT EXISTS (SELECT 1 FROM activity_tombstones WHERE tenant_id = ? AND activity_id = ? AND revision >= ?) THEN ? ELSE NULL END)"
    ).bind(tenantId, body.activity_id, body.revision, tombstoneGuard),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN EXISTS (SELECT 1 FROM tenants WHERE tenant_id = ? AND state = 'active') THEN ? ELSE NULL END)"
    ).bind(tenantId, tenantGuard),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?) AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?) AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?) AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?) THEN ? ELSE NULL END)"
    ).bind(
      registrationGuard,
      deviceGuard,
      tombstoneGuard,
      tenantGuard,
      `${registrationGuard}:commit`
    ),
    db.prepare(
      "DELETE FROM activity_tombstones WHERE tenant_id = ? AND activity_id = ? AND revision < ?"
    ).bind(tenantId, body.activity_id, body.revision),
    db.prepare("DELETE FROM admission_guards WHERE guard_id IN (?, ?, ?, ?, ?)").bind(
      registrationGuard,
      deviceGuard,
      tombstoneGuard,
      tenantGuard,
      `${registrationGuard}:commit`
    )
  ];
  try {
    if (request) await runManagementMutationAtomically(db, request, mutation);
    else await db.batch(mutation);
  } catch (error51) {
    const current = await getActivity(db, tenantId, body.activity_id);
    const latestTombstone = await first(
      db,
      "SELECT revision FROM activity_tombstones WHERE tenant_id = ? AND activity_id = ?",
      tenantId,
      body.activity_id
    );
    if (current && current.revision >= body.revision || latestTombstone && latestTombstone.revision >= body.revision)
      throw new StorageConflictError("stale_revision", "Live Activity revision is stale");
    throw error51;
  }
  const row = await getActivity(db, tenantId, body.activity_id);
  if (!row) throw new Error("Live Activity registration was not persisted");
  return row;
}
__name(registerLiveActivity, "registerLiveActivity");
async function getActivity(db, tenantId, activityId) {
  return first(
    db,
    "SELECT * FROM live_activities WHERE tenant_id = ? AND activity_id = ?",
    tenantId,
    activityId
  );
}
__name(getActivity, "getActivity");
async function revokeActivity(db, tenantId, activityId, revision2, now, request, expectedStateHash) {
  const existing = await getActivity(db, tenantId, activityId);
  if (existing && revision2 < existing.revision)
    throw new StorageConflictError("stale_revision", "Live Activity revision is stale");
  if (expectedStateHash !== void 0 && existing?.state_hash !== expectedStateHash) return;
  if (existing && existing.status !== "active" && revision2 <= existing.revision)
    throw new StorageConflictError("stale_revision", "Live Activity revision is ended or stale");
  const tombstone = await first(
    db,
    "SELECT revision FROM activity_tombstones WHERE tenant_id = ? AND activity_id = ?",
    tenantId,
    activityId
  );
  if (tombstone && revision2 < tombstone.revision)
    throw new StorageConflictError("stale_revision", "Live Activity revision is stale");
  if (tombstone && revision2 <= tombstone.revision)
    throw new StorageConflictError("stale_revision", "Live Activity revision is stale");
  const mutationGuard = `${tenantId}:${activityId}:revoke:${revision2}`;
  const statePredicate = expectedStateHash === void 0 ? "" : " AND state_hash = ?";
  const mutation = [
    db.prepare(
      `UPDATE live_activities SET status = 'revoked', revision = ?, token_ciphertext = '', token_key_version = '', state_json = NULL, state_hash = NULL, state_timestamp = NULL, updated_at = ?
         WHERE tenant_id = ? AND activity_id = ? AND revision <= ? AND (status IN ('active', 'ended') OR revision < ?) AND EXISTS (SELECT 1 FROM tenants WHERE tenant_id = ? AND state = 'active')${statePredicate}`
    ).bind(
      revision2,
      now,
      tenantId,
      activityId,
      revision2,
      revision2,
      tenantId,
      ...expectedStateHash === void 0 ? [] : [expectedStateHash]
    ),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN changes() = 1 OR (NOT EXISTS (SELECT 1 FROM live_activities WHERE tenant_id = ? AND activity_id = ?) AND NOT EXISTS (SELECT 1 FROM activity_tombstones WHERE tenant_id = ? AND activity_id = ? AND revision >= ?) AND EXISTS (SELECT 1 FROM tenants WHERE tenant_id = ? AND state = 'active')) THEN ? ELSE NULL END)"
    ).bind(tenantId, activityId, tenantId, activityId, revision2, tenantId, mutationGuard),
    db.prepare(
      "INSERT INTO activity_tombstones (tenant_id, activity_id, revision, revoked_at) SELECT ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?) ON CONFLICT (tenant_id, activity_id) DO UPDATE SET revision = MAX(activity_tombstones.revision, excluded.revision), revoked_at = excluded.revoked_at"
    ).bind(tenantId, activityId, revision2, now, mutationGuard),
    db.prepare(
      "UPDATE deliveries SET state = 'cancelled', lease_id = NULL, lease_expires = NULL, payload_ciphertext = '', payload_key_version = '', updated_at = ? WHERE tenant_id = ? AND activity_id = ? AND state IN ('pending_enqueue', 'queued', 'sending') AND EXISTS (SELECT 1 FROM admission_guards WHERE guard_id = ?)"
    ).bind(now, tenantId, activityId, mutationGuard),
    db.prepare("DELETE FROM admission_guards WHERE guard_id = ?").bind(mutationGuard)
  ];
  try {
    if (request) await runManagementMutationAtomically(db, request, mutation);
    else await db.batch(mutation);
  } catch (error51) {
    const current = await getActivity(db, tenantId, activityId);
    if (current && (current.revision >= revision2 || current.status !== "active"))
      throw new StorageConflictError("stale_revision", "Live Activity revision is stale");
    throw error51;
  }
}
__name(revokeActivity, "revokeActivity");
async function countUsage(db, tenantId, now) {
  const day = new Date(now * 1e3).toISOString().slice(0, 10);
  const row = await first(
    db,
    "SELECT accepted, routine_live_activity FROM daily_usage WHERE tenant_id = ? AND usage_day = ?",
    tenantId,
    day
  );
  return { accepted: row?.accepted ?? 0, routine: row?.routine_live_activity ?? 0 };
}
__name(countUsage, "countUsage");
async function countGlobalUsage(db, now) {
  const day = new Date(now * 1e3).toISOString().slice(0, 10);
  const row = await first(
    db,
    "SELECT accepted, routine_live_activity, recovery FROM service_daily_usage WHERE usage_day = ?",
    day
  );
  return {
    accepted: row?.accepted ?? 0,
    routine: row?.routine_live_activity ?? 0,
    recovery: row?.recovery ?? 0
  };
}
__name(countGlobalUsage, "countGlobalUsage");
function hashPayload(payload) {
  return Array.from(
    relaySha256(new TextEncoder().encode(relayCanonicalJson(payload))),
    (byte) => byte.toString(16).padStart(2, "0")
  ).join("");
}
__name(hashPayload, "hashPayload");
async function admitDeliveryAtomically(db, input) {
  const payloadHash2 = hashPayload(input.payload);
  const storedPayload = input.kind === "alert" ? {
    envelope: input.payload,
    ...input.sound === false ? { sound: false } : {}
  } : input.payload;
  const encrypted = await encryptAtRest(
    currentStorageKeyVersion(input.keys),
    new TextEncoder().encode(relayCanonicalJson(storedPayload)),
    input.keys
  );
  const day = new Date(input.now * 1e3).toISOString().slice(0, 10);
  const guardPrefix = `${input.tenantId}:${input.deliveryId}`;
  const quotaGuard = `${guardPrefix}:quota`;
  const globalQuotaGuard = `${guardPrefix}:global-quota`;
  const deliveryGuard = `${guardPrefix}:delivery`;
  const stateGuard = `${guardPrefix}:state`;
  const statements = [
    db.prepare(
      "INSERT OR IGNORE INTO tenants (tenant_id, revision, state, updated_at) VALUES (?, 1, 'active', ?)"
    ).bind(input.tenantId, input.now),
    db.prepare(
      "INSERT INTO request_nonces (tenant_id, nonce, expires_at, created_at) VALUES (?, ?, ?, ?)"
    ).bind(input.tenantId, input.nonce, input.now + RELAY_LIMITS.nonceWindowSeconds, input.now),
    db.prepare(
      "INSERT INTO idempotency_keys (tenant_id, idempotency_key, route, body_digest, response_json, created_at) VALUES (?, ?, ?, ?, ?, ?)"
    ).bind(
      input.tenantId,
      input.idempotencyKey,
      input.route,
      input.bodyDigest,
      relayCanonicalJson(input.response),
      input.now
    ),
    db.prepare("INSERT OR IGNORE INTO service_daily_usage (usage_day) VALUES (?)").bind(day),
    input.routine ? db.prepare(
      "UPDATE service_daily_usage SET accepted = accepted + 1, routine_live_activity = routine_live_activity + 1 WHERE usage_day = ? AND accepted < ? AND routine_live_activity < ? AND accepted < ?"
    ).bind(
      day,
      RELAY_LIMITS.hardAcceptedPerDay,
      RELAY_LIMITS.routineLiveActivityPerDay,
      RELAY_LIMITS.expectedAcceptedPerDay
    ) : db.prepare(
      "UPDATE service_daily_usage SET accepted = accepted + 1 WHERE usage_day = ? AND accepted < ?"
    ).bind(day, RELAY_LIMITS.hardAcceptedPerDay),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN changes() = 1 THEN ? ELSE NULL END)"
    ).bind(globalQuotaGuard)
  ];
  if (input.kind === "live_activity") {
    if (!input.activityId || input.stateHash === void 0 || input.stateTimestamp === void 0) {
      throw new Error("Live Activity admission requires state coordinates");
    }
    const routinePredicate = input.routine ? "AND (state_timestamp IS NULL OR ? - state_timestamp >= ?)" : "";
    const routineValues = input.routine ? [input.stateTimestamp, RELAY_LIMITS.routineLiveActivityIntervalSeconds] : [];
    statements.push(
      db.prepare(
        `UPDATE live_activities SET state_json = ?, state_hash = ?, state_timestamp = ?, updated_at = ?
           WHERE tenant_id = ? AND activity_id = ? AND device_id = ? AND status = 'active'
             AND lease_expires > ? AND revision = ? AND COALESCE(state_hash, '') <> ?
             AND (state_timestamp IS NULL OR ? > state_timestamp)
             AND EXISTS (SELECT 1 FROM tenants WHERE tenant_id = ? AND state = 'active')
             ${routinePredicate}`
      ).bind(
        encodeEncrypted(encrypted),
        input.stateHash,
        input.stateTimestamp,
        input.now,
        input.tenantId,
        input.activityId,
        input.deviceId,
        input.now,
        input.revision,
        input.stateHash,
        input.stateTimestamp,
        input.tenantId,
        ...routineValues
      ),
      db.prepare(
        "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN changes() = 1 THEN ? ELSE NULL END)"
      ).bind(stateGuard)
    );
  }
  statements.push(
    db.prepare("INSERT OR IGNORE INTO daily_usage (tenant_id, usage_day) VALUES (?, ?)").bind(input.tenantId, day),
    input.routine ? db.prepare(
      "UPDATE daily_usage SET accepted = accepted + 1, routine_live_activity = routine_live_activity + 1 WHERE tenant_id = ? AND usage_day = ? AND accepted < ? AND routine_live_activity < ? AND accepted < ?"
    ).bind(
      input.tenantId,
      day,
      RELAY_LIMITS.hardAcceptedPerDay,
      RELAY_LIMITS.routineLiveActivityPerDay,
      RELAY_LIMITS.expectedAcceptedPerDay
    ) : db.prepare(
      "UPDATE daily_usage SET accepted = accepted + 1 WHERE tenant_id = ? AND usage_day = ? AND accepted < ?"
    ).bind(input.tenantId, day, RELAY_LIMITS.hardAcceptedPerDay),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN changes() = 1 THEN ? ELSE NULL END)"
    ).bind(quotaGuard)
  );
  const deliveryInsert = input.kind === "alert" ? db.prepare(
    `INSERT INTO deliveries (tenant_id, delivery_id, device_id, kind, activity_id, revision, issued, expires, payload_ciphertext, payload_key_version, payload_hash, state, attempts, next_attempt, lease_id, lease_expires, last_error, created_at, updated_at)
           SELECT ?, ?, ?, 'alert', NULL, ?, ?, ?, ?, ?, ?, 'pending_enqueue', 0, ?, NULL, NULL, NULL, ?, ?
           FROM devices WHERE tenant_id = ? AND device_id = ? AND revoked_at IS NULL AND revision = ? AND lease_expires > ?
             AND EXISTS (SELECT 1 FROM tenants WHERE tenant_id = ? AND state = 'active')`
  ).bind(
    input.tenantId,
    input.deliveryId,
    input.deviceId,
    input.revision,
    input.issued,
    input.expires,
    encodeEncrypted(encrypted),
    encrypted.keyVersion,
    payloadHash2,
    input.now,
    input.now,
    input.now,
    input.tenantId,
    input.deviceId,
    input.revision,
    input.now,
    input.tenantId
  ) : db.prepare(
    `INSERT INTO deliveries (tenant_id, delivery_id, device_id, kind, activity_id, revision, issued, expires, payload_ciphertext, payload_key_version, payload_hash, state, attempts, next_attempt, lease_id, lease_expires, last_error, created_at, updated_at)
           SELECT ?, ?, ?, 'live_activity', ?, ?, ?, ?, ?, ?, ?, 'pending_enqueue', 0, ?, NULL, NULL, NULL, ?, ?
           FROM live_activities WHERE tenant_id = ? AND activity_id = ? AND device_id = ? AND status = 'active' AND revision = ? AND lease_expires > ?`
  ).bind(
    input.tenantId,
    input.deliveryId,
    input.deviceId,
    input.activityId,
    input.revision,
    input.issued,
    input.expires,
    encodeEncrypted(encrypted),
    encrypted.keyVersion,
    payloadHash2,
    input.now,
    input.now,
    input.now,
    input.tenantId,
    input.activityId,
    input.deviceId,
    input.revision,
    input.now
  );
  statements.push(
    deliveryInsert,
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN changes() = 1 THEN ? ELSE NULL END)"
    ).bind(deliveryGuard),
    input.kind === "live_activity" ? db.prepare("DELETE FROM admission_guards WHERE guard_id IN (?, ?, ?, ?)").bind(stateGuard, globalQuotaGuard, quotaGuard, deliveryGuard) : db.prepare("DELETE FROM admission_guards WHERE guard_id IN (?, ?, ?)").bind(globalQuotaGuard, quotaGuard, deliveryGuard)
  );
  await db.batch(statements);
  const delivery = await getDelivery(db, input.tenantId, input.deliveryId);
  if (!delivery) throw new Error("Delivery admission did not persist");
  return { delivery, payloadHash: payloadHash2 };
}
__name(admitDeliveryAtomically, "admitDeliveryAtomically");
async function getDelivery(db, tenantId, deliveryId) {
  return first(
    db,
    "SELECT * FROM deliveries WHERE tenant_id = ? AND delivery_id = ?",
    tenantId,
    deliveryId
  );
}
__name(getDelivery, "getDelivery");
async function decodeDeliveryPayload(row, keys) {
  const plaintext = await decryptAtRest(decodeEncrypted(row.payload_ciphertext), keys);
  const parsed = JSON.parse(new TextDecoder().decode(plaintext));
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
    throw new Error("Stored delivery payload is invalid");
  const record2 = parsed;
  if (row.kind !== "alert" || !("envelope" in record2)) return { payload: record2 };
  if (!record2.envelope || typeof record2.envelope !== "object" || Array.isArray(record2.envelope) || record2.sound !== void 0 && record2.sound !== false || Object.keys(record2).some((key) => key !== "envelope" && key !== "sound"))
    throw new Error("Stored alert delivery payload is invalid");
  return {
    payload: record2.envelope,
    ...record2.sound === false ? { sound: false } : {}
  };
}
__name(decodeDeliveryPayload, "decodeDeliveryPayload");
async function markDeliveryQueued(db, tenantId, deliveryId, now) {
  const result = await run(
    db,
    "UPDATE deliveries SET state = 'queued', updated_at = ? WHERE tenant_id = ? AND delivery_id = ? AND state = 'pending_enqueue'",
    now,
    tenantId,
    deliveryId
  );
  return result.meta.changes === 1;
}
__name(markDeliveryQueued, "markDeliveryQueued");
async function claimDelivery(db, tenantId, deliveryId, leaseId, now) {
  const leaseExpires = now + RELAY_LIMITS.deliveryLeaseSeconds;
  const result = await run(
    db,
    "UPDATE deliveries SET state = 'sending', attempts = attempts + 1, lease_id = ?, lease_expires = ?, updated_at = ? WHERE tenant_id = ? AND delivery_id = ? AND state = 'queued' AND next_attempt <= ? AND (lease_expires IS NULL OR lease_expires <= ?)",
    leaseId,
    leaseExpires,
    now,
    tenantId,
    deliveryId,
    now,
    now
  );
  if (result.meta.changes !== 1) return null;
  return getDelivery(db, tenantId, deliveryId);
}
__name(claimDelivery, "claimDelivery");
async function renewDeliveryLease(db, row, now) {
  if (!row.lease_id) return false;
  const result = await run(
    db,
    "UPDATE deliveries SET lease_expires = ?, updated_at = ? WHERE tenant_id = ? AND delivery_id = ? AND state = 'sending' AND lease_id = ? AND lease_expires > ?",
    now + RELAY_LIMITS.deliveryLeaseSeconds,
    now,
    row.tenant_id,
    row.delivery_id,
    row.lease_id,
    now
  );
  return result.meta.changes === 1;
}
__name(renewDeliveryLease, "renewDeliveryLease");
async function completeDelivery(db, row, state, error51, now) {
  const result = await run(
    db,
    "UPDATE deliveries SET state = ?, lease_id = NULL, lease_expires = NULL, last_error = ?, updated_at = ? WHERE tenant_id = ? AND delivery_id = ? AND state = 'sending' AND lease_id = ?",
    state,
    error51,
    now,
    row.tenant_id,
    row.delivery_id,
    row.lease_id
  );
  return result.meta.changes === 1;
}
__name(completeDelivery, "completeDelivery");
async function completeDeliveryAndEndActivity(db, row, now, expectedStateHash) {
  const guardId = `${row.tenant_id}:${row.delivery_id}:terminal`;
  const results = await db.batch([
    db.prepare(
      "UPDATE deliveries SET state = 'delivered', lease_id = NULL, lease_expires = NULL, last_error = NULL, updated_at = ? WHERE tenant_id = ? AND delivery_id = ? AND state = 'sending' AND lease_id = ?"
    ).bind(now, row.tenant_id, row.delivery_id, row.lease_id),
    db.prepare(
      "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN changes() = 1 THEN ? ELSE NULL END)"
    ).bind(guardId),
    db.prepare(
      "INSERT INTO activity_tombstones (tenant_id, activity_id, revision, revoked_at) SELECT tenant_id, activity_id, revision, ? FROM live_activities WHERE tenant_id = ? AND activity_id = ? AND device_id = ? AND revision = ? AND status = 'active' AND state_hash = ? ON CONFLICT (tenant_id, activity_id) DO UPDATE SET revision = MAX(activity_tombstones.revision, excluded.revision), revoked_at = excluded.revoked_at"
    ).bind(now, row.tenant_id, row.activity_id, row.device_id, row.revision, expectedStateHash),
    db.prepare(
      "UPDATE live_activities SET status = 'revoked', token_ciphertext = '', token_key_version = '', state_json = NULL, state_hash = NULL, state_timestamp = NULL, updated_at = ? WHERE tenant_id = ? AND activity_id = ? AND device_id = ? AND revision = ? AND status = 'active' AND state_hash = ?"
    ).bind(now, row.tenant_id, row.activity_id, row.device_id, row.revision, expectedStateHash),
    db.prepare("DELETE FROM admission_guards WHERE guard_id = ?").bind(guardId)
  ]);
  return results[0]?.meta.changes === 1;
}
__name(completeDeliveryAndEndActivity, "completeDeliveryAndEndActivity");
async function retryDelivery(db, row, error51, nextAttempt, now) {
  const result = await run(
    db,
    "UPDATE deliveries SET state = 'queued', lease_id = NULL, lease_expires = NULL, last_error = ?, next_attempt = ?, updated_at = ? WHERE tenant_id = ? AND delivery_id = ? AND state = 'sending' AND lease_id = ?",
    error51,
    nextAttempt,
    now,
    row.tenant_id,
    row.delivery_id,
    row.lease_id
  );
  return result.meta.changes === 1;
}
__name(retryDelivery, "retryDelivery");
async function dueDeliveries(db, now, limit = 50) {
  const result = await db.prepare(
    "SELECT * FROM deliveries WHERE (state IN ('pending_enqueue', 'queued') AND next_attempt <= ?) OR (state = 'sending' AND lease_expires <= ?) ORDER BY created_at ASC LIMIT ?"
  ).bind(now, now, Math.max(1, Math.min(50, limit))).all();
  return result.results;
}
__name(dueDeliveries, "dueDeliveries");
async function recoverDelivery(db, row, now) {
  const day = new Date(now * 1e3).toISOString().slice(0, 10);
  const guardId = `${row.tenant_id}:${row.delivery_id}:recovery`;
  const globalGuardId = `${guardId}:global`;
  const tenantGuardId = `${guardId}:tenant`;
  try {
    await db.batch([
      db.prepare("INSERT OR IGNORE INTO service_daily_usage (usage_day) VALUES (?)").bind(day),
      db.prepare(
        "UPDATE service_daily_usage SET recovery = recovery + 1 WHERE usage_day = ? AND recovery < ?"
      ).bind(day, RELAY_LIMITS.recoveryPerDay),
      db.prepare(
        "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN changes() = 1 THEN ? ELSE NULL END)"
      ).bind(globalGuardId),
      db.prepare("INSERT OR IGNORE INTO daily_usage (tenant_id, usage_day) VALUES (?, ?)").bind(row.tenant_id, day),
      db.prepare(
        "UPDATE daily_usage SET recovery = recovery + 1 WHERE tenant_id = ? AND usage_day = ? AND recovery < ?"
      ).bind(row.tenant_id, day, RELAY_LIMITS.recoveryPerDay),
      db.prepare(
        "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN changes() = 1 THEN ? ELSE NULL END)"
      ).bind(tenantGuardId),
      db.prepare(
        "UPDATE deliveries SET state = 'pending_enqueue', lease_id = NULL, lease_expires = NULL, next_attempt = ?, updated_at = ? WHERE tenant_id = ? AND delivery_id = ? AND ((state IN ('pending_enqueue', 'queued') AND next_attempt <= ?) OR (state = 'sending' AND lease_expires <= ?))"
      ).bind(
        now + RELAY_LIMITS.recoveryRequeueDelaySeconds,
        now,
        row.tenant_id,
        row.delivery_id,
        now,
        now
      ),
      db.prepare(
        "INSERT INTO admission_guards (guard_id) VALUES (CASE WHEN changes() = 1 THEN ? ELSE NULL END)"
      ).bind(`${guardId}:delivery`),
      db.prepare("DELETE FROM admission_guards WHERE guard_id IN (?, ?, ?)").bind(globalGuardId, tenantGuardId, `${guardId}:delivery`)
    ]);
    return true;
  } catch {
    return false;
  }
}
__name(recoverDelivery, "recoverDelivery");
async function markRecoveredDeliveryQueued(db, row, now) {
  const result = await run(
    db,
    "UPDATE deliveries SET state = 'queued', lease_id = NULL, lease_expires = NULL, next_attempt = ?, updated_at = ? WHERE tenant_id = ? AND delivery_id = ? AND ((state = 'pending_enqueue' AND next_attempt > ?) OR (state = 'sending' AND lease_expires <= ?))",
    now,
    now,
    row.tenant_id,
    row.delivery_id,
    now,
    now
  );
  return result.meta.changes === 1;
}
__name(markRecoveredDeliveryQueued, "markRecoveredDeliveryQueued");
async function retryRecoveryAfterPublishFailure(db, row, now) {
  await run(
    db,
    "UPDATE deliveries SET next_attempt = ?, updated_at = ? WHERE tenant_id = ? AND delivery_id = ? AND state = 'pending_enqueue'",
    now,
    now,
    row.tenant_id,
    row.delivery_id
  );
}
__name(retryRecoveryAfterPublishFailure, "retryRecoveryAfterPublishFailure");
async function revokeDeviceForInvalidToken(db, tenantId, deviceId, expectedRevision, expectedTokenCiphertext, now) {
  await db.batch([
    db.prepare(
      "INSERT INTO device_tombstones (tenant_id, device_id, revision, revoked_at) SELECT ?, ?, ?, ? FROM devices WHERE tenant_id = ? AND device_id = ? AND revision = ? AND token_ciphertext = ? AND revoked_at IS NULL AND EXISTS (SELECT 1 FROM tenants WHERE tenant_id = ? AND state = 'active') ON CONFLICT (tenant_id, device_id) DO UPDATE SET revision = MAX(device_tombstones.revision, excluded.revision), revoked_at = excluded.revoked_at"
    ).bind(
      tenantId,
      deviceId,
      expectedRevision,
      now,
      tenantId,
      deviceId,
      expectedRevision,
      expectedTokenCiphertext,
      tenantId
    ),
    db.prepare(
      "UPDATE devices SET revoked_at = ?, token_ciphertext = '', token_key_version = '', updated_at = ? WHERE tenant_id = ? AND device_id = ? AND revoked_at IS NULL AND revision = ? AND token_ciphertext = ? AND EXISTS (SELECT 1 FROM tenants WHERE tenant_id = ? AND state = 'active')"
    ).bind(now, now, tenantId, deviceId, expectedRevision, expectedTokenCiphertext, tenantId)
  ]);
}
__name(revokeDeviceForInvalidToken, "revokeDeviceForInvalidToken");

