import { existsSync, lstatSync, readFileSync, readdirSync, realpathSync } from "node:fs";
import { basename, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const FORBIDDEN_CREDENTIAL_NAMES = Object.freeze([
  "GEMINI_API_KEY",
  "VITE_GEMINI_API_KEY",
  "GOOGLE_API_KEY",
  "GROQ_API_KEY",
  "ELEVENLABS_API_KEY",
  "VITE_ELEVENLABS_API_KEY",
  "SUPABASE_SERVICE_ROLE_KEY",
  "SUPABASE_SECRET_KEY",
  "EMBED_INTERNAL_SECRET",
]);

const BUNDLED_ENVIRONMENT_FILE = /^(?:\.env(?:\.|$)|\.dev\.vars$)/;

function filesBelow(root) {
  const files = [];
  const visitedDirectories = new Set();

  function visit(path) {
    const info = lstatSync(path);
    if (info.isSymbolicLink()) {
      const target = realpathSync(path);
      const targetInfo = lstatSync(target);
      if (targetInfo.isDirectory()) visit(target);
      else if (targetInfo.isFile()) files.push(path);
      return;
    }
    if (info.isFile()) {
      files.push(path);
      return;
    }
    if (!info.isDirectory()) return;

    const canonical = realpathSync(path);
    if (visitedDirectories.has(canonical)) return;
    visitedDirectories.add(canonical);
    for (const entry of readdirSync(path).sort()) visit(resolve(path, entry));
  }

  visit(root);
  return files;
}

function contains(buffer, text) {
  return text.length > 0 && buffer.includes(Buffer.from(text));
}

/**
 * Inspect final build artifacts, not source files. Returned findings contain
 * labels and paths only; credential values are never returned or logged.
 */
export function scanProductionArtifacts({
  roots,
  configuredSecrets = [],
  forbiddenCredentialNames = FORBIDDEN_CREDENTIAL_NAMES,
  scanCredentialNames = true,
}) {
  if (!Array.isArray(roots) || roots.length === 0) {
    throw new Error("at least one production artifact is required");
  }

  const leaks = [];
  for (const rootInput of roots) {
    const root = resolve(rootInput);
    if (!existsSync(root)) {
      throw new Error(`production artifact does not exist: ${root}`);
    }

    for (const file of filesBelow(root)) {
      const artifactPath = relative(root, file) || basename(file);
      if (BUNDLED_ENVIRONMENT_FILE.test(basename(file))) {
        leaks.push({ path: artifactPath, reason: "bundled environment file" });
        continue;
      }

      const content = readFileSync(file);
      if (scanCredentialNames) {
        const matchedNames = forbiddenCredentialNames.filter((name) => contains(content, name));
        for (const name of matchedNames) {
          // VITE_GEMINI_API_KEY also contains GEMINI_API_KEY. Report the most
          // specific name once so one unsafe reference produces one finding.
          if (matchedNames.some((other) => other !== name && other.includes(name))) continue;
          leaks.push({ path: artifactPath, reason: `forbidden credential name ${name}` });
        }
      }
      for (const secret of configuredSecrets) {
        if (secret.value.length >= 12 && contains(content, secret.value)) {
          leaks.push({ path: artifactPath, reason: `configured secret ${secret.name}` });
        }
      }
    }
  }
  return leaks;
}

function unquote(value) {
  const trimmed = value.trim();
  if (
    trimmed.length >= 2 &&
    ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
      (trimmed.startsWith("'") && trimmed.endsWith("'")))
  ) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

export function configuredSecretsFromEnvironment(projectRoot = process.cwd()) {
  const byName = new Map();
  for (const name of FORBIDDEN_CREDENTIAL_NAMES) {
    const value = process.env[name];
    if (value) byName.set(name, value);
  }

  for (const filename of [".env", ".env.local", ".env.production", ".env.production.local"]) {
    const path = resolve(projectRoot, filename);
    if (!existsSync(path)) continue;
    for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
      const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)$/);
      if (!match || !FORBIDDEN_CREDENTIAL_NAMES.includes(match[1])) continue;
      const value = unquote(match[2]);
      if (value) byName.set(match[1], value);
    }
  }

  return [...byName].map(([name, value]) => ({ name, value }));
}

function runCommandLine() {
  const args = process.argv.slice(2);
  const configuredValuesOnly = args[0] === "--configured-values-only";
  const roots = configuredValuesOnly ? args.slice(1) : args;
  if (roots.length === 0) {
    console.error(
      "Usage: npm run check:production-secrets -- [--configured-values-only] <artifact> [artifact ...]",
    );
    process.exitCode = 2;
    return;
  }

  try {
    const leaks = scanProductionArtifacts({
      roots,
      configuredSecrets: configuredSecretsFromEnvironment(),
      scanCredentialNames: !configuredValuesOnly,
    });
    if (leaks.length === 0) {
      console.log(`Production credential check passed (${roots.length} artifact root(s)).`);
      return;
    }

    console.error("Production credential check failed:");
    for (const leak of leaks) console.error(`- ${leak.path}: ${leak.reason}`);
    process.exitCode = 1;
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 2;
  }
}

if (fileURLToPath(import.meta.url) === resolve(process.argv[1] ?? "")) runCommandLine();
