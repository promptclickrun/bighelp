// src/apns.ts
var APNS_RESPONSE_BYTES = 8192;
var APNS_TIMEOUT_MS = 1e4;
function apnsIdForDelivery(tenantId, deliveryId) {
  const digest = relaySha256(new TextEncoder().encode(`${tenantId}:${deliveryId}`));
  const bytes3 = digest.slice(0, 16);
  bytes3[6] = (bytes3[6] ?? 0) & 15 | 80;
  bytes3[8] = (bytes3[8] ?? 0) & 63 | 128;
  const hex3 = Array.from(bytes3, (value) => value.toString(16).padStart(2, "0")).join("");
  return `${hex3.slice(0, 8)}-${hex3.slice(8, 12)}-${hex3.slice(12, 16)}-${hex3.slice(16, 20)}-${hex3.slice(20)}`;
}
__name(apnsIdForDelivery, "apnsIdForDelivery");
function pemToDer(pem) {
  const normalized = pem.replace("-----BEGIN PRIVATE KEY-----", "").replace("-----END PRIVATE KEY-----", "").replace(/\s/g, "");
  if (!normalized || !/^[A-Za-z0-9+/]+=*$/.test(normalized))
    throw new Error("APNs private key is invalid");
  const binary = atob(normalized);
  const bytes3 = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes3[index] = binary.charCodeAt(index);
  return bytes3;
}
__name(pemToDer, "pemToDer");
async function createApnsJwt(credentials, nowSeconds2) {
  if (!/^[A-Za-z0-9]{1,32}$/.test(credentials.teamId) || !/^[A-Za-z0-9]{1,32}$/.test(credentials.keyId)) {
    throw new Error("APNs credentials are invalid");
  }
  const issued = Math.floor(nowSeconds2);
  const header = relayBase64UrlEncode(
    new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: credentials.keyId }))
  );
  const claims = relayBase64UrlEncode(
    new TextEncoder().encode(JSON.stringify({ iss: credentials.teamId, iat: issued }))
  );
  const signingInput = new TextEncoder().encode(`${header}.${claims}`);
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(credentials.privateKeyPem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, signingInput);
  return `${header}.${claims}.${relayBase64UrlEncode(new Uint8Array(signature))}`;
}
__name(createApnsJwt, "createApnsJwt");
async function sendApns(input) {
  if (!/^(?:[0-9a-f]{2}){1,256}$/.test(input.tokenHex)) throw new Error("APNs token is invalid");
  const fetcher = input.fetchImpl ?? fetch;
  const jwt2 = await createApnsJwt(input.credentials, input.nowSeconds);
  const host = input.environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const topic = input.pushType === "liveactivity" ? `${input.topic}.push-type.liveactivity` : input.topic;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), input.timeoutMs ?? APNS_TIMEOUT_MS);
  let response2;
  try {
    response2 = await fetcher(`https://${host}/3/device/${input.tokenHex}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt2}`,
        "apns-topic": topic,
        "apns-push-type": input.pushType,
        "apns-priority": String(input.priority),
        "content-type": "application/json",
        ...input.tenantId && input.deliveryId ? {
          "apns-id": apnsIdForDelivery(input.tenantId, input.deliveryId),
          "apns-collapse-id": apnsIdForDelivery(input.tenantId, input.deliveryId)
        } : {}
      },
      body: JSON.stringify(input.payload),
      signal: controller.signal
    });
  } catch (error51) {
    clearTimeout(timeout);
    throw error51;
  }
  let bounded;
  try {
    bounded = await readApnsResponseBody(response2);
  } finally {
    clearTimeout(timeout);
  }
  let reason;
  if (bounded) {
    try {
      const parsed = JSON.parse(bounded);
      if (typeof parsed.reason === "string") reason = parsed.reason;
    } catch {
      reason = void 0;
    }
  }
  return {
    ...classifyApnsResponse(response2.status, reason),
    status: response2.status,
    ...reason ? { reason } : {}
  };
}
__name(sendApns, "sendApns");
async function readApnsResponseBody(response2) {
  const reader = response2.body?.getReader();
  if (!reader) return "";
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      total += next.value.byteLength;
      if (total > APNS_RESPONSE_BYTES) {
        await reader.cancel("APNs response exceeds bounded limit");
        return "";
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
  return new TextDecoder().decode(bytes3);
}
__name(readApnsResponseBody, "readApnsResponseBody");

