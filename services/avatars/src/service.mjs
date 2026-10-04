const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
  'Access-Control-Allow-Headers': 'If-None-Match',
  'Access-Control-Expose-Headers': 'ETag, Cache-Control',
  'X-Content-Type-Options': 'nosniff',
};

// A quoted entity tag may contain a comma. Compare opaque values weakly for GET/HEAD.
function matches(header, tag) {
  if (!header) return false;
  const value = header.trim();
  if (value === '*') return true;
  const list = /(?:W\/)?"[\x21\x23-\x7e\x80-\xff]*"/y;
  let offset = 0, found = false;
  while (offset < value.length) {
    if (/[ \t,]/.test(value.charAt(offset))) { offset++; continue; }
    list.lastIndex = offset;
    const match = list.exec(value);
    if (!match) return false;
    found ||= match[0].replace(/^W\//, '') === tag;
    offset = list.lastIndex;
    if (offset < value.length && !/[ \t,]/.test(value.charAt(offset))) return false;
    while (/[ \t]/.test(value.charAt(offset)) && offset < value.length) offset++;
    if (offset < value.length && value.charAt(offset) !== ',') return false;
  }
  return found;
}

export async function respond(request, env, source, now = Date.now()) {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (!['GET', 'HEAD'].includes(request.method)) {
    return new Response('Read only', { status: 405, headers: { ...cors, Allow: 'GET, HEAD, OPTIONS', 'Cache-Control': 'no-store' } });
  }
  const path = new URL(request.url).pathname;
  if (/^\/assets\/[a-f0-9]{64}\.(svg|png|json)$/.test(path) || path === '/NOTICES.txt') {
    const result = await env.ASSETS.fetch(request);
    const headers = new Headers(result.headers);
    for (const [key, value] of Object.entries(cors)) headers.set(key, value);
    headers.set('Content-Security-Policy', "default-src 'none'; sandbox");
    headers.set('Cache-Control', result.status === 200 || result.status === 304
      ? (path === '/NOTICES.txt' ? 'public, max-age=300' : 'public, max-age=31536000, immutable') : 'no-store');
    return new Response(request.method === 'HEAD' ? null : result.body, { status: result.status, headers });
  }
  if (!['/v1/avatars.json', '/v1/avatar-kit.json'].includes(path)) return new Response('Not found', { status: 404, headers: { ...cors, 'Cache-Control': 'no-store' } });
  const sets = source.sets.filter(s => (!s.startsAt || Date.parse(s.startsAt) <= now) && (!s.expiresAt || now < Date.parse(s.expiresAt)));
  const ids = new Set(sets.map(s => s.id));
  const transitions = source.sets.flatMap(s => [s.startsAt, s.expiresAt]).filter(Boolean).map(Date.parse).filter(t => t > now);
  const next = transitions.length ? Math.min(...transitions) : null;
  const nextChangeAt = next === null ? null : new Date(next).toISOString();
  const { kit, ...catalog } = source;
  const avatars = source.avatars.filter(a => ids.has(a.setId));
  const activeIDs = new Set(avatars.map(a => a.id));
  const data = path === '/v1/avatar-kit.json'
    ? { ...kit, characters: kit.characters.filter(c => activeIDs.has(c.id)), nextChangeAt }
    : { ...catalog, sets, avatars, nextChangeAt };
  const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(data)));
  const revision = Array.from(new Uint8Array(hash), byte => byte.toString(16).padStart(2, '0')).join('');
  const etag = `"${revision}"`;
  const ttl = next === null ? 300 : Math.max(0, Math.min(300, Math.floor((next - now) / 1000)));
  const headers = { ...cors, 'Content-Type': 'application/json; charset=utf-8', ETag: etag, 'Cache-Control': `public, max-age=${ttl}, must-revalidate` };
  if (matches(request.headers.get('If-None-Match'), etag)) return new Response(null, { status: 304, headers });
  return new Response(request.method === 'HEAD' ? null : JSON.stringify({ ...data, revision }), { headers });
}
