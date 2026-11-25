// Release 1 early deploy (LM-119, LM-127): builds a tiny static site that holds
// only the /privacy page and the passkey association file, so the rest of the
// web app (including /security) is NOT served before the iOS release.
//
//   npm run build && npx vite-node scripts/build-release1-site.tsx
//
// Output: dist-release1/ (not committed; see .gitignore), with a wrangler.jsonc for a
// Worker named "lumen" that serves ./site as static assets and nothing else.
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createElement } from "react";
import { renderToPipeableStream } from "react-dom/server";
import { Writable } from "node:stream";
import { Route } from "../src/routes/privacy";

const out = "dist-release1";
const site = join(out, "site");
const builtAssets = join("dist", "client", "assets");

if (!existsSync(builtAssets)) {
  throw new Error("Run `npm run build` first: the page's stylesheet comes from dist/client/assets.");
}
const css = readdirSync(builtAssets).filter((f) => /^styles-.*\.css$/.test(f));
if (css.length !== 1) throw new Error(`Expected one styles-*.css in ${builtAssets}, found ${css.length}.`);

rmSync(out, { recursive: true, force: true });
mkdirSync(join(site, "assets"), { recursive: true });
mkdirSync(join(site, ".well-known"), { recursive: true });

cpSync(join(builtAssets, css[0]), join(site, "assets", css[0]));
cpSync("public/.well-known/apple-app-site-association", join(site, ".well-known", "apple-app-site-association"));
cpSync("public/_headers", join(site, "_headers"));

const Page = (Route as unknown as { options: { component: () => JSX.Element } }).options.component;
// The route's component may be code-split (lazy), so wait for Suspense to settle.
const body = await new Promise<string>((resolve, reject) => {
  let text = "";
  const sink = new Writable({
    write(chunk, _enc, done) {
      text += chunk.toString();
      done();
    },
    final(done) {
      resolve(text);
      done();
    },
  });
  const stream = renderToPipeableStream(createElement(Page), {
    onAllReady: () => stream.pipe(sink),
    onShellError: reject,
    onError: reject,
  });
});
const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Privacy policy — Lumen</title>
<meta name="description" content="Who handles your Lumen journal, and the controls you have, in plain words.">
<link rel="stylesheet" href="/assets/${css[0]}">
</head>
<body>${body}</body>
</html>
`;
writeFileSync(join(site, "privacy.html"), html);

writeFileSync(
  join(out, "wrangler.jsonc"),
  JSON.stringify(
    {
      name: "lumen",
      compatibility_date: "2025-09-24",
      assets: { directory: "./site" },
    },
    null,
    2,
  ) + "\n",
);
console.log(`Wrote ${out}/ : /privacy, /.well-known/apple-app-site-association, _headers, 1 stylesheet.`);
