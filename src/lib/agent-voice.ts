import { supabase } from "@/integrations/supabase/client";

export type AgentVoiceIntent = "curious-follow-up" | "supportive-error" | "neutral";

export interface SpeakAgentVoiceOptions {
  intent?: AgentVoiceIntent;
  onStart?: () => void;
  onEnd?: () => void;
}

type VoiceTone = {
  pitch: number;
  rate: number;
  volume: number;
};

const VOICE_TONES: Record<AgentVoiceIntent, VoiceTone> = {
  "curious-follow-up": { pitch: 1.04, rate: 0.98, volume: 1 },
  "supportive-error": { pitch: 0.99, rate: 0.94, volume: 1 },
  neutral: { pitch: 1.01, rate: 0.96, volume: 1 },
};

const WARM_VOICE_HINTS = [
  "alex",
  "aria",
  "ava",
  "emma",
  "enhanced",
  "google uk english",
  "google us english",
  "jenny",
  "karen",
  "microsoft aria",
  "microsoft ava",
  "microsoft jenny",
  "moira",
  "natural",
  "neural",
  "premium",
  "samantha",
  "serena",
  "susan",
  "tessa",
  "victoria",
  "zira",
] as const;

const NOVELTY_VOICE_HINTS = [
  "bells",
  "boing",
  "bubbles",
  "cellos",
  "compact",
  "fred",
  "hysterical",
  "novelty",
  "organ",
  "robot",
  "trinoids",
  "whisper",
  "zarvox",
] as const;

let activeUtterance: SpeechSynthesisUtterance | null = null;
let activeAudio: HTMLAudioElement | null = null;
let activeAudioUrl: string | null = null;
let activeVoiceRequest = 0;

interface ElevenLabsVoiceResponse {
  audioBase64?: string;
  mimeType?: string;
  error?: string;
}

export let lastElevenLabsError: string | null = null;

let audioUnlocked = false;
const SILENT_WAV =
  "data:audio/wav;base64,UklGRigAAABXQVZFZm10IBIAAAABAAEARKwAAIhYAQACABAAAABkYXRhAgAAAAEA";

export function unlockAgentAudio() {
  if (audioUnlocked || typeof Audio === "undefined") return;
  const audio = new Audio(SILENT_WAV);
  audio.muted = false;
  audio.volume = 0;
  audio
    .play()
    .then(() => {
      audioUnlocked = true;
    })
    .catch(() => {});
}

export async function speakAgentVoiceWithElevenLabs(
  text: string,
  options: SpeakAgentVoiceOptions = {},
): Promise<boolean> {
  if (typeof window === "undefined" || typeof Audio === "undefined") return false;

  const trimmedText = text.trim();
  if (!trimmedText) return false;

  stopAgentVoice();
  const requestId = activeVoiceRequest + 1;
  activeVoiceRequest = requestId;

  try {
    const body = {
      text: trimmedText,
      intent: options.intent ?? "neutral",
    };
    const data = await requestElevenLabsAudio(body);

    if (requestId !== activeVoiceRequest) return false;
    const response = data;
    if (response.error || !response.audioBase64) {
      lastElevenLabsError = response.error ?? "no audio returned";
      console.warn("[ElevenLabs] TTS failed, falling back to browser voice:", response.error);
      return false;
    }
    lastElevenLabsError = null;

    console.info("[ElevenLabs] TTS playing");
    const audioBlob = base64ToBlob(response.audioBase64, response.mimeType ?? "audio/mpeg");
    const audioUrl = URL.createObjectURL(audioBlob);
    const audio = new Audio(audioUrl);
    activeAudio = audio;
    activeAudioUrl = audioUrl;

    audio.onplay = () => options.onStart?.();
    audio.onended = () => {
      clearActiveAudio(audio, audioUrl);
      options.onEnd?.();
    };
    audio.onerror = () => {
      clearActiveAudio(audio, audioUrl);
      options.onEnd?.();
    };

    await audio.play();
    return true;
  } catch (err) {
    lastElevenLabsError = err instanceof Error ? err.message : String(err);
    console.error("[ElevenLabs] TTS error, falling back to browser voice:", err);
    if (requestId === activeVoiceRequest) options.onEnd?.();
    return false;
  }
}

async function requestElevenLabsAudio(body: {
  text: string;
  intent: AgentVoiceIntent;
}): Promise<ElevenLabsVoiceResponse> {
  const endpoint = getAgentTtsEndpoint();
  if (endpoint) {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });

    if (!response.ok) return { error: "ElevenLabs TTS request failed" };
    return (await response.json()) as ElevenLabsVoiceResponse;
  }

  // The ElevenLabs credential lives only in the speak-agent function's
  // secrets. There is deliberately no browser-direct path: it would need the
  // provider key in the client bundle.
  const { data, error } = await supabase.functions.invoke("speak-agent", { body });
  if (error) return { error: error.message };
  return data as ElevenLabsVoiceResponse;
}

function getAgentTtsEndpoint() {
  return import.meta.env.VITE_AGENT_TTS_URL?.trim() || "";
}

export function speakAgentVoice(text: string, options: SpeakAgentVoiceOptions = {}): boolean {
  const synthesis = getSpeechSynthesis();
  if (!synthesis || typeof SpeechSynthesisUtterance === "undefined") return false;

  const trimmedText = text.trim();
  if (!trimmedText) return false;

  stopAgentVoice();

  const intent = options.intent ?? "neutral";
  const tone = VOICE_TONES[intent];
  const language = getBrowserLanguage();
  const voice = chooseAgentVoice(synthesis.getVoices(), language);
  const utterance = new SpeechSynthesisUtterance(trimmedText);

  if (voice) {
    utterance.voice = voice;
    utterance.lang = voice.lang;
  } else {
    utterance.lang = language;
  }

  utterance.pitch = tone.pitch;
  utterance.rate = tone.rate;
  utterance.volume = tone.volume;
  utterance.onstart = () => {
    options.onStart?.();
  };
  utterance.onend = () => {
    clearActiveUtterance(utterance);
    options.onEnd?.();
  };
  utterance.onerror = () => {
    clearActiveUtterance(utterance);
    options.onEnd?.();
  };

  try {
    activeUtterance = utterance;
    synthesis.speak(utterance);
    return true;
  } catch {
    clearActiveUtterance(utterance);
    return false;
  }
}

export function stopAgentVoice() {
  activeVoiceRequest += 1;
  const synthesis = getSpeechSynthesis();
  synthesis?.cancel();
  activeUtterance = null;

  if (activeAudio) {
    activeAudio.pause();
    activeAudio.src = "";
    activeAudio.load();
  }

  if (activeAudioUrl) URL.revokeObjectURL(activeAudioUrl);
  activeAudio = null;
  activeAudioUrl = null;
}

function getSpeechSynthesis(): SpeechSynthesis | null {
  if (typeof window === "undefined" || !("speechSynthesis" in window)) return null;
  return window.speechSynthesis;
}

function getBrowserLanguage(): string {
  if (typeof navigator === "undefined") return "en-US";
  return navigator.language || "en-US";
}

function chooseAgentVoice(
  voices: SpeechSynthesisVoice[],
  language: string,
): SpeechSynthesisVoice | null {
  if (voices.length === 0) return null;

  return [...voices].sort((a, b) => scoreVoice(b, language) - scoreVoice(a, language))[0] ?? null;
}

function scoreVoice(voice: SpeechSynthesisVoice, language: string): number {
  const name = voice.name.toLowerCase();
  const voiceLanguage = voice.lang.toLowerCase();
  const requestedLanguage = language.toLowerCase();
  const requestedBaseLanguage = requestedLanguage.split("-")[0] ?? "en";
  let score = 0;

  if (voiceLanguage === requestedLanguage) {
    score += 40;
  } else if (voiceLanguage.startsWith(`${requestedBaseLanguage}-`)) {
    score += 30;
  } else if (voiceLanguage.startsWith("en-")) {
    score += 22;
  }

  if (voice.default) score += 8;
  if (voice.localService) score += 4;
  if (name.includes("english")) score += 4;

  for (const hint of WARM_VOICE_HINTS) {
    if (name.includes(hint)) score += 10;
  }

  for (const hint of NOVELTY_VOICE_HINTS) {
    if (name.includes(hint)) score -= 24;
  }

  return score;
}

function base64ToBlob(base64: string, mimeType: string) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return new Blob([bytes], { type: mimeType });
}

function clearActiveAudio(audio: HTMLAudioElement, audioUrl: string) {
  if (activeAudio === audio) {
    activeAudio = null;
  }
  if (activeAudioUrl === audioUrl) {
    URL.revokeObjectURL(audioUrl);
    activeAudioUrl = null;
  }
}

function clearActiveUtterance(utterance: SpeechSynthesisUtterance) {
  if (activeUtterance === utterance) {
    activeUtterance = null;
  }
}
