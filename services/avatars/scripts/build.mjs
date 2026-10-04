import { readFile, writeFile, mkdir, copyFile, access } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { convertCharacter } from './kit.mjs';
import { validateSets, validateSVG, renderPNG, idPattern } from './assets.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const base = 'https://avatars.bighelp.app';
const { schemaVersion, sets } = JSON.parse(await readFile(path.join(root, 'sets.json'), 'utf8'));
if (schemaVersion !== 1) throw new Error('Unsupported source schema');
validateSets(sets);
const avatars = [], ids = new Set(), characters = [];
const palettes = JSON.parse(await readFile(path.join(root, 'sources/palettes.json'), 'utf8'));
const kitSettings = JSON.parse(await readFile(path.join(root, 'sources/kit-settings.json'), 'utf8'));
const staticKitSettings = structuredClone(kitSettings);
const authored = new Map();
for (const [setId, file] of [['bighelp', 'helpers'], ['halloween', 'halloween']]) {
  const pack = JSON.parse(await readFile(path.join(root, `sources/packs/${file}.json`), 'utf8'));
  if (pack.version !== 1 || pack.characters.length !== 10) throw new Error('Invalid authored pack');
  for (const key of ['version', 'states', 'themes', 'keyframes']) {
    if (file === 'helpers') kitSettings[key] = pack[key];
    else if (JSON.stringify(kitSettings[key]) !== JSON.stringify(pack[key])) throw new Error(`Conflicting pack ${key}`);
  }
  for (const character of pack.characters) {
    if (authored.has(character.id)) throw new Error('Duplicate authored ID');
    authored.set(character.id, { setId, character });
  }
}
await mkdir(path.join(root, 'public/assets'), { recursive: true });
async function asset(bytes, extension) {
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const file = path.join(root, `public/assets/${sha256}.${extension}`);
  // Content addresses are immutable. Never remove earlier revisions on rebuild.
  try {
    await access(file);
    if (!(await readFile(file)).equals(Buffer.from(bytes))) throw new Error('Immutable asset collision');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    await writeFile(file, bytes);
  }
  return { url: `${base}/assets/${sha256}.${extension}`, sha256, bytes: Buffer.byteLength(bytes), contentType: extension === 'svg' ? 'image/svg+xml' : extension === 'png' ? 'image/png' : 'application/json' };
}
for (const set of sets) {
  const folder = path.join(root, 'sources', set.id);
  const entries = JSON.parse(await readFile(path.join(folder, 'index.json'), 'utf8'));
  if (!Array.isArray(entries) || !entries.length) throw new Error(`Empty set ${set.id}`);
  for (const entry of entries) {
    if (!idPattern.test(entry.id) || ids.has(entry.id) || typeof entry.name !== 'string' || !entry.name.trim() || entry.name.length > 80 || !/^[a-z0-9-]+\.svg$/.test(entry.file)) throw new Error('Invalid avatar metadata');
    if (entry.role !== undefined && (typeof entry.role !== 'string' || entry.role.length > 160)) throw new Error('Invalid avatar role');
    ids.add(entry.id);
    if (ids.size > 1000) throw new Error('Catalog limit exceeded');
    if (entry.nativeLook && !['face', 'shape'].includes(entry.nativeLook.style)) throw new Error('Unknown native look');
    const svg = await readFile(path.join(folder, entry.file), 'utf8');
    validateSVG(svg);
    const png = renderPNG(svg);
    if (!palettes[entry.id]?.p) throw new Error(`Missing primary palette: ${entry.id}`);
    const supplied = authored.get(entry.id);
    if (['bighelp', 'halloween'].includes(set.id) && supplied?.setId !== set.id) throw new Error(`Missing authored character ${entry.id}`);
    const character = supplied?.character ?? convertCharacter(svg, entry, palettes[entry.id]);
    characters.push(character);
    const kit = await asset(JSON.stringify({ ...(supplied ? kitSettings : staticKitSettings), characters: [character] }), 'json');
    avatars.push({ id: entry.id, name: entry.name, setId: set.id, category: set.category,
      startsAt: set.startsAt, expiresAt: set.expiresAt,
      ...(entry.role ? { role: entry.role } : {}),
      ...(entry.nativeLook ? { nativeLook: entry.nativeLook } : {}),
      kit,
      svg: await asset(svg, 'svg'), png: { ...await asset(png, 'png'), width: 512, height: 512 },
    });
  }
}
const catalog = { schemaVersion: 1, avatarKitURL: `${base}/v1/avatar-kit.json`, kit: { ...kitSettings, characters }, categories: [{ id: 'bighelp', name: 'bighelp', isFirstParty: true }, { id: 'faces', name: 'Faces' }, { id: 'shapes', name: 'Shapes' }, { id: 'seasonal', name: 'Seasonal' }], sets, avatars };
await writeFile(path.join(root, 'catalog.json'), JSON.stringify(catalog, null, 2) + '\n');
await copyFile(path.join(root, 'NOTICES.txt'), path.join(root, 'public/NOTICES.txt'));
console.log(JSON.stringify({ avatars: avatars.length, sets: sets.map(s => ({ id: s.id, count: avatars.filter(a => a.setId === s.id).length, expiresAt: s.expiresAt })) }));
