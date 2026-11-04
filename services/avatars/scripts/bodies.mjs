// Bot Studio bodies (v2): validates sources/bodies/*.json (format: docs/BOT_BODIES.md) and builds the
// /v2/bodies.json feed. Pure functions; the build and `bodies:app` scripts do the file writing.
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';

const DAY = 86_400_000;
const maxBytes = 512 * 1024;
const maxBodiesPerSet = 60;
const idPattern = /^[a-z0-9][a-z0-9-]{0,63}$/;
const slugPattern = /^[a-z0-9-]+$/;
const categories = ['shapes', 'hermes', 'bighelp', 'seasonal'];
const tones = ['main', 'accent', 'shade', 'light', 'ink'];
const hex = /^#[0-9A-Fa-f]{6}$/;
const emberCoral = '#FF8A7A';
const datePattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$/;
// Sets the app lists first, in this order. Seasonal sets follow by date, then unknown sets by id.
const setOrder = ['shapes', 'hermes', 'bighelp', 'classics', 'bits', 'pocket-curios', 'bitty-bots'];
// Numbers each path command takes per group.
const argCounts = { m: 2, l: 2, h: 1, v: 1, c: 6, q: 4, a: 7, z: 0 };

class BodyError extends Error {}
const fail = (where, message) => { throw new BodyError(`${where}: ${message}`); };

function exactKeys(value, where, required, optional = []) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) fail(where, 'expected an object');
  for (const key of required) if (!(key in value)) fail(where, `missing "${key}"`);
  for (const key of Object.keys(value)) if (!required.includes(key) && !optional.includes(key)) fail(where, `unknown key "${key}"`);
}
const isNumber = (v) => typeof v === 'number' && Number.isFinite(v);
function inRange(v, min, max, where, label) {
  if (!isNumber(v) || v < min || v > max) fail(where, `${label} must be a number from ${min} to ${max}`);
}
function text(v, where, label, max) {
  if (typeof v !== 'string' || !v.trim() || v.length > max) fail(where, `${label} must be text of 1 to ${max} characters`);
}
function date(v, where, label) {
  if (v === null) return;
  if (typeof v !== 'string' || !datePattern.test(v) || !Number.isFinite(Date.parse(v))) fail(where, `${label} must be an ISO 8601 date with an offset, or null`);
  // Date.parse rolls impossible dates such as February 30 over.
  const [year, month, day] = v.slice(0, 10).split('-').map(Number);
  if (day < 1 || day > new Date(Date.UTC(year, month, 0)).getUTCDate()) fail(where, `${label} is not a real calendar date`);
}

// Only M L H V C Q A Z, plain decimal numbers, and the right number of numbers for each command.
function validatePath(d, where) {
  if (typeof d !== 'string' || !d || d.length > 4000) fail(where, 'd must be text of 1 to 4000 characters');
  const token = /[A-Za-z]|-?(?:\d+\.?\d*|\.\d+)/y;
  const separators = /[\s,]*/y;
  let offset = 0, command = null, count = 0, first = true;
  const closeGroup = () => {
    if (command === null) return;
    const need = argCounts[command.toLowerCase()];
    if (need === 0 ? count !== 0 : count === 0 || count % need !== 0) fail(where, `command ${command} has the wrong number of values`);
  };
  while (true) {
    separators.lastIndex = offset;
    separators.exec(d);
    offset = separators.lastIndex;
    if (offset >= d.length) break;
    token.lastIndex = offset;
    const match = token.exec(d);
    if (!match) fail(where, `d has something other than commands and plain numbers near "${d.slice(offset, offset + 8)}"`);
    offset = token.lastIndex;
    const value = match[0];
    if (/[A-Za-z]/.test(value)) {
      if (!(value.toLowerCase() in argCounts)) fail(where, `d uses command ${value}; only M L H V C Q A Z are allowed`);
      if (first && value.toLowerCase() !== 'm') fail(where, 'd must start with M');
      closeGroup();
      command = value; count = 0;
    } else {
      if (command === null) fail(where, 'd must start with M');
      if (!Number.isFinite(Number(value))) fail(where, `d has a number that is not finite: ${value}`);
      if (command.toLowerCase() === 'a' && [3, 4].includes(count % 7) && value !== '0' && value !== '1') fail(where, 'arc flags must be 0 or 1');
      count++;
    }
    first = false;
  }
  closeGroup();
  if (command === null) fail(where, 'd has no commands');
}

function validatePart(part, where) {
  exactKeys(part, where, ['d', 'tone'], ['stroke', 'round']);
  validatePath(part.d, `${where}.d`);
  if (!tones.includes(part.tone)) fail(where, `tone must be one of ${tones.join(', ')}`);
  if ('stroke' in part && 'round' in part) fail(where, 'use at most one of stroke and round');
  for (const key of ['stroke', 'round']) if (key in part) inRange(part[key], 0, 24, where, key);
}

function validateBody(body, setId, where) {
  exactKeys(body, where, ['id', 'name', 'parts', 'eyes', 'eyeTilt', 'rotation', 'colors'], ['role']);
  const prefix = `${setId}.`;
  if (typeof body.id !== 'string' || !body.id.startsWith(prefix) || !slugPattern.test(body.id.slice(prefix.length))) fail(where, `id must be "${setId}.<slug>" with a slug of a-z, 0-9 and -`);
  text(body.name, where, 'name', 80);
  if ('role' in body) text(body.role, where, 'role', 160);
  if (!Array.isArray(body.parts) || body.parts.length < 1 || body.parts.length > 12) fail(where, 'parts must be a list of 1 to 12');
  body.parts.forEach((part, i) => validatePart(part, `${where}.parts[${i}]`));
  if (!Array.isArray(body.eyes) || body.eyes.length !== 2) fail(where, 'eyes must be exactly two [x, y, height] lists');
  body.eyes.forEach((eye, i) => {
    if (!Array.isArray(eye) || eye.length !== 3) fail(where, `eyes[${i}] must be [x, y, height]`);
    inRange(eye[0], 0, 100, where, `eyes[${i}] x`);
    inRange(eye[1], 0, 100, where, `eyes[${i}] y`);
    inRange(eye[2], 6, 20, where, `eyes[${i}] height`);
  });
  inRange(body.eyeTilt, -45, 45, where, 'eyeTilt');
  inRange(body.rotation, -45, 45, where, 'rotation');
  exactKeys(body.colors, `${where}.colors`, ['main'], ['accent']);
  for (const key of Object.keys(body.colors)) if (typeof body.colors[key] !== 'string' || !hex.test(body.colors[key])) fail(where, `colors.${key} must be #RRGGBB`);
  if (body.colors.main.toUpperCase() === emberCoral) fail(where, `colors.main must not be the brand coral ${emberCoral}`);
}

// Checks one source file's contents; `file` is the file name, which must match the set id.
function validateSource(file, source) {
  const where = file;
  exactKeys(source, where, ['set', 'bodies']);
  const { set } = source;
  exactKeys(set, `${where} set`, ['id', 'name', 'category', 'startsAt', 'expiresAt']);
  if (typeof set.id !== 'string' || !idPattern.test(set.id)) fail(`${where} set`, 'id must be lowercase letters, digits and -');
  if (file !== `${set.id}.json`) fail(where, `file name must be ${set.id}.json to match the set id`);
  text(set.name, `${where} set`, 'name', 80);
  if (!categories.includes(set.category)) fail(`${where} set`, `category must be one of ${categories.join(', ')}`);
  date(set.startsAt, `${where} set`, 'startsAt');
  date(set.expiresAt, `${where} set`, 'expiresAt');
  if (set.startsAt && set.expiresAt && Date.parse(set.startsAt) >= Date.parse(set.expiresAt)) fail(`${where} set`, 'expiresAt must be after startsAt');
  if (!Array.isArray(source.bodies) || source.bodies.length < 1) fail(where, 'bodies must be a list with at least one body');
  if (source.bodies.length > maxBodiesPerSet) fail(where, `a set can hold at most ${maxBodiesPerSet} bodies`);
  source.bodies.forEach((body, i) => validateBody(body, set.id, `${where} bodies[${i}]${typeof body?.id === 'string' ? ` (${body.id})` : ''}`));
}

// Fixed key order, so the output only changes when a source does.
function canonicalPart(part) {
  return { d: part.d, tone: part.tone, ...('stroke' in part ? { stroke: part.stroke } : {}), ...('round' in part ? { round: part.round } : {}) };
}
function canonicalBody(body, setId) {
  return {
    id: body.id, name: body.name, ...('role' in body ? { role: body.role } : {}),
    parts: body.parts.map(canonicalPart), eyes: body.eyes.map(eye => [...eye]), eyeTilt: body.eyeTilt, rotation: body.rotation,
    colors: { main: body.colors.main, ...('accent' in body.colors ? { accent: body.colors.accent } : {}) }, set: setId,
  };
}

function compareSets(a, b) {
  const rank = (s) => { const i = setOrder.indexOf(s.id); return i >= 0 ? i : s.category === 'seasonal' ? setOrder.length : setOrder.length + 1; };
  if (rank(a) !== rank(b)) return rank(a) - rank(b);
  if (rank(a) === setOrder.length) {
    const start = (s) => s.startsAt ? Date.parse(s.startsAt) : -Infinity;
    const end = (s) => s.expiresAt ? Date.parse(s.expiresAt) : Infinity;
    if (start(a) !== start(b)) return start(a) < start(b) ? -1 : 1;
    if (end(a) !== end(b)) return end(a) < end(b) ? -1 : 1;
  }
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

/**
 * Builds the v2 feed from `[{ file, data }]` (file name and parsed JSON of each source). Throws a BodyError with
 * the file and the rule that failed. A set that expired more than 30 days before `now` is left out; the other
 * seasonal sets stay with their dates because the app filters by them.
 */
export function buildBodies(files, now = Date.now()) {
  const ids = new Set(), sets = [];
  for (const { file, data } of files) {
    validateSource(file, data);
    for (const body of data.bodies) {
      if (ids.has(body.id)) fail(file, `duplicate body id ${body.id}`);
      ids.add(body.id);
    }
    sets.push(data);
  }
  const kept = sets.filter(({ set }) => !(set.expiresAt && now - Date.parse(set.expiresAt) > 30 * DAY));
  kept.sort((a, b) => compareSets(a.set, b.set));
  const feed = {
    schemaVersion: 2,
    sets: kept.map(({ set }) => ({ id: set.id, name: set.name, category: set.category, startsAt: set.startsAt, expiresAt: set.expiresAt })),
    bodies: kept.flatMap(({ set, bodies }) => bodies.map(body => canonicalBody(body, set.id))),
  };
  const bytes = Buffer.byteLength(JSON.stringify(feed));
  if (bytes > maxBytes) fail('bodies', `output is ${bytes} bytes; the limit is ${maxBytes}`);
  return feed;
}

/** Reads every `*.json` in `folder` (sorted by name) and builds the feed. */
export async function loadBodies(folder, now = Date.now()) {
  const names = (await readdir(folder)).filter(name => name.endsWith('.json')).sort();
  const files = [];
  for (const file of names) {
    let data;
    try { data = JSON.parse(await readFile(path.join(folder, file), 'utf8')); }
    catch (error) { throw new BodyError(`${file}: not valid JSON (${error.message})`); }
    files.push({ file, data });
  }
  return buildBodies(files, now);
}
