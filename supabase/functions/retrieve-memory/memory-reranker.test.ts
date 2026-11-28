import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  createHttpMemoryReranker,
  rankedCandidatePriorities,
} from "./memory-reranker.ts";

Deno.test("cross-encoder receives request-local IDs and its scores map back to the original candidates", async () => {
  const calls: Request[] = [];
  const reranker = createHttpMemoryReranker({
    endpoint: "https://ranker.example.test/score",
    bearerToken: "internal-token",
    fetchImpl: (input, init) => {
      calls.push(new Request(input, init));
      return Promise.resolve(
        Response.json({
          scores: [{ id: "candidate-1", score: -2.4 }, {
            id: "candidate-0",
            score: 1.7,
          }],
        }),
      );
    },
  });
  const scores = await reranker.rank("Where is it?", [
    { id: "a", text: "Memory A" },
    { id: "b", text: "Memory B" },
  ], new AbortController().signal);
  assertEquals([...scores], [["b", -2.4], ["a", 1.7]]);
  const request = calls[0];
  assertEquals(request.headers.get("authorization"), "Bearer internal-token");
  assertEquals(await request.json(), {
    query: "Where is it?",
    documents: [{ id: "candidate-0", text: "Memory A" }, {
      id: "candidate-1",
      text: "Memory B",
    }],
  });
});

Deno.test("invalid, duplicate, and missing model scores fail closed", async () => {
  for (
    const body of [
      {
        scores: [{ id: "candidate-0", score: 0.4 }, {
          id: "candidate-0",
          score: 0.2,
        }],
      },
      {
        scores: [{ id: "candidate-0", score: Number.NaN }, {
          id: "candidate-1",
          score: 0.2,
        }],
      },
      { scores: [{ id: "candidate-0", score: 0.4 }] },
      { scores: [{ id: "a", score: 0.4 }, { id: "b", score: 0.2 }] },
    ]
  ) {
    const reranker = createHttpMemoryReranker({
      endpoint: "https://ranker.example.test/score",
      fetchImpl: () => Promise.resolve(Response.json(body)),
    });
    await assertRejects(() =>
      reranker.rank(
        "q",
        [{ id: "a", text: "A" }, { id: "b", text: "B" }],
        new AbortController().signal,
      )
    );
  }
});

Deno.test("budget cancellation aborts the inference request", async () => {
  let aborted = false;
  const reranker = createHttpMemoryReranker({
    endpoint: "https://ranker.example.test/score",
    timeoutMs: 10,
    // Deliberately ignore abort and never settle: the adapter must still
    // return at its own deadline rather than relying on fetch cooperation.
    fetchImpl: (_input, init) =>
      new Promise((_resolve) => {
        init?.signal?.addEventListener("abort", () => {
          aborted = true;
        }, { once: true });
      }),
  });
  const started = Date.now();
  await assertRejects(() =>
    reranker.rank("q", [{ id: "a", text: "A" }], new AbortController().signal)
  );
  assertEquals(Date.now() - started < 500, true);
  assertEquals(aborted, true);
});

Deno.test("parent cancellation rejects even when fetch ignores abort", async () => {
  let aborted = false;
  const reranker = createHttpMemoryReranker({
    endpoint: "https://ranker.example.test/score",
    timeoutMs: 1000,
    fetchImpl: (_input, init) =>
      new Promise((_resolve) => {
        init?.signal?.addEventListener("abort", () => {
          aborted = true;
        }, { once: true });
      }),
  });
  const controller = new AbortController();
  const pending = reranker.rank(
    "q",
    [{ id: "a", text: "A" }],
    controller.signal,
  );
  controller.abort();
  await assertRejects(() => pending);
  assertEquals(aborted, true);
});

Deno.test("model order maps to rank priorities without interpreting scores as probabilities", () => {
  assertEquals([...rankedCandidatePriorities([
    { id: "later", score: -4.2 },
    { id: "first", score: -0.3 },
    { id: "middle", score: -1.2 },
  ])], [["first", 1], ["middle", 0.9999], ["later", 0.9998]]);
});
