import assert from 'node:assert/strict';
import test from 'node:test';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { releaseGatePassed, stages } from './retrieval-release-gate.mjs';

const successful = () => ({ version: 1, passed: true,
  stages: Object.fromEntries(stages.map(stage => [stage, 'passed'])) });

test('release requires every stage and successful Flutter execution', () => {
  assert.equal(releaseGatePassed(successful(), 0), true);
  assert.equal(releaseGatePassed(successful(), 1), false);
  assert.equal(releaseGatePassed(null, 0), false);
  const failedDeployment = successful();
  failedDeployment.deploymentCommands = { migrations: 'failure', functions: 'skipped' };
  assert.equal(releaseGatePassed(failedDeployment, 0), false);
  for (const stage of stages) {
    for (const outcome of ['failed', 'blocked', undefined]) {
      const report = successful();
      report.stages[stage] = outcome;
      assert.equal(releaseGatePassed(report, 0), false, `${stage}: ${outcome}`);
    }
  }
});

test('missing configuration exits nonzero and replaces any old green report', () => {
  const directory = mkdtempSync(join(tmpdir(), 'retrieval-gate-test-'));
  const reportPath = join(directory, 'report.json');
  writeFileSync(reportPath, JSON.stringify(successful()));
  const env = { ...process.env, RETRIEVAL_GATE_REPORT: reportPath };
  for (const name of ['SUPABASE_URL', 'SUPABASE_ANON_KEY',
    'SUPABASE_SERVICE_ROLE_KEY', 'EMBED_INTERNAL_SECRET', 'RETRIEVAL_GATE_TARGET']) {
    delete env[name];
  }
  const result = spawnSync(process.execPath,
    [fileURLToPath(new URL('./retrieval-release-gate.mjs', import.meta.url))],
    { env, encoding: 'utf8' });
  assert.equal(result.status, 1);
  const report = JSON.parse(readFileSync(reportPath, 'utf8'));
  assert.equal(report.passed, false);
  assert.equal(report.stages.configuration, 'failed');
  assert.equal(report.stages.semantic_retrieval, 'blocked');
});
