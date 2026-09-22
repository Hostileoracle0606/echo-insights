import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { scanProductionArtifacts } from "./production-secrets.mjs";

function artifactFixture() {
  return mkdtempSync(join(tmpdir(), "echo-production-artifact-"));
}

test("allows public Supabase configuration in a production artifact", () => {
  const root = artifactFixture();
  writeFileSync(join(root, "main.js"), "VITE_SUPABASE_URL VITE_SUPABASE_PUBLISHABLE_KEY");

  assert.deepEqual(scanProductionArtifacts({ roots: [root] }), []);
});

test("reports a server-only credential name without exposing its value", () => {
  const root = artifactFixture();
  writeFileSync(join(root, "main.js"), "const keyName = 'VITE_GEMINI_API_KEY';");

  const leaks = scanProductionArtifacts({ roots: [root] });

  assert.equal(leaks.length, 1);
  assert.equal(leaks[0].reason, "forbidden credential name VITE_GEMINI_API_KEY");
  assert(!JSON.stringify(leaks).includes("AIza"));
});

test("reports an environment file bundled into an application", () => {
  const root = artifactFixture();
  const assets = join(root, "flutter_assets");
  mkdirSync(assets);
  writeFileSync(join(assets, ".env"), "GEMINI_API_KEY=not-a-real-secret");

  const leaks = scanProductionArtifacts({ roots: [root] });

  assert.equal(leaks.length, 1);
  assert.equal(leaks[0].reason, "bundled environment file");
});

test("reports a Cloudflare local secrets file bundled into a server artifact", () => {
  const root = artifactFixture();
  writeFileSync(join(root, ".dev.vars"), "UNLISTED_SECRET=not-a-real-secret");

  const leaks = scanProductionArtifacts({ roots: [root] });

  assert.equal(leaks.length, 1);
  assert.equal(leaks[0].reason, "bundled environment file");
});

test("finds a configured secret value but reports only its label", () => {
  const root = artifactFixture();
  const secret = "configured-secret-value-123456";
  writeFileSync(join(root, "app.bin"), `prefix:${secret}:suffix`);

  const leaks = scanProductionArtifacts({
    roots: [root],
    configuredSecrets: [{ name: "GEMINI_API_KEY", value: secret }],
  });

  assert.equal(leaks.length, 1);
  assert.equal(leaks[0].reason, "configured secret GEMINI_API_KEY");
  assert(!JSON.stringify(leaks).includes(secret));
});

test("a server artifact can allow credential names while still scanning values", () => {
  const root = artifactFixture();
  writeFileSync(join(root, "worker.js"), "const expectedRuntimeName = 'SUPABASE_SECRET_KEY';");

  assert.deepEqual(scanProductionArtifacts({ roots: [root], scanCredentialNames: false }), []);
});

test("rejects a missing production artifact", () => {
  assert.throws(
    () => scanProductionArtifacts({ roots: ["/definitely/missing/echo-artifact"] }),
    /production artifact does not exist/,
  );
});
