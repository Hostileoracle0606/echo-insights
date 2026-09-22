import type { Speaker, TurnEvent } from "./types";

interface PendingTranscriptCheckpoint {
  generation: number;
  text: string;
  expired?: boolean;
}

/**
 * Translates Gemini Live's raw transcript signals into turn-machine events.
 *
 * Chunks only produce replaceable interim text. When a provider turn closes,
 * its buffer is parked until either the authoritative final chunk or the
 * finalization deadline arrives. Gemini does not guarantee those signals'
 * order, so clearing the buffer at `turnComplete` can lose the turn's prefix.
 */
export interface TranscriptAssembler {
  checkpoint: () => AssemblerCheckpoint;
  userChunk: (chunk: string) => TurnEvent[];
  userInterim: (text: string) => TurnEvent[];
  userFinal: (chunk: string) => TurnEvent[];
  assistantChunk: (chunk: string) => TurnEvent[];
  assistantFinal: (chunk: string) => TurnEvent[];
  turnComplete: () => TurnEvent[];
  interrupted: (heardChars: number | null) => TurnEvent[];
  /** Expires the exact parked buffer governed by a fired fallback deadline. */
  expirePending: (speaker: Speaker, generation: number) => void;
  reset: () => void;
  assistantText: () => string;
}

export interface AssemblerCheckpoint {
  userBuffer: string;
  assistantBuffer: string;
  userTurnOpen: boolean;
  userTurnClosed: boolean;
  pendingUser?: PendingTranscriptCheckpoint[];
  pendingAssistant?: PendingTranscriptCheckpoint[];
  nextGeneration?: number;
  assistantInterrupted?: boolean;
}

export function createTranscriptAssembler(checkpoint?: AssemblerCheckpoint): TranscriptAssembler {
  let userBuffer = checkpoint?.userBuffer ?? "";
  let assistantBuffer = checkpoint?.assistantBuffer ?? "";
  let userTurnOpen = checkpoint?.userTurnOpen ?? false;
  let userTurnClosed = checkpoint?.userTurnClosed ?? false;
  let assistantInterrupted = checkpoint?.assistantInterrupted ?? false;
  let nextGeneration = checkpoint?.nextGeneration ?? 0;
  const pendingUser = structuredClone(checkpoint?.pendingUser ?? []);
  const pendingAssistant = structuredClone(checkpoint?.pendingAssistant ?? []);

  const pendingFor = (speaker: Speaker): PendingTranscriptCheckpoint[] =>
    speaker === "user" ? pendingUser : pendingAssistant;

  function park(speaker: Speaker): number | undefined {
    const text = speaker === "user" ? userBuffer : assistantBuffer;
    if (speaker === "user") userBuffer = "";
    else assistantBuffer = "";
    if (!text.trim()) return undefined;
    const pending = { generation: ++nextGeneration, text };
    pendingFor(speaker).push(pending);
    return pending.generation;
  }

  function discardExpiredBeforeNewTurn(speaker: Speaker): void {
    const queue = pendingFor(speaker);
    for (let index = queue.length - 1; index >= 0; index -= 1) {
      if (queue[index]?.expired) queue.splice(index, 1);
    }
  }

  function resolvePendingFinal(speaker: Speaker, chunk: string): TurnEvent[] | null {
    const queue = pendingFor(speaker);
    const pending = queue[0];
    if (!pending) return null;
    if (pending.expired) {
      queue.shift();
      const activeText = speaker === "user" ? userBuffer : assistantBuffer;
      // Active text proves a newer turn is underway; this final belongs there.
      // Otherwise it is the delayed final represented by the expired slot.
      return activeText ? null : [];
    }
    queue.shift();
    const text = pending.text + chunk;
    if (!text.trim()) return [];
    return [{ type: "finalTranscript", speaker, text }];
  }

  function closeUserTurnIfNeeded(): TurnEvent[] {
    if (!userTurnOpen || userTurnClosed) return [];
    userTurnClosed = true;
    const transcriptGeneration = park("user");
    return [
      transcriptGeneration === undefined
        ? { type: "turnCompleted", speaker: "user" }
        : { type: "turnCompleted", speaker: "user", transcriptGeneration },
    ];
  }

  function resetActive(): void {
    userBuffer = "";
    assistantBuffer = "";
    userTurnOpen = false;
    userTurnClosed = false;
    assistantInterrupted = false;
  }

  return {
    checkpoint: () => ({
      userBuffer,
      assistantBuffer,
      userTurnOpen,
      userTurnClosed,
      pendingUser: structuredClone(pendingUser),
      pendingAssistant: structuredClone(pendingAssistant),
      nextGeneration,
      assistantInterrupted,
    }),

    userChunk(chunk) {
      if (!chunk) return [];
      discardExpiredBeforeNewTurn("user");
      userBuffer += chunk;
      userTurnOpen = true;
      return [{ type: "interimTranscript", speaker: "user", text: userBuffer }];
    },

    userInterim(text) {
      discardExpiredBeforeNewTurn("user");
      userBuffer = text;
      userTurnOpen = true;
      return [{ type: "interimTranscript", speaker: "user", text: userBuffer }];
    },

    userFinal(chunk) {
      const pending = resolvePendingFinal("user", chunk);
      if (pending) return pending;
      userBuffer += chunk;
      const text = userBuffer;
      userBuffer = "";
      userTurnOpen = true;
      if (!text.trim()) return [];
      return [{ type: "finalTranscript", speaker: "user", text }];
    },

    assistantChunk(chunk) {
      if (!chunk || assistantInterrupted) return [];
      discardExpiredBeforeNewTurn("assistant");
      const closing = closeUserTurnIfNeeded();
      assistantBuffer += chunk;
      return [
        ...closing,
        { type: "interimTranscript", speaker: "assistant", text: assistantBuffer },
      ];
    },

    assistantFinal(chunk) {
      const pending = resolvePendingFinal("assistant", chunk);
      if (pending) return pending;
      if (assistantInterrupted) return [];
      const closing = closeUserTurnIfNeeded();
      assistantBuffer += chunk;
      const text = assistantBuffer;
      assistantBuffer = "";
      if (!text.trim()) return closing;
      return [...closing, { type: "finalTranscript", speaker: "assistant", text }];
    },

    turnComplete() {
      const events = closeUserTurnIfNeeded();
      const transcriptGeneration = assistantInterrupted ? undefined : park("assistant");
      if (assistantInterrupted) assistantBuffer = "";
      events.push(
        transcriptGeneration === undefined
          ? { type: "turnCompleted", speaker: "assistant" }
          : { type: "turnCompleted", speaker: "assistant", transcriptGeneration },
      );
      resetActive();
      return events;
    },

    interrupted(heardChars) {
      assistantInterrupted = true;
      if (assistantBuffer.trim()) {
        pendingAssistant.push({
          generation: ++nextGeneration,
          text: assistantBuffer,
          expired: true,
        });
      }
      assistantBuffer = "";
      return [{ type: "assistantInterrupted", heardChars }];
    },

    expirePending(speaker, generation) {
      const pending = pendingFor(speaker).find((item) => item.generation === generation);
      if (pending) pending.expired = true;
    },

    reset() {
      resetActive();
      pendingUser.length = 0;
      pendingAssistant.length = 0;
      nextGeneration = 0;
    },

    assistantText() {
      return assistantBuffer;
    },
  };
}
