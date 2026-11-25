// Claude for eval work, on the owner's Claude plan through Claude Code in
// headless mode, never through the Anthropic API.
//
// Two rules keep it on the plan and cheap:
// - API credentials are removed from the child's environment, so the CLI can
//   only use its claude.ai login (checked by assertPlanAuth).
// - Every call is lean: no tools, no settings, no MCP servers, no skills, a
//   short system prompt, run from an empty temp dir so no CLAUDE.md is read.
//   Without these each call carries the whole Claude Code context (~85x more).
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export class PlanLimitReached extends Error {
  constructor(message) { super(message); this.name = 'PlanLimitReached'; }
}
export class PlanUnavailable extends Error {
  constructor(message) { super(message); this.name = 'PlanUnavailable'; }
}

const CREDENTIALS = ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN'];
const LIMIT = /usage limit|hit your (usage )?limit|limit reached|rate limit/i;

export function planEnv(env) {
  const out = { ...env };
  for (const name of CREDENTIALS) delete out[name];
  return out;
}

function exec(spawnImpl, args, { env, cwd, stdin = '' }) {
  return new Promise((resolve, reject) => {
    const child = spawnImpl('claude', args, { env, cwd, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('error', (e) => reject(new PlanUnavailable(`claude CLI failed to start: ${e.message}`)));
    child.on('close', (code) => resolve({ code, stdout, stderr }));
    child.stdin.write(stdin);
    child.stdin.end();
  });
}

const parse = (text) => {
  try { return JSON.parse(text); } catch { return null; }
};

export function createPlanRunner({ spawnImpl = spawn, model = 'opus', env = process.env } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'lumen-eval-claude-'));
  const mcpConfig = join(dir, 'mcp.json');
  writeFileSync(mcpConfig, '{"mcpServers":{}}');
  const childEnv = planEnv(env);

  return {
    async run({ system, prompt, schema }) {
      const args = [
        '-p', '--model', model, '--no-session-persistence',
        '--tools', '', '--setting-sources', '',
        '--strict-mcp-config', '--mcp-config', mcpConfig,
        '--disable-slash-commands', '--no-chrome',
        '--system-prompt', system,
        '--output-format', 'json', '--json-schema', JSON.stringify(schema),
      ];
      const { code, stdout, stderr } = await exec(spawnImpl, args, { env: childEnv, cwd: dir, stdin: prompt });
      const reply = parse(stdout);
      if (!reply) throw new PlanUnavailable(`claude CLI exited ${code} without JSON: ${stderr.slice(0, 200)}`);
      if (reply.is_error) {
        const message = String(reply.result ?? 'unknown error');
        throw LIMIT.test(message) ? new PlanLimitReached(message) : new PlanUnavailable(message);
      }
      if (reply.structured_output == null) throw new PlanUnavailable('claude CLI returned no structured output');
      return { output: reply.structured_output, usage: reply.usage ?? {}, costNotional: reply.total_cost_usd ?? 0 };
    },
  };
}

/** Refuses to run unless the CLI is logged in with a Claude plan (not a Console/API login). */
export async function assertPlanAuth({ spawnImpl = spawn, env = process.env } = {}) {
  const { stdout } = await exec(spawnImpl, ['auth', 'status'], { env: planEnv(env), cwd: tmpdir() });
  const status = parse(stdout);
  if (!status?.loggedIn || status.authMethod !== 'claude.ai') {
    throw new PlanUnavailable(`Claude CLI must be logged in with a Claude plan (claude.ai); got ${status?.authMethod ?? 'no login'}`);
  }
}
