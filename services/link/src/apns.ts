import { encodeBase64URL, sha256Bytes } from "./encoding.js";
import { readByteStream } from "./http-primitives.js";

export type ApnsPushType = "alert" | "background" | "liveactivity";
export type ApnsEnvironment = "sandbox" | "production";
export type ApnsOutcomeKind = "sent" | "token_invalid" | "provider_token" | "retryable" | "rejected";

export interface ApnsSecrets {
  APNS_KEY_P8?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_TOPIC?: string;
}

export interface ApnsConfig {
  keyId: string;
  teamId: string;
  privateKeyPem: string;
  topic: string;
}

export interface ApnsResult {
  outcome: ApnsOutcomeKind;
  /** The HTTP status, or 0 when APNs never answered. */
  status: number;
  /** A fixed code: `sent`, `timeout`, `transport_error` or the snake-cased APNs reason. */
  reason: string;
  providerMs: number;
}

export interface SendApnsInput {
  config: ApnsConfig;
  environment: ApnsEnvironment;
  /** Lowercase hex, as the phone gave it. Never logged. */
  tokenHex: string;
  pushType: ApnsPushType;
  priority: 5 | 10;
  /** Unix seconds after which APNs drops the push. */
  expiration: number;
  apnsId: string;
  collapseId?: string;
  payload: object;
  /**
   * The last awaited step before the request leaves. Egress authority is
   * decided here, so nothing awaited may sit between it and `fetch`.
   */
  authorize: () => Promise<void>;
}

export const DEFAULT_APNS_TOPIC = "app.loopdy.mobile";
/** APNs rejects a new token under 20 minutes old and one over 60 minutes old. */
export const APNS_TOKEN_MAX_AGE_MS = 40 * 60 * 1_000;
export const APNS_TIMEOUT_MS = 5_000;
export const APNS_RESPONSE_BYTES = 4_096;
/** APNs allows 4 KiB; this keeps a margin. */
export const APNS_PAYLOAD_BYTES = 4_000;

/** The reasons APNs documents. Anything else is reported as `other`. */
const KNOWN_REASONS = new Set([
  "BadCertificate", "BadCertificateEnvironment", "BadCollapseId", "BadDeviceToken",
  "BadExpirationDate", "BadMessageId", "BadPath", "BadPriority", "BadTopic",
  "DeviceTokenNotForTopic", "DuplicateHeaders", "ExpiredProviderToken", "ExpiredToken",
  "Forbidden", "IdleTimeout", "InternalServerError", "InvalidProviderToken", "InvalidPushType",
  "MethodNotAllowed", "MissingDeviceToken", "MissingProviderToken", "MissingTopic",
  "PayloadEmpty", "PayloadTooLarge", "ServiceUnavailable", "Shutdown", "TooManyProviderTokenUpdates",
  "TooManyRequests", "TopicDisallowed", "Unregistered",
]);

let cachedToken: { fingerprint: string; token: string; mintedAt: number } | null = null;

/** Drops the cached provider token. For tests. */
export function resetApnsTokenCache(): void {
  cachedToken = null;
}

/** The provider settings, or null when any is missing or malformed. */
export function apnsConfig(env: ApnsSecrets): ApnsConfig | null {
  const keyId = env.APNS_KEY_ID?.trim() ?? "";
  const teamId = env.APNS_TEAM_ID?.trim() ?? "";
  // A secret pasted through some tools keeps its line breaks as the two characters \n.
  const privateKeyPem = (env.APNS_KEY_P8 ?? "").replace(/\\n/g, "\n").trim();
  const topic = env.APNS_TOPIC?.trim() || DEFAULT_APNS_TOPIC;
  if (!/^[A-Za-z0-9]{1,32}$/.test(keyId) || !/^[A-Za-z0-9]{1,32}$/.test(teamId)
      || !/^[A-Za-z0-9.-]{3,128}$/.test(topic) || !privateKeyPem.includes("BEGIN PRIVATE KEY")) {
    return null;
  }
  return { keyId, teamId, privateKeyPem, topic };
}

export function apnsTopicFor(config: ApnsConfig, pushType: ApnsPushType): string {
  return pushType === "liveactivity" ? `${config.topic}.push-type.liveactivity` : config.topic;
}

/** A version 8 UUID from the SHA-256 of the key, so a retry carries the same ID. */
export async function apnsIdFor(dedupeKey: string): Promise<string> {
  const bytes = (await sha256Bytes(`apns-id-v1\0${dedupeKey}`)).slice(0, 16);
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x80;
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80;
  const hex = Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/**
 * A collapse ID for an event. APNs caps the header at 64 bytes and an event ID
 * is 101, so this is the event ID's digest: the same event always gets the same one.
 */
export async function apnsCollapseIdFor(eventId: string): Promise<string> {
  return encodeBase64URL(await sha256Bytes(`apns-collapse-v1\0${eventId}`)).slice(0, 43);
}

function pemToDer(pem: string): Uint8Array {
  const normalized = pem.replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "").replace(/\s/g, "");
  if (!normalized || !/^[A-Za-z0-9+/]+=*$/.test(normalized)) throw new Error("apns_key_invalid");
  return Uint8Array.from(atob(normalized), (character) => character.charCodeAt(0));
}

async function mintProviderToken(config: ApnsConfig, nowMs: number): Promise<string> {
  const header = encodeBase64URL(new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: config.keyId })));
  const claims = encodeBase64URL(new TextEncoder().encode(
    JSON.stringify({ iss: config.teamId, iat: Math.floor(nowMs / 1_000) }),
  ));
  const key = await crypto.subtle.importKey(
    "pkcs8", pemToDer(config.privateKeyPem), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );
  // WebCrypto signs ECDSA as the raw r||s pair, which is what a JWS wants.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`),
  );
  return `${header}.${claims}.${encodeBase64URL(new Uint8Array(signature))}`;
}

/**
 * The cached provider token, minted again after 40 minutes. `rejected` is a
 * token APNs just refused: if another request already replaced it, use that one.
 */
export async function apnsProviderToken(config: ApnsConfig, rejected?: string): Promise<string> {
  const nowMs = Date.now();
  const fingerprint = `${config.keyId}\0${config.teamId}\0${config.privateKeyPem}`;
  if (cachedToken && cachedToken.fingerprint === fingerprint
      && nowMs - cachedToken.mintedAt >= 0 && nowMs - cachedToken.mintedAt < APNS_TOKEN_MAX_AGE_MS
      && cachedToken.token !== rejected) {
    return cachedToken.token;
  }
  const token = await mintProviderToken(config, nowMs);
  cachedToken = { fingerprint, token, mintedAt: nowMs };
  return token;
}

export function classifyApnsResponse(status: number, reason: string | undefined): ApnsOutcomeKind {
  if (status === 200) return "sent";
  if (status === 410) return "token_invalid";
  if (status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic")) {
    return "token_invalid";
  }
  if (status === 403 && (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken"
      || reason === "MissingProviderToken")) {
    return "provider_token";
  }
  if (status === 429 || status >= 500) return "retryable";
  return "rejected";
}

/** A fixed lowercase code for an APNs reason, such as `bad_device_token`. */
export function apnsReasonCode(reason: string | undefined): string {
  if (!reason) return "none";
  if (!KNOWN_REASONS.has(reason)) return "other";
  return reason.replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase();
}

class ResponseTooLarge extends Error {}

async function readReason(response: Response): Promise<string | undefined> {
  try {
    const bytes = await readByteStream(response.body, APNS_RESPONSE_BYTES, () => {
      throw new ResponseTooLarge();
    });
    const parsed: unknown = JSON.parse(new TextDecoder().decode(bytes));
    const reason = parsed && typeof parsed === "object" ? (parsed as { reason?: unknown }).reason : undefined;
    return typeof reason === "string" ? reason.slice(0, 64) : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Sends one push. A refused provider token is replaced and the push sent again,
 * once. The authorize step runs again before that second request.
 */
export async function sendApns(input: SendApnsInput): Promise<ApnsResult> {
  if (!/^(?:[0-9a-f]{2}){32,100}$/.test(input.tokenHex)) {
    return { outcome: "rejected", status: 0, reason: "token_malformed", providerMs: 0 };
  }
  const host = input.environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const body = JSON.stringify(input.payload);
  let refused: string | undefined;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    let jwt: string;
    try {
      jwt = await apnsProviderToken(input.config, refused);
    } catch {
      // A key that reads but won't sign. The caller sends it another way.
      return { outcome: "rejected", status: 0, reason: "provider_key_invalid", providerMs: 0 };
    }
    const headers = new Headers({
      authorization: `bearer ${jwt}`,
      "apns-topic": apnsTopicFor(input.config, input.pushType),
      "apns-push-type": input.pushType,
      "apns-priority": String(input.priority),
      "apns-expiration": String(input.expiration),
      "apns-id": input.apnsId,
      "content-type": "application/json",
    });
    if (input.collapseId) headers.set("apns-collapse-id", input.collapseId);
    // Egress authority is the final decision. Keep it the last await before the request.
    await input.authorize();
    const startedAt = Date.now();
    let response: Response;
    try {
      response = await fetch(`https://${host}/3/device/${input.tokenHex}`, {
        method: "POST",
        headers,
        body,
        signal: AbortSignal.timeout(APNS_TIMEOUT_MS),
        redirect: "manual",
      });
    } catch (error) {
      const timedOut = error instanceof Error && (error.name === "TimeoutError" || error.name === "AbortError");
      return {
        outcome: "retryable", status: 0, reason: timedOut ? "timeout" : "transport_error",
        providerMs: Date.now() - startedAt,
      };
    }
    if (response.status === 200) await response.body?.cancel().catch(() => undefined);
    const reason = response.status === 200 ? undefined : await readReason(response);
    const providerMs = Date.now() - startedAt;
    const outcome = classifyApnsResponse(response.status, reason);
    if (outcome === "provider_token" && attempt === 0) {
      refused = jwt;
      continue;
    }
    return {
      outcome, status: response.status,
      reason: outcome === "sent" ? "sent" : apnsReasonCode(reason), providerMs,
    };
  }
  return { outcome: "provider_token", status: 403, reason: "provider_token_refused", providerMs: 0 };
}
