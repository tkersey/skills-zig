const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('node:child_process');
const { readFileSync } = require('node:fs');
const { setTimeout } = require('node:timers/promises');

const repository = 'tkersey/homebrew-tap';
const contexts = ['test-bot (macos-latest)', 'test-bot (ubuntu-latest)'];

function validateAutoMerge({ pr, files, content, expectedContent, head, version, rules, repo, review }) {
  assert.match(head, /^[0-9a-f]{40}$/);
  assert.match(version, /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/);
  assert.equal(pr.state, 'open');
  assert.equal(pr.draft, false);
  assert.equal(pr.base.repo.full_name, repository);
  assert.equal(pr.base.ref, 'main');
  assert.equal(pr.head.repo.full_name, repository);
  assert.equal(pr.head.ref, `automation/ledger-${version}`);
  assert.equal(pr.head.sha, head, 'Tap PR head changed');
  assert.equal(files.length, 1, 'Only the verified formula may change');
  assert.equal(files[0].filename, 'Formula/ledger.rb');
  assert.equal(files[0].status, 'modified');
  assert.equal(content, expectedContent, 'PR formula differs from verified release formula');
  assert.equal(repo.allow_squash_merge, true);
  assert.ok(rules.some(rule => rule.type === 'pull_request' &&
    rule.parameters.required_review_thread_resolution), 'Review resolution must be enforced');
  const required = rules.filter(rule => rule.type === 'required_status_checks')
    .flatMap(rule => rule.parameters.required_status_checks);
  for (const context of contexts) {
    assert.ok(required.some(check => check.context === context && check.integration_id === 15368),
      `Required GitHub Actions check missing: ${context}`);
  }
  assert.notEqual(review.reviewDecision, 'CHANGES_REQUESTED');
  assert.deepEqual(review.reviewRequests, [], 'Review requests require human disposition');
}

function checksReady(checks) {
  let ready = true;
  for (const context of contexts) {
    const matches = checks.filter(check => check.name === context);
    if (matches.length === 0) { ready = false; continue; }
    assert.equal(matches.length, 1, `Ambiguous check: ${context}`);
    if (matches[0].bucket === 'pending') { ready = false; continue; }
    assert.equal(matches[0].bucket, 'pass', `Required check did not pass: ${context}`);
  }
  return ready;
}

async function main() {
  const number = process.env.TAP_PR;
  const head = process.env.TAP_HEAD;
  const version = process.env.TAP_VERSION;
  assert.match(number, /^[1-9][0-9]*$/);
  assert.match(head, /^[0-9a-f]{40}$/);
  const expectedContent = readFileSync(process.argv[2], 'utf8');
  const gh = (...args) => execFileSync('gh', args, { encoding: 'utf8' });
  const api = path => JSON.parse(gh('api', `repos/${repository}/${path}`));
  const pages = path => JSON.parse(gh('api', '--paginate', '--slurp', `repos/${repository}/${path}`));
  function validate() {
    const content = api(`contents/Formula/ledger.rb?ref=${head}`);
    validateAutoMerge({
      pr: api(`pulls/${number}`),
      files: pages(`pulls/${number}/files?per_page=100`).flat(),
      head, version, expectedContent,
      content: Buffer.from(content.content, 'base64').toString('utf8'),
      rules: pages('rules/branches/main?per_page=100').flat(),
      repo: JSON.parse(gh('api', `repos/${repository}`)),
      review: JSON.parse(gh('pr', 'view', number, '--repo', repository,
        '--json', 'reviewDecision,reviewRequests')),
    });
  }
  validate();
  const deadline = Date.now() + 8 * 60 * 1000;
  while (true) {
    assert.equal(api(`pulls/${number}`).head.sha, head, 'Tap PR head changed while waiting');
    const observed = spawnSync('gh', ['pr', 'checks', number, '--repo', repository,
      '--required', '--json', 'name,bucket'], { encoding: 'utf8' });
    // Checks may not be registered immediately after PR creation.
    assert.ok(observed.status === 0 || observed.status === 8 ||
      (observed.status === 1 && /no (?:required )?checks reported on /.test(observed.stderr)),
      observed.stderr || 'Could not read required checks');
    const checks = observed.stdout.trim() ? JSON.parse(observed.stdout) : [];
    if (checksReady(checks)) break;
    assert.ok(Date.now() < deadline, 'Timed out waiting for required tap checks');
    console.log('Waiting for macOS and Linux checks on the verified head');
    await setTimeout(10000);
  }
  validate();
  gh('pr', 'merge', number, '--repo', repository, '--squash', '--match-head-commit', head);
  const result = JSON.parse(gh('pr', 'view', number, '--repo', repository,
    '--json', 'state,headRefOid,mergedAt,mergeCommit'));
  assert.equal(result.headRefOid, head);
  assert.equal(result.state, 'MERGED');
  assert.ok(result.mergedAt && result.mergeCommit?.oid, 'Merged-state proof missing');
  console.log(`Ledger ${version}: PR #${number} merged at ${result.mergeCommit.oid}`);
}

module.exports = { validateAutoMerge, checksReady };
if (require.main === module) main().catch(error => { console.error(error); process.exitCode = 1; });
