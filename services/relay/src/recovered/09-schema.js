// src/schema.ts
var RELAY_LIMITS = Object.freeze({
  expectedAcceptedPerDay: 3e3,
  hardAcceptedPerDay: 1e4,
  routineLiveActivityPerDay: 750,
  recoveryPerDay: 1e3,
  maxQueueRetries: 2,
  maxCronRepublish: 1,
  requestBytes: 4096,
  responseBytes: 65536,
  deliveryTtlSeconds: 900,
  liveActivityTtlSeconds: 120,
  nonceWindowSeconds: 300,
  idempotencyRetentionSeconds: 86400,
  recoveryRequeueDelaySeconds: 60,
  deviceLeaseSeconds: 2592e3,
  liveActivityLeaseSeconds: 28800,
  // The queue worker processes a batch serially. This lease deliberately
  // exceeds the bounded APNs call timeout with room for D1 settlement so a
  // later message cannot outlive the ownership it just claimed.
  deliveryLeaseSeconds: 60,
  routineLiveActivityIntervalSeconds: 30,
  storageCiphertextVersion: "v1"
});
var ROUTES = Object.freeze({
  health: "/health",
  deviceRegister: "/v1/devices/register",
  senderKeyAcknowledgement: "/v1/devices/ack-sender-keys",
  deviceRevoke: "/v1/devices/revoke",
  liveActivityRegister: "/v1/live-activities/register",
  liveActivityRevoke: "/v1/live-activities/revoke",
  tenantRevoke: "/v1/tenants/revoke",
  tenantDelete: "/v1/tenants/delete",
  delivery: "/v1/deliveries"
});
var routeNames = {
  [ROUTES.deviceRegister]: "device_register",
  [ROUTES.senderKeyAcknowledgement]: "sender_key_acknowledgement",
  [ROUTES.deviceRevoke]: "device_revoke",
  [ROUTES.liveActivityRegister]: "live_activity_register",
  [ROUTES.liveActivityRevoke]: "live_activity_revoke",
  [ROUTES.tenantRevoke]: "tenant_revoke",
  [ROUTES.tenantDelete]: "tenant_delete",
  [ROUTES.delivery]: "delivery"
};
function routePath(path) {
  const route = routeNames[path];
  if (!route) throw new RelaySchemaError("unknown_route", "Unknown relay route");
  return route;
}
__name(routePath, "routePath");
function parseRouteRequest(path, body) {
  const parsed = (() => {
    switch (routePath(path)) {
      case "device_register":
        return RelayDeviceRegistrationRequestV1.parse(body);
      case "sender_key_acknowledgement":
        return RelaySenderKeyAcknowledgementRequestV1.parse(body);
      case "device_revoke":
        return RelayDeviceRevokeRequestV1.parse(body);
      case "live_activity_register":
        return RelayLiveActivityRegistrationRequestV1.parse(body);
      case "live_activity_revoke":
        return RelayLiveActivityRevokeRequestV1.parse(body);
      case "tenant_revoke":
        return RelayTenantRevokeRequestV1.parse(body);
      case "tenant_delete":
        return RelayTenantDeleteRequestV1.parse(body);
      case "delivery":
        return parseDeliveryRequest(body);
    }
  })();
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new RelaySchemaError("invalid_schema", "Relay request must be an object");
  }
  return parsed;
}
__name(parseRouteRequest, "parseRouteRequest");
function parseDeliveryRequest(body) {
  const parsed = RelayDeliveryRequestV1.safeParse(body);
  if (parsed.success) return parsed.data;
  const live = RelayLiveActivityDeliveryRequestV1.parse(body);
  return live;
}
__name(parseDeliveryRequest, "parseDeliveryRequest");
function parseCanonicalJson(raw) {
  if (new TextEncoder().encode(raw).byteLength > RELAY_LIMITS.requestBytes) {
    throw new RelaySchemaError("body_too_large", "Relay request exceeds the size limit");
  }
  let value;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new RelaySchemaError("invalid_json", "Relay request JSON is invalid");
  }
  if (relayCanonicalJson(value) !== raw) {
    throw new RelaySchemaError("noncanonical_json", "Relay request JSON is not canonical");
  }
  return value;
}
__name(parseCanonicalJson, "parseCanonicalJson");
function sanitizeLiveActivityState(input) {
  const parsed = RelayLiveActivityDeliveryRequestV1.shape.state.parse(input);
  const safe = {
    version: parsed.version,
    kind: parsed.kind,
    activity_id: parsed.activity_id,
    session_ref: parsed.session_ref,
    phase: parsed.phase,
    progress: parsed.progress,
    active_session_count: parsed.active_session_count,
    timestamp: parsed.timestamp,
    expires: parsed.expires
  };
  if (parsed.current_action !== void 0) safe.current_action = parsed.current_action;
  if (parsed.completed_steps !== void 0) safe.completed_steps = parsed.completed_steps;
  if (parsed.active_subagent_count !== void 0)
    safe.active_subagent_count = parsed.active_subagent_count;
  if (parsed.latest_tool !== void 0) safe.latest_tool = parsed.latest_tool;
  return safe;
}
__name(sanitizeLiveActivityState, "sanitizeLiveActivityState");
var RelaySchemaError = class extends Error {
  static {
    __name(this, "RelaySchemaError");
  }
  code;
  constructor(code, message) {
    super(message);
    this.name = "RelaySchemaError";
    this.code = code;
  }
};
function isRoutineLiveActivity(state) {
  return ["thinking", "running", "using_tool", "delegating", "responding"].includes(
    String(state.phase)
  );
}
__name(isRoutineLiveActivity, "isRoutineLiveActivity");

