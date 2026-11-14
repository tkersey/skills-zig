const assert = require('node:assert/strict');
const { test } = require('node:test');
const { validateAutoMerge, checksReady } = require('./auto-merge.cjs');

function fixture() {
  return {
    pr: { state: 'open', draft: false,
      base: { ref: 'main', repo: { full_name: 'tkersey/homebrew-tap' } },
      head: { ref: 'automation/ledger-1.8.1', sha: 'a'.repeat(40), repo: { full_name: 'tkersey/homebrew-tap' } } },
    files: [{ filename: 'Formula/ledger.rb', status: 'modified' }],
    content: 'verified formula', expectedContent: 'verified formula', head: 'a'.repeat(40), version: '1.8.1',
    rules: [
      { type: 'pull_request', parameters: { required_review_thread_resolution: true } },
      { type: 'required_status_checks', parameters: { required_status_checks:
        ['test-bot (macos-latest)', 'test-bot (ubuntu-latest)']
          .map(context => ({ context, integration_id: 15368 })) } },
    ],
    repo: { allow_squash_merge: true },
    review: { reviewDecision: '', reviewRequests: [] },
  };
}

test('admits only the exact verified formula PR under both platform requirements', () => {
  assert.doesNotThrow(() => validateAutoMerge(fixture()));
});

test('head drift, unrelated changes, forks and different formula bytes fail closed', () => {
  for (const change of [
    f => { f.pr.head.sha = 'b'.repeat(40); },
    f => { f.pr.head.repo.full_name = 'other/homebrew-tap'; },
    f => { f.pr.base.ref = 'other'; },
    f => { f.pr.head.ref = 'human-change'; },
    f => { f.pr.draft = true; },
    f => { f.pr.state = 'closed'; },
    f => { f.files.push({ filename: 'README.md', status: 'modified' }); },
    f => { f.files[0].filename = 'Formula/seq.rb'; },
    f => { f.files[0].status = 'renamed'; },
    f => { f.content += '\nunverified change'; },
  ]) {
    const f = fixture(); change(f); assert.throws(() => validateAutoMerge(f));
  }
});

test('missing requirements, spoofed check providers and review intervention block auto-merge', () => {
  for (const change of [
    f => { f.rules[1].parameters.required_status_checks.pop(); },
    f => { f.rules[1].parameters.required_status_checks.shift(); },
    f => { f.rules[1].parameters.required_status_checks[0].integration_id = -1; },
    f => { f.rules = []; },
    f => { f.rules[0].parameters.required_review_thread_resolution = false; },
    f => { f.repo.allow_squash_merge = false; },
    f => { f.review.reviewDecision = 'CHANGES_REQUESTED'; },
    f => { f.review.reviewRequests = [{ login: 'reviewer' }]; },
  ]) {
    const f = fixture(); change(f); assert.throws(() => validateAutoMerge(f));
  }
});

test('both required checks must pass; missing, pending, failed or skipped checks do not admit merging', () => {
  const checks = ['test-bot (macos-latest)', 'test-bot (ubuntu-latest)'].map(name =>
    ({ name, bucket: 'pass' }));
  assert.equal(checksReady(checks), true);
  assert.equal(checksReady([]), false);
  assert.equal(checksReady(checks.slice(0, 1)), false);
  assert.equal(checksReady(checks.map(c => ({ ...c, bucket: 'pending' }))), false);
  for (const bucket of ['fail', 'cancel', 'skipping', 'unknown']) {
    assert.throws(() => checksReady([checks[0], { ...checks[1], bucket }]));
  }
  assert.throws(() => checksReady([...checks, checks[0]]));
});

test('CLI merges only the revalidated head and requires terminal merged readback', () => {
  const { mkdtempSync, writeFileSync, existsSync, rmSync } = require('node:fs');
  const { tmpdir } = require('node:os');
  const { join, resolve } = require('node:path');
  const { spawnSync } = require('node:child_process');
  for (const scenario of ['success', 'head-drift', 'unmerged', 'no-checks', 'no-required-checks']) {
    const dir = mkdtempSync(join(tmpdir(), 'tap-merge-test-'));
    try {
      writeFileSync(join(dir, 'fixture.json'), JSON.stringify(fixture()));
      writeFileSync(join(dir, 'formula.rb'), 'verified formula');
      writeFileSync(join(dir, 'gh'), `#!/usr/bin/env node
const fs = require('node:fs');
const f = JSON.parse(fs.readFileSync(process.env.FIXTURE, 'utf8'));
const a = process.argv.slice(2);
const out = v => console.log(JSON.stringify(v));
const countFile = process.env.FIXTURE + '.count';
if (a[0] === 'api') {
  const path = a.at(-1);
  if (path.includes('/contents/')) out({content: Buffer.from(f.content).toString('base64')});
  else if (path.includes('/files?')) out([f.files]);
  else if (path.includes('/rules/')) out([f.rules]);
  else if (path.endsWith('/pulls/81')) {
    const count = fs.existsSync(countFile) ? Number(fs.readFileSync(countFile)) + 1 : 1;
    fs.writeFileSync(countFile, String(count));
    if (process.env.SCENARIO === 'head-drift' && count >= 3) f.pr.head.sha = 'b'.repeat(40);
    out(f.pr);
  } else if (path === 'repos/tkersey/homebrew-tap') out(f.repo);
  else throw Error('Unexpected API call ' + path);
} else if (a[1] === 'checks') {
  if (process.env.SCENARIO.startsWith('no-') && !fs.existsSync(countFile + '.checks')) {
    fs.writeFileSync(countFile + '.checks', 'seen');
    console.error(process.env.SCENARIO === 'no-checks' ? "no checks reported on the 'branch' branch" : "no required checks reported on the 'branch' branch");
    process.exit(1);
  }
  out(['test-bot (macos-latest)', 'test-bot (ubuntu-latest)'].map(name => ({name,bucket:'pass'})));
} else if (a[1] === 'merge') {
  require('node:assert/strict').deepEqual(a, ['pr','merge','81','--repo','tkersey/homebrew-tap','--squash','--match-head-commit',f.head]);
  fs.writeFileSync(process.env.FIXTURE + '.merged', 'yes');
} else if (a.at(-1) === 'reviewDecision,reviewRequests') out(f.review);
else if (a.at(-1) === 'state,headRefOid,mergedAt,mergeCommit') {
  out({state:process.env.SCENARIO === 'unmerged' ? 'OPEN' : 'MERGED',headRefOid:f.head,mergedAt:'2026-11-14T00:00:00Z',mergeCommit:{oid:'c'.repeat(40)}});
} else throw Error('Unexpected gh call ' + a.join(' '));
`, { mode: 0o755 });
      const child = spawnSync(process.execPath, [resolve(__dirname, 'auto-merge.cjs'), join(dir, 'formula.rb')], {
        encoding: 'utf8', timeout: 15000,
        env: { ...process.env, PATH: dir + ':' + process.env.PATH, FIXTURE: join(dir, 'fixture.json'),
          SCENARIO: scenario, TAP_PR: '81', TAP_HEAD: 'a'.repeat(40), TAP_VERSION: '1.8.1' },
      });
      assert.equal(child.status, ['head-drift', 'unmerged'].includes(scenario) ? 1 : 0, child.stderr);
      assert.equal(existsSync(join(dir, 'fixture.json.merged')), scenario !== 'head-drift');
    } finally { rmSync(dir, { recursive: true, force: true }); }
  }
});
