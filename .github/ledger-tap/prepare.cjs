const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { readFileSync, writeFileSync, appendFileSync, mkdtempSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');

const repository = 'tkersey/skills-zig';
const platforms = ['darwin-arm64', 'linux-x86_64'];

function versionParts(version) {
  assert.match(version, /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/);
  return version.split('.').map(BigInt);
}

function prepareFormula(formula, release, archives) {
  assert.equal(release.draft, false);
  assert.equal(release.prerelease, false);
  assert.match(release.tag_name, /^ledger-v/);
  const version = release.tag_name.slice('ledger-v'.length);
  const next = versionParts(version);
  const versions = [...formula.matchAll(/^  version "([^"]+)"$/gm)];
  assert.equal(versions.length, 1, 'Expected one formula version');
  const current = versionParts(versions[0][1]);
  const different = next.findIndex((part, i) => part !== current[i]);
  if (different !== -1 && next[different] < current[different]) {
    return { formula, version, changed: false };
  }

  let updated = formula.replace(/^  version "[^"]+"$/m, `  version "${version}"`);
  for (const platform of platforms) {
    const name = `${release.tag_name}-${platform}.tar.gz`;
    const assets = release.assets.filter(asset => asset.name === name);
    assert.equal(assets.length, 1, `Expected one published asset: ${name}`);
    const asset = assets[0];
    assert.equal(asset.state, 'uploaded');
    assert.equal(asset.browser_download_url,
      `https://github.com/${repository}/releases/download/${release.tag_name}/${name}`);
    assert.match(asset.digest, /^sha256:[0-9a-f]{64}$/);
    const archive = archives[platform];
    assert.ok(Buffer.isBuffer(archive) && archive.length > 0, `Missing archive: ${name}`);
    const digest = createHash('sha256').update(archive).digest('hex');
    assert.equal(`sha256:${digest}`, asset.digest, `Checksum mismatch: ${name}`);
    const url = `    url "https://github.com/${repository}/releases/download/ledger-v#{version}/ledger-v#{version}-${platform}.tar.gz"`;
    const lines = updated.split('\n');
    assert.equal(lines.filter(line => line === url).length, 1, `Unexpected formula URL: ${platform}`);
    const index = lines.indexOf(url) + 1;
    assert.match(lines[index], /^    sha256 "[0-9a-f]{64}"$/);
    lines[index] = `    sha256 "${digest}"`;
    updated = lines.join('\n');
  }
  return { formula: updated, version, changed: updated !== formula };
}

function main() {
  const gh = (...args) => execFileSync('gh', args, { encoding: 'utf8' });
  let tag = process.env.RELEASE_TAG;
  const commit = process.env.RELEASE_COMMIT;
  if (commit) {
    assert.match(commit, /^[0-9a-f]{40}$/);
    const content = JSON.parse(gh('api', `repos/${repository}/contents/apps/ledger/VERSION?ref=${commit}`));
    tag = `ledger-v${Buffer.from(content.content, 'base64').toString('utf8').trim()}`;
  }
  assert.ok(tag, 'RELEASE_TAG or RELEASE_COMMIT is required');
  assert.match(tag, /^ledger-v/);
  versionParts(tag.slice('ledger-v'.length));
  if (commit) {
    const target = JSON.parse(gh('api', `repos/${repository}/commits/${tag}`));
    assert.equal(target.sha, commit, 'Release tag no longer matches the successful release run');
  }
  const release = JSON.parse(gh('api', `repos/${repository}/releases/tags/${tag}`));
  assert.equal(release.tag_name, tag);
  const directory = mkdtempSync(join(tmpdir(), 'ledger-tap-'));
  try {
    const patterns = platforms.flatMap(platform => ['--pattern', `${tag}-${platform}.tar.gz`]);
    gh('release', 'download', tag, '--repo', repository, '--dir', directory, ...patterns);
    const archives = Object.fromEntries(platforms.map(platform =>
      [platform, readFileSync(join(directory, `${tag}-${platform}.tar.gz`))]));
    const path = process.argv[2];
    assert.ok(path, 'Formula path is required');
    const result = prepareFormula(readFileSync(path, 'utf8'), release, archives);
    if (result.changed) writeFileSync(path, result.formula);
    if (process.env.GITHUB_OUTPUT) {
      appendFileSync(process.env.GITHUB_OUTPUT, `version=${result.version}\nchanged=${result.changed}\n`);
    }
    console.log(`Ledger ${result.version}: ${result.changed ? 'formula updated' : 'no update needed'}`);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

module.exports = { prepareFormula };
if (require.main === module) main();
