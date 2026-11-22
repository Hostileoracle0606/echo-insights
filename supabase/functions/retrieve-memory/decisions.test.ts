import { createDecisionsRouter } from "./decisions.ts";

function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}
function answer(choice: string, keys: string[], confidence = 0.9) {
  return {
    type: "choice",
    choice,
    confidence,
    probabilities: Object.fromEntries(
      keys.map((
        k,
      ) => [
        k,
        k === choice ? confidence : (1 - confidence) / (keys.length - 1),
      ]),
    ),
  };
}
const ops = ["recall", "confirm_event", "calculate", "conversation"];
const scopes = [
  "current",
  "previous",
  "as_of",
  "compare_versions",
  "unspecified",
];
function payload(op = "recall", scope = "previous") {
  return {
    answers: { operation: answer(op, ops), time_scope: answer(scope, scopes) },
  };
}
const response = (body: unknown) =>
  new Response(JSON.stringify(body), { status: 200 });

Deno.test("sends one Decisions request with full question and both closed-set choices", async () => {
  let calls = 0;
  const route = createDecisionsRouter({
    getApiKey: () => "test-key",
    fetchImpl: async (url, init) => {
      calls++;
      assert(
        url === "https://generativelanguage.googleapis.com/v1beta/decisions",
      );
      assert(init?.method === "POST");
      assert(new Headers(init.headers).get("x-goog-api-key") === "test-key");
      const body = JSON.parse(init.body as string);
      assert(
        body.model === "gemini-decision-1" &&
          body.input === "What was my goal before I updated it?",
      );
      assert(
        body.questions.operation.type === "choice" &&
          body.questions.time_scope.type === "choice",
      );
      assert(Object.keys(body.questions).length === 2);
      return response(payload());
    },
  });
  assert(
    JSON.stringify(
      await route(
        "What was my goal before I updated it?",
        new AbortController().signal,
      ),
    ) === JSON.stringify({ operation: "recall", timeScope: "previous" }),
  );
  assert(calls === 1);
});

Deno.test("missing key and already aborted requests do not leave the server", async () => {
  let calls = 0;
  const fetchImpl: typeof fetch = () => {
    calls++;
    throw new Error("unexpected egress");
  };
  const signal = new AbortController();
  signal.abort();
  assert(
    await createDecisionsRouter({ getApiKey: () => "", fetchImpl })(
      "private",
      new AbortController().signal,
    ) === null,
  );
  assert(
    await createDecisionsRouter({ getApiKey: () => "key", fetchImpl })(
      "private",
      signal.signal,
    ) === null,
  );
  assert(calls === 0);
});

Deno.test("invalid, weak and conflicting decisions fall back", async () => {
  const invalid = payload();
  invalid.answers.operation.choice = "delete";
  const low = payload();
  low.answers.operation = answer("recall", ops, 0.4);
  const conflict = payload();
  conflict.answers.operation.probabilities.recall = 0.1;
  const incompatible = payload("conversation", "previous");
  for (const body of [invalid, low, conflict, incompatible]) {
    const route = createDecisionsRouter({
      getApiKey: () => "key",
      fetchImpl: async () => response(body),
    });
    assert(await route("private", new AbortController().signal) === null);
  }
});

Deno.test("a confident operation with a weak time scope keeps the operation and leaves scope unspecified", async () => {
  // Live probe: "What book did I finish in February?" gave recall 0.99, as_of 0.58.
  const weakScope = payload("recall", "as_of");
  weakScope.answers.time_scope = answer("as_of", scopes, 0.58);
  const observed: unknown[] = [];
  const route = createDecisionsRouter({
    getApiKey: () => "key",
    fetchImpl: async () => response(weakScope),
    observe: (o) => observed.push(o),
  });
  assert(
    JSON.stringify(await route("private", new AbortController().signal)) ===
      JSON.stringify({ operation: "recall", timeScope: "unspecified" }),
  );
  assert(
    JSON.stringify(
      observed.map((o) => (o as { confidenceRange?: string }).confidenceRange),
    ) ===
      JSON.stringify(["low"]),
    "a degraded scope is reported as low confidence",
  );
  // An invalid scope is not a weak one: it still falls back entirely.
  const invalidScope = payload();
  invalidScope.answers.time_scope.choice = "someday";
  const strict = createDecisionsRouter({
    getApiKey: () => "key",
    fetchImpl: async () => response(invalidScope),
  });
  assert(await strict("private", new AbortController().signal) === null);
});

Deno.test("timeout returns even when fetch ignores abort and late results are discarded", async () => {
  let finish!: (value: Response) => void;
  const route = createDecisionsRouter({
    getApiKey: () => "key",
    timeoutMs: 10,
    fetchImpl: () =>
      new Promise((resolve) => {
        finish = resolve;
      }),
  });
  assert(await route("private", new AbortController().signal) === null);
  finish(response(payload()));
});

Deno.test("provider errors and observations do not expose provider text", async () => {
  const events: unknown[] = [];
  const route = createDecisionsRouter({
    getApiKey: () => "secret-key",
    observe: (e) => events.push(e),
    fetchImpl: () => {
      throw new Error("private journal text secret-key");
    },
  });
  assert(
    await route("private journal text", new AbortController().signal) === null,
  );
  assert(JSON.stringify(events).includes("provider"));
  assert(
    !JSON.stringify(events).includes("secret-key") &&
      !JSON.stringify(events).includes("private journal text"),
  );
});

Deno.test("accepts distinct valid operation and scope fixture pairs", async () => {
  for (
    const [question, operation, scope] of [
      ["What is my current goal?", "recall", "current"],
      ["What was my previous goal?", "recall", "previous"],
      ["How much did my goal increase?", "calculate", "compare_versions"],
      [
        "Did I actually change my coffee limit?",
        "confirm_event",
        "unspecified",
      ],
      ["How are you?", "conversation", "unspecified"],
    ]
  ) {
    const route = createDecisionsRouter({
      getApiKey: () => "key",
      fetchImpl: async () => response(payload(operation, scope)),
    });
    const result = await route(question, new AbortController().signal);
    assert(result?.operation === operation && result.timeScope === scope);
  }
});
