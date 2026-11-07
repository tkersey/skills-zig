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

function releaseTagFromRun(app, run, artifacts) {
  assert.ok(['ledger', 'seq'].includes(app), 'Unsupported tap product');
  assert.equal(run.status, 'completed');
  assert.equal(run.conclusion, 'success');
  assert.equal(run.repository.full_name, repository);
  assert.equal(run.head_repository.full_name, repository);
  assert.equal(run.path, `.github/workflows/release-${app}.yml`);
  assert.equal(artifacts.length, platforms.length);
  let tag;
  for (const platform of platforms) {
    const matches = artifacts.filter(artifact => artifact.name.endsWith(`-${platform}.tar.gz`));
    assert.equal(matches.length, 1, `Expected one qualified archive: ${platform}`);
    assert.equal(matches[0].expired, false);
    const candidate = matches[0].name.slice(0, -`-${platform}.tar.gz`.length);
    assert.ok(candidate.startsWith(`${app}-v`));
    versionParts(candidate.slice(`${app}-v`.length));
    if (tag) assert.equal(candidate, tag, 'Qualified archives disagree on release tag');
    tag = candidate;
  }
  return tag;
}

function prepareFormula(app, formula, release, archives, qualifiedArchives = null) {
  assert.ok(['ledger', 'seq'].includes(app), 'Unsupported tap product');
  assert.equal(release.draft, false);
  assert.equal(release.prerelease, false);
  assert.ok(release.tag_name.startsWith(`${app}-v`));
  const version = release.tag_name.slice(`${app}-v`.length);
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
    if (qualifiedArchives) {
      assert.ok(Buffer.isBuffer(qualifiedArchives[platform]), `Missing qualified archive: ${name}`);
      assert.ok(archive.equals(qualifiedArchives[platform]), `Published archive differs from successful run: ${name}`);
    }
    const digest = createHash('sha256').update(archive).digest('hex');
    assert.equal(`sha256:${digest}`, asset.digest, `Checksum mismatch: ${name}`);
    const url = `    url "https://github.com/${repository}/releases/download/${app}-v#{version}/${app}-v#{version}-${platform}.tar.gz"`;
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
  const app = process.argv[2];
  assert.ok(['ledger', 'seq'].includes(app), 'Unsupported tap product');
  const gh = (...args) => execFileSync('gh', args, { encoding: 'utf8' });
  let tag = process.env.RELEASE_TAG;
  const commit = process.env.RELEASE_COMMIT;
  const runId = process.env.RELEASE_RUN_ID;
  if (runId) {
    assert.match(runId, /^[1-9][0-9]*$/);
    assert.ok(!tag && !commit, 'Select either a successful run or an explicit release');
    const run = JSON.parse(gh('api', `repos/${repository}/actions/runs/${runId}`));
    const pages = JSON.parse(gh('api', '--paginate', '--slurp',
      `repos/${repository}/actions/runs/${runId}/artifacts?per_page=100`));
    const artifacts = pages.flatMap(page => page.artifacts);
    assert.ok(pages.length > 0);
    assert.ok(pages.every(page => page.total_count === artifacts.length), 'Incomplete artifact inventory');
    tag = releaseTagFromRun(app, run, artifacts);
  }
  if (commit) {
    assert.match(commit, /^[0-9a-f]{40}$/);
    const content = JSON.parse(gh('api', `repos/${repository}/contents/apps/${app}/VERSION?ref=${commit}`));
    tag = `${app}-v${Buffer.from(content.content, 'base64').toString('utf8').trim()}`;
  }
  assert.ok(tag, 'RELEASE_TAG, RELEASE_COMMIT or RELEASE_RUN_ID is required');
  assert.ok(tag.startsWith(`${app}-v`));
  versionParts(tag.slice(`${app}-v`.length));
  if (commit) {
    const target = JSON.parse(gh('api', `repos/${repository}/commits/${tag}`));
    assert.equal(target.sha, commit, 'Release tag no longer matches the successful release run');
  }
  const release = JSON.parse(gh('api', `repos/${repository}/releases/tags/${tag}`));
  assert.equal(release.tag_name, tag);
  const directory = mkdtempSync(join(tmpdir(), `${app}-tap-`));
  try {
    const patterns = platforms.flatMap(platform => ['--pattern', `${tag}-${platform}.tar.gz`]);
    gh('release', 'download', tag, '--repo', repository, '--dir', directory, ...patterns);
    const archives = Object.fromEntries(platforms.map(platform =>
      [platform, readFileSync(join(directory, `${tag}-${platform}.tar.gz`))]));
    let qualifiedArchives = null;
    if (runId) {
      qualifiedArchives = Object.fromEntries(platforms.map(platform => {
        const name = `${tag}-${platform}.tar.gz`;
        const destination = join(directory, 'qualified', platform);
        gh('run', 'download', runId, '--repo', repository, '--name', name, '--dir', destination);
        return [platform, readFileSync(join(destination, name))];
      }));
    }
    const path = process.argv[3];
    assert.ok(path, 'Formula path is required');
    const result = prepareFormula(app, readFileSync(path, 'utf8'), release, archives, qualifiedArchives);
    if (result.changed) writeFileSync(path, result.formula);
    if (process.env.GITHUB_OUTPUT) {
      appendFileSync(process.env.GITHUB_OUTPUT, `version=${result.version}\nchanged=${result.changed}\n`);
    }
    console.log(`${app} ${result.version}: ${result.changed ? 'formula updated' : 'no update needed'}`);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

module.exports = { prepareFormula, releaseTagFromRun };
if (require.main === module) main();
