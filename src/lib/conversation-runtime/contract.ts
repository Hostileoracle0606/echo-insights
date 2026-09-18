import { z } from "zod";

const text = z.string().max(50000);
const textSignal = (type: string) => z.object({ type: z.literal(type), text }).strict();
export const observationSchema = z.union([
  textSignal("userChunk"),
  textSignal("userInterim"),
  textSignal("userFinal"),
  textSignal("assistantChunk"),
  textSignal("assistantFinal"),
  textSignal("typed"),
  z.object({ type: z.literal("turnComplete") }).strict(),
  z.object({ type: z.literal("end") }).strict(),
  z.object({ type: z.literal("interrupted"), heardChars: z.number().int().nonnegative().max(50000).nullable() }).strict(),
  z.object({ type: z.literal("playback"), heardChars: z.number().int().nonnegative().max(50000) }).strict(),
]);

export type Observation =
  | { type: "userChunk" | "userInterim" | "userFinal" | "assistantChunk" | "assistantFinal" | "typed"; text: string }
  | { type: "turnComplete" | "end" }
  | { type: "interrupted"; heardChars: number | null }
  | { type: "playback"; heardChars: number };
export type Envelope = { sequence: number; id: string; observation: Observation };
export const envelopeSchema = z.object({
  sequence: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
  id: z.string().uuid(), observation: observationSchema,
}).strict();
export const startSchema = z.object({
  sessionId: z.string().uuid(), deviceId: z.string().uuid(),
  mode: z.enum(["wiki", "granular"]).default("granular"),
}).strict();
export const appendSchema = z.object({
  deviceId: z.string().uuid(), events: z.array(envelopeSchema).min(1).max(64),
}).strict();
