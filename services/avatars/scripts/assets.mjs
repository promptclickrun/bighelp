import { XMLParser, XMLValidator } from 'fast-xml-parser';
import { Resvg } from '@resvg/resvg-js';

export const idPattern = /^[a-z0-9][a-z0-9-]{0,63}$/;
export function validateSets(sets) {
  if (!Array.isArray(sets) || sets.length > 100) throw new Error('Expected at most 100 sets');
  const seen = new Set();
  for (const s of sets) {
    if (!idPattern.test(s.id) || seen.has(s.id)) throw new Error('Invalid or duplicate set ID');
    seen.add(s.id);
    if (typeof s.name !== 'string' || !s.name.trim() || s.name.length > 80 || !['bighelp', 'faces', 'shapes', 'seasonal'].includes(s.category)) throw new Error('Invalid set metadata');
    for (const date of [s.startsAt, s.expiresAt]) {
      if (date === null) continue;
      if (typeof date !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$/.test(date) || !Number.isFinite(Date.parse(date))) throw new Error('Dates need an explicit UTC offset, or null');
      // Date.parse normalizes impossible dates such as February 30.
      const [year, month, day] = date.slice(0, 10).split('-').map(Number);
      if (day < 1 || day > new Date(Date.UTC(year, month, 0)).getUTCDate()) throw new Error('Invalid calendar date');
    }
    if (s.startsAt && s.expiresAt && Date.parse(s.startsAt) >= Date.parse(s.expiresAt)) throw new Error('Expiry must follow start');
  }
}

const tags = new Set(['svg', 'defs', 'clipPath', 'g', 'path', 'circle', 'ellipse', 'rect', 'line', 'polygon', 'polyline']);
const attributes = new Set(['id', 'clip-path', 'xmlns', 'viewBox', 'width', 'height', 'preserveAspectRatio', 'overflow', 'role', 'aria-label', 'fill', 'stroke', 'stroke-width', 'stroke-linecap', 'stroke-linejoin', 'stroke-miterlimit', 'stroke-dasharray', 'stroke-dashoffset', 'opacity', 'fill-opacity', 'stroke-opacity', 'fill-rule', 'clip-rule', 'd', 'cx', 'cy', 'r', 'rx', 'ry', 'x', 'y', 'x1', 'y1', 'x2', 'y2', 'points', 'transform']);
export function validateSVG(svg) {
  if (Buffer.byteLength(svg) > 512000 || /<!|<\?/.test(svg) || XMLValidator.validate(svg) !== true) throw new Error('Malformed or oversized SVG');
  const nodes = new XMLParser({ preserveOrder: true, ignoreAttributes: false, processEntities: false, parseAttributeValue: false }).parse(svg);
  if (nodes.length !== 1 || !nodes[0].svg) throw new Error('Expected one SVG root');
  let count = 0;
  function walk(list, depth = 0) {
    if (depth > 24) throw new Error('SVG nesting too deep');
    for (const node of list) {
      if (++count > 10000) throw new Error('Too many SVG nodes');
      for (const [key, value] of Object.entries(node)) {
        if (key === ':@') {
          for (const [attribute, text] of Object.entries(value)) {
            const name = attribute.slice(2);
            if (name === 'clip-path') {
              if (!/^url\(#[a-zA-Z][a-zA-Z0-9_-]*\)$/.test(String(text))) throw new Error('Only local clipping paths are supported');
            } else if (!attributes.has(name) || /url\s*\(|[&<>]/i.test(String(text))) throw new Error(`Unsupported SVG attribute: ${name}`);
            if (name === 'id' && !/^[a-zA-Z][a-zA-Z0-9_-]*$/.test(String(text))) throw new Error('Invalid SVG ID');
            if (name === 'xmlns' && text !== 'http://www.w3.org/2000/svg') throw new Error('Invalid SVG namespace');
          }
        } else if (key === '#text' && !String(value).trim()) {
          continue;
        } else {
          if (!tags.has(key) || !Array.isArray(value)) throw new Error(`Unsupported SVG element: ${key}`);
          walk(value, depth + 1);
        }
      }
    }
  }
  walk(nodes);
  const viewBox = nodes[0][':@']?.['@_viewBox'];
  const dimensions = String(viewBox).trim().split(/[\s,]+/).map(Number);
  if (dimensions.length !== 4 || dimensions.some(n => !Number.isFinite(n) || Math.abs(n) > 100000) || dimensions[2] <= 0 || dimensions[3] <= 0) throw new Error('A bounded viewBox is required');
}

export function renderPNG(svg) {
  validateSVG(svg);
  // Native Shapes allow drawing beyond their nominal box (the triangle's apex).
  // Keep the source SVG unchanged, but expand the raster viewport to retain that art.
  if (/<svg\b[^>]*\boverflow=["']visible["']/.test(svg)) {
    const root = new XMLParser({ ignoreAttributes: false }).parse(svg).svg;
    const [x, y, w, h] = root['@_viewBox'].trim().split(/[\s,]+/).map(Number);
    const normalized = svg.replace(/<svg\b[^>]*>/, tag => tag.replace(/\s(?:width|height)\s*=\s*(?:"[^"]*"|'[^']*')/g, '').replace(/>$/, ` width="${w}" height="${h}">`));
    const box = new Resvg(normalized, { font: { loadSystemFonts: false } }).getBBox();
    if (box && (box.x < 0 || box.y < 0 || box.x + box.width > w || box.y + box.height > h)) {
      const left = Math.min(0, box.x) - 1, top = Math.min(0, box.y) - 1;
      const right = Math.max(w, box.x + box.width) + 1, bottom = Math.max(h, box.y + box.height) + 1;
      svg = svg.replace(/viewBox\s*=\s*(?:"[^"]*"|'[^']*')/, `viewBox="${x + left} ${y + top} ${right - left} ${bottom - top}"`);
    }
  }
  const square = svg.replace(/<svg\b[^>]*>/, root => root.replace(/\s(?:width|height)\s*=\s*(?:"[^"]*"|'[^']*')/g, '').replace(/>$/, ' width="512" height="512">'));
  return Buffer.from(new Resvg(square, { font: { loadSystemFonts: false } }).render().asPng());
}
