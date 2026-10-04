import { readFile, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { validateSets } from './assets.mjs';

export function updateExpiry(config, id, date) {
  const set = config.sets.find(s => s.id === id);
  if (!set) throw new Error(`Unknown set: ${id}`);
  const expiresAt = date === 'none' ? null : date;
  validateSets(config.sets.map(s => s === set ? { ...s, expiresAt } : s));
  set.expiresAt = expiresAt;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [id, date] = process.argv.slice(2);
  if (!id || !date || process.argv.length !== 4) throw new Error('Usage: node scripts/set-expiry.mjs <set-id> <ISO-offset-timestamp|none>');
  const file = new URL('../sets.json', import.meta.url);
  const config = JSON.parse(await readFile(file, 'utf8'));
  updateExpiry(config, id, date);
  await writeFile(file, JSON.stringify(config, null, 2) + '\n');
  console.log(`Updated ${id}. Run npm test, npm run build, then deploy to publish the change.`);
}
