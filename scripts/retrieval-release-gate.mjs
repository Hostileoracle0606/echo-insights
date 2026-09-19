import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const stages = Object.freeze([
  'configuration', 'deployment', 'authentication', 'migrations_and_seed',
  'lexical_retrieval', 'embedding_generation', 'semantic_retrieval',
  'flutter_consumption', 'unauthorized_notebook', 'cleanup',
]);

export function releaseGatePassed(report, exitCode) {
  return exitCode === 0 && report?.version === 1 && report.passed === true &&
    (!report.deploymentCommands ||
      Object.values(report.deploymentCommands).every(outcome => outcome === 'success')) &&
    stages.every(stage => report.stages?.[stage] === 'passed');
}

function run() {
  const root = fileURLToPath(new URL('../', import.meta.url));
  const output = resolve(root, process.env.RETRIEVAL_GATE_REPORT ??
    'build/release-gates/retrieval.json');
  // A unique input report prevents a stale successful report releasing a build.
  const temporary = join(mkdtempSync(join(tmpdir(), 'retrieval-gate-')), 'report.json');
  const required = ['SUPABASE_URL', 'SUPABASE_ANON_KEY',
    'SUPABASE_SERVICE_ROLE_KEY', 'EMBED_INTERNAL_SECRET'];
  const configured = required.every(name => process.env[name]?.trim()) &&
    ['local', 'staging'].includes(process.env.RETRIEVAL_GATE_TARGET);
  let report;
  let result;
  if (configured) {
    result = spawnSync('flutter', [
      'test', '--no-pub', 'test_release/retrieval_release_gate_test.dart',
      '--reporter', 'expanded',
    ], {
      cwd: root,
      env: { ...process.env, RETRIEVAL_GATE_REPORT: temporary },
      encoding: 'utf8', timeout: 11 * 60 * 1000, maxBuffer: 4 * 1024 * 1024,
    });
    try { report = JSON.parse(readFileSync(temporary, 'utf8')); } catch { /* fail closed */ }
  }
  if (!report) {
    report = { version: 1, passed: false,
      stages: Object.fromEntries(stages.map(stage => [stage, 'blocked'])) };
    report.stages.configuration = configured ? 'passed' : 'failed';
    report.execution = configured ? 'flutter_failed_or_missing_report' : 'missing_configuration';
  }
  if (process.env.RETRIEVAL_MIGRATIONS_OUTCOME || process.env.RETRIEVAL_FUNCTIONS_OUTCOME) {
    report.deploymentCommands = {
      migrations: process.env.RETRIEVAL_MIGRATIONS_OUTCOME ?? 'missing',
      functions: process.env.RETRIEVAL_FUNCTIONS_OUTCOME ?? 'missing',
    };
  }
  report.passed = releaseGatePassed(report, result?.status);
  report.finishedAt = new Date().toISOString();
  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`);
  // Do not forward subprocess output: SDK exceptions may contain private data.
  for (const stage of stages) console.log(`${stage}: ${report.stages[stage] ?? 'blocked'}`);
  console.log(`Retrieval gate ${report.passed ? 'PASSED' : 'FAILED'}; report: ${output}`);
  process.exitCode = report.passed ? 0 : 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) run();
