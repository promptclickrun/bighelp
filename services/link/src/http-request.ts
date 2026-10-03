import { LoopdyLinkError } from "./contracts.js";
import { HTTPError } from "./http-response.js";

const MAX_BODY_CHARACTERS = 65_536;
export const MAX_PROFILE_BODY_CHARACTERS = 3_000_000;

export async function readJSONObject(request: Request): Promise<Record<string, unknown>> {
  return parseJSON(await readBoundedBody(request));
}

export async function readBoundedBody(
  request: Request,
  maximumCharacters = MAX_BODY_CHARACTERS,
): Promise<string> {
  const contentType = (request.headers.get("content-type") ?? "")
    .split(";", 1)[0]!
    .trim()
    .toLowerCase();
  if (contentType !== "application/json") {
    throw new HTTPError(415, "content_type_invalid", "Request must contain JSON");
  }
  const declaredLength = request.headers.get("content-length");
  if (declaredLength && Number(declaredLength) > maximumCharacters) {
    throw new HTTPError(413, "body_too_large", "Request body is too large");
  }
  const body = await request.text();
  if (body.length > maximumCharacters) {
    throw new HTTPError(413, "body_too_large", "Request body is too large");
  }
  return body;
}

export function parseJSON(body: string): Record<string, unknown> {
  let value: unknown;
  try {
    value = JSON.parse(body);
  } catch {
    throw new HTTPError(400, "json_invalid", "Request JSON is invalid");
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new HTTPError(400, "json_invalid", "Request JSON must be an object");
  }
  return value as Record<string, unknown>;
}

export function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length < 1 || value.length > MAX_BODY_CHARACTERS) {
    throw new HTTPError(400, "request_invalid", `${field} is invalid`);
  }
  return value;
}

export function requiredPositiveInteger(value: unknown, field: string): number {
  if (!Number.isSafeInteger(value) || Number(value) < 1) {
    throw new HTTPError(400, "request_invalid", `${field} is invalid`);
  }
  return Number(value);
}

export function requiredNonnegativeInteger(value: unknown, field: string): number {
  if (!Number.isSafeInteger(value) || Number(value) < 0) {
    throw new HTTPError(400, "request_invalid", `${field} is invalid`);
  }
  return Number(value);
}

export function bearerToken(request: Request): string {
  const authorization = request.headers.get("authorization");
  const match = /^Bearer ([A-Za-z0-9_-]{32,128})$/.exec(authorization ?? "");
  if (!match) throw new LoopdyLinkError("session_invalid", "Account session is invalid");
  return match[1]!;
}
