// Prompts and output schemas for the Claude writer. Claude writes language
// only: what each turn must say and what each question must ask come from
// world.mjs.

export const TURNS_SYSTEM = `You write what a person says out loud to Lumen, a voice journal companion, in one conversation. You are given the facts this conversation must state, each with an id.

Rules:
- Write 1 or 2 turns in natural, casual first-person speech (the person is "I"; Lumen is not addressed by name). No stage directions, no quotes around speech.
- Every fact must be stated in exactly one turn; list the ids of the facts each turn states in factIds.
- Use each person's full name the first time they come up in this conversation; a first name is fine after that. Use place, organisation, project and event names exactly as given.
- Say nothing that isn't in the facts: no new people, places, dates or details, and nothing that the facts don't establish yet.
- Corrections should sound like real self-corrections ("actually, ...").`;

export const QUERIES_SYSTEM = `You write the questions a person later asks Lumen, their voice journal companion, about things they told it before. Each question comes with an intent saying what to ask and a list of words it must not use.

Rules:
- One question per id, spoken naturally in the first person, as one sentence or two short ones.
- Follow the style instruction for every question.
- Never use any of the avoid words, and never state or hint at the answer.
- Ask only what the intent asks; don't add details or names it doesn't give.`;

export const TURNS_SCHEMA = {
  type: 'object',
  properties: {
    turns: {
      type: 'array',
      minItems: 1,
      maxItems: 2,
      items: {
        type: 'object',
        properties: { text: { type: 'string' }, factIds: { type: 'array', items: { type: 'string' } } },
        required: ['text', 'factIds'],
        additionalProperties: false,
      },
    },
  },
  required: ['turns'],
  additionalProperties: false,
};

export const QUERIES_SCHEMA = {
  type: 'object',
  properties: {
    queries: {
      type: 'array',
      items: {
        type: 'object',
        properties: { id: { type: 'string' }, text: { type: 'string' } },
        required: ['id', 'text'],
        additionalProperties: false,
      },
    },
  },
  required: ['queries'],
  additionalProperties: false,
};

export function turnsPrompt(session, facts, retryErrors = [], attempt = 0) {
  const lines = facts.map((f) => `[${f.id}] ${f.statement}`).join('\n');
  const retry = retryErrors.length ? `\n\nAttempt ${attempt + 1}. A previous attempt was rejected for these reasons; fix them:\n- ${retryErrors.join('\n- ')}` : '';
  return `<session>${session}</session>\n<facts>\n${lines}\n</facts>${retry}`;
}

export function queriesPrompt(queries, style, retryErrors = [], attempt = 0) {
  const lines = queries.map((q) => `[${q.id}] intent: ${q.intent}${q.avoidTerms.length ? ` | avoid: ${q.avoidTerms.join(', ')}` : ''}`).join('\n');
  const retry = retryErrors.length ? `\n\nAttempt ${attempt + 1}. A previous attempt was rejected for these reasons; fix them:\n- ${retryErrors.join('\n- ')}` : '';
  return `<style>${style}</style>\n<questions>\n${lines}\n</questions>${retry}`;
}
