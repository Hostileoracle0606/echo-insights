// The end-to-end answer uses the production voice prompt, read from the app's
// source at run time (lib/logic/conversation_policy.dart), never a copy that
// could drift. PROMPT_SHA256 pins the version this track was checked against;
// a test fails when the app's prompt changes, so the change is looked at.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const PROMPT_SHA256 = '0e7bb43120db72f69cbda1cbcc005c2e723867002f3038a87e53306547e577ec';
const source = join(resolve(dirname(fileURLToPath(import.meta.url)), '../../..'), 'lib/logic/conversation_policy.dart');

export function productionAnswerPrompt() {
  const match = readFileSync(source, 'utf8').match(/geminiLiveSystemInstruction =\s*r'''([\s\S]*?)'''/);
  if (!match) throw new Error('answer prompt: geminiLiveSystemInstruction not found in conversation_policy.dart');
  const text = match[1];
  return { text, sha256: createHash('sha256').update(text).digest('hex') };
}
