// node eval/stages/gen/review-cli.mjs page   --split test [--smoke] [--per-family 10]
//   writes <split>/review.html and review-sample.json; open the page, mark items, download verdicts.
// node eval/stages/gen/review-cli.mjs record --split test [--smoke] --verdicts ~/Downloads/review-verdicts.json
//   writes the tally into <split>/manifest.json (review.perFamily, review.wrongIds).
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { recordReview, reviewPage, reviewSample } from './review.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const [command, ...args] = process.argv.slice(2);
const flag = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const dir = join(root, 'eval/stages/data', args.includes('--smoke') ? 'smoke' : '', flag('--split') ?? 'test');
const records = readFileSync(join(dir, 'worlds.jsonl'), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));

if (command === 'page') {
  const sample = reviewSample(records, { perFamily: Number(flag('--per-family') ?? 10), seed: 1 });
  writeFileSync(join(dir, 'review-sample.json'), `${JSON.stringify(sample, null, 2)}\n`);
  writeFileSync(join(dir, 'review.html'), reviewPage(sample));
  console.log(`review: ${sample.length} items → ${join(dir, 'review.html')}`);
} else if (command === 'record') {
  const sample = JSON.parse(readFileSync(join(dir, 'review-sample.json'), 'utf8'));
  const verdicts = JSON.parse(readFileSync(flag('--verdicts'), 'utf8'));
  const tally = recordReview(sample, verdicts);
  const manifestPath = join(dir, 'manifest.json');
  const manifest = existsSync(manifestPath) ? JSON.parse(readFileSync(manifestPath, 'utf8')) : {};
  manifest.review = { reviewer: 'owner', reviewedAt: new Date().toISOString(), sampled: sample.length, ...tally };
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`review: ${tally.wrongIds.length} marked wrong of ${sample.length}`);
} else {
  console.error('usage: review-cli.mjs page|record --split <split> [...]');
  process.exit(2);
}
