const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { test } = require('node:test');
const { prepareFormula } = require('./prepare.cjs');

function fixture(version = '1.7.0', current = '1.6.0') {
  const archives = {
    'darwin-arm64': Buffer.from('macOS release archive'),
    'linux-x86_64': Buffer.from('Linux release archive'),
  };
  const tag = `ledger-v${version}`;
  const assets = Object.entries(archives).map(([platform, data]) => ({
    name: `${tag}-${platform}.tar.gz`,
    state: 'uploaded',
    digest: `sha256:${createHash('sha256').update(data).digest('hex')}`,
    browser_download_url: `https://github.com/tkersey/skills-zig/releases/download/${tag}/${tag}-${platform}.tar.gz`,
  }));
  const formula = `class Ledger < Formula
  desc "Native artifact validation and durable protocol runtime"
  version "${current}"

  if OS.mac?
    url "https://github.com/tkersey/skills-zig/releases/download/ledger-v#{version}/ledger-v#{version}-darwin-arm64.tar.gz"
    sha256 "${'0'.repeat(64)}"
  else
    url "https://github.com/tkersey/skills-zig/releases/download/ledger-v#{version}/ledger-v#{version}-linux-x86_64.tar.gz"
    sha256 "${'1'.repeat(64)}"
  end

  test do
    system bin/"ledger", "--help"
  end
end
`;
  return { formula, release: { tag_name: tag, draft: false, prerelease: false, assets }, archives };
}

function prepare(f) {
  return prepareFormula(f.formula, f.release, f.archives);
}

test('updates only version and the two platform checksums', () => {
  const f = fixture();
  const result = prepare(f);
  assert.equal(result.changed, true);
  assert.equal(result.version, '1.7.0');
  const expected = f.formula
    .replace('version "1.6.0"', 'version "1.7.0"')
    .replace('0'.repeat(64), f.release.assets[0].digest.slice(7))
    .replace('1'.repeat(64), f.release.assets[1].digest.slice(7));
  assert.equal(result.formula, expected);
  assert.equal(prepare({ ...f, formula: result.formula }).changed, false);
});

test('version ordering is numeric and never downgrades the tap', () => {
  for (const [next, current, changed] of [
    ['1.10.0', '1.9.0', true], ['2.0.0', '1.99.0', true],
    ['1.7.1', '1.7.0', true], ['1.7.0', '1.7.1', false],
    ['1.9.0', '1.10.0', false], ['1.99.0', '2.0.0', false],
  ]) {
    const f = fixture(next, current);
    const result = prepare(f);
    assert.equal(result.changed, changed);
    if (!changed) assert.equal(result.formula, f.formula);
  }
});

test('drafts, prereleases, malformed versions and wrong product tags fail', () => {
  for (const patch of [
    { draft: true }, { prerelease: true }, { tag_name: 'seq-v1.7.0' },
    { tag_name: 'ledger-v1.7.0-rc1' }, { tag_name: 'ledger-v01.7.0' },
    { tag_name: 'ledger-v1.7.0\nchanged=true' },
  ]) {
    const f = fixture();
    Object.assign(f.release, patch);
    assert.throws(() => prepare(f));
  }
});

test('each platform requires exactly one uploaded asset at the expected URL', () => {
  for (const index of [0, 1]) {
    for (const change of [
      f => f.release.assets.splice(index, 1),
      f => f.release.assets.push(f.release.assets[index]),
      f => { f.release.assets[index].state = 'new'; },
      f => { f.release.assets[index].browser_download_url = 'https://example.com/archive'; },
      f => { f.release.assets[index].digest = null; },
    ]) {
      const f = fixture();
      change(f);
      assert.throws(() => prepare(f));
    }
  }
});

test('download corruption, empty bytes and missing archives fail on both platforms', () => {
  for (const platform of ['darwin-arm64', 'linux-x86_64']) {
    for (const data of [Buffer.from('corrupt'), Buffer.alloc(0), undefined]) {
      const f = fixture();
      f.archives[platform] = data;
      assert.throws(() => prepare(f));
    }
  }
});

test('unexpected formula structure fails instead of updating a different field', () => {
  for (const change of [
    s => s.replace('  version "1.6.0"', ''),
    s => s.replace('  version "1.6.0"', '  version "1.6.0"\n  version "1.5.0"'),
    s => s.replace('darwin-arm64.tar.gz', 'darwin-x86_64.tar.gz'),
    s => s.replace('linux-x86_64.tar.gz', 'linux-arm64.tar.gz'),
    s => s.replace('    sha256', '    other'),
  ]) {
    const f = fixture();
    f.formula = change(f.formula);
    assert.throws(() => prepare(f));
  }
});
