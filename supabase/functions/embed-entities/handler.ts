import type { TableClient } from "../_shared/db-client.ts";
import type { Embedder } from "../_shared/embedder.ts";
import { errorClass, safeLog } from "../_shared/safe-log.ts";

const CHUNK = 10;

async function contentHash(name: string, description: string | null): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${name}\n${description ?? ""}`),
  );
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

type EntityRow = { id: string; name: string; description: string | null };
type EmbeddingRow = { entity_id: string; content_hash: string; embedding_model: string };

export interface EmbedEntitiesDeps {
  /** Service-role client: this function is internal-only, gated by a shared secret. */
  adminClient(): TableClient;
  embedder(): Embedder;
  env(name: string): string | undefined;
  fetch: typeof fetch;
  /** EdgeRuntime.waitUntil, where the runtime has one. */
  waitUntil?(promise: Promise<unknown>): void;
  log?: (fields: Record<string, unknown>) => void;
}

export function createHandler(deps: EmbedEntitiesDeps): (req: Request) => Promise<Response> {
  const log = deps.log ?? ((fields) => safeLog("embed-entities", fields));
  const handle = async (req: Request): Promise<Response> => {
    // Internal-only: gated by a shared secret, not a user JWT.
    if (req.headers.get("x-internal-secret") !== deps.env("EMBED_INTERNAL_SECRET")) {
      return new Response("forbidden", { status: 403 });
    }
    const { notebookId } = (await req.json()) as { notebookId: string };
    const admin = deps.adminClient();
    const embedder = deps.embedder();

    // Every DB op checks `error` — a failed cast/privilege/service-role issue must
    // NOT be reported as success (embedded: N), or retries + live checks go blind.
    // Log a non-sensitive stage + SQLSTATE only (never row content).
    const fail = (stage: string, code: unknown) => {
      log({ event: "fail", stage, code: typeof code === "string" ? code : undefined });
      return Response.json({ ok: false, stage, code }, { status: 500 });
    };

    // Authoritative owner from notebooks (NOT from entity rows).
    const { data: nb, error: nbErr } = await admin
      .from("notebooks")
      .select("user_id")
      .eq("id", notebookId)
      .single();
    if (nbErr) return fail("notebook", nbErr.code);
    if (!nb) return Response.json({ ok: false, reason: "notebook gone" });
    const owner = (nb as { user_id: string }).user_id;

    // Filter by user_id = owner: entity insert RLS only checks auth.uid() = user_id,
    // NOT notebook ownership, so a foreign user could inject rows into this
    // notebook_id. Embedding only the owner's own rows neutralizes that here.
    // (Hardening the entities insert/update policy to also check notebook
    // ownership is the deeper pre-existing fix, tracked separately in the spec.)
    const { data: entities, error: entErr } = await admin
      .from("entities")
      .select("id,name,description")
      .eq("notebook_id", notebookId)
      .eq("user_id", owner);
    if (entErr) return fail("entities", entErr.code);
    const rows = (entities ?? []) as EntityRow[];
    const { data: existing, error: exErr } = await admin
      .from("entity_embeddings")
      .select("entity_id,content_hash,embedding_model")
      .eq("notebook_id", notebookId);
    if (exErr) return fail("existing", exErr.code);
    const existingRows = (existing ?? []) as EmbeddingRow[];
    const have = new Map(existingRows.map((r) => [r.entity_id, r]));

    // Prune orphans for this notebook.
    const currentIds = new Set(rows.map((r) => r.id));
    const orphans = existingRows.map((r) => r.entity_id).filter((id) => !currentIds.has(id));
    if (orphans.length) {
      const { error: delErr } = await admin
        .from("entity_embeddings")
        .delete()
        .eq("notebook_id", notebookId)
        .in("entity_id", orphans);
      if (delErr) return fail("prune", delErr.code);
    }

    // Stale = missing OR content changed OR model changed.
    const stale: { id: string; name: string; description: string | null; hash: string }[] = [];
    for (const r of rows) {
      const hash = await contentHash(r.name, r.description);
      const cur = have.get(r.id);
      if (!cur || cur.content_hash !== hash || cur.embedding_model !== embedder.modelId) {
        stale.push({ id: r.id, name: r.name, description: r.description, hash });
      }
    }

    const batch = stale.slice(0, CHUNK);
    if (batch.length) {
      const vecs = await embedder.embed(batch.map((s) => `${s.name}\n${s.description ?? ""}`));
      const { error: upErr } = await admin.from("entity_embeddings").upsert(
        batch.map((s, i) => ({
          notebook_id: notebookId,
          entity_id: s.id,
          user_id: owner,
          embedding: JSON.stringify(vecs[i]),
          embedding_model: embedder.modelId,
          content_hash: s.hash,
          updated_at: new Date().toISOString(),
        })),
      );
      if (upErr) return fail("upsert", upErr.code); // a vector-cast/privilege failure is NOT a success
    }

    // Continuation: more remain → re-enqueue self via fetch (NOT net.http_post,
    // which is Postgres-only). Wrap in EdgeRuntime.waitUntil so the runtime does
    // not cancel the in-flight reenqueue when this invocation returns; the cron
    // reconcile sweep remains the final backstop if it still drops.
    if (batch.length === CHUNK && stale.length > CHUNK) {
      const url = `${deps.env("SUPABASE_URL")}/functions/v1/embed-entities`;
      const reenqueue = deps
        .fetch(url, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-internal-secret": deps.env("EMBED_INTERNAL_SECRET")!,
          },
          body: JSON.stringify({ notebookId }),
        })
        .catch(() => {});
      deps.waitUntil?.(reenqueue);
    }

    return Response.json({
      ok: true,
      embedded: batch.length,
      remaining: Math.max(0, stale.length - batch.length),
      pruned: orphans.length,
    });
  };

  // Anything that escapes (a malformed body, the embedder) is logged by class
  // only; the runtime would otherwise log the message and stack.
  return async (req: Request): Promise<Response> => {
    try {
      return await handle(req);
    } catch (error) {
      log({ event: "unhandled", errorClass: errorClass(error) });
      return Response.json({ ok: false, stage: "unhandled" }, { status: 500 });
    }
  };
}
