import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';

test('publishes authored packs unchanged with their animation settings', async () => {
  execFileSync(process.execPath, ['scripts/build.mjs']);
  const catalog = JSON.parse(await readFile('catalog.json'));
  const collections = [
    { file: 'helpers', setId: 'bighelp', category: 'bighelp', count: 10 },
    { file: 'halloween', setId: 'halloween', category: 'seasonal', count: 10 },
    { file: 'pocket-curios', setId: 'pocket-curios', category: 'bighelp', count: 20 },
    { file: 'bitty-bots', setId: 'bitty-bots', category: 'bighelp', count: 16 },
    { file: 'thanksgiving', setId: 'thanksgiving', category: 'seasonal', count: 5 },
    { file: 'christmas', setId: 'christmas', category: 'seasonal', count: 5 },
  ];
  for (const { file, setId, category, count } of collections) {
    const pack = JSON.parse(await readFile(`sources/packs/${file}.json`));
    assert.equal(pack.characters.length, count);
    assert.equal(catalog.avatars.filter(a => a.setId === setId).length, count, `${setId} count`);
    for (const key of ['version', 'states', 'themes', 'keyframes']) assert.deepEqual(catalog.kit[key], pack[key]);
    for (const character of pack.characters) {
      assert.deepEqual(catalog.kit.characters.find(c => c.id === character.id), character);
      const entry = catalog.avatars.find(a => a.id === character.id);
      const individual = JSON.parse(await readFile(`public/assets/${entry.kit.url.split('/').pop()}`));
      assert.deepEqual(individual.characters, [character]);
      for (const key of ['version', 'states', 'themes', 'keyframes']) assert.deepEqual(individual[key], pack[key]);
      assert.equal(entry.category, category);
      assert.equal(entry.name, character.name);
      if (file !== 'helpers' && file !== 'halloween') assert.equal(entry.role, character.role);
    }
  }
  assert.equal(catalog.avatars.length, 84);
  assert.deepEqual(catalog.sets.find(s => s.id === 'pocket-curios'), {
    id: 'pocket-curios', name: 'Pocket Curios', category: 'bighelp', startsAt: null, expiresAt: null,
  });
  assert.equal(catalog.sets.find(s => s.id === 'halloween').expiresAt, '2026-11-03T00:00:00-06:00');
  for (const set of [
    { id: 'bitty-bots', name: 'Bitty Bots', category: 'bighelp', startsAt: null, expiresAt: null },
    { id: 'thanksgiving', name: 'Thanksgiving', category: 'seasonal', startsAt: null, expiresAt: '2026-11-30T00:00:00-06:00' },
    { id: 'christmas', name: 'Christmas', category: 'seasonal', startsAt: null, expiresAt: '2027-01-02T00:00:00-06:00' },
  ]) assert.deepEqual(catalog.sets.find(s => s.id === set.id), set);
});

test('one-color collections keep no background color and use the accent only for kit effects', async () => {
  // The app hides the backdrop disc and derives one from the primary color, so these packs
  // deliberately have no `bg`; nothing may add one on the way to the catalog.
  const catalog = JSON.parse(await readFile('catalog.json'));
  for (const file of ['bitty-bots', 'thanksgiving', 'christmas']) {
    for (const character of JSON.parse(await readFile(`sources/packs/${file}.json`)).characters) {
      const published = catalog.kit.characters.find(c => c.id === character.id);
      assert.equal('bg' in published.colors, false, character.id);
      assert.ok(JSON.stringify(published.tree).includes('"@p"'), character.id);
      assert.equal(JSON.stringify(published.tree).includes('"@s"'), false, character.id);
      const accentShowsAtIdle = (node, hidden = false) => {
        const idle = node.st?.idle ?? {};
        const isHidden = hidden || idle.o === 0;
        return (!isHidden && (idle.f === '@a' || idle.s === '@a')) || (node.k ?? []).some(child => accentShowsAtIdle(child, isHidden));
      };
      assert.equal(accentShowsAtIdle(published.tree), false, `${character.id} shows the accent at rest`);
    }
  }
});

test('authored SVG previews are each pack\'s idle art with the disc off', () => {
  for (const set of ['pocket-curios', 'bitty-bots', 'thanksgiving', 'christmas']) {
    execFileSync('python3', ['scripts/preview-svg.py', set, '--check']);
  }
});
