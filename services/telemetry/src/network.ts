const HASH_BYTES = 16;

// One IPv6 customer can use a whole /64 (and more), so a per-address key would be trivial to dodge.
// IPv6 is cut to its /64 prefix; IPv4 (and IPv4-mapped IPv6) keeps the full address.
export function networkPrefix(address: string): string {
  const trimmed = address.trim().toLowerCase().split("%")[0]!;
  if (!trimmed.includes(":")) return trimmed;

  // ::ffff:a.b.c.d is an IPv4 client seen through a translator. Keep the whole IPv4 address.
  const mapped = /^(?:0{0,4}:){1,6}ffff:(\d{1,3}(?:\.\d{1,3}){3})$/.exec(trimmed);
  if (mapped) return mapped[1]!;

  let text = trimmed;
  const lastColon = text.lastIndexOf(":");
  const tail = text.slice(lastColon + 1);
  if (tail.includes(".")) {
    const octets = tail.split(".").map(Number);
    if (octets.length !== 4 || octets.some((octet) => !Number.isInteger(octet) || octet < 0 || octet > 255)) {
      return trimmed;
    }
    const high = ((octets[0]! << 8) | octets[1]!).toString(16);
    const low = ((octets[2]! << 8) | octets[3]!).toString(16);
    text = `${text.slice(0, lastColon + 1)}${high}:${low}`;
  }

  const halves = text.split("::");
  if (halves.length > 2) return trimmed;
  const head = halves[0] ? halves[0].split(":") : [];
  const rest = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  const missing = 8 - head.length - rest.length;
  if (halves.length === 1 ? head.length !== 8 : missing < 1) return trimmed;
  const groups = halves.length === 1 ? head : [...head, ...Array<string>(missing).fill("0"), ...rest];
  if (!groups.every((group) => /^[0-9a-f]{1,4}$/.test(group))) return trimmed;
  return `${groups.slice(0, 4).map((group) => parseInt(group, 16).toString(16)).join(":")}::/64`;
}

// HMAC-SHA256 of the client network, cut to 16 bytes. Without the secret there is no network key at all,
// because falling back to the raw address would put it into the rate limiter. The caller then uses one
// shared key, so a missing secret limits everyone together instead of nobody.
export async function networkKey(secret: string | undefined, address: string | null): Promise<string | null> {
  if (!secret || !address) return null;
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(networkPrefix(address))));
  return Array.from(mac.slice(0, HASH_BYTES), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
