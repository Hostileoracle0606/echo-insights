#!/usr/bin/env node
// Generates Lumen's standard session greeting as a bundled asset, so the app
// can play it locally on every tap instead of asking Gemini Live to generate
// an opening (which cost tokens on every warm-up, most never heard).
//
// Source of truth for the words: assets/audio/lumen_opening.txt (the app
// shows the same file as the greeting's transcript). Voice: Aoede, the
// prebuilt voice Lumen uses in Gemini Live, via Gemini's TTS model.
//
// Usage (key from the environment, never on the command line):
//   GEMINI_API_KEY=… node tool/generate_opening_audio.mjs
// Output: assets/audio/lumen_opening.wav (PCM16 mono, 24kHz).
import { readFileSync, writeFileSync } from "node:fs";

const MODEL = "gemini-2.5-flash-preview-tts";
const VOICE = "Aoede";
const TEXT_PATH = new URL("../assets/audio/lumen_opening.txt", import.meta.url);
const WAV_PATH = new URL("../assets/audio/lumen_opening.wav", import.meta.url);

const key = process.env.GEMINI_API_KEY;
if (!key) {
  console.error("GEMINI_API_KEY is not set.");
  process.exit(1);
}
const text = readFileSync(TEXT_PATH, "utf8").trim();

const response = await fetch(
  `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`,
  {
    method: "POST",
    headers: { "content-type": "application/json", "x-goog-api-key": key },
    body: JSON.stringify({
      contents: [
        {
          parts: [
            {
              text: `Say warmly, unhurried and natural, like a friend greeting you: ${text}`,
            },
          ],
        },
      ],
      generationConfig: {
        responseModalities: ["AUDIO"],
        speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: VOICE } } },
      },
    }),
  },
);
if (!response.ok) {
  console.error(`TTS request failed: ${response.status} ${await response.text()}`);
  process.exit(1);
}
const json = await response.json();
const inline = json.candidates?.[0]?.content?.parts?.find((p) => p.inlineData)?.inlineData;
if (!inline?.data) {
  console.error("TTS response carried no audio.");
  process.exit(1);
}
const rate = Number(/rate=(\d+)/.exec(inline.mimeType ?? "")?.[1] ?? 24000);
const pcm = Buffer.from(inline.data, "base64");

const header = Buffer.alloc(44);
header.write("RIFF", 0);
header.writeUInt32LE(36 + pcm.length, 4);
header.write("WAVE", 8);
header.write("fmt ", 12);
header.writeUInt32LE(16, 16);
header.writeUInt16LE(1, 20); // PCM
header.writeUInt16LE(1, 22); // mono
header.writeUInt32LE(rate, 24);
header.writeUInt32LE(rate * 2, 28);
header.writeUInt16LE(2, 32);
header.writeUInt16LE(16, 34);
header.write("data", 36);
header.writeUInt32LE(pcm.length, 40);
writeFileSync(WAV_PATH, Buffer.concat([header, pcm]));

console.log(
  `Wrote ${WAV_PATH.pathname}: ${(pcm.length / 2 / rate).toFixed(2)}s at ${rate}Hz (${inline.mimeType}).`,
);
