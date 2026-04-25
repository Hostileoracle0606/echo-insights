import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SYSTEM = `You are a knowledge graph builder for a personal voice journal.
Given a journal utterance and the current graph, extract:
- entities (people, places, organizations, projects, events, concepts, emotions, objects)
- relations between them (short snake_case verb phrases like "works_with", "lives_in", "feels", "owns", "happened_at")
- metadata (dates, roles, locations, durations, sentiment) — only when clearly stated

Then identify ONE concrete piece of MISSING information that would most enrich the graph (a thin entity, an unspecified relation, or an obvious follow-up about something the user just mentioned). Craft a SHORT, warm, specific question (one sentence, < 20 words). Make it feel like a thoughtful friend curious about the user — never generic.

Use the entity NAMES as ids in relations (the host will slugify). Reuse exact names from the existing graph when the same entity is referenced.`;

interface Body {
  text: string;
  existingEntities?: Array<{ name: string; type: string; description?: string }>;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  try {
    const { text, existingEntities = [] } = (await req.json()) as Body;
    if (!text || text.trim().length < 2) {
      return new Response(JSON.stringify({ entities: [], relations: [] }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
    if (!LOVABLE_API_KEY) throw new Error("LOVABLE_API_KEY not configured");

    const tools = [
      {
        type: "function",
        function: {
          name: "update_graph",
          description: "Return entities, relations, and a single follow-up question.",
          parameters: {
            type: "object",
            properties: {
              entities: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    name: { type: "string" },
                    type: {
                      type: "string",
                      enum: ["person", "place", "organization", "project", "event", "concept", "emotion", "object", "other"],
                    },
                    description: { type: "string" },
                    metadata: { type: "object", additionalProperties: { type: "string" } },
                  },
                  required: ["name", "type"],
                  additionalProperties: false,
                },
              },
              relations: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    source: { type: "string" },
                    target: { type: "string" },
                    label: { type: "string" },
                    metadata: { type: "object", additionalProperties: { type: "string" } },
                  },
                  required: ["source", "target", "label"],
                  additionalProperties: false,
                },
              },
              followUp: {
                type: "object",
                properties: {
                  question: { type: "string" },
                  reason: { type: "string", description: "What's missing in the graph that this would fill." },
                  targetEntityNames: { type: "array", items: { type: "string" } },
                },
                required: ["question", "reason", "targetEntityNames"],
                additionalProperties: false,
              },
            },
            required: ["entities", "relations", "followUp"],
            additionalProperties: false,
          },
        },
      },
    ];

    const userMsg = `EXISTING GRAPH (top entities):\n${
      existingEntities.slice(0, 30).map((e) => `- ${e.name} (${e.type})${e.description ? `: ${e.description}` : ""}`).join("\n") || "(empty)"
    }\n\nNEW UTTERANCE:\n"""${text}"""`;

    const resp = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${LOVABLE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "google/gemini-2.5-flash",
        messages: [
          { role: "system", content: SYSTEM },
          { role: "user", content: userMsg },
        ],
        tools,
        tool_choice: { type: "function", function: { name: "update_graph" } },
      }),
    });

    if (!resp.ok) {
      const errText = await resp.text();
      console.error("AI gateway error", resp.status, errText);
      if (resp.status === 429) {
        return new Response(JSON.stringify({ error: "Rate limit exceeded. Please wait a moment." }), {
          status: 429,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (resp.status === 402) {
        return new Response(JSON.stringify({ error: "AI credits exhausted. Add credits in Settings → Workspace → Usage." }), {
          status: 402,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      return new Response(JSON.stringify({ error: "AI request failed" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const data = await resp.json();
    const call = data.choices?.[0]?.message?.tool_calls?.[0];
    let parsed: any = { entities: [], relations: [] };
    if (call?.function?.arguments) {
      try { parsed = JSON.parse(call.function.arguments); } catch (e) { console.error("parse fail", e); }
    }

    return new Response(JSON.stringify(parsed), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("extract-graph error:", e);
    return new Response(JSON.stringify({ error: e instanceof Error ? e.message : "Unknown" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
