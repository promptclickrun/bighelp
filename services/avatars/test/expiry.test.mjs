import test from 'node:test';
import assert from 'node:assert/strict';
import { updateExpiry } from '../scripts/set-expiry.mjs';
const source = () => ({ schemaVersion: 1, sets: [{ id: 'halloween', name: 'Halloween', category: 'seasonal', startsAt: null, expiresAt: null }] });
test('maintainer can set or remove a collection expiry', () => {
  const data = source();
  updateExpiry(data, 'halloween', '2026-11-03T00:00:00-06:00');
  assert.equal(data.sets[0].expiresAt, '2026-11-03T00:00:00-06:00');
  updateExpiry(data, 'halloween', 'none');
  assert.equal(data.sets[0].expiresAt, null);
});
test('unknown sets and ambiguous dates fail without changing configuration', () => {
  const data = source();
  assert.throws(() => updateExpiry(data, 'unknown', 'none'));
  assert.throws(() => updateExpiry(data, 'halloween', '2026-11-03'));
  assert.deepEqual(data, source());
});
