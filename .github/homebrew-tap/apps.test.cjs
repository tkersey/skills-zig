const assert = require('node:assert/strict');
const { existsSync, readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { test } = require('node:test');
const { tapApps } = require('./apps.cjs');

const root = resolve(__dirname, '..', '..');

test('every released CLI has a tap handoff and vice versa', () => {
  const classifier = readFileSync(resolve(root, '.github/scripts/release_apps.sh'), 'utf8');
  const match = classifier.match(/^apps=\(([^)]*)\)$/m);
  assert.ok(match, 'release_apps.sh must declare apps=(...)');
  const released = match[1].trim().split(/\s+/);
  assert.deepEqual([...tapApps].sort(), [...released].sort());
  for (const app of tapApps) {
    assert.ok(existsSync(resolve(root, `.github/workflows/release-${app}.yml`)), `release-${app}.yml`);
  }
});
