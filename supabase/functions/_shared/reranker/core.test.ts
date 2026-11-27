import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { candidateDocument, candidateIds, selectReranked } from "./core.ts";
import { normalizeName } from "../graphloop/noise.ts";

// Expected values are outputs of ml/embedding/validation/rerank_core.ts (branch
// feat/reranker), the code the reranker was evaluated with. core.ts must not drift.
const graph = {
  entities: {
    "aurelio-sutherland": { id: "aurelio-sutherland", name: "Aurelio Sutherland", type: "person", description: "a nurse" },
    mossley: { id: "mossley", name: "Mossley", type: "place" },
    pickle: { id: "pickle", name: "Pickle", type: "person", description: "A grey tabby cat." },
  },
  relations: { r1: { source: "aurelio-sutherland", target: "mossley", label: "lives_in" } },
};

Deno.test("the candidate pool matches the evaluated code: eligible vector seeds plus name matches", () => {
  const pool = (q: string) => candidateIds(graph.entities, q, ["pickle"], normalizeName);
  assertEquals(pool("Where does Aurelio live now?"), ["pickle"]);
  assertEquals(pool("aurelio"), ["aurelio-sutherland", "pickle"]);
  assertEquals(pool("the cat"), ["pickle"]);
  assertEquals(pool("Mossley"), ["mossley", "pickle"]);
});

Deno.test("cards match the evaluated code: name and type, description, relation lines", () => {
  assertEquals(candidateDocument(graph, "aurelio-sutherland"), "Aurelio Sutherland (person)\na nurse\nAurelio Sutherland --lives_in--> Mossley");
  assertEquals(candidateDocument(graph, "mossley"), "Mossley (place)\nAurelio Sutherland --lives_in--> Mossley");
  assertEquals(candidateDocument(graph, "pickle"), "Pickle (person)\nA grey tabby cat.");
});

Deno.test("seeds keep current search's count, in the reranker's order, as priorities", () => {
  assertEquals(selectReranked(["aurelio-sutherland", "mossley", "pickle"], [0.2, 3.1, -1], 2, (p) => [...p]),
    [["mossley", 1], ["aurelio-sutherland", 0.99]]);
});
