// Browser contract tests with explicitly synthetic API fixtures. Live Access/D1 verification is separate.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const origin = 'https://reviewer.example.test';
const assets = fileURLToPath(new URL('../reviewer/', import.meta.url));
const csp = "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'";
let browser;
before(async () => { browser = await chromium.launch({ headless: true }); });
after(async () => { await browser?.close(); });

function sample(index = 0) {
  return { id: `sample-${String(index).padStart(4, '0')}`, version: 1, kind: 'blueprint',
    status: index === 0 ? 'pending' : 'approved', source: 'community', title: `Sample template ${index}`,
    board: 'feed', category: 'research', text: `Sample template ${index}: find one useful development and explain it clearly.`,
    credit: 'Sample author', submitterName: 'Sample author', submitterUsername: 'sample-author',
    submitterEmail: 'author@example.test', submitterGithubId: null, createdAt: '2026-01-01T12:00:00Z',
    updatedAt: '2026-01-01T12:00:00Z', reviewedAt: null, reviewedBy: null, reviewNote: null };
}
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };

async function fixture({ count = 3, holdPatch } = {}) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const rows = new Map(Array.from({ length: count }, (_, i) => { const row = sample(i); return [row.id, row]; }));
  const calls = [], pageErrors = [];
  let expired = false, nextId = 0;
  const page = await context.newPage();
  page.on('pageerror', e => pageErrors.push(e.message));
  await context.route(`${origin}/**`, async route => {
    const req = route.request(), url = new URL(req.url()), path = url.pathname, method = req.method();
    const json = (value, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(value), headers: { 'Cache-Control': 'no-store' } });
    if (!path.startsWith('/review/')) {
      const file = path === '/' ? 'index.html' : path.slice(1);
      if (!['index.html', 'app.js', 'style.css'].includes(file)) return json({ error: 'Not found.' }, 404);
      return route.fulfill({ status: 200, body: await readFile(`${assets}/${file}`), contentType: file.endsWith('.js') ? 'text/javascript' : file.endsWith('.css') ? 'text/css' : 'text/html', headers: { 'Content-Security-Policy': csp } });
    }
    if (expired) return json({ error: 'Reviewers only.' }, 401);
    if (path === '/review/session') return json({ reviewer: 'reviewer@example.test' });
    const [, , , id, action] = path.split('/');
    const body = req.postDataJSON();
    calls.push({ path, method, body, headers: req.headers() });
    if (method !== 'GET') assert.equal(req.headers()['x-catalog-review'], '1');
    if (!id && method === 'GET') {
      const offset = Number(url.searchParams.get('offset') || 0), limit = Number(url.searchParams.get('limit') || 100);
      const all = [...rows.values()];
      return json({ templates: all.slice(offset, offset + limit), total: all.length, nextOffset: offset + limit < all.length ? offset + limit : null });
    }
    if (!id && method === 'POST') {
      const row = { ...sample(1), ...body, id: body.id || `created-${++nextId}`, version: 1, status: 'approved', source: 'bighelp', credit: body.creditName || null };
      row.title = row.kind === 'agent' ? row.name : row.text.slice(0, 80);
      rows.set(row.id, row); return json(row, 201);
    }
    if (method === 'PATCH' && holdPatch) { holdPatch.started.resolve(); await holdPatch.release.promise; }
    const row = rows.get(id);
    if (!row) return json({ error: 'No template with that id.' }, 404);
    if (method === 'GET') return json(row);
    if (req.headers()['if-match'] !== `"v${row.version}"`) return json({ error: 'This template changed elsewhere. Reload it before trying again.' }, 409);
    if (method === 'DELETE') { rows.delete(id); return json({ id, deleted: true }); }
    if (method === 'PATCH') Object.assign(row, body, { credit: body.creditName ?? null });
    else if (action === 'unpublish') row.status = 'pending';
    else if (action === 'approve') row.status = 'approved';
    else if (action === 'reject') { row.status = 'rejected'; row.reviewNote = body.note; }
    else return json({ error: 'Not found.' }, 404);
    row.version += 1;
    return json(row);
  });
  await page.goto(`${origin}/#all`);
  await page.waitForFunction(() => !document.querySelector('#list-status').textContent.includes('Loading') && document.querySelector('#list-status').textContent.trim() !== '');
  return { page, rows, calls, pageErrors, expire: value => { expired = value; }, close: () => context.close() };
}

async function openRow(page, id) {
  await page.locator('#search').fill(id);
  await page.locator('#rows tr button').click();
}
async function editFirst(page) {
  await openRow(page, 'sample-0000');
  await page.getByRole('tab', { name: 'Edit', exact: true }).click();
}

test('loads every catalog page and renders a mobile-scrolling table without document overflow', async () => {
  const f = await fixture({ count: 501 });
  try {
    assert.equal(await f.page.locator('#rows tr').count(), 501);
    assert.equal(f.calls.filter(c => c.method === 'GET').length, 3);
    assert.equal(await f.page.locator('#count-all').textContent(), '501');
    for (const [name, width, height] of [['desktop', 1440, 1000], ['mobile', 390, 844]]) {
      await f.page.setViewportSize({ width, height });
      if (process.env.BIGREVIEW_QA_SCREENSHOT_DIR) {
        await mkdir(process.env.BIGREVIEW_QA_SCREENSHOT_DIR, { recursive: true });
        await f.page.screenshot({ path: `${process.env.BIGREVIEW_QA_SCREENSHOT_DIR}/reviewer-fixture-${name}.png` });
      }
      const actual = await f.page.evaluate(() => document.documentElement.scrollWidth);
      assert.equal(actual, width);
    }
    assert.deepEqual(f.pageErrors, []);
  } finally { await f.close(); }
});

test('a save works on the first click directly from an edited field', async () => {
  const f = await fixture();
  try {
    await editFirst(f.page);
    await f.page.locator('#f-text').fill('Save this changed template on the first click without requiring a second click.');
    await Promise.all([
      f.page.waitForResponse(r => r.request().method() === 'PATCH', { timeout: 3000 }),
      f.page.locator('#editor-actions').getByRole('button', { name: 'Save changes', exact: true }).click(),
    ]);
    assert.equal(f.rows.get('sample-0000').version, 2);
  } finally { await f.close(); }
});

test('freezes the owned draft while a save is in flight', async () => {
  const holdPatch = { started: deferred(), release: deferred() }, f = await fixture({ holdPatch });
  try {
    await editFirst(f.page);
    await f.page.locator('#f-text').fill('This draft must survive an in-flight save without accepting an accidental newer edit.');
    await f.page.locator('#f-text').press('Tab');
    await f.page.locator('#editor-actions').getByRole('button', { name: 'Save changes', exact: true }).click();
    await Promise.race([holdPatch.started.promise, new Promise((_, reject) => setTimeout(() => reject(new Error('Save did not reach the API')), 3000))]);
    assert.equal(await f.page.locator('#f-text').isDisabled(), true);
    assert.equal(await f.page.locator('#editor-close').isDisabled(), true);
    holdPatch.release.resolve();
    await f.page.waitForFunction(() => !document.querySelector('#editor-close').disabled);
    assert.match(f.rows.get('sample-0000').text, /^This draft must survive/);
    assert.deepEqual(f.pageErrors, []);
  } finally { holdPatch.release.resolve(); await f.close(); }
});

test('keeps a conflicting draft and an expired-session draft instead of silently overwriting them', async () => {
  const f = await fixture();
  try {
    await editFirst(f.page);
    const draft = 'Keep this unsaved draft intact when another reviewer changes the template.';
    await f.page.locator('#f-text').fill(draft);
    f.rows.get('sample-0000').version += 1;
    await f.page.locator('#editor-actions').getByRole('button', { name: 'Save changes', exact: true }).click();
    await f.page.locator('#editor-error').getByRole('button', { name: 'Load latest (discards your edits)', exact: true }).waitFor();
    assert.equal(await f.page.locator('#f-text').inputValue(), draft);
    f.expire(true);
    await f.page.locator('#editor-actions').getByRole('button', { name: 'Save changes', exact: true }).click();
    await f.page.waitForFunction(() => !document.querySelector('#auth-banner').hidden);
    assert.equal(await f.page.locator('#f-text').inputValue(), draft);
    assert.equal(f.rows.get('sample-0000').version, 2);
  } finally { await f.close(); }
});

test('creates, unpublishes, rejects, approves and deletes through real controls and typed confirmation', async () => {
  const f = await fixture();
  try {
    await f.page.locator('#new-template').click();
    await f.page.locator('#f-kind').selectOption('blueprint');
    await f.page.locator('#f-text').fill('A fixture-only blueprint used to verify the complete management controls.');
    await f.page.locator('#editor-actions').getByRole('button', { name: 'Publish template', exact: true }).click();
    await f.page.waitForFunction(() => !document.querySelector('#editor').open);
    assert.equal(f.rows.get('created-1').status, 'approved');
    for (const [action, expected] of [['Unpublish', 'pending'], ['Reject with reason', 'rejected'], ['Approve & publish', 'approved']]) {
      await openRow(f.page, 'created-1');
      await f.page.locator('#editor-actions').getByRole('button', { name: action, exact: true }).click();
      if (expected === 'rejected') await f.page.locator('#prompt-note').fill('Fixture-only rejection reason.');
      await f.page.locator('#prompt-confirm').click();
      await f.page.waitForFunction(() => !document.querySelector('#editor').open);
      assert.equal(f.rows.get('created-1').status, expected);
    }
    await openRow(f.page, 'created-1');
    await f.page.locator('#editor-actions').getByRole('button', { name: 'Delete', exact: true }).click();
    await f.page.locator('#prompt-confirm').click();
    assert.equal(f.rows.has('created-1'), true);
    assert.equal(await f.page.locator('#prompt-error').isVisible(), true);
    await f.page.locator('#prompt-typed').fill('DELETE');
    await f.page.locator('#prompt-confirm').click();
    await f.page.waitForFunction(() => !document.querySelector('#editor').open);
    assert.equal(f.rows.has('created-1'), false);
    assert.deepEqual(f.pageErrors, []);
  } finally { await f.close(); }
});

test('bulk deletion uses a fixed versioned selection and an exact count confirmation', async () => {
  const f = await fixture();
  try {
    await f.page.locator('#select-all').check();
    await f.page.locator('#bulk-delete').click();
    await f.page.locator('#prompt-typed').fill('DELETE');
    await f.page.locator('#prompt-confirm').click();
    assert.equal(f.rows.size, 3);
    assert.equal(await f.page.locator('#prompt-error').isVisible(), true);
    await f.page.locator('#prompt-typed').fill('DELETE 3');
    await f.page.locator('#prompt-confirm').click();
    await f.page.waitForFunction(() => document.querySelector('#count-all').textContent === '0');
    assert.equal(f.rows.size, 0);
    assert.equal(f.calls.filter(c => c.method === 'DELETE').length, 3);
  } finally { await f.close(); }
});
