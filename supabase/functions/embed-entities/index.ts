import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { GteSmallEmbedder } from "../_shared/embedder.ts";

const CHUNK = 10;

async function contentHash(name: string, description: string | null): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${name}\n${description ?? ""}`),
  );
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

serve(async (req) => {
  // Internal-only: gated by a shared secret, not a user JWT.
  if (req.headers.get("x-internal-secret") !== Deno.env.get("EMBED_INTERNAL_SECRET")) {
    return new Response("forbidden", { status: 403 });
  }
  const { notebookId } = (await req.json()) as { notebookId: string };
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const embedder = new GteSmallEmbedder();

  // Every DB op checks `error` — a failed cast/privilege/service-role issue must
  // NOT be reported as success (embedded: N), or retries + live checks go blind.
  // Log a non-sensitive stage + SQLSTATE only (never row content).
  const fail = (stage: string, code: unknown) => {
    console.error(`embed-entities stage=${stage} code=${code}`);
    return Response.json({ ok: false, stage, code }, { status: 500 });
  };

  // Authoritative owner from notebooks (NOT from entity rows).
  const { data: nb, error: nbErr } = await admin.from("notebooks").select("user_id").eq("id", notebookId).single();
  if (nbErr) return fail("notebook", nbErr.code);
  if (!nb) return Response.json({ ok: false, reason: "notebook gone" });
  const owner = nb.user_id as string;

  // Filter by user_id = owner: entity insert RLS only checks auth.uid() = user_id,
  // NOT notebook ownership, so a foreign user could inject rows into this
  // notebook_id. Embedding only the owner's own rows neutralizes that here.
  // (Hardening the entities insert/update policy to also check notebook
  // ownership is the deeper pre-existing fix, tracked separately in the spec.)
  const { data: entities, error: entErr } = await admin
    .from("entities").select("id,name,description").eq("notebook_id", notebookId).eq("user_id", owner);
  if (entErr) return fail("entities", entErr.code);
  const rows = entities ?? [];
  const { data: existing, error: exErr } = await admin
    .from("entity_embeddings").select("entity_id,content_hash,embedding_model").eq("notebook_id", notebookId);
  if (exErr) return fail("existing", exErr.code);
  const have = new Map((existing ?? []).map((r) => [r.entity_id, r]));

  // Prune orphans for this notebook.
  const currentIds = new Set(rows.map((r) => r.id));
  const orphans = (existing ?? []).map((r) => r.entity_id).filter((id) => !currentIds.has(id));
  if (orphans.length) {
    const { error: delErr } = await admin.from("entity_embeddings").delete().eq("notebook_id", notebookId).in("entity_id", orphans);
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
        notebook_id: notebookId, entity_id: s.id, user_id: owner,
        embedding: JSON.stringify(vecs[i]), embedding_model: embedder.modelId, content_hash: s.hash,
        updated_at: new Date().toISOString(),
      })),
    );
    if (upErr) return fail("upsert", upErr.code);   // a vector-cast/privilege failure is NOT a success
  }

  // Continuation: more remain → re-enqueue self via fetch (NOT net.http_post,
  // which is Postgres-only). Wrap in EdgeRuntime.waitUntil so the runtime does
  // not cancel the in-flight reenqueue when this invocation returns; the cron
  // reconcile sweep remains the final backstop if it still drops.
  if (batch.length === CHUNK && stale.length > CHUNK) {
    const url = `${Deno.env.get("SUPABASE_URL")}/functions/v1/embed-entities`;
    const reenqueue = fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-internal-secret": Deno.env.get("EMBED_INTERNAL_SECRET")! },
      body: JSON.stringify({ notebookId }),
    }).catch(() => {});
    // deno-lint-ignore no-explicit-any
    (globalThis as any).EdgeRuntime?.waitUntil?.(reenqueue);
  }

  return Response.json({ ok: true, embedded: batch.length, remaining: Math.max(0, stale.length - batch.length), pruned: orphans.length });
});
