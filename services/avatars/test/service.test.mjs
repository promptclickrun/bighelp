import test from 'node:test';
import assert from 'node:assert/strict';
import { respond } from '../src/service.mjs';

const source = { schemaVersion: 1, categories: [{ id: 'faces', name: 'Faces' }, { id: 'seasonal', name: 'Seasonal' }], sets: [
  { id: 'faces', name: 'Faces', category: 'faces', startsAt: null, expiresAt: null },
  { id: 'halloween', name: 'Halloween', category: 'seasonal', startsAt: null, expiresAt: '2026-11-03T00:00:00-06:00' },
  { id: 'thanksgiving', name: 'Thanksgiving', category: 'seasonal', startsAt: '2026-11-03T00:00:00-06:00', expiresAt: null },
], avatars: [
  { id: 'face-round', setId: 'faces' }, { id: 'halloween-bat', setId: 'halloween' }, { id: 'thanksgiving-turkey', setId: 'thanksgiving' },
] };
const env = { ASSETS: { fetch: async () => new Response('asset') } };
const request = (path = '/v1/avatars.json', options) => new Request(`https://avatars.bighelp.app${path}`, options);
const before = Date.parse('2026-10-04T12:00:00Z');

test('native JSON endpoint filters expired characters and immutable kit files remain available', async () => {
  const augmented = { ...source, kit: { version: 1, states: ['idle'], themes: [], keyframes: {}, characters: source.avatars.map(a => ({id:a.id})) } };
  const response = await respond(request('/v1/avatar-kit.json'), env, augmented, before);
  assert.equal(response.status, 200);
  const kit = await response.json();
  assert.equal(kit.version, 1);
  assert.deepEqual(kit.characters.map(c=>c.id), ['face-round','halloween-bat']);
  const after = await respond(request('/v1/avatar-kit.json'), env, augmented, Date.parse('2026-11-03T06:00:00Z'));
  assert.deepEqual((await after.json()).characters.map(c=>c.id), ['face-round','thanksgiving-turkey']);
  const index = await (await respond(request(),env,augmented,before)).json();
  assert.equal(index.kit, undefined);
  assert.equal((await respond(request('/assets/'+ 'a'.repeat(64) + '.json'),env,augmented,before)).status, 200);
});

test('seasonal transition changes ETag exactly at expiry and bounds cache lifetime', async () => {
  const cutoff = Date.parse(source.sets[1].expiresAt);
  const old = await respond(request(), env, source, cutoff - 1000);
  assert.equal(old.headers.get('Cache-Control'), 'public, max-age=1, must-revalidate');
  const tag = old.headers.get('ETag');
  assert.ok(tag);
  const fresh = await respond(request('/v1/avatars.json', { headers: { 'If-None-Match': tag } }), env, source, cutoff);
  assert.equal(fresh.status, 200);
  assert.notEqual(fresh.headers.get('ETag'), tag);
  assert.deepEqual((await fresh.json()).avatars.map(a => a.id), ['face-round', 'thanksgiving-turkey']);
});

test('unchanged feed accepts strong, weak, listed, and wildcard validators', async () => {
  const initial = await respond(request(), env, source, before);
  const tag = initial.headers.get('ETag');
  for (const validator of [tag, `W/${tag}`, `"old,tag", W/${tag}`, '*']) {
    const response = await respond(request('/v1/avatars.json', { headers: { 'If-None-Match': validator } }), env, source, before);
    assert.equal(response.status, 304, validator);
    assert.equal(await response.text(), '');
  }
  for (const validator of ['"old"', `W/${tag.slice(0, -1)}wrong"`, `bad ${tag}`]) {
    assert.equal((await respond(request('/v1/avatars.json', { headers: { 'If-None-Match': validator } }), env, source, before)).status, 200);
  }
});

test('public clients cannot write and expired assets remain downloadable', async () => {
  for (const method of ['POST', 'PUT', 'PATCH', 'DELETE']) {
    for (const path of ['/v1/avatars.json', '/admin/sets', '/assets/a.svg']) {
      assert.equal((await respond(request(path, { method }), env, source, before)).status, 405);
    }
  }
  const asset = await respond(request('/assets/' + 'a'.repeat(64) + '.svg'), env, source, Date.parse('2027-01-01'));
  assert.equal(await asset.text(), 'asset');
  assert.equal(asset.headers.get('Cache-Control'), 'public, max-age=31536000, immutable');
  assert.ok(asset.headers.get('Content-Security-Policy').includes("default-src 'none'"));
  assert.equal((await respond(request('/missing', { headers: { 'If-None-Match': '*' } }), env, source, before)).status, 404);
  const head = await respond(request('/v1/avatars.json', { method: 'HEAD' }), env, source, before);
  assert.equal(head.status, 200);
  assert.equal(await head.text(), '');
});

test('public catalog serves current sets without authentication', async () => {
  const response = await respond(request(), env, source, before);
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.schemaVersion, 1);
  assert.deepEqual(data.avatars.map(a => a.id), ['face-round', 'halloween-bat']);
  assert.deepEqual(data.sets.map(s => s.id), ['faces', 'halloween']);
  assert.equal(data.nextChangeAt, '2026-11-03T06:00:00.000Z');
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), '*');
});
