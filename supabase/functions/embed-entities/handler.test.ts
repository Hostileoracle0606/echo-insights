import { assert, assertEquals, assertNotEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { DbQuery, TableClient } from "../_shared/db-client.ts";
import type { Embedder } from "../_shared/embedder.ts";
import { createHandler } from "./handler.ts";

// LM-102: the vector build is safe to repeat. Key: (notebook_id, entity_id),
// versioned by content_hash + embedding_model. First stored vector for a key wins.

const NB = "nb-1";
const OWNER = "user-1";

type Row = Record<string, unknown>;

/** In-memory tables with the semantics the handler relies on (primary key, ignoreDuplicates). */
class FakeDb {
  entities: Row[] = [];
  embeddings: Row[] = [];
  /** Run before an upsert lands, to model a racing run that stored first. */
  beforeUpsert?: () => void;

  client(): TableClient {
    return { from: (table: string) => this.query(table) as unknown as DbQuery };
  }

  private query(table: string) {
    // deno-lint-ignore no-this-alias
    const db = this;
    const preds: ((r: Row) => boolean)[] = [];
    let op: "select" | "delete" | "upsert" = "select";
    let single = false;
    let upsertRows: Row[] = [];
    let ignoreDuplicates = false;
    const rowsOf = (): Row[] =>
      table === "entities"
        ? db.entities
        : table === "entity_embeddings"
        ? db.embeddings
        : [{ id: NB, user_id: OWNER }];
    const run = () => {
      const matches = (r: Row) => preds.every((p) => p(r));
      if (op === "delete") {
        const keep = db.embeddings.filter((r) => !matches(r));
        db.embeddings.length = 0;
        db.embeddings.push(...keep);
        return { data: null, error: null };
      }
      if (op === "upsert") {
        db.beforeUpsert?.();
        for (const row of upsertRows) {
          const i = db.embeddings.findIndex((r) =>
            r.notebook_id === row.notebook_id && r.entity_id === row.entity_id
          );
          if (i === -1) db.embeddings.push({ ...row });
          else if (!ignoreDuplicates) db.embeddings[i] = { ...row };
        }
        return { data: null, error: null };
      }
      const found = rowsOf().filter(matches);
      return { data: single ? found[0] ?? null : found, error: null };
    };
    const q: Record<string, unknown> = {
      select: () => q,
      eq: (c: string, v: unknown) => (preds.push((r) => r[c] === v), q),
      in: (c: string, vs: string[]) => (preds.push((r) => vs.includes(r[c] as string)), q),
      delete: () => (op = "delete", q),
      single: () => (single = true, q),
      upsert: (rows: Row[], options?: Record<string, unknown>) => {
        op = "upsert";
        upsertRows = rows;
        ignoreDuplicates = options?.ignoreDuplicates === true;
        return q;
      },
      then: (res: (v: unknown) => unknown, rej?: (e: unknown) => unknown) =>
        Promise.resolve(run()).then(res, rej),
    };
    return q;
  }
}

/** Embedder that records every call; vectors come from a settable seed. */
class CountingEmbedder implements Embedder {
  readonly modelId = "test@1";
  calls = 0;
  seed = 1;
  embed(texts: string[]): Promise<number[][]> {
    this.calls++;
    return Promise.resolve(texts.map(() => [this.seed]));
  }
}

function setup() {
  const db = new FakeDb();
  const embedder = new CountingEmbedder();
  const handler = createHandler({
    adminClient: () => db.client(),
    embedder: () => embedder,
    env: (n) => (n === "EMBED_INTERNAL_SECRET" ? "s" : "http://x"),
    fetch: (() => Promise.resolve(new Response("{}"))) as typeof fetch,
    log: () => {},
  });
  const run = async () => {
    const res = await handler(
      new Request("http://x", {
        method: "POST",
        headers: { "x-internal-secret": "s" },
        body: JSON.stringify({ notebookId: NB }),
      }),
    );
    return await res.json() as Record<string, unknown>;
  };
  const addEntity = (id: string, name: string, description: string | null) => {
    db.entities.push({ id, name, description, notebook_id: NB, user_id: OWNER });
  };
  return { db, embedder, run, addEntity };
}

Deno.test("LM-102 vectors: building twice leaves one row and the second run embeds nothing", async () => {
  const { db, embedder, run, addEntity } = setup();
  addEntity("maya", "Maya", "A friend");

  const first = await run();
  const second = await run();

  assertEquals(first.embedded, 1);
  assertEquals(second.embedded, 0);
  assertEquals(embedder.calls, 1);
  assertEquals(db.embeddings.length, 1);
});

Deno.test("LM-102 vectors: changed content is a new key and replaces the row", async () => {
  const { db, embedder, run, addEntity } = setup();
  addEntity("maya", "Maya", "A friend");
  await run();
  const oldHash = db.embeddings[0].content_hash;
  embedder.seed = 2;

  db.entities[0].description = "A friend who moved to Berlin";
  const out = await run();

  assertEquals(out.embedded, 1);
  assertEquals(db.embeddings.length, 1);
  assertNotEquals(db.embeddings[0].content_hash, oldHash);
  assertEquals(db.embeddings[0].embedding, JSON.stringify([2]));
});

Deno.test("LM-102 vectors: a racing write for the same key with a different vector leaves the stored row unchanged", async () => {
  const { db, embedder, run, addEntity } = setup();
  addEntity("maya", "Maya", "A friend");
  // A racing run stores its vector for the same (entity, hash, model) after
  // this run decided the row was missing but before this run's write lands.
  const hash = await sha("Maya\nA friend");
  db.beforeUpsert = () => {
    db.beforeUpsert = undefined;
    db.embeddings.push({
      notebook_id: NB,
      entity_id: "maya",
      user_id: OWNER,
      embedding: JSON.stringify([1]),
      embedding_model: "test@1",
      content_hash: hash,
    });
  };
  embedder.seed = 99; // this run offers a different vector

  const out = await run();

  assertEquals(out.ok, true);
  assertEquals(db.embeddings.length, 1);
  assertEquals(db.embeddings[0].embedding, JSON.stringify([1]));
  assert(embedder.calls === 1);
});

async function sha(text: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
