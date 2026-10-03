// src/auth.ts
var IDENTIFIER2 = /^[A-Za-z0-9][A-Za-z0-9._:-]*$/;
var TOPIC2 = /^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$/;
var RELAY_TENANT_REGISTRY_MAX_BYTES = 5e3;
var RELAY_TENANT_REGISTRY_MAX_ENTRIES = 64;
var RelayAuthError = class extends Error {
  static {
    __name(this, "RelayAuthError");
  }
  code;
  status;
  constructor(code, message, status = 401) {
    super(message);
    this.name = "RelayAuthError";
    this.code = code;
    this.status = status;
  }
};
function parseTenantRegistry(raw) {
  let value = raw;
  if (typeof raw === "string") {
    if (new TextEncoder().encode(raw).byteLength > RELAY_TENANT_REGISTRY_MAX_BYTES)
      throw new RelayAuthError("invalid_registry", "Relay tenant registry is invalid", 500);
    try {
      value = JSON.parse(raw);
    } catch {
      throw new RelayAuthError("invalid_registry", "Relay tenant registry is invalid", 500);
    }
  } else {
    try {
      if (new TextEncoder().encode(JSON.stringify(raw)).byteLength > RELAY_TENANT_REGISTRY_MAX_BYTES)
        throw new RelayAuthError("invalid_registry", "Relay tenant registry is invalid", 500);
    } catch (error51) {
      if (error51 instanceof RelayAuthError) throw error51;
      throw new RelayAuthError("invalid_registry", "Relay tenant registry is invalid", 500);
    }
  }
  if (!Array.isArray(value) || value.length === 0 || value.length > RELAY_TENANT_REGISTRY_MAX_ENTRIES) {
    throw new RelayAuthError("invalid_registry", "Relay tenant registry is invalid", 500);
  }
  const map2 = /* @__PURE__ */ new Map();
  for (const candidate of value) {
    if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) {
      throw new RelayAuthError("invalid_registry", "Relay tenant registry is invalid", 500);
    }
    const input = candidate;
    const allowed = /* @__PURE__ */ new Set([
      "tenant_id",
      "credential_key_id",
      "hmac_key_b64url",
      "sender_key_revision",
      "current",
      "previous",
      "allowed_topics"
    ]);
    if (Object.keys(input).some((key) => !allowed.has(key))) {
      throw new RelayAuthError("invalid_registry", "Relay tenant registry is invalid", 500);
    }
    const keySet = RelaySenderKeySetResponseV1.safeParse({
      version: 1,
      revision: input.sender_key_revision,
      current: input.current,
      previous: input.previous
    });
    if (!keySet.success || typeof input.tenant_id !== "string" || typeof input.credential_key_id !== "string" || typeof input.hmac_key_b64url !== "string" || input.tenant_id.length > 180 || input.credential_key_id.length > 180 || !IDENTIFIER2.test(input.tenant_id) || !IDENTIFIER2.test(input.credential_key_id) || !Array.isArray(input.allowed_topics) || input.allowed_topics.length < 1 || input.allowed_topics.length > 8 || input.allowed_topics.some(
      (topic) => typeof topic !== "string" || !TOPIC2.test(topic) || topic.endsWith(".push-type.liveactivity")
    ) || new Set(input.allowed_topics).size !== input.allowed_topics.length) {
      throw new RelayAuthError("invalid_registry", "Relay tenant registry is invalid", 500);
    }
    let hmac;
    try {
      hmac = relayBase64UrlDecode(input.hmac_key_b64url);
    } catch {
      throw new RelayAuthError("invalid_registry", "Relay tenant registry is invalid", 500);
    }
    if (hmac.byteLength < 32 || hmac.byteLength > 4096 || map2.has(input.tenant_id)) {
      throw new RelayAuthError("invalid_registry", "Relay tenant registry is invalid", 500);
    }
    map2.set(input.tenant_id, {
      tenant_id: input.tenant_id,
      credential_key_id: input.credential_key_id,
      hmac_key_b64url: input.hmac_key_b64url,
      sender_key_revision: input.sender_key_revision,
      current: keySet.data.current,
      previous: keySet.data.previous,
      allowed_topics: input.allowed_topics
    });
  }
  return map2;
}
__name(parseTenantRegistry, "parseTenantRegistry");
async function authenticateRelayRequest(request, options) {
  const url2 = new URL(request.url);
  if (url2.search || url2.hash || url2.pathname.includes("%")) {
    throw new RelayAuthError("invalid_path", "Relay request path is invalid");
  }
  const body = options.body ?? await request.clone().text();
  const tenantId = request.headers.get("x-loopdy-tenant-id") ?? "";
  const credentialKeyId = request.headers.get("x-loopdy-credential-key-id") ?? "";
  const nonce = request.headers.get("x-loopdy-nonce") ?? "";
  const timestampHeader = request.headers.get("x-loopdy-timestamp") ?? "";
  const signature = request.headers.get("x-loopdy-signature") ?? "";
  const tenant = options.registry.get(tenantId);
  if (!tenant || tenant.credential_key_id !== credentialKeyId) {
    throw new RelayAuthError("invalid_credentials", "Relay credentials are invalid");
  }
  const timestamp2 = Number(timestampHeader);
  if (!/^\d+$/.test(timestampHeader) || !Number.isSafeInteger(timestamp2)) {
    throw new RelayAuthError("invalid_timestamp", "Relay timestamp is invalid");
  }
  try {
    validateRelayRequestTimestamp(timestamp2, options.now);
  } catch {
    throw new RelayAuthError(
      "stale_timestamp",
      "Relay request timestamp is outside the allowed window"
    );
  }
  try {
    if (relayBase64UrlDecode(nonce).byteLength !== 16) throw new Error("nonce");
    const signatureBytes = relayBase64UrlDecode(signature);
    if (signatureBytes.byteLength !== 32) throw new Error("signature");
    const hmacKey = await crypto.subtle.importKey(
      "raw",
      relayBase64UrlDecode(tenant.hmac_key_b64url),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["verify"]
    );
    const signingInput = relayRequestSigningInput({
      method: request.method,
      path: url2.pathname,
      tenantId,
      credentialKeyId,
      timestamp: timestamp2,
      nonce,
      body: new TextEncoder().encode(body)
    });
    const valid = await crypto.subtle.verify("HMAC", hmacKey, signatureBytes, signingInput);
    if (!valid) throw new Error("signature");
  } catch {
    throw new RelayAuthError("invalid_signature", "Relay request signature is invalid");
  }
  const bodyDigest = Array.from(
    relaySha256(new TextEncoder().encode(body)),
    (byte) => byte.toString(16).padStart(2, "0")
  ).join("");
  return { tenantId, credentialKeyId, nonce, timestamp: timestamp2, bodyDigest, tenant };
}
__name(authenticateRelayRequest, "authenticateRelayRequest");
function senderKeys(tenant) {
  return tenant.previous ? [tenant.current, tenant.previous] : [tenant.current];
}
__name(senderKeys, "senderKeys");
function senderKey(tenant, keyId2, now) {
  return senderKeys(tenant).find(
    (key) => key.key_id === keyId2 && key.not_before <= now && now <= key.not_after
  );
}
__name(senderKey, "senderKey");
function senderKeyForIssuedEnvelope(tenant, keyId2, issued) {
  return senderKeys(tenant).find(
    (key) => key.key_id === keyId2 && key.not_before <= issued && issued <= key.not_after
  );
}
__name(senderKeyForIssuedEnvelope, "senderKeyForIssuedEnvelope");

