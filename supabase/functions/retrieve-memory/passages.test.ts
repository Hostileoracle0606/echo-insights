import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { readMemoryPassages, searchMemoryPassages } from "./passages.ts";
import { StubEmbedder } from "../_shared/embedder.ts";

const entry = (id: string, text: string) => ({
  entryId: id,
  notebookId: "n",
  text,
  createdAt: "2026-01-01T00:00:00Z",
  spokenAt: null,
});

Deno.test("passage search uses direct candidates without graph and rereads selected sources", async () => {
  let calls = 0;
  const client = {
    rpc: (_name: string, args: Record<string, unknown>) => {
      calls++;
      return Promise.resolve({
        data: args.p_exact
          ? [entry("a", "I planted basil")]
          : [entry("a", "I planted basil"), entry("b", "I bought a car")],
        error: null,
      });
    },
  };
  const result = await searchMemoryPassages(
    client,
    new StubEmbedder(),
    "What did I plant?",
    "basil",
  );
  assertEquals(result, [entry("a", "I planted basil")]);
  assertEquals(calls, 2);
});

Deno.test("changed and deleted sources are excluded after ranking", async () => {
  const client = {
    rpc: (_name: string, args: Record<string, unknown>) =>
      Promise.resolve({
        data: args.p_exact
          ? [entry("a", "changed")]
          : [entry("a", "old"), entry("b", "deleted")],
        error: null,
      }),
  };
  assertEquals(
    await searchMemoryPassages(client, new StubEmbedder(), "old"),
    [],
  );
});

Deno.test("exact reread returns only valid source rows", async () => {
  const client = {
    rpc: (_name: string, _args: Record<string, unknown>) =>
      Promise.resolve({
        data: [entry("a", "safe"), { entryId: "bad" }],
        error: null,
      }),
  };
  assertEquals(await readMemoryPassages(client, ["a"]), [entry("a", "safe")]);
});

Deno.test("lexical search survives an unavailable local embedder", async () => {
  const client = {
    rpc: (_name: string, _args: Record<string, unknown>) =>
      Promise.resolve({ data: [entry("a", "basil grows here")], error: null }),
  };
  const embedder = {
    modelId: "unavailable",
    embed: async (_texts: string[]): Promise<number[][]> => {
      throw new Error("not available");
    },
  };
  assertEquals(await searchMemoryPassages(client, embedder, "basil"), [
    entry("a", "basil grows here"),
  ]);
});
