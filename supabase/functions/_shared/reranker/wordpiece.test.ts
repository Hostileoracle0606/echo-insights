import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { WordPiece } from "./wordpiece.ts";

const dir = new URL(".", import.meta.url);
const fixture = JSON.parse(await Deno.readTextFile(new URL("tokenizer-fixture.json", dir)));
const tokenizer = WordPiece.fromVocab(await Deno.readTextFile(new URL("vocab.txt", dir)));

Deno.test("query–card pairs encode exactly as the Python tokenizer the reranker was trained with", () => {
  for (const c of fixture.cases) {
    const got = tokenizer.encodePair(c.query, c.document, fixture.max_length);
    assertEquals(got.inputIds, c.input_ids, c.query);
    assertEquals(got.tokenTypeIds, c.token_type_ids, c.query);
  }
});
