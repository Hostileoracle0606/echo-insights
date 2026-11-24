/**
 * End to end: the graph the production replay left behind is restored with the
 * background distractors and embedded (hybrid, as production), retrieve-memory
 * ranks for each question (user scope, as Live's tool call), Gemini answers in
 * text with the production Live prompt, the memory tool and the retrieval as its
 * tool response, and Claude (on the plan) judges. Text stands in for Live audio.
 */
import { attribute, finalCorrect } from "./attribution.mjs";
import { MEMORY_TOOL, productionAnswerPrompt } from "./answer-prompt.mjs";
import { goldEntities, goldIdFor } from "./match.mjs";
import { rankWorld } from "./oracle.mjs";

const JUDGE_SYSTEM = `You grade one answer given by Lumen, a voice journal companion, to a question the user asked about things they told it earlier. You get the question, what the correct answer is (or that the user never told Lumen, or asked Lumen to remove it), and Lumen's answer.
- "correct": the answer states the correct answer (any wording), without contradicting it.
- "abstained": the answer says it doesn't know or wasn't told, without guessing a specific answer.
- "wrong": anything else, including a wrong specific answer or an invented one.
Give a one-sentence reason quoting the deciding words.`;
const JUDGE_SCHEMA = {
  type: "object",
  properties: { verdict: { type: "string", enum: ["correct", "wrong", "abstained"] }, reason: { type: "string" } },
  required: ["verdict", "reason"],
  additionalProperties: false,
};

/**
 * As production: the Live prompt as the system instruction, the memory tool
 * declared, and the retrieval delivered as that tool's response ({ context,
 * quotes }) to a call the model "made" with the question as its query.
 */
export async function answer({ question, context, quotes, geminiKey, fetchImpl }: { question: string; context: string; quotes: unknown[]; geminiKey: string; fetchImpl: any }) {
  const started = Date.now();
  await fetchImpl.pace?.();
  const response = await fetchImpl("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent", {
    method: "POST",
    headers: { "content-type": "application/json", "x-goog-api-key": geminiKey },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: productionAnswerPrompt().text }] },
      tools: [{ functionDeclarations: [MEMORY_TOOL] }],
      contents: [
        { role: "user", parts: [{ text: question }] },
        { role: "model", parts: [{ functionCall: { name: MEMORY_TOOL.name, args: { query: question } } }] },
        { role: "user", parts: [{ functionResponse: { name: MEMORY_TOOL.name, response: { context, quotes } } }] },
      ],
      generationConfig: { thinkingConfig: { thinkingBudget: 0 }, maxOutputTokens: 400 },
    }),
    signal: AbortSignal.timeout(60_000),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`answer → ${response.status}`);
  const text = (body.candidates?.[0]?.content?.parts ?? []).map((p: { text?: string }) => p.text ?? "").join("").trim();
  return { text, latencyMs: Date.now() - started };
}

export async function judgeAnswer(runner: any, cache: any, { question, answerText, gold, answerable }: { question: string; answerText: string; gold: string; answerable: boolean }) {
  const expected = answerable ? gold : "The user never told Lumen this, or asked Lumen to remove it; the right response is to say so.";
  const prompt = `<question>${question}</question>\n<correct_answer>${expected}</correct_answer>\n<lumen_answer>${answerText}</lumen_answer>`;
  const key = `e2e-judge:${prompt}`;
  let out = cache.get(key);
  if (!out) {
    ({ output: out } = await runner.run({ system: JUDGE_SYSTEM, prompt, schema: JUDGE_SCHEMA }));
    cache.set(key, out);
  }
  return out as { verdict: "correct" | "wrong" | "abstained"; reason: string };
}

export async function runE2EWorld({ record, replay, stack, embedSecret, geminiKey, fetchImpl, runner, cache }: any) {
  const { world, written } = record;
  const gold = goldEntities(world);
  const names = new Map(replay.snapshot.tables.entities.map((e: { id: string; name: string }) => [e.id, e.name]));
  const { value: ranked, leftover } = await rankWorld({ world, written, snapshot: replay.snapshot, stack, embedSecret, mode: "hybrid" });
  const texts = new Map(written.queries.map((q: { id: string; text: string }) => [q.id, q.text]));
  const rows = [];
  for (const r of ranked) {
    const q = world.queries.find((x: { id: string }) => x.id === r.queryId);
    const question = texts.get(q.id) as string;
    const reply = await answer({ question, context: r.context, quotes: r.quotes ?? [], geminiKey, fetchImpl });
    const verdict = await judgeAnswer(runner, cache, { question, answerText: reply.text, gold: q.answer, answerable: q.answerable });
    const correct = finalCorrect(verdict.verdict, q.answerable);
    const top10 = r.ranked.map((id: string) => goldIdFor(names.get(id) ?? "", gold)).filter(Boolean);
    const answers = q.gold.filter((g: { relevance: number }) => g.relevance === 2).map((g: { entityId: string }) => g.entityId);
    rows.push({
      worldId: world.id, queryId: q.id, family: q.family, answerable: q.answerable,
      answer: reply.text, verdict: verdict.verdict, reason: verdict.reason, correct,
      foundAnswersTop10: q.answerable ? answers.every((a: string) => top10.includes(a)) : null,
      stage: attribute({ answers, extracted: replay.extractedGold, stored: replay.storedGold, top10, correct, answerable: q.answerable }),
      latencyMs: { retrieval: r.latencyMs, answer: reply.latencyMs },
    });
  }
  return { rows, leftover };
}
