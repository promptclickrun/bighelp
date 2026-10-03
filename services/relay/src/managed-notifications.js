// Authored derivative feature source, concatenated after the immutable recovered
// module definitions. No public HTTP path can invoke these RPC-only methods.
async function ensureManagedNotificationSchema(db) {
  await db.batch([
    db.prepare(`CREATE TABLE IF NOT EXISTS notification_grants (
      tenant_id TEXT NOT NULL, grant_id TEXT NOT NULL, device_id TEXT NOT NULL,
      revision INTEGER NOT NULL, state TEXT NOT NULL, expires_at INTEGER NOT NULL,
      public_json TEXT NOT NULL, PRIMARY KEY(tenant_id,grant_id))`),
    db.prepare(`CREATE TABLE IF NOT EXISTS notification_delivery_grants (
      tenant_id TEXT NOT NULL, delivery_id TEXT NOT NULL, grant_id TEXT NOT NULL,
      grant_revision INTEGER NOT NULL, body_hash TEXT NOT NULL, expires_at INTEGER NOT NULL,
      PRIMARY KEY(tenant_id,delivery_id))`),
    db.prepare(`CREATE TABLE IF NOT EXISTS notification_activity_grants (
      tenant_id TEXT NOT NULL, activity_id TEXT NOT NULL, grant_id TEXT NOT NULL,
      session_ref TEXT NOT NULL, token_hash TEXT NOT NULL, revision INTEGER NOT NULL,
      lease_expires INTEGER NOT NULL, status TEXT NOT NULL, last_admitted_at INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(tenant_id,activity_id), UNIQUE(tenant_id,token_hash))`)
  ]);
}
async function cleanupManagedNotificationMaterial(db, now) {
  await ensureManagedNotificationSchema(db);
  await db.batch([
    db.prepare("DELETE FROM notification_delivery_grants WHERE rowid IN (SELECT rowid FROM notification_delivery_grants WHERE expires_at<? LIMIT 500)").bind(now - 86400),
    db.prepare("DELETE FROM notification_activity_grants WHERE rowid IN (SELECT rowid FROM notification_activity_grants WHERE lease_expires<? LIMIT 500)").bind(now - 86400),
    db.prepare("DELETE FROM notification_grants WHERE rowid IN (SELECT rowid FROM notification_grants WHERE expires_at<? LIMIT 500)").bind(now - 86400)
  ]);
}
function notificationFailure(code = "notification_grant_invalid") {
  throw new LoopdyLinkEnrollmentError(code, code);
}
// This allowlist does not upgrade existing immutable grant eventTypes.
const MANAGED_NOTIFICATION_EVENTS = new Set(["session.completed", "session.failed", "approval.required"]);
function validateManagedGrant(grant, tenant) {
  if (!grant || typeof grant !== "object" || grant.tenantId !== tenant.tenant_id ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(grant.grantId) ||
      !/^[A-Za-z0-9_-]{1,96}$/.test(grant.deviceId) ||
      !Number.isSafeInteger(grant.revision) || grant.revision < 1 ||
      !Number.isSafeInteger(grant.createdAt) || !Number.isSafeInteger(grant.expiresAt) ||
      grant.expiresAt <= grant.createdAt || grant.expiresAt - grant.createdAt > 2592000 ||
      !["active", "revoked"].includes(grant.state) ||
      !Array.isArray(grant.eventTypes) || grant.eventTypes.length < 1 || grant.eventTypes.length > MANAGED_NOTIFICATION_EVENTS.size ||
      new Set(grant.eventTypes).size !== grant.eventTypes.length ||
      grant.eventTypes.some(type => !MANAGED_NOTIFICATION_EVENTS.has(type))) notificationFailure();
  if (relayKeyId(relayBase64UrlDecode(grant.hostPublicKey)) !== grant.hostKeyId ||
      relayKeyId(relayBase64UrlDecode(grant.recipientPublicKey)) !== grant.recipientKeyId) notificationFailure();
}
async function managedRecipient(env, deviceId, now = nowSeconds()) {
  const tenant = requiredLinkTenant(env);
  await assertTenantActive(env.DB, tenant.tenant_id);
  const device = await getDevice(env.DB, tenant.tenant_id, deviceId);
  if (!device || device.revoked_at !== null || device.lease_expires <= now || !tenant.allowed_topics.includes(device.topic)) notificationFailure("notification_recipient_unavailable");
  return { tenantId: tenant.tenant_id, deviceId, recipientPublicKey: device.recipient_public_key,
    recipientKeyId: device.recipient_key_id, revision: device.revision, leaseExpires: device.lease_expires };
}
async function putManagedGrant(env, grant) {
  const tenant = requiredLinkTenant(env); validateManagedGrant(grant, tenant);
  await ensureManagedNotificationSchema(env.DB);
  const now = nowSeconds();
  if (grant.state === "active") {
    if (grant.expiresAt <= now) notificationFailure("notification_grant_expired");
    const recipient = await managedRecipient(env, grant.deviceId, now);
    if (recipient.recipientKeyId !== grant.recipientKeyId || recipient.recipientPublicKey !== grant.recipientPublicKey || recipient.revision !== grant.recipientRevision || recipient.leaseExpires < grant.expiresAt) notificationFailure("notification_recipient_changed");
  }
  await env.DB.prepare(`INSERT INTO notification_grants(tenant_id,grant_id,device_id,revision,state,expires_at,public_json)
    VALUES(?,?,?,?,?,?,?) ON CONFLICT(tenant_id,grant_id) DO UPDATE SET revision=excluded.revision,state=excluded.state,public_json=excluded.public_json
    WHERE notification_grants.device_id=excluded.device_id AND excluded.state='revoked' AND excluded.revision>notification_grants.revision`)
    .bind(grant.tenantId, grant.grantId, grant.deviceId, grant.revision, grant.state, grant.expiresAt, relayCanonicalJson(grant)).run();
  const row = await env.DB.prepare("SELECT * FROM notification_grants WHERE tenant_id=? AND grant_id=?").bind(grant.tenantId, grant.grantId).first();
  if (!row || row.public_json !== relayCanonicalJson(grant) || row.state !== grant.state || row.revision !== grant.revision) notificationFailure("notification_grant_conflict");
  if (grant.state === "revoked") {
    await env.DB.batch([
      env.DB.prepare(`UPDATE deliveries SET state='cancelled',updated_at=? WHERE tenant_id=? AND state IN ('pending_enqueue','queued','retry','sending')
        AND delivery_id IN(SELECT delivery_id FROM notification_delivery_grants WHERE tenant_id=? AND grant_id=?)`).bind(now, grant.tenantId, grant.tenantId, grant.grantId),
      env.DB.prepare("UPDATE notification_activity_grants SET status='revoked' WHERE tenant_id=? AND grant_id=?").bind(grant.tenantId, grant.grantId)
    ]);
  }
  return JSON.parse(row.public_json);
}
async function requireManagedGrant(env, grant, now = nowSeconds()) {
  const tenant = requiredLinkTenant(env); validateManagedGrant(grant, tenant);
  await ensureManagedNotificationSchema(env.DB);
  const row = await env.DB.prepare("SELECT * FROM notification_grants WHERE tenant_id=? AND grant_id=?").bind(grant.tenantId, grant.grantId).first();
  if (!row || row.state !== "active" || row.revision !== grant.revision || row.expires_at <= now || row.public_json !== relayCanonicalJson(grant)) notificationFailure("notification_grant_inactive");
  const recipient = await managedRecipient(env, grant.deviceId, now);
  if (recipient.revision !== grant.recipientRevision || recipient.recipientKeyId !== grant.recipientKeyId || recipient.recipientPublicKey !== grant.recipientPublicKey) notificationFailure("notification_recipient_changed");
  return row;
}
// Called on every queue attempt and immediately before APNs, including retries.
// Managed IDs fail closed if fence metadata is absent; legacy IDs are unchanged.
async function managedNotificationDeliveryAllowed(env, row, now) {
  if (!row.delivery_id.startsWith("ng-")) return true;
  await ensureManagedNotificationSchema(env.DB);
  const fence = await env.DB.prepare(`SELECT g.public_json,g.state,g.revision,g.expires_at,f.grant_revision
    FROM notification_delivery_grants f JOIN notification_grants g ON g.tenant_id=f.tenant_id AND g.grant_id=f.grant_id
    WHERE f.tenant_id=? AND f.delivery_id=?`).bind(row.tenant_id, row.delivery_id).first();
  if (!fence || fence.state !== "active" || fence.revision !== fence.grant_revision || fence.expires_at <= now) return false;
  const grant = JSON.parse(fence.public_json);
  const device = await getDevice(env.DB, row.tenant_id, row.device_id);
  if (grant.deviceId !== row.device_id || !device || device.revoked_at !== null || device.revision !== grant.recipientRevision || device.recipient_key_id !== grant.recipientKeyId) return false;
  if (row.activity_id) {
    const activity = await env.DB.prepare("SELECT * FROM notification_activity_grants WHERE tenant_id=? AND activity_id=?").bind(row.tenant_id, row.activity_id).first();
    if (!activity || activity.grant_id !== grant.grantId || activity.status !== "active" || activity.lease_expires <= now) return false;
  }
  return true;
}
async function managedDeliveryFence(env, grant, deliveryId, body, expires) {
  await env.DB.prepare(`INSERT INTO notification_delivery_grants(tenant_id,delivery_id,grant_id,grant_revision,body_hash,expires_at)
    SELECT ?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM notification_grants WHERE tenant_id=? AND grant_id=? AND state='active' AND revision=?)
    AND (SELECT COUNT(*) FROM notification_delivery_grants WHERE tenant_id=? AND grant_id=?)<4096
    ON CONFLICT DO NOTHING`).bind(grant.tenantId, deliveryId, grant.grantId, grant.revision, digestHex(relayCanonicalJson(body)), expires,
      grant.tenantId, grant.grantId, grant.revision, grant.tenantId, grant.grantId).run();
  const fence = await env.DB.prepare("SELECT * FROM notification_delivery_grants WHERE tenant_id=? AND delivery_id=?").bind(grant.tenantId, deliveryId).first();
  if (!fence || fence.grant_id !== grant.grantId || fence.grant_revision !== grant.revision || fence.body_hash !== digestHex(relayCanonicalJson(body))) notificationFailure("notification_delivery_conflict");
}
async function admitManagedDelivery(env, grant, input) {
  await requireManagedGrant(env, grant);
  await managedDeliveryFence(env, grant, input.deliveryId, input.payload, input.expires);
  const existing = await getDelivery(env.DB, grant.tenantId, input.deliveryId);
  if (existing) {
    if (existing.device_id !== grant.deviceId || existing.kind !== input.kind || existing.activity_id !== input.activityId || existing.payload_hash !== payloadHash(input.payload)) notificationFailure("notification_delivery_conflict");
    if (existing.state === "pending_enqueue") await enqueueWake(env, grant.tenantId, input.deliveryId, nowSeconds());
    return { status: "duplicate", deliveryId: input.deliveryId };
  }
  try {
    await admitDeliveryAtomically(env.DB, {
      tenantId: grant.tenantId, nonce: input.deliveryId, idempotencyKey: input.deliveryId,
      route: "private/notifications", bodyDigest: digestBase64Url(relayCanonicalJson(input.payload)),
      response: { version: 1, status: "accepted", id: input.deliveryId, revision: input.revision },
      deviceId: grant.deviceId, keys: storageKeys(env), now: nowSeconds(), ...input
    });
  } catch (error) {
    const raced = await getDelivery(env.DB, grant.tenantId, input.deliveryId);
    if (!raced || raced.payload_hash !== payloadHash(input.payload) || raced.device_id !== grant.deviceId || raced.activity_id !== input.activityId) throw error;
  }
  // Re-check the fence after admission. Revocation can race the D1 transaction.
  const row = await getDelivery(env.DB, grant.tenantId, input.deliveryId);
  if (!row || !await managedNotificationDeliveryAllowed(env, row, nowSeconds())) notificationFailure("notification_grant_inactive");
  await enqueueWake(env, grant.tenantId, input.deliveryId, nowSeconds());
  return { status: "accepted", deliveryId: input.deliveryId };
}
async function sendManagedEvent(env, { grant, event }) {
  const now = nowSeconds(); await requireManagedGrant(env, grant, now);
  assertExactKeys(event, ["version", "eventId", "eventType", "sessionReference", "envelope", "sound"]);
  if (event.version !== 1 || !new RegExp(`^${grant.grantId}:[0-9a-f]{64}$`).test(event.eventId) || !MANAGED_NOTIFICATION_EVENTS.has(event.eventType) || !grant.eventTypes.includes(event.eventType) || typeof event.sound !== "boolean" || !/^[A-Za-z0-9_-]{43}$/.test(event.sessionReference)) notificationFailure("notification_event_invalid");
  const envelope = RelayAlertEnvelopeV1.parse(event.envelope);
  if (!/^ng-[0-9a-f-]{36}$/.test(envelope.delivery_id) || envelope.sender_key_id !== grant.hostKeyId || envelope.recipient_key_id !== grant.recipientKeyId || envelope.event_ref !== digestBase64Url(event.eventId) || envelope.expires <= now || envelope.expires > grant.expiresAt || Math.abs(envelope.issued - now) > 300) notificationFailure("notification_event_invalid");
  await verifyPluginEnvelope(envelope, grant.hostPublicKey, { tenantId: grant.tenantId, deviceId: grant.deviceId });
  return admitManagedDelivery(env, grant, { deliveryId: envelope.delivery_id, kind: "alert", activityId: null,
    revision: grant.recipientRevision, issued: envelope.issued, expires: envelope.expires, payload: envelope, sound: event.sound, routine: false });
}
function managedActivityReceipt(row) {
  return { grantId: row.grant_id, activityId: row.activity_id, sessionReference: row.session_ref,
    revision: row.revision, leaseExpires: row.lease_expires, status: row.status };
}
async function readManagedActivity(env, { grant, activityId }) {
  await requireManagedGrant(env, grant);
  const row = await env.DB.prepare("SELECT * FROM notification_activity_grants WHERE tenant_id=? AND activity_id=?").bind(grant.tenantId, activityId).first();
  if (!row || row.grant_id !== grant.grantId) notificationFailure("notification_activity_unknown");
  return row;
}
async function registerManagedActivity(env, { grant, activity }) {
  await requireManagedGrant(env, grant);
  if (activity.deviceId !== grant.deviceId || activity.leaseExpires > grant.expiresAt || !/^[A-Za-z0-9_-]{43}$/.test(activity.sessionReference)) notificationFailure("notification_activity_invalid");
  RelayLiveActivityRegistrationRequestV1.parse({ version: 1, idempotency_key: crypto.randomUUID(),
    device_id: activity.deviceId, activity_id: activity.activityId, session_ref: activity.sessionReference,
    push_token: activity.pushToken, environment: activity.environment, topic: activity.topic,
    revision: activity.revision, timestamp: activity.timestamp, lease_expires: activity.leaseExpires });
  const count = await env.DB.prepare("SELECT COUNT(*) AS count FROM notification_activity_grants WHERE tenant_id=? AND grant_id=?").bind(grant.tenantId, grant.grantId).first();
  const owned = await env.DB.prepare("SELECT 1 FROM notification_activity_grants WHERE tenant_id=? AND activity_id=?").bind(grant.tenantId, activity.activityId).first();
  if (count.count >= 128 && !owned) notificationFailure("notification_activity_limit");
  const tokenHash = digestHex(`${activity.environment}\0${activity.topic}\0${activity.pushToken.toLowerCase()}`);
  const previous = await env.DB.prepare("SELECT * FROM notification_activity_grants WHERE tenant_id=? AND (activity_id=? OR token_hash=?)").bind(grant.tenantId, activity.activityId, tokenHash).all();
  if (previous.results.some(row => row.grant_id !== grant.grantId || row.activity_id !== activity.activityId || row.session_ref !== activity.sessionReference || row.status !== "active" || row.revision > activity.revision || (row.revision === activity.revision && (row.token_hash !== tokenHash || row.lease_expires !== activity.leaseExpires)))) notificationFailure("notification_activity_conflict");
  const existing = await getActivity(env.DB, grant.tenantId, activity.activityId);
  if (existing && previous.results.length === 0) notificationFailure("notification_activity_already_owned");
  // Token comparison is private and bounded by existing device registration caps.
  const others = await env.DB.prepare("SELECT * FROM live_activities WHERE tenant_id=? AND device_id=? AND status='active' AND lease_expires>?").bind(grant.tenantId, grant.deviceId, nowSeconds()).all();
  const keys = storageKeys(env);
  for (const other of others.results) {
    if (other.activity_id !== activity.activityId && other.environment === activity.environment && other.topic === activity.topic) {
      const token = new TextDecoder().decode(await encryptedToken(other.token_ciphertext, keys));
      if (token === activity.pushToken.toLowerCase()) notificationFailure("notification_activity_token_owned");
    }
  }
  // Reserve immutable owner before exposing the underlying registration.
  await env.DB.prepare(`INSERT INTO notification_activity_grants(tenant_id,activity_id,grant_id,session_ref,token_hash,revision,lease_expires,status)
    VALUES(?,?,?,?,?,?,?,'active') ON CONFLICT(tenant_id,activity_id) DO UPDATE SET token_hash=excluded.token_hash,revision=excluded.revision,lease_expires=excluded.lease_expires
    WHERE notification_activity_grants.grant_id=excluded.grant_id AND notification_activity_grants.session_ref=excluded.session_ref AND notification_activity_grants.status='active' AND excluded.revision>=notification_activity_grants.revision`)
    .bind(grant.tenantId, activity.activityId, grant.grantId, activity.sessionReference, tokenHash, activity.revision, activity.leaseExpires).run();
  await requireManagedGrant(env, grant);
  const reserved = await readManagedActivity(env, { grant, activityId: activity.activityId });
  if (reserved.revision !== activity.revision || reserved.session_ref !== activity.sessionReference || reserved.token_hash !== tokenHash || reserved.lease_expires !== activity.leaseExpires) notificationFailure("notification_activity_conflict");
  await registerLoopdyLinkLiveActivity(env, activity);
  return managedActivityReceipt(await readManagedActivity(env, { grant, activityId: activity.activityId }));
}
async function updateManagedActivity(env, { grant, activityId, update }) {
  const owner = await readManagedActivity(env, { grant, activityId });
  if (owner.status !== "active" || owner.lease_expires <= nowSeconds() || update.sessionReference !== owner.session_ref) notificationFailure("notification_activity_inactive");
  assertExactKeys(update, ["updateId", "sessionReference", "phase", "currentAction", "progress", "completedSteps", "activeSubagentCount", "latestTool", "timestamp", "expires"]);
  const actions = { thinking: "Your agent is working", waiting: "Your agent needs attention", using_tool: "Your agent is working", delegating: "Agents are working", responding: "Your agent is responding", completed: "Your agent finished", failed: "Your agent could not finish" };
  if (!/^[A-Za-z0-9_-]{16,128}$/.test(update.updateId) || !Object.hasOwn(actions, update.phase) || (update.currentAction !== actions[update.phase] && !(update.phase === "completed" && update.currentAction === "Stopped")) || update.latestTool !== null || update.progress !== (["completed", "failed"].includes(update.phase) ? 100 : 0) || Math.abs(update.timestamp - nowSeconds()) > 120 || update.expires <= nowSeconds() || update.expires > grant.expiresAt) notificationFailure("notification_activity_invalid");
  const state = RelayLiveActivityDeliveryRequestV1.shape.state.parse({ version: 1, kind: "live_activity", activity_id: activityId,
    session_ref: update.sessionReference, phase: update.phase, current_action: update.currentAction, progress: update.progress,
    active_session_count: update.activeSubagentCount, completed_steps: update.completedSteps,
    active_subagent_count: update.activeSubagentCount, latest_tool: null, timestamp: update.timestamp, expires: update.expires });
  const activity = await getActivity(env.DB, grant.tenantId, activityId);
  if (!activity || activity.device_id !== grant.deviceId || activity.session_ref !== owner.session_ref || activity.revision !== owner.revision) notificationFailure("notification_activity_conflict");
  const deliveryId = `ng-${digestBase64Url(`${grant.grantId}\0${activityId}\0${update.updateId}`)}`;
  const routine = !["waiting", "completed", "failed"].includes(state.phase);
  const now = nowSeconds();
  const replay = await getDelivery(env.DB, grant.tenantId, deliveryId);
  if (routine && !replay) {
    const reserved = await env.DB.prepare(`UPDATE notification_activity_grants SET last_admitted_at=?
      WHERE tenant_id=? AND activity_id=? AND grant_id=? AND status='active' AND last_admitted_at<=?`)
      .bind(now, grant.tenantId, activityId, grant.grantId, now - RELAY_LIMITS.routineLiveActivityIntervalSeconds).run();
    if (reserved.meta.changes !== 1) notificationFailure("notification_activity_coalesced");
  }
  return admitManagedDelivery(env, grant, { deliveryId, kind: "live_activity", activityId, revision: activity.revision,
    issued: state.timestamp, expires: state.expires, payload: state, routine, routineTimestamp: now,
    stateHash: digestHex(relayCanonicalJson(state)), stateTimestamp: state.timestamp });
}
class ManagedLoopdyLinkEnrollment extends LoopdyLinkEnrollment {
  async notificationRecipient(input) { assertExactKeys(input, ["deviceId"]); return managedRecipient(this.env, input.deviceId); }
  async putNotificationGrant(grant) { return putManagedGrant(this.env, grant); }
  async revokeNotificationGrant(grant) { if (grant.state !== "revoked") notificationFailure(); return putManagedGrant(this.env, grant); }
  async sendNotificationEvent(input) { return sendManagedEvent(this.env, input); }
  async registerNotificationActivity(input) { return registerManagedActivity(this.env, input); }
  async notificationActivity(input) {
    const owner = await readManagedActivity(this.env, input);
    const activity = await getActivity(this.env.DB, input.grant.tenantId, input.activityId);
    if (!activity || activity.device_id !== input.grant.deviceId || activity.session_ref !== owner.session_ref || activity.revision !== owner.revision) notificationFailure("notification_activity_unconfirmed");
    return managedActivityReceipt({ ...owner, status: activity.status });
  }
  async updateNotificationActivity(input) { return updateManagedActivity(this.env, input); }
  async revokeNotificationActivity(input) {
    const owner = await readManagedActivity(this.env, input);
    if (input.revision < owner.revision || Math.abs(input.timestamp - nowSeconds()) > 300) notificationFailure("notification_activity_invalid");
    await revokeLoopdyLinkLiveActivity(this.env, { deviceId: input.grant.deviceId, activityId: input.activityId, revision: input.revision, timestamp: input.timestamp });
    await this.env.DB.prepare("UPDATE notification_activity_grants SET status='revoked',revision=? WHERE tenant_id=? AND activity_id=? AND grant_id=?")
      .bind(input.revision, input.grant.tenantId, input.activityId, input.grant.grantId).run();
    return managedActivityReceipt(await readManagedActivity(this.env, input));
  }
  async registerLiveActivity(input) {
    await ensureManagedNotificationSchema(this.env.DB);
    const tenant = requiredLinkTenant(this.env);
    const occupied = await this.env.DB.prepare("SELECT 1 FROM notification_activity_grants WHERE tenant_id=? AND (activity_id=? OR token_hash=?)")
      .bind(tenant.tenant_id, input.activityId, digestHex(`${input.environment}\0${input.topic}\0${String(input.pushToken).toLowerCase()}`)).first();
    if (occupied) notificationFailure("notification_activity_already_owned");
    return super.registerLiveActivity(input);
  }
  async updateLiveActivity(input) {
    await ensureManagedNotificationSchema(this.env.DB);
    const tenant = requiredLinkTenant(this.env);
    const occupied = await this.env.DB.prepare("SELECT 1 FROM notification_activity_grants WHERE tenant_id=? AND activity_id=?").bind(tenant.tenant_id, input.activityId).first();
    if (occupied) notificationFailure("notification_activity_already_owned");
    return super.updateLiveActivity(input);
  }
}
