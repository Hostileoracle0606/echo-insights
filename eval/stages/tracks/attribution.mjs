// End-to-end correctness and stage attribution.

/** Judge verdict -> correct: answerable questions need a correct answer; unanswerable ones need an abstention. */
export const finalCorrect = (verdict, answerable) => (answerable ? verdict === 'correct' : verdict === 'abstained');

/**
 * The first pipeline stage where an answering (relevance-2) gold entity was
 * lost, for a question answered wrong. answers/extracted/stored/top10 are gold
 * entity ids. null when correct.
 */
export function attribute({ answers, extracted, stored, top10, correct, answerable }) {
  if (correct) return null;
  if (!answerable || !answers.length) return 'answer';
  const all = (ids) => answers.every((a) => ids.includes(a));
  if (!all(extracted)) return 'extraction';
  if (!all(stored)) return 'admission';
  if (!all(top10)) return 'retrieval';
  return 'answer';
}
