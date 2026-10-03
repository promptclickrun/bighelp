import { privateJSON } from "./http-primitives.js";
import { LoopdyLinkError } from "./contracts.js";

export function json(body: unknown, status = 200): Response {
  return privateJSON(body, status, { "content-type": "application/json; charset=utf-8" });
}

export function notFound(): Response {
  return json({ version: 1, error: "not_found", message: "Loopdy Link route was not found" }, 404);
}

export function errorResponse(error: unknown): Response {
  if (error instanceof HTTPError) {
    return json({ version: 1, error: error.code, message: error.message }, error.status);
  }
  if (error instanceof LoopdyLinkError) {
    return json(
      { version: 1, error: error.code, message: error.message },
      linkErrorStatus(error.code),
    );
  }
  console.error("Loopdy Link request failed", error);
  return json({ version: 1, error: "internal_error", message: "Loopdy Link request failed" }, 500);
}

const LINK_ERROR_STATUS = new Map<string, number>([
  ["session_invalid", 401],
  ["session_expired", 401],
  ["account_deletion_not_accepted", 401],
  ["device_credentials_missing", 401],
  ["device_revoked", 403],
  ["authorization_epoch_stale", 403],
  ["device_signature_invalid", 403],
  ["nonce_replayed", 403],
  ["pairing_proof_invalid", 403],
  ["pairing_code_invalid", 403],
  ["pairing_secret_invalid", 403],
  ["device_not_found", 404],
  ["pairing_not_found", 404],
  ["account_not_found", 404],
  ["account_key_missing", 404],
  ["pairing_expired", 410],
  ["pairing_pending", 425],
  ["stale_revision", 409],
  ["device_conflict", 409],
  ["challenge_used", 409],
  ["pairing_already_pending", 409],
  ["account_key_conflict", 409],
]);

function linkErrorStatus(code: string): number {
  return LINK_ERROR_STATUS.get(code) ?? 400;
}

export class HTTPError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}
