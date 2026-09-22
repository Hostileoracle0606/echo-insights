import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { REQUIRED_DEFINES, flutterBuildArgs, missingDefines } from "./ios-build.mjs";

const configured = {
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_ANON_KEY: "anon-key",
  NOTEBOOK_RUNTIME_URL: "https://runtime.example.com",
};

const script = fileURLToPath(new URL("./ios-build.mjs", import.meta.url));

function runScript(args, env) {
  // PATH is kept so node resolves, but no flutter call may happen on failure.
  return spawnSync(process.execPath, [script, ...args], {
    env: { PATH: process.env.PATH, ...env },
    encoding: "utf8",
  });
}

test("names every missing define in an empty environment", () => {
  assert.deepEqual(missingDefines({}), [...REQUIRED_DEFINES]);
});

test("treats whitespace-only values as missing", () => {
  assert.deepEqual(missingDefines({ ...configured, SUPABASE_ANON_KEY: "  " }), [
    "SUPABASE_ANON_KEY",
  ]);
});

test("refuses to produce build arguments without every define", () => {
  assert.throws(
    () => flutterBuildArgs("ios", { SUPABASE_URL: "https://example.supabase.co" }),
    /Missing required build configuration: SUPABASE_ANON_KEY, NOTEBOOK_RUNTIME_URL/,
  );
});

test("unsigned ios build passes all three defines", () => {
  const args = flutterBuildArgs("ios", configured);
  assert.deepEqual(args.slice(0, 4), ["build", "ios", "--release", "--no-codesign"]);
  for (const name of REQUIRED_DEFINES) {
    assert(args.includes(`--dart-define=${name}=${configured[name]}`), name);
  }
});

test("ipa build uses the export options plist and forwards extra args", () => {
  const args = flutterBuildArgs("ipa", configured, ["--build-number=7"]);
  assert.deepEqual(args.slice(0, 4), [
    "build",
    "ipa",
    "--release",
    "--export-options-plist=ios/ExportOptions.plist",
  ]);
  assert.equal(args.at(-1), "--build-number=7");
  assert.equal(args.filter((a) => a.startsWith("--dart-define=")).length, 3);
});

test("rejects an unknown build target", () => {
  assert.throws(() => flutterBuildArgs("apk", configured), /unknown build target "apk"/);
});

test("CLI exits nonzero naming every missing variable before invoking flutter", () => {
  const result = runScript(["ios"], {});
  assert.equal(result.status, 1);
  assert.match(
    result.stderr,
    /Missing required build configuration: SUPABASE_URL, SUPABASE_ANON_KEY, NOTEBOOK_RUNTIME_URL/,
  );
  assert.doesNotMatch(result.stdout, /flutter build/);
});

test("CLI without a target prints usage and exits nonzero", () => {
  const result = runScript([], configured);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /Usage: node scripts\/ios-build\.mjs <ios\|ipa>/);
});
