import test from 'node:test';
import assert from 'node:assert/strict';
import { Resvg } from '@resvg/resvg-js';
import { validateSVG, validateSets, renderPNG } from '../scripts/assets.mjs';

test('raster previews preserve overflow-visible art instead of cutting off the top', () => {
  const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 44" overflow="visible"><path d="M20 -3 L38 36 L2 36 Z" fill="#123456"/></svg>';
  const png = renderPNG(svg);
  const pixels = new Resvg(`<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512"><image width="512" height="512" href="data:image/png;base64,${png.toString('base64')}"/></svg>`).render().pixels;
  assert.equal([...pixels.subarray(0, 512 * 4)].filter((_, i) => i % 4 === 3).some(alpha => alpha !== 0), false);
});

const circle = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><circle cx="50" cy="50" r="30" fill="#123456"/></svg>';
test('accepts bounded static SVG and produces a real square PNG', () => {
  assert.doesNotThrow(() => validateSVG(circle));
  const png = renderPNG(circle);
  assert.equal(png.subarray(1, 4).toString(), 'PNG');
  assert.equal(png.readUInt32BE(16), 512);
  assert.equal(png.readUInt32BE(20), 512);
});
test('rejects active content, remote resources, and malformed or oversized SVG', () => {
  for (const unsafe of [circle.replace('<circle', '<script/><circle'), circle.replace('<circle', '<image href="https://example.com/x"/><circle'), circle.replace('<circle', '<circle onload="alert(1)"'), '<!DOCTYPE svg>'+circle, circle.replace('fill="#123456"', 'fill="url(https://example.com/a)"'), '<svg><path></svg>', 'x'.repeat(512001)]) {
    assert.throws(() => validateSVG(unsafe));
  }
});
test('accepts local clipping paths without allowing external paint resources', () => {
  assert.doesNotThrow(() => validateSVG('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><defs><clipPath id="crop"><rect width="80" height="80"/></clipPath></defs><g clip-path="url(#crop)"><circle cx="50" cy="50" r="40"/></g></svg>'));
});
test('accepts the official bighelp category', () => {
  assert.doesNotThrow(() => validateSets([{ id: 'bighelp', name: 'bighelp', category: 'bighelp', startsAt: null, expiresAt: null }]));
});
test('set dates require explicit offsets and valid windows', () => {
  const valid = { id: 'halloween', name: 'Halloween', category: 'seasonal', startsAt: null, expiresAt: '2026-11-03T00:00:00-06:00' };
  assert.doesNotThrow(() => validateSets([valid]));
  for (const expiresAt of ['2026-11-03', '2026-11-03T00:00:00', 'garbage', '2026-02-30T00:00:00Z']) assert.throws(() => validateSets([{ ...valid, expiresAt }]));
  assert.throws(() => validateSets([valid, valid]));
  assert.throws(() => validateSets([{ ...valid, startsAt: '2026-12-01T00:00:00Z' }]));
  assert.throws(() => validateSets([{ ...valid, id: '../../outside' }]));
});
