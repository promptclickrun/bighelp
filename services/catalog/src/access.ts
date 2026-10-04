// Verifies the Cloudflare Access JWT that Access puts on every request it lets through.
// The Worker checks it itself, so a mis-scoped Access app can't open the signed-in routes.

export interface AccessConfig {
  teamDomain: string;
  audience: string;
}

export interface Principal {
  /** Present for people signed in with Google or GitHub. */
  email?: string;
  /** Present for service tokens (agents): the token's client ID. */
  serviceTokenId?: string;
}

interface Jwk extends JsonWebKey {
  kid?: string;
}

export type KeySource = (teamDomain: string) => Promise<Jwk[]>;

const KEY_CACHE_MS = 10 * 60 * 1000;
let cachedKeys: { teamDomain: string; keys: Jwk[]; at: number } | undefined;

/** Fetches Access's signing keys, cached for ten minutes per isolate. */
export const fetchAccessKeys: KeySource = async (teamDomain) => {
  if (cachedKeys && cachedKeys.teamDomain === teamDomain && Date.now() - cachedKeys.at < KEY_CACHE_MS) {
    return cachedKeys.keys;
  }
  const response = await fetch(`https://${teamDomain}/cdn-cgi/access/certs`);
  if (!response.ok) throw new Error(`Access keys returned ${response.status}`);
  const body = await response.json<{ keys?: Jwk[] }>();
  const keys = body.keys ?? [];
  cachedKeys = { teamDomain, keys, at: Date.now() };
  return keys;
};

/** The principal behind a request, or null if it carries no valid Access token. */
export async function verifyAccess(
  request: Request,
  config: AccessConfig,
  keys: KeySource = fetchAccessKeys,
  now = Date.now(),
): Promise<Principal | null> {
  const token = request.headers.get("Cf-Access-Jwt-Assertion");
  if (!token || !config.audience || !config.teamDomain) return null;
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const [headerPart, payloadPart, signaturePart] = parts as [string, string, string];

  let header: { alg?: string; kid?: string };
  let claims: {
    aud?: string | string[];
    iss?: string;
    exp?: number;
    nbf?: number;
    email?: string;
    common_name?: string;
  };
  try {
    header = JSON.parse(decodeText(headerPart));
    claims = JSON.parse(decodeText(payloadPart));
  } catch {
    return null;
  }
  if (header.alg !== "RS256") return null;

  const jwk = (await keys(config.teamDomain)).find((key) => key.kid === header.kid);
  if (!jwk) return null;
  const key = await crypto.subtle.importKey(
    "jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"],
  );
  const valid = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5", key, decodeBytes(signaturePart),
    new TextEncoder().encode(`${headerPart}.${payloadPart}`),
  );
  if (!valid) return null;

  const seconds = now / 1000;
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audiences.includes(config.audience)) return null;
  if (claims.iss !== `https://${config.teamDomain}`) return null;
  if (typeof claims.exp !== "number" || claims.exp < seconds) return null;
  if (typeof claims.nbf === "number" && claims.nbf > seconds + 60) return null;

  if (claims.email) return { email: claims.email.toLowerCase() };
  if (claims.common_name) return { serviceTokenId: claims.common_name };
  return null;
}

function decodeBytes(part: string): Uint8Array<ArrayBuffer> {
  const base64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=");
  const binary = atob(base64);
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

function decodeText(part: string): string {
  return new TextDecoder().decode(decodeBytes(part));
}
