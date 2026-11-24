# Memory pipeline baseline (smoke run)

**Synthetic benchmark data**, generated in code and worded by Claude; no real user data. Split: test, 3 conversation histories, 10 questions. Commit bceecde, local Supabase stack.

**Largest source of failures:** Admission accounts for 33.3% of end-to-end misses (95% CI 0%–100%, 1 of 3 misses).

## Where end-to-end misses come from

| Stage | Misses | Share of misses [95% CI] |
|---|---|---|
| Admission | 1 | 33.3% [0%–100%] |
| Retrieval | 1 | 33.3% [0%–50%] |
| Answer | 1 | 33.3% [0%–50%] |
| Extraction | 0 | 0% [0%–0%] |

## Metrics

| Metric | Value [95% CI] | Sample |
|---|---|---|
| Extraction · entity precision | 0.769 [0.625–0.875] | n = 3, histories = 3 |
| Extraction · entity recall | 1.000 [1.000–1.000] | n = 3, histories = 3 |
| Extraction · entity F1 | 0.870 [0.769–0.933] | n = 3, histories = 3 |
| Extraction · relation F1 (entity pairs) | 0.651 [0.500–0.750] | n = 3, histories = 3 |
| Extraction · relation F1 (typed, Claude-judged labels) | 0.605 [0.333–0.750] | n = 3, histories = 3 |
| Extraction · attribute recall | 0.750 [0.500–1.000] | n = 3, histories = 3 |
| Admission · valid memory persistence rate | 0.840 [0.700–1.000] | n = 25, histories = 3 |
| Admission · false rejection rate | 0.160 [0.000–0.300] | n = 25, histories = 3 |
| Admission · wrong merge rate | 0.000 [0.000–0.000] | n = 25, histories = 3 |
| Oracle retrieval (hybrid, production) · Recall@1 | 0.000 [0.000–0.000] | n = 10, histories = 3 |
| Oracle retrieval (hybrid, production) · Recall@5 | 0.400 [0.000–0.750] | n = 10, histories = 3 |
| Oracle retrieval (hybrid, production) · Recall@10 | 0.600 [0.333–0.750] | n = 10, histories = 3 |
| Oracle retrieval (hybrid, production) · MRR | 0.167 [0.083–0.271] | n = 10, histories = 3 |
| Oracle retrieval (hybrid, production) · NDCG@10 | 0.405 [0.260–0.541] | n = 10, histories = 3 |
| Oracle retrieval (lexical-only fallback) · Recall@1 | 0.000 [0.000–0.000] | n = 10, histories = 3 |
| Oracle retrieval (lexical-only fallback) · Recall@5 | 0.400 [0.000–0.750] | n = 10, histories = 3 |
| Oracle retrieval (lexical-only fallback) · Recall@10 | 0.600 [0.333–0.750] | n = 10, histories = 3 |
| Oracle retrieval (lexical-only fallback) · MRR | 0.167 [0.083–0.271] | n = 10, histories = 3 |
| Oracle retrieval (lexical-only fallback) · NDCG@10 | 0.405 [0.260–0.541] | n = 10, histories = 3 |
| Oracle · hybrid − lexical, Recall@10 (paired) | 0.000 [0.000–0.000] | n = 10, histories = 3 |
| Oracle · hybrid − lexical, MRR (paired) | 0.000 [0.000–0.000] | n = 10, histories = 3 |
| End to end · answer accuracy (all questions) | 0.700 [0.500–1.000] | n = 10, histories = 3 |
| End to end · answer accuracy (answerable) | 0.700 [0.500–1.000] | n = 10, histories = 3 |
| End to end · answering memories retrieved in top 10 | 0.600 [0.333–1.000] | n = 10, histories = 3 |

Intervals: 2,000 bootstrap resamples of whole conversation histories (questions about one history move together).

## Latency (local stack, not production)

| Stage | P50 ms | P95 ms | n |
|---|---|---|---|
| extraction | 1324 | 2430 | n = 20 |
| commit | 21 | 38 | n = 20 |
| retrieval | 241 | 453 | n = 30 |
| answer | 740 | 1069 | n = 10 |

## Notes

- Synthetic benchmark (eval/stages/data); every history, name and question is generated, labelled in code, worded by Claude.
- Extraction precision counts every extracted entity the gold has no label for, including reasonable concept entities.
- Relation pair F1 is unordered; typed F1 uses Claude (on the plan) to decide label equivalence.
- End-to-end answers are text from gemini-2.5-flash with the production Live prompt and the retrieved context in the system prompt; production uses Live audio and a tool call.
- Oracle descriptions use one fixed template, so they read differently from extractor-written descriptions.
