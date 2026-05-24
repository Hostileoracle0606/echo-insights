import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

type VoiceIntent = "curious-follow-up" | "supportive-error" | "neutral";

interface Body {
  text: string;
  intent?: VoiceIntent;
}

const DEFAULT_VOICE_ID = "EXAVITQu4vr4xnSDxMaL";
const DEFAULT_MODEL_ID = "eleven_turbo_v2_5";
const DEFAULT_OUTPUT_FORMAT = "mp3_44100_128";
const MAX_TEXT_LENGTH = 900;

const VOICE_SETTINGS: Record<
  VoiceIntent,
  {
    stability: number;
    similarity_boost: number;
    style: number;
    use_speaker_boost: boolean;
  }
> = {
  "curious-follow-up": {
    stability: 0.32,
    similarity_boost: 0.85,
    style: 0.55,
    use_speaker_boost: true,
  },
  "supportive-error": {
    stability: 0.45,
    similarity_boost: 0.85,
    style: 0.4,
    use_speaker_boost: true,
  },
  neutral: {
    stability: 0.35,
    similarity_boost: 0.85,
    style: 0.5,
    use_speaker_boost: true,
  },
};

function jsonResponse(body: unknown, init?: ResponseInit) {
  return new Response(JSON.stringify(body), {
    ...init,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      ...(init?.headers ?? {}),
    },
  });
}

function cleanText(value: unknown) {
  if (typeof value !== "string") return "";
  return value.replace(/\s+/g, " ").trim().slice(0, MAX_TEXT_LENGTH);
}

function normalizeIntent(value: unknown): VoiceIntent {
  if (value === "curious-follow-up" || value === "supportive-error" || value === "neutral") {
    return value;
  }
  return "neutral";
}

function arrayBufferToBase64(buffer: ArrayBuffer) {
  const bytes = new Uint8Array(buffer);
  const chunkSize = 0x8000;
  let binary = "";

  for (let i = 0; i < bytes.length; i += chunkSize) {
    const chunk = bytes.subarray(i, i + chunkSize);
    binary += String.fromCharCode(...chunk);
  }

  return btoa(binary);
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, { status: 405 });
  }

  try {
    const body = (await req.json()) as Body;
    const text = cleanText(body.text);
    if (!text) return jsonResponse({ error: "No text provided" }, { status: 400 });

    // ── Auth preamble ─────────────────────────────────────────────
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonResponse({ error: "missing authorization" }, { status: 401 });
    }
    const supabaseUserClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: userError } =
      await supabaseUserClient.auth.getUser();
    if (userError || !user) {
      return jsonResponse({ error: "invalid session" }, { status: 401 });
    }
    // ── End auth preamble ──────────────────────────────────────────

    const apiKey = Deno.env.get("ELEVENLABS_API_KEY");
    if (!apiKey) {
      return jsonResponse({ error: "ELEVENLABS_API_KEY is not configured" }, { status: 501 });
    }

    const intent = normalizeIntent(body.intent);
    const voiceId = Deno.env.get("ELEVENLABS_VOICE_ID") ?? DEFAULT_VOICE_ID;
    const modelId = Deno.env.get("ELEVENLABS_MODEL_ID") ?? DEFAULT_MODEL_ID;
    const outputFormat = Deno.env.get("ELEVENLABS_OUTPUT_FORMAT") ?? DEFAULT_OUTPUT_FORMAT;
    const url = new URL(`https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`);
    url.searchParams.set("output_format", outputFormat);

    const response = await fetch(url, {
      method: "POST",
      headers: {
        "xi-api-key": apiKey,
        Accept: "audio/mpeg",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        text,
        model_id: modelId,
        voice_settings: VOICE_SETTINGS[intent],
      }),
    });

    if (!response.ok) {
      const detail = await response.text();
      console.error("ElevenLabs TTS error", response.status, detail);
      return jsonResponse({ error: "ElevenLabs TTS request failed" }, { status: response.status });
    }

    const audioBuffer = await response.arrayBuffer();
    const mimeType = response.headers.get("Content-Type") ?? "audio/mpeg";
    return jsonResponse({
      audioBase64: arrayBufferToBase64(audioBuffer),
      mimeType,
    });
  } catch (error) {
    console.error("speak-agent error:", error);
    return jsonResponse(
      { error: error instanceof Error ? error.message : "Unknown error" },
      { status: 500 },
    );
  }
});
