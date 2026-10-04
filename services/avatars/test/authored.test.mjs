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
      if (file === 'pocket-curios') assert.equal(entry.role, character.role);
    }
  }
  assert.equal(catalog.avatars.length, 58);
  assert.deepEqual(catalog.sets.find(s => s.id === 'pocket-curios'), {
    id: 'pocket-curios', name: 'Pocket Curios', category: 'bighelp', startsAt: null, expiresAt: null,
  });
  assert.equal(catalog.sets.find(s => s.id === 'halloween').expiresAt, '2026-11-03T00:00:00-06:00');
});
