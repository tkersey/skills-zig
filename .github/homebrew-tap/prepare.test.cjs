const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { test } = require('node:test');
const { prepareFormula, releaseTagFromRun } = require('./prepare.cjs');

for (const app of ['ledger', 'seq']) {
  function fixture(version = '1.7.0', current = '1.6.0') {
    const archives = {
      'darwin-arm64': Buffer.from('macOS release archive'),
      'linux-x86_64': Buffer.from('Linux release archive'),
    };
    const tag = `${app}-v${version}`;
    const assets = Object.entries(archives).map(([platform, data]) => ({
      name: `${tag}-${platform}.tar.gz`,
      state: 'uploaded',
      digest: `sha256:${createHash('sha256').update(data).digest('hex')}`,
      browser_download_url: `https://github.com/tkersey/skills-zig/releases/download/${tag}/${tag}-${platform}.tar.gz`,
    }));
    const formula = `class ${app === 'ledger' ? 'Ledger' : 'Seq'} < Formula
  desc "Native artifact validation and durable protocol runtime"
  version "${current}"

  if OS.mac?
    url "https://github.com/tkersey/skills-zig/releases/download/${app}-v#{version}/${app}-v#{version}-darwin-arm64.tar.gz"
    sha256 "${'0'.repeat(64)}"
  else
    url "https://github.com/tkersey/skills-zig/releases/download/${app}-v#{version}/${app}-v#{version}-linux-x86_64.tar.gz"
    sha256 "${'1'.repeat(64)}"
  end

  test do
    system bin/"${app}", "--help"
  end
end
`;
    return { formula, release: { tag_name: tag, draft: false, prerelease: false, assets }, archives };
  }

  function prepare(f) {
    return prepareFormula(app, f.formula, f.release, f.archives);
  }

  test(app + ': updates only version and the two platform checksums', () => {
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

  test(app + ': version ordering is numeric and never downgrades the tap', () => {
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

  test(app + ': drafts, prereleases, malformed versions and wrong product tags fail', () => {
    for (const patch of [
      { draft: true }, { prerelease: true }, { tag_name: 'lift-v1.7.0' },
      { tag_name: `${app}-v1.7.0-rc1` }, { tag_name: `${app}-v01.7.0` },
      { tag_name: `${app}-v1.7.0\nchanged=true` },
    ]) {
      const f = fixture();
      Object.assign(f.release, patch);
      assert.throws(() => prepare(f));
    }
  });

  test(app + ': each platform requires exactly one uploaded asset at the expected URL', () => {
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

  test(app + ': download corruption, empty bytes and missing archives fail on both platforms', () => {
    for (const platform of ['darwin-arm64', 'linux-x86_64']) {
      for (const data of [Buffer.from('corrupt'), Buffer.alloc(0), undefined]) {
        const f = fixture();
        f.archives[platform] = data;
        assert.throws(() => prepare(f));
      }
    }
  });

  test(app + ': unexpected formula structure fails instead of updating a different field', () => {
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

  test(app + ': successful run artifacts identify the release independently of workflow head', () => {
    const f = fixture();
    const run = {
      status: 'completed', conclusion: 'success',
      repository: { full_name: 'tkersey/skills-zig' },
      head_repository: { full_name: 'tkersey/skills-zig' },
      path: '.github/workflows/release-' + app + '.yml',
      head_sha: 'b'.repeat(40),
    };
    const artifacts = f.release.assets.map(asset => ({ name: asset.name, expired: false }));
    assert.equal(releaseTagFromRun(app, run, artifacts), app + '-v1.7.0');
    for (const patch of [
      { status: 'in_progress' }, { conclusion: 'failure' }, { conclusion: 'cancelled' },
      { repository: { full_name: 'other/repo' } },
      { head_repository: { full_name: 'fork/skills-zig' } },
      { path: '.github/workflows/pr-ci.yml' },
    ]) assert.throws(() => releaseTagFromRun(app, { ...run, ...patch }, artifacts));
    for (const invalid of [
      [], artifacts.slice(0, 1), [...artifacts, artifacts[0]], [artifacts[0], artifacts[0]],
      [artifacts[0], { ...artifacts[1], expired: true }],
      [artifacts[0], { ...artifacts[1], name: artifacts[1].name.replace('1.7.0', '1.7.1') }],
      artifacts.map(a => ({ ...a, name: a.name.replace(app + '-v', 'lift-v') })),
      artifacts.map(a => ({ ...a, name: a.name.replace('1.7.0', '01.7.0') })),
    ]) assert.throws(() => releaseTagFromRun(app, run, invalid));
  });

  test(app + ': published bytes must equal the successful run even with valid release digests', () => {
    const f = fixture();
    assert.equal(prepareFormula(app, f.formula, f.release, f.archives, f.archives).changed, true);
    for (const platform of ['darwin-arm64', 'linux-x86_64']) {
      for (const value of [Buffer.from('different qualified archive'), undefined]) {
        assert.throws(() => prepareFormula(app, f.formula, f.release, f.archives,
          { ...f.archives, [platform]: value }));
      }
    }
  });
}
