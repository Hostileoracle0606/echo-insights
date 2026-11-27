# Optional memory reranking

Stage 2 is disabled unless `MEMORY_RERANKER_URL` is set. The endpoint accepts
`POST { query, documents: [{ id, text }] }` and returns
`{ scores: [{ id, score }] }`. The IDs are request-local. Scores are
uncalibrated model outputs. Configure `MEMORY_RERANKER_TIMEOUT_MS` for candidate redaction and scoring together (default `500`, maximum
`2000`), `MEMORY_RERANKER_CANDIDATE_COUNT` (default `12`, range `1..32`), and
optionally `MEMORY_RERANKER_BEARER_TOKEN`.

The ranker runs after the user's graph has been loaded under their auth scope
and before linked evidence is fetched. Candidate documents contain entity
name/type, description, and active relationship lines; each is passed through
`redact_forgotten_text` before inference, and empty redacted documents are
omitted. The scorer receives graph records and the full redacted question.
An invalid response, timeout, or service error keeps the existing
selector result. The adapter enforces its deadline even if the HTTP transport
ignores abort. Fact lookup keeps the original selector's entity closure;
reranking changes only which linked passages are used for quote fallback.

## Local debug trace

Debugging is opt-in through the programmatic callback. A benchmark or local
operator harness can pass a restricted sink; no trace is added to a user
response or normal function logs:

```ts
const evidence = await graphEvidence(client, graph, query, semantic, signal, {
  reranker,
  rerankQuery: fullRedactedQuestion,
  candidateCount: 12,
  debug: (trace) => restrictedLocalSink.write(JSON.stringify(trace)),
});
```

The trace includes candidate IDs, raw scores, retrieval/graph features, baseline
and reranked IDs, graph paths, fallback status, and elapsed time. It excludes
query text and journal excerpts. Candidate IDs can still be user-associated
metadata, so keep the sink local and access-controlled.
