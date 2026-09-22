import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Every value lib/env.dart needs at runtime. An app built without them has no
// backend, and lib/main.dart refuses to start, so the build refuses first.
export const REQUIRED_DEFINES = Object.freeze([
  "SUPABASE_URL",
  "SUPABASE_ANON_KEY",
  "NOTEBOOK_RUNTIME_URL",
]);

// A signed App Store build must link a live privacy policy from the account
// sheet (Guideline 5.1.1(i)) and send password-reset links to a real page.
// Unsigned builds pass these through when set.
export const SIGNED_ONLY_DEFINES = Object.freeze(["PRIVACY_POLICY_URL", "PASSWORD_RESET_URL"]);

export const BUILD_TARGETS = Object.freeze({
  // Unsigned .app for CI and release smoke checks.
  ios: Object.freeze(["build", "ios", "--release", "--no-codesign"]),
  // Signed App Store Connect archive + .ipa (see docs/ios-release.md).
  ipa: Object.freeze([
    "build",
    "ipa",
    "--release",
    "--export-options-plist=ios/ExportOptions.plist",
  ]),
});

export function requiredDefines(target) {
  return target === "ipa" ? [...REQUIRED_DEFINES, ...SIGNED_ONLY_DEFINES] : [...REQUIRED_DEFINES];
}

export function missingDefines(env = process.env, target = "ios") {
  return requiredDefines(target).filter((name) => !env[name]?.trim());
}

/**
 * Returns the flutter arguments for [target], or throws naming every missing
 * define. There is no path that yields build arguments without the defines.
 */
export function flutterBuildArgs(target, env = process.env, extraArgs = []) {
  const base = BUILD_TARGETS[target];
  if (!base) {
    throw new Error(
      `unknown build target "${target}" (expected one of: ${Object.keys(BUILD_TARGETS).join(", ")})`,
    );
  }
  const missing = missingDefines(env, target);
  if (missing.length > 0) {
    throw new Error(`Missing required build configuration: ${missing.join(", ")}`);
  }
  const defines = [...REQUIRED_DEFINES, ...SIGNED_ONLY_DEFINES].filter((name) => env[name]?.trim());
  return [
    ...base,
    ...defines.map((name) => `--dart-define=${name}=${env[name].trim()}`),
    ...extraArgs,
  ];
}

function runCommandLine() {
  const [target, ...extraArgs] = process.argv.slice(2);
  if (!target) {
    console.error(
      `Usage: node scripts/ios-build.mjs <${Object.keys(BUILD_TARGETS).join("|")}> [flutter build args ...]`,
    );
    process.exitCode = 2;
    return;
  }

  let args;
  try {
    args = flutterBuildArgs(target, process.env, extraArgs);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
    return;
  }

  // Log the command without define values.
  console.log(`flutter ${args.map((a) => a.replace(/^(--dart-define=[A-Z_]+=).*/, "$1***")).join(" ")}`);
  const root = fileURLToPath(new URL("../", import.meta.url));
  const result = spawnSync("flutter", args, { cwd: root, stdio: "inherit" });
  if (result.error) {
    console.error(`could not run flutter: ${result.error.message}`);
    process.exitCode = 1;
    return;
  }
  process.exitCode = result.status ?? 1;
}

if (fileURLToPath(import.meta.url) === resolve(process.argv[1] ?? "")) runCommandLine();
