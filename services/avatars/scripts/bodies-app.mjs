// Writes the Bot Studio bodies feed to the app's bundled copy: Bighelp/Resources/BotBodies.json.
// Run `npm run bodies:app` from services/avatars; the app owner commits the result.
import { writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { loadBodies } from './bodies.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const target = fileURLToPath(new URL('../../../Bighelp/Resources/BotBodies.json', import.meta.url));
const bodies = await loadBodies(`${root}sources/bodies`);
await writeFile(target, JSON.stringify(bodies, null, 1) + '\n');
console.log(`Wrote ${bodies.bodies.length} bodies in ${bodies.sets.length} sets to ${target}`);
