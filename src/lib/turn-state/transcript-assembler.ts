import type { TurnEvent } from "./types";

/**
 * Translates Gemini Live's raw transcript signals into turn-machine events.
 *
 * This is where the cumulative-prefix bug lived. The old adapter fired a
 * "sentence" callback carrying the whole turn-so-far at every sentence
 * boundary, and each fire ran a complete extract → merge → commit. Sentence one
 * could therefore commit, and then sentence one *plus* sentence two could
 * commit again, double-counting everything in the first sentence.
 *
 * Here, chunks only ever produce a *replaceable* interim transcript. Nothing
 * durable happens until a turn is explicitly completed.
 *
 * Turn boundaries: Gemini's `turnComplete` describes the MODEL's turn. The user
 * turn ends earlier — server VAD detects end of speech and the model starts
 * answering — so the first assistant output after user speech is what closes
 * the user turn. A user turn the assistant never answered is closed by
 * `turnComplete` as a fallback.
 */
export interface TranscriptAssembler {
  checkpoint: () => AssemblerCheckpoint;
  /** Incremental user transcription chunk. */
  userChunk: (chunk: string) => TurnEvent[];
  /** Provider interim transcription: replaces the accumulated buffer. */
  userInterim: (text: string) => TurnEvent[];
  /** Final ("finished") user transcription chunk; closes the transcript. */
  userFinal: (chunk: string) => TurnEvent[];
  assistantChunk: (chunk: string) => TurnEvent[];
  assistantFinal: (chunk: string) => TurnEvent[];
  turnComplete: () => TurnEvent[];
  interrupted: (heardChars: number | null) => TurnEvent[];
  reset: () => void;
  /** Current assistant display text — the basis for the heard watermark. */
  assistantText: () => string;
}

export interface AssemblerCheckpoint {
  userBuffer: string;
  assistantBuffer: string;
  userTurnOpen: boolean;
  userTurnClosed: boolean;
}

export function createTranscriptAssembler(checkpoint?: AssemblerCheckpoint): TranscriptAssembler {
  let userBuffer = checkpoint?.userBuffer ?? "";
  let assistantBuffer = checkpoint?.assistantBuffer ?? "";
  let userTurnOpen = checkpoint?.userTurnOpen ?? false;
  let userTurnClosed = checkpoint?.userTurnClosed ?? false;

  /** The assistant answering is the signal that the user's turn is over. */
  function closeUserTurnIfNeeded(): TurnEvent[] {
    if (!userTurnOpen || userTurnClosed) return [];
    userTurnClosed = true;
    return [{ type: "turnCompleted", speaker: "user" }];
  }

  function resetAll(): void {
    userBuffer = "";
    assistantBuffer = "";
    userTurnOpen = false;
    userTurnClosed = false;
  }

  return {
    checkpoint: () => ({ userBuffer, assistantBuffer, userTurnOpen, userTurnClosed }),
    userChunk(chunk) {
      if (!chunk) return [];
      userBuffer += chunk;
      userTurnOpen = true;
      return [{ type: "interimTranscript", speaker: "user", text: userBuffer }];
    },

    userInterim(text) {
      // Replacement, not an append: the provider has revised its own guess.
      userBuffer = text;
      userTurnOpen = true;
      return [{ type: "interimTranscript", speaker: "user", text: userBuffer }];
    },

    userFinal(chunk) {
      userBuffer += chunk;
      const text = userBuffer;
      userBuffer = "";
      userTurnOpen = true;
      if (!text.trim()) return [];
      return [{ type: "finalTranscript", speaker: "user", text }];
    },

    assistantChunk(chunk) {
      if (!chunk) return [];
      const closing = closeUserTurnIfNeeded();
      assistantBuffer += chunk;
      return [
        ...closing,
        { type: "interimTranscript", speaker: "assistant", text: assistantBuffer },
      ];
    },

    assistantFinal(chunk) {
      const closing = closeUserTurnIfNeeded();
      assistantBuffer += chunk;
      const text = assistantBuffer;
      assistantBuffer = "";
      if (!text.trim()) return closing;
      return [...closing, { type: "finalTranscript", speaker: "assistant", text }];
    },

    turnComplete() {
      const events: TurnEvent[] = [...closeUserTurnIfNeeded()];
      events.push({ type: "turnCompleted", speaker: "assistant" });
      resetAll();
      return events;
    },

    interrupted(heardChars) {
      return [{ type: "assistantInterrupted", heardChars }];
    },

    reset: resetAll,

    assistantText() {
      return assistantBuffer;
    },
  };
}
