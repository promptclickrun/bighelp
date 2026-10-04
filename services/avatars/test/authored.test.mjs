import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';

test('publishes authored packs unchanged with their animation settings', async () => {
  execFileSync(process.execPath, ['scripts/build.mjs']);
  const catalog = JSON.parse(await readFile('catalog.json'));
  for (const file of ['helpers', 'halloween']) {
    const pack = JSON.parse(await readFile(`sources/packs/${file}.json`));
    for (const key of ['version', 'states', 'themes', 'keyframes']) assert.deepEqual(catalog.kit[key], pack[key]);
    for (const character of pack.characters) {
      assert.deepEqual(catalog.kit.characters.find(c => c.id === character.id), character);
      const entry = catalog.avatars.find(a => a.id === character.id);
      const individual = JSON.parse(await readFile(`public/assets/${entry.kit.url.split('/').pop()}`));
      assert.deepEqual(individual.characters, [character]);
      assert.deepEqual(individual.keyframes, pack.keyframes);
      assert.equal(entry.category, file === 'helpers' ? 'bighelp' : 'seasonal');
    }
  }
  assert.equal(catalog.avatars.length, 38);
});
