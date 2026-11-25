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

// The memory tool Gemini Live is given (lib/providers/journal_provider.dart
// liveTools); a test checks these strings against the Dart source.
export const MEMORY_TOOL = {
  name: 'get_relevant_memory',
  description: 'Retrieve past memory relevant to a query: related entities and how they connect. Use when the user references something from earlier, or when grounding your reply in prior context would help. Distinct from the graph summary given at the start. For planning only — never read aloud.',
  parameters: {
    type: 'object',
    properties: { query: { type: 'string', description: 'A few words to recall: a name, a topic, or a phrase.' } },
    required: ['query'],
  },
};
