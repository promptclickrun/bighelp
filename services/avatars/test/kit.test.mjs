import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { convertCharacter } from '../scripts/kit.mjs';
const visit = (node) => [node, ...(node.k ?? []).flatMap(visit)];

test('native kit geometry has editable palette tokens and 200-unit normalization', () => {
  const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><g fill="#123456"><circle cx="50" cy="50" r="30"/></g><rect x="40" y="40" width="4" height="10" rx="2" fill="#000000" transform="rotate(-8 42 45)"/></svg>';
  const c = convertCharacter(svg, { id: 'test', name: 'Test' }, { p: '#123456', ink: '#000000' });
  assert.equal(c.colors.p, '#123456');
  const nodes = visit(c.tree);
  assert.ok(nodes.some(n => n.st.idle.f === '@p'));
  assert.ok(nodes.some(n => n.st.idle.f === '@ink'));
  assert.ok(nodes.some(n => n.m?.[0] === 2 && n.m?.[3] === 2));
  assert.ok(nodes.some(n => n.t === 'rect' && n.m?.length === 6));
  assert.ok(nodes.some(n => n.rig && n.body));
});

test('Candy Corn clips become actual paths, not unsupported native clip nodes', async () => {
  const svg = await readFile(new URL('../sources/halloween/halloween-candy-corn.svg', import.meta.url), 'utf8');
  const c = convertCharacter(svg, { id: 'halloween-candy-corn', name: 'Candy Corn' }, { p: '#F28C3C', s: '#F6F1E6', a: '#F6C945', ink: '#1A0F12' });
  const paths = visit(c.tree).filter(n => n.t === 'path');
  assert.equal(paths.length, 3);
  assert.deepEqual(paths.map(n => n.st.idle.f), ['@s', '@p', '@a']);
  assert.ok(visit(c.tree).every(n => !['defs', 'clipPath'].includes(n.t)));
  assert.ok(paths.every(n => n.d && !n.d.includes('NaN')));
});
