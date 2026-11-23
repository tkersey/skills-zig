import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {assess} from './review-action-fixture.mjs';

const evaluatorId = 'codec-observer/v1';
const unavailableMessages = new Set([
  'encode did not return a string',
  'Decoded value is not a plain object',
  'Unexpected decoded field',
  'Invalid decoded timeout',
  'Missing observation',
  'Decoded value is not an object',
  'Decoded value is outside the required domain',
  'Decoded timeout is outside the required domain'
]);

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

function inputLabel(input) {
  if (!Object.hasOwn(input, 'timeout')) return 'absent';
  return input.timeout === null ? 'null' : String(input.timeout);
}

export function obligationId(input, inherited) {
  return `case/${inputLabel(input)}/inherited-${inherited}`;
}

function parseArguments(argv) {
  const names = ['contract', 'subject', 'root', 'task', 'program', 'goal', 'report', 'timeout-ms'];
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index]?.replace(/^--/, '');
    if (!names.includes(name) || Object.hasOwn(values, name) || index + 1 >= argv.length) {
      throw new Error(`Invalid argument: ${argv[index]}`);
    }
    values[name] = argv[index + 1];
  }
  for (const name of names) if (!Object.hasOwn(values, name)) throw new Error(`Missing --${name}`);
  return values;
}

function contextDigest(subject, root) {
  const context = subject.artifacts.find(artifact => artifact.id === subject.context_artifact);
  return sha256(readFileSync(resolve(root, context.path)));
}

function unavailable(ids, runId, reason) {
  return ids.map(id => ({obligation_id: id, run_id: runId, status: 'unavailable', reason, artifact_ids: []}));
}

function caseRecord(item, runId) {
  const id = obligationId(item.input, item.inherited);
  const base = {obligation_id: id, run_id: runId};
  if (!Object.hasOwn(item, 'error')) {
    return {...base, status: 'observed', observation: {kind: 'scalar', value: item.actual}, artifact_ids: []};
  }
  const message = item.error.replace(/^(Error: )+/, '');
  if (unavailableMessages.has(message)) {
    return {...base, status: 'unavailable', reason: `Fixture observation invalid: ${message}`, artifact_ids: []};
  }
  return {...base, status: 'observed', observation: {kind: 'scalar', value: 'rejected'}, artifact_ids: []};
}

export function observe(options) {
  const contractBytes = readFileSync(options.contract);
  const subjectBytes = readFileSync(options.subject);
  const contract = JSON.parse(contractBytes);
  const subject = JSON.parse(subjectBytes);
  const ids = contract.obligations.map(obligation => obligation.id);
  const run = {
    id: 'codec-run-1',
    evaluator_id: evaluatorId,
    evaluator_sha256: sha256(readFileSync(fileURLToPath(import.meta.url))),
    outcome: 'complete',
    reason: ''
  };
  let records;
  try {
    const result = assess(options.task, options.program, options.goal, options.report, Number(options['timeout-ms']));
    if (result.execution !== 'complete') {
      run.outcome = result.error === 'ETIMEDOUT' ? 'timed_out' : 'error';
      run.reason = `Candidate execution unavailable: ${result.error}`;
      records = unavailable(ids, run.id, run.reason);
    } else if (!result.candidate_stable || result.protected_changes.length > 0) {
      run.outcome = 'error';
      run.reason = result.candidate_stable
        ? `Protected task inputs changed: ${result.protected_changes.join(', ')}`
        : 'Candidate source changed during observation';
      records = unavailable(ids, run.id, run.reason);
    } else {
      records = result.observations.map(item => caseRecord(item, run.id))
        .filter(record => ids.includes(record.obligation_id));
    }
  } catch (error) {
    run.outcome = 'error';
    run.reason = `Fixture could not observe the candidate: ${String(error)}`;
    records = unavailable(ids, run.id, run.reason);
  }
  return {
    schema: 'assay-evidence/v1',
    contract_sha256: sha256(contractBytes),
    subject_sha256: sha256(subjectBytes),
    context_sha256: contextDigest(subject, options.root),
    runs: [run],
    records,
    artifacts: []
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.stdout.write(`${JSON.stringify(observe(parseArguments(process.argv.slice(2))))}\n`);
  } catch (error) {
    console.error(String(error));
    process.exitCode = 2;
  }
}
