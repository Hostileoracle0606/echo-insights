// Minimal reproduction of a product behaviour seen in continuity-paraphrase
// (2026-11-18): an extraction patch whose relation names an entity the patch
// doesn't declare passes the extraction Lambda's validation and the app's
// mergeExtraction, then commit_notebook rejects the WHOLE turn (invalidChange)
// — every entity in that turn is lost. Live local stack only; no Gemini call.
// Run: source eval/privacy/local-env.sh && npx vitest run --config eval/memory/vite.config.ts repro
import { describe, expect, it } from "vitest";

import { mergeExtraction } from "@/lib/journal-store";
import type { JournalState } from "@/lib/journal-types";

import { localStack, withUser } from "./stack.mjs";

const stack = localStack(process.env);
const empty: JournalState = { entries: [], entities: {}, relations: {}, followUps: [], askedQuestions: [] };
const text = "My knee is sore after the long run, and Tobias says I should rest for two days.";

async function commitAs(user: { id: string; token: string }, patch: Parameters<typeof mergeExtraction>[2]) {
  const headers = { apikey: stack!.anonKey, authorization: `Bearer ${user.token}`, "content-type": "application/json" };
  const nb = await (await fetch(`${stack!.url}/rest/v1/notebooks`, {
    method: "POST", headers: { ...headers, prefer: "return=representation" },
    body: JSON.stringify({ user_id: user.id, title: "repro", started_at: new Date().toISOString() }),
  })).json();
  const { change } = mergeExtraction(empty, text, patch);
  const response = await fetch(`${stack!.url}/rest/v1/rpc/commit_notebook`, {
    method: "POST", headers,
    body: JSON.stringify({ p_notebook_id: nb[0].id, p_expected_revision: 0, p_request_id: crypto.randomUUID(), p_change: change }),
  });
  return response.json();
}

describe.skipIf(!stack)("commit_notebook and an undeclared relation endpoint", () => {
  it("control: the same turn commits when every relation endpoint is declared", async () => {
    const { value } = await withUser(stack, (user: { id: string; token: string }) => commitAs(user, {
      entities: [{ name: "Tobias Wren", type: "person" }, { name: "Knee", type: "other" }],
      relations: [{ source: "Tobias Wren", target: "Knee", label: "advised rest for" }],
    }));
    expect(value.status).toBe("committed");
  });

  it("finding: one undeclared endpoint rejects the whole turn, losing Tobias Wren too", async () => {
    const { value } = await withUser(stack, (user: { id: string; token: string }) => commitAs(user, {
      entities: [{ name: "Tobias Wren", type: "person" }],
      relations: [{ source: "Tobias Wren", target: "Knee", label: "advised rest for" }],
    }));
    expect(value).toEqual({ status: "rejected", code: "invalidChange" });
  });
});
