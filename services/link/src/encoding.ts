// Mechanics only: alphabet, canonicality, size and error policies belong to
// each protocol boundary. Do not use decoding as input validation.
export function encodeBase64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return binaryBase64URL(binary);
}

// Preserve the existing bounded notification/provider encoder's spread behavior.
export function encodeSmallBase64URL(bytes: Uint8Array): string {
  return binaryBase64URL(String.fromCharCode(...bytes));
}

function binaryBase64URL(binary: string): string {
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function decodeBase64URL(value: string, pad = true): Uint8Array {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const binary = atob(pad ? normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=") : normalized);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export function randomBase64URL(byteCount: number): string {
  return encodeBase64URL(crypto.getRandomValues(new Uint8Array(byteCount)));
}

export async function sha256Bytes(value: string | Uint8Array): Promise<Uint8Array> {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

export async function sha256Base64URL(value: string | Uint8Array): Promise<string> {
  return encodeBase64URL(await sha256Bytes(value));
}
