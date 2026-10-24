const HASH_BYTES = 16;

// HMAC-SHA256 of the client address, cut to 16 bytes. Without the secret there is no network key at all,
// because falling back to the raw address would put it into the rate limiter.
export async function networkKey(secret: string | undefined, address: string | null): Promise<string | null> {
  if (!secret || !address) return null;
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(address)));
  return Array.from(mac.slice(0, HASH_BYTES), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
