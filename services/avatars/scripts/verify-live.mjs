import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';

const base = 'https://avatars.bighelp.app';
const expected = JSON.parse(await readFile(new URL('../catalog.json', import.meta.url), 'utf8'));
const response = await fetch(`${base}/v1/avatars.json`);
assert.equal(response.status, 200);
const catalog = await response.json();
const active = expected.avatars.filter(a => (!a.startsAt || Date.parse(a.startsAt) <= Date.now()) && (!a.expiresAt || Date.now() < Date.parse(a.expiresAt)));
assert.deepEqual(catalog.avatars.map(a => a.id).sort(), active.map(a => a.id).sort());
assert.equal(new Set(catalog.avatars.map(a => a.id)).size, catalog.avatars.length);
const files = catalog.avatars.flatMap(a => [a.svg, a.png]);
let checked = 0;
for (let i = 0; i < files.length; i += 6) {
  await Promise.all(files.slice(i, i + 6).map(async file => {
    assert.equal(new URL(file.url).origin, base);
    const downloaded = await fetch(file.url);
    assert.equal(downloaded.status, 200, file.url);
    const bytes = Buffer.from(await downloaded.arrayBuffer());
    assert.equal(bytes.length, file.bytes, file.url);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), file.sha256, file.url);
    assert.equal(downloaded.headers.get('content-type').split(';')[0], file.contentType);
    assert.ok(downloaded.headers.get('cache-control').includes('immutable'));
    if (file.contentType === 'image/png') {
      assert.equal(bytes.readUInt32BE(16), 512);
      assert.equal(bytes.readUInt32BE(20), 512);
    }
    checked++;
  }));
}
const tag = response.headers.get('etag').replace(/^W\//, '');
for (const value of [tag, `W/${tag}`, `"old,tag", W/${tag}`, '*']) {
  assert.equal((await fetch(`${base}/v1/avatars.json`, { headers: { 'If-None-Match': value } })).status, 304);
}
for (const method of ['POST', 'PUT', 'PATCH', 'DELETE']) {
  assert.equal((await fetch(`${base}/v1/avatars.json`, { method })).status, 405);
}
assert.equal((await fetch(`${base}/v1/avatars.json`, { method: 'HEAD' })).status, 200);
assert.equal((await fetch(`${base}/not-found`, { headers: { 'If-None-Match': '*' } })).status, 404);
assert.equal((await fetch(`${base}/NOTICES.txt`)).status, 200);
console.log(JSON.stringify({ checkedAt: new Date().toISOString(), avatars: catalog.avatars.length, assetsVerified: checked,
  sets: catalog.sets.map(s => ({ ...s, count: catalog.avatars.filter(a => a.setId === s.id).length })),
  conditionalGET: 'strong/weak/list/wildcard: 304', writes: 'POST/PUT/PATCH/DELETE: 405', head: 200, missing: 404,
}, null, 2));
