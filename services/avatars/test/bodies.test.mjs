import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { buildBodies, loadBodies } from '../scripts/bodies.mjs';
import { respond } from '../src/service.mjs';

const folder = new URL('./fixtures/bodies/', import.meta.url);
const now = Date.parse('2026-11-10T12:00:00Z');
const load = (name) => readFile(new URL(name, folder), 'utf8').then(JSON.parse);
const shapes = () => load('shapes.json');
// Builds one source after `change` edits a fresh copy of the valid shapes fixture.
const build = async (change, file = 'shapes.json') => {
  const data = await shapes();
  change(data, data.bodies[0]);
  return buildBodies([{ file, data }], now);
};
const rejects = (change, pattern, file) => assert.rejects(build(change, file), pattern);

test('a valid folder builds, keeps body order and canonical key order', async () => {
  const feed = await loadBodies(new URL(folder).pathname, now);
  assert.equal(feed.schemaVersion, 2);
  assert.deepEqual(Object.keys(feed), ['schemaVersion', 'sets', 'bodies']);
  assert.deepEqual(feed.bodies.filter(b => b.set === 'shapes').map(b => b.id), ['shapes.tile', 'shapes.ball']);
  assert.deepEqual(Object.keys(feed.bodies[0]), ['id', 'name', 'parts', 'eyes', 'eyeTilt', 'rotation', 'colors', 'set']);
  assert.deepEqual(Object.keys(feed.bodies[1]), ['id', 'name', 'role', 'parts', 'eyes', 'eyeTilt', 'rotation', 'colors', 'set']);
  assert.deepEqual(Object.keys(feed.sets[0]), ['id', 'name', 'category', 'startsAt', 'expiresAt']);
});

test('output does not depend on key order or file order in the sources', async () => {
  const feed = await loadBodies(new URL(folder).pathname, now);
  const files = await Promise.all(['halloween', 'zeta-set', 'shapes', 'christmas', 'alpha-set', 'thanksgiving', 'bitty-bots']
    .map(async name => ({ file: `${name}.json`, data: await load(`${name}.json`) })));
  // Reverse the keys of every body: the feed still has the same bytes.
  for (const { data } of files) data.bodies = data.bodies.map(b => Object.fromEntries(Object.entries(b).reverse()));
  assert.equal(JSON.stringify(buildBodies(files, now)), JSON.stringify(feed));
});

test('sets are ordered: fixed list, seasonal by date, unknown by id', async () => {
  const feed = await loadBodies(new URL(folder).pathname, now);
  assert.deepEqual(feed.sets.map(s => s.id), ['shapes', 'bitty-bots', 'halloween', 'thanksgiving', 'christmas', 'alpha-set', 'zeta-set']);
});

test('a set expired more than 30 days ago is dropped, with its bodies', async () => {
  const late = await loadBodies(new URL(folder).pathname, Date.parse('2026-12-20T00:00:00Z'));
  assert.ok(!late.sets.some(s => s.id === 'halloween'));
  assert.ok(!late.bodies.some(b => b.set === 'halloween'));
  assert.ok(late.sets.some(s => s.id === 'thanksgiving'), 'expired 20 days ago: kept');
  // A set that has not started yet stays, with its dates.
  const early = await loadBodies(new URL(folder).pathname, Date.parse('2026-10-01T00:00:00Z'));
  assert.deepEqual(early.sets.find(s => s.id === 'christmas').startsAt, '2026-12-01T00:00:00-06:00');
});

test('an expired set is still checked before it is dropped', async () => {
  const data = await load('halloween.json');
  data.bodies[0].rotation = 90;
  assert.throws(() => buildBodies([{ file: 'halloween.json', data }], Date.parse('2030-01-01T00:00:00Z')), /rotation/);
});

test('shape of the file and the set', async () => {
  await rejects(d => { d.extra = 1; }, /unknown key "extra"/);
  await rejects(d => { d.bodies = []; }, /at least one body/);
  await rejects(d => { d.set.category = 'faces'; }, /category/);
  await rejects(d => { d.set.name = ''; }, /name/);
  await rejects(d => { d.set.startsAt = '2026-11-03'; }, /startsAt/);
  await rejects(d => { d.set.expiresAt = '2026-02-30T00:00:00Z'; }, /calendar date/);
  await rejects(d => { d.set.startsAt = '2027-01-01T00:00:00Z'; d.set.expiresAt = '2026-01-01T00:00:00Z'; }, /after startsAt/);
  await rejects(() => {}, /file name must be shapes\.json/, 'other.json');
  await rejects((d, b) => { b.extra = true; }, /unknown key "extra"/);
});

test('body ids: prefix, slug and uniqueness', async () => {
  await rejects((d, b) => { b.id = 'tile'; }, /shapes\.<slug>/);
  await rejects((d, b) => { b.id = 'hermes.tile'; }, /shapes\.<slug>/);
  await rejects((d, b) => { b.id = 'shapes.Tile'; }, /slug/);
  await rejects((d, b) => { b.id = 'shapes.a_b'; }, /slug/);
  await rejects((d, b) => { b.id = 'shapes.'; }, /slug/);
  await rejects((d, b) => { d.bodies.push(structuredClone(b)); }, /duplicate body id shapes\.tile/);
  const [a, b] = await Promise.all([shapes(), shapes()]);
  assert.throws(() => buildBodies([{ file: 'shapes.json', data: a }, { file: 'shapes.json', data: b }], now), /duplicate body id/);
});

test('parts: count, tone, stroke and round', async () => {
  await rejects((d, b) => { b.parts = []; }, /1 to 12/);
  await rejects((d, b) => { b.parts = Array.from({ length: 13 }, () => structuredClone(b.parts[0])); }, /1 to 12/);
  await buildBodies([{ file: 'shapes.json', data: await (async () => { const d = await shapes(); d.bodies[0].parts = Array.from({ length: 12 }, () => structuredClone(d.bodies[0].parts[0])); return d; })() }], now);
  await rejects((d, b) => { b.parts[0].tone = 'red'; }, /tone/);
  await rejects((d, b) => { b.parts[0].stroke = 4; b.parts[0].round = 4; }, /at most one of stroke and round/);
  await rejects((d, b) => { b.parts[0].round = 25; }, /round must be a number from 0 to 24/);
  await rejects((d, b) => { b.parts[0].round = -1; }, /round/);
  await rejects((d, b) => { b.parts[0].stroke = '4'; }, /stroke/);
  await rejects((d, b) => { b.parts[0].fill = 'red'; }, /unknown key "fill"/);
});

test('path data: length, commands and numbers', async () => {
  await rejects((d, b) => { b.parts[0].d = 'M0 0' + 'L1 1'.repeat(1000); }, /4000/);
  await rejects((d, b) => { b.parts[0].d = ''; }, /1 to 4000/);
  await rejects((d, b) => { b.parts[0].d = 'M0 0S1 1 2 2'; }, /command S/);
  await rejects((d, b) => { b.parts[0].d = 'M0 0T1 1'; }, /command T/);
  await rejects((d, b) => { b.parts[0].d = 'M0 0 1e3 5'; }, /command e/);
  await rejects((d, b) => { b.parts[0].d = 'M0 0 L+5 5'; }, /plain numbers/);
  await rejects((d, b) => { b.parts[0].d = 'M0 0 L5 5 NaN'; }, /command N|plain numbers/);
  await rejects((d, b) => { b.parts[0].d = 'M0 0 L1e999 5'; }, /command e/);
  await rejects((d, b) => { b.parts[0].d = 'L5 5'; }, /start with M/);
  await rejects((d, b) => { b.parts[0].d = 'M0 0 L5'; }, /wrong number of values/);
  await rejects((d, b) => { b.parts[0].d = 'M0 0 Z5'; }, /wrong number of values/);
  await rejects((d, b) => { b.parts[0].d = 'M0 0 A5 5 0 2 1 9 9'; }, /arc flags/);
  await rejects((d, b) => { b.parts[0].d = 'M0 0 L5 5 ; rm'; }, /plain numbers/);
  // Both cases, relative commands, implicit repeats and compact separators are fine.
  await build((d, b) => { b.parts[0].d = 'm10 10l5-5h3v4c1 1 2 2 3 3q1 1 2 2a5 5 0 1 0 9 9zM1.5.5L2,3Z'; });
});

test('eyes, tilt and rotation ranges', async () => {
  await rejects((d, b) => { b.eyes = [[40, 46, 11]]; }, /exactly two/);
  await rejects((d, b) => { b.eyes[0] = [40, 46]; }, /\[x, y, height\]/);
  await rejects((d, b) => { b.eyes[0][0] = 101; }, /x must/);
  await rejects((d, b) => { b.eyes[1][1] = -1; }, /y must/);
  await rejects((d, b) => { b.eyes[0][2] = 5; }, /height must be a number from 6 to 20/);
  await rejects((d, b) => { b.eyes[0][2] = 21; }, /height/);
  await rejects((d, b) => { b.rotation = 46; }, /rotation/);
  await rejects((d, b) => { b.rotation = -46; }, /rotation/);
  await rejects((d, b) => { b.eyeTilt = 50; }, /eyeTilt/);
  await rejects((d, b) => { b.eyeTilt = null; }, /eyeTilt/);
  await build((d, b) => { b.rotation = -45; b.eyeTilt = 45; b.eyes = [[0, 100, 6], [100, 0, 20]]; });
});

test('colors', async () => {
  await rejects((d, b) => { b.colors.main = '#12345'; }, /colors\.main/);
  await rejects((d, b) => { b.colors.main = 'blue'; }, /colors\.main/);
  await rejects((d, b) => { b.colors.accent = '#GGGGGG'; }, /colors\.accent/);
  await rejects((d, b) => { b.colors.main = '#ff8a7a'; }, /brand coral/);
  await rejects((d, b) => { delete b.colors.main; }, /missing "main"/);
  await rejects((d, b) => { b.colors.shade = '#000000'; }, /unknown key "shade"/);
  await build((d, b) => { delete b.colors.accent; });
});

test('size limits: 60 bodies per set, 512 KB overall', async () => {
  await build((d, b) => { d.bodies = Array.from({ length: 60 }, (_, i) => ({ ...structuredClone(b), id: `shapes.b${i}` })); });
  await rejects((d, b) => { d.bodies = Array.from({ length: 61 }, (_, i) => ({ ...structuredClone(b), id: `shapes.b${i}` })); }, /at most 60/);
  const files = [];
  for (let s = 0; s < 4; s++) {
    const data = await shapes();
    data.set.id = `big-${s}`;
    data.bodies = Array.from({ length: 60 }, (_, i) => {
      const b = structuredClone(data.bodies[0]);
      b.id = `big-${s}.b${i}`;
      b.parts = Array.from({ length: 12 }, () => ({ d: 'M0 0' + ' L10 10'.repeat(300), tone: 'main' }));
      return b;
    });
    files.push({ file: `big-${s}.json`, data });
  }
  assert.throws(() => buildBodies(files, now), /limit is 524288/);
});

test('/v2/bodies.json is served like v1 and v1 is untouched', async () => {
  const feed = await loadBodies(new URL(folder).pathname, now);
  const env = { ASSETS: { fetch: async () => new Response('asset') } };
  const source = { schemaVersion: 1, categories: [], sets: [{ id: 'faces', name: 'Faces', category: 'faces', startsAt: null, expiresAt: null }], avatars: [{ id: 'face-round', setId: 'faces' }],
    kit: { version: 1, states: ['idle'], themes: [], keyframes: {}, characters: [{ id: 'face-round' }] } };
  const get = (path, options, bodies) => respond(new Request(`https://avatars.bighelp.app${path}`, options), env, source, now, bodies);

  const response = await get('/v2/bodies.json', undefined, feed);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Content-Type'), 'application/json; charset=utf-8');
  assert.equal(response.headers.get('Cache-Control'), 'public, max-age=300, must-revalidate');
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), '*');
  assert.equal(response.headers.get('X-Content-Type-Options'), 'nosniff');
  assert.deepEqual(await response.json(), feed);

  const tag = response.headers.get('ETag');
  assert.equal((await get('/v2/bodies.json', { headers: { 'If-None-Match': tag } }, feed)).status, 304);
  const head = await get('/v2/bodies.json', { method: 'HEAD' }, feed);
  assert.equal(head.status, 200);
  assert.equal(await head.text(), '');
  assert.equal((await get('/v2/bodies.json', { method: 'POST' }, feed)).status, 405);
  assert.equal((await get('/v2/bodies.json')).status, 404, 'no feed built: not found');

  // v1 answers are byte-identical with or without the v2 feed.
  for (const path of ['/v1/avatars.json', '/v1/avatar-kit.json']) {
    const [plain, withBodies] = [await get(path, undefined, undefined), await get(path, undefined, feed)];
    assert.equal(await withBodies.text(), await plain.text());
    assert.equal(withBodies.headers.get('ETag'), plain.headers.get('ETag'));
  }
});
