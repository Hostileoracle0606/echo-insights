import type {
  ActiveTurn,
  ConversationTurn,
  FinalizedTurn,
  Speaker,
  TurnEffect,
  TurnEvent,
  TurnIdentity,
  TurnMachine,
  TurnMachineDeps,
  TurnMachineState,
  TurnCheckpoint,
} from "./types";

const EMPTY_STATE: TurnMachineState = {
  sessionId: null,
  notebookId: null,
  active: { user: null, assistant: null },
  awaiting: { user: null, assistant: null },
  pending: [],
  conversation: [],
  preview: null,
  staleRejections: 0,
  revision: 0,
};

const MAX_CONVERSATION = 16;

/** Orders ISO-8601 instants by time (Dart checkpoints carry microseconds). */
export function compareInstants(a: string, b: string): number {
  const ta = Date.parse(a);
  const tb = Date.parse(b);
  if (Number.isNaN(ta) || Number.isNaN(tb)) return a.localeCompare(b);
  return ta - tb;
}

/** Inserts by utterance start; ties keep finalization order. */
function insertChronologically(
  conversation: ConversationTurn[],
  turn: ConversationTurn,
): ConversationTurn[] {
  let at = conversation.length;
  while (at > 0 && compareInstants(conversation[at - 1].startedAt, turn.startedAt) > 0) at -= 1;
  return [...conversation.slice(0, at), turn, ...conversation.slice(at)];
}
const PROVISIONAL_MIN_CHARS = 6;
const SPEAKERS: Speaker[] = ["user", "assistant"];

/** Stable, dependency-free content hash. Proves which text produced an extraction. */
function fnv1a(text: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, "0");
}

/**
 * Cuts `text` at the playback watermark without splitting a word. A half-spoken
 * word was not heard as that word, so it must not reach the extractor.
 */
function truncateToHeard(text: string, heardChars: number): string {
  if (heardChars >= text.length) return text;
  if (heardChars <= 0) return "";
  const slice = text.slice(0, heardChars);
  // If the cut landed mid-word, fall back to the last completed word.
  if (/\s/.test(text.charAt(heardChars))) return slice.trimEnd();
  const lastSpace = slice.search(/\s\S*$/);
  return lastSpace <= 0 ? "" : slice.slice(0, lastSpace).trimEnd();
}

function newActiveTurn(turnId: string, speaker: Speaker, startedAt: string): ActiveTurn {
  return {
    turnId,
    speaker,
    phase: "listening",
    text: "",
    transcriptVersion: 0,
    generation: 0,
    finalText: null,
    turnCompleted: false,
    heardChars: speaker === "assistant" ? 0 : null,
    interrupted: false,
    startedAt,
  };
}

export function createTurnMachine(deps: TurnMachineDeps, checkpoint?: TurnCheckpoint): TurnMachine {
  const hash = deps.hash ?? fnv1a;
  const extractorVersion = deps.extractorVersion ?? "v1";
  const provisional = deps.provisionalExtraction ?? false;

  if (checkpoint && checkpoint.version !== 1) throw new Error("Unsupported turn checkpoint");
  let state: TurnMachineState = checkpoint ? structuredClone(checkpoint.state) : structuredClone(EMPTY_STATE);
  /** In-memory only: prevents starting the same durable step twice. */
  let inFlight: string | null = checkpoint?.inFlight ?? null;
  /**
   * Assistant transcript gate after a barge-in. Gemini's documented sequence is
   * `interrupted` then `turnComplete`, and output transcription has no ordering
   * guarantee — so text can still arrive for speech that was never played.
   * `collecting` drops it for the interrupted turn; `awaitingNewTurn` drops
   * trailing final text until genuinely new speech starts.
   */
  let assistantGate: "collecting" | "awaitingNewTurn" | null = checkpoint?.assistantGate ?? null;

  function keyOf(turn: {
    turnId: string;
    transcriptVersion: number;
    generation: number;
  }): TurnIdentity {
    return {
      sessionId: state.sessionId!,
      notebookId: state.notebookId!,
      turnId: turn.turnId,
      transcriptVersion: turn.transcriptVersion,
      generation: turn.generation,
    };
  }

  function ensureActive(speaker: Speaker): ActiveTurn {
    return state.active[speaker] ?? newActiveTurn(deps.newTurnId(), speaker, deps.now());
  }

  function setActive(speaker: Speaker, turn: ActiveTurn | null): void {
    state = { ...state, active: { ...state.active, [speaker]: turn } };
  }

  function setAwaiting(speaker: Speaker, turn: ActiveTurn | null): void {
    state = { ...state, awaiting: { ...state.awaiting, [speaker]: turn } };
  }

  function findActive(turnId: string): ActiveTurn | null {
    for (const speaker of SPEAKERS) {
      if (state.active[speaker]?.turnId === turnId) return state.active[speaker];
      if (state.awaiting[speaker]?.turnId === turnId) return state.awaiting[speaker];
    }
    return null;
  }

  function rejectStale(): TurnEffect[] {
    state = { ...state, staleRejections: state.staleRejections + 1 };
    return [];
  }

  /** Session and notebook identity must match before anything else is considered. */
  function sessionMatches(key: TurnIdentity): boolean {
    return key.sessionId === state.sessionId && key.notebookId === state.notebookId;
  }

  function replaceHead(patch: Partial<FinalizedTurn>): FinalizedTurn {
    const head = { ...state.pending[0], ...patch } as FinalizedTurn;
    state = { ...state, pending: [head, ...state.pending.slice(1)] };
    return head;
  }

  function dropHead(): TurnEffect[] {
    const head = state.pending[0];
    state = { ...state, pending: state.pending.slice(1) };
    inFlight = null;
    return head ? [{ type: "forgetTurn", turnId: head.turnId }, ...driveQueue()] : driveQueue();
  }

  /**
   * Advances the head of the pending queue. Turns are processed strictly in
   * their original order with one durable step in flight at a time — that
   * ordering is what makes conflict replay deterministic and keeps mention
   * counts from double-applying.
   */
  function driveQueue(): TurnEffect[] {
    const head = state.pending[0];
    if (!head || inFlight) return [];

    if (head.stage === "finalRecorded") {
      inFlight = head.turnId;
      // The key carries the turn's OWN session, not whichever socket happens to
      // be open now: a reconnect must not invalidate work already finalized.
      return [
        {
          type: "startDurableExtraction",
          key: {
            sessionId: head.sessionId,
            notebookId: head.notebookId,
            turnId: head.turnId,
            transcriptVersion: head.transcriptVersion,
            generation: head.generation,
          },
          transcript: head.transcript,
        },
      ];
    }
    if (head.stage === "extracted") {
      inFlight = head.turnId;
      // Record "about to commit, with this request id, against this revision"
      // BEFORE the durable write, so an unknown outcome can be retried
      // identically rather than guessed at.
      const updated = replaceHead({ stage: "commitPending", baseRevision: state.revision });
      return [
        { type: "persistTurn", turn: updated },
        { type: "startCommit", turnId: updated.turnId, commitRequestId: updated.commitRequestId },
      ];
    }
    if (head.stage === "commitPending") {
      inFlight = head.turnId;
      return [{ type: "startCommit", turnId: head.turnId, commitRequestId: head.commitRequestId }];
    }
    return [];
  }

  /**
   * Turns a completed active turn into an immutable finalized turn. This is the
   * only path by which spoken text becomes eligible to change the canonical graph.
   */
  function finalize(turn: ActiveTurn, transcript: string, truncated: boolean): TurnEffect[] {
    const text = transcript.trim();
    if (state.active[turn.speaker]?.turnId === turn.turnId) setActive(turn.speaker, null);
    if (state.awaiting[turn.speaker]?.turnId === turn.turnId) setAwaiting(turn.speaker, null);
    if (!text) return [];

    const finalized: FinalizedTurn = {
      turnId: turn.turnId,
      sessionId: state.sessionId!,
      notebookId: state.notebookId!,
      speaker: turn.speaker,
      transcript: text,
      transcriptVersion: turn.transcriptVersion,
      transcriptHash: hash(text),
      extractorVersion,
      // Advancing the generation invalidates any provisional work for this turn.
      generation: turn.generation + 1,
      commitRequestId: deps.newRequestId(),
      stage: "finalRecorded",
      extraction: null,
      baseRevision: null,
      revision: null,
      finalizedAt: deps.now(),
      truncatedFromInterruption: truncated,
    };

    const effects: TurnEffect[] = [];
    if (turn.generation > 0) {
      effects.push({ type: "cancelExtraction", turnId: turn.turnId, generation: turn.generation });
    }
    state = {
      ...state,
      pending: [...state.pending, finalized],
      preview: state.preview?.turnId === turn.turnId ? null : state.preview,
      conversation: insertChronologically(state.conversation, {
        turnId: turn.turnId,
        role: turn.speaker,
        text,
        createdAt: finalized.finalizedAt,
        startedAt: turn.startedAt,
      }).slice(-MAX_CONVERSATION),
    };
    // The checkpoint is written BEFORE the expensive model call, so a restart
    // between here and extraction resumes instead of losing the turn.
    effects.push({ type: "persistTurn", turn: finalized });
    return [...effects, ...driveQueue()];
  }

  function reduce(event: TurnEvent): TurnEffect[] {
    switch (event.type) {
      case "sessionStarted": {
        assistantGate = null;
        if (state.notebookId !== null && state.notebookId === event.notebookId) {
          // Reconnecting to the SAME notebook. A live socket is session-scoped;
          // a finalized turn's durable work is notebook-scoped and stays valid
          // — dropping it here would strand committed-but-unconfirmed writes.
          // Only replaceable, in-progress state is discarded.
          state = {
            ...state,
            sessionId: event.sessionId,
            active: { user: null, assistant: null },
            awaiting: { user: null, assistant: null },
            preview: null,
          };
          return driveQueue();
        }
        // A different notebook: nothing from the previous one may carry over.
        state = { ...EMPTY_STATE, sessionId: event.sessionId, notebookId: event.notebookId };
        inFlight = null;
        return [];
      }

      case "sessionEnded": {
        state = {
          ...state,
          active: { user: null, assistant: null },
          awaiting: { user: null, assistant: null },
          preview: null,
        };
        assistantGate = null;
        return [];
      }

      case "interimTranscript": {
        if (!state.sessionId) return [];
        if (event.speaker === "assistant") {
          if (assistantGate === "collecting") return [];
          // Genuinely new speech ends the post-interruption gate.
          if (assistantGate === "awaitingNewTurn") assistantGate = null;
        }
        const base = ensureActive(event.speaker);
        // An authoritative final transcript already arrived; interim chatter
        // must not overwrite it.
        if (base.finalText !== null) return [];
        if (base.text === event.text) return [];

        const startProvisional =
          provisional &&
          event.speaker === "user" &&
          event.text.trim().length >= PROVISIONAL_MIN_CHARS;
        const next: ActiveTurn = {
          ...base,
          phase: "interim",
          text: event.text,
          transcriptVersion: base.transcriptVersion + 1,
          generation: startProvisional ? base.generation + 1 : base.generation,
        };
        setActive(event.speaker, next);
        if (!startProvisional) return [];

        const effects: TurnEffect[] = [];
        if (base.generation > 0) {
          effects.push({
            type: "cancelExtraction",
            turnId: base.turnId,
            generation: base.generation,
          });
        }
        // Provisional extraction is display-only. Nothing it returns may reach
        // the canonical graph, persistence, mention counts, or follow-ups.
        effects.push({ type: "startProvisionalExtraction", key: keyOf(next), text: event.text });
        return effects;
      }

      case "finalTranscript": {
        if (!state.sessionId) return [];
        // Unheard text for an interrupted assistant turn never becomes durable.
        if (event.speaker === "assistant" && assistantGate !== null) return [];

        const waiting = state.awaiting[event.speaker];
        if (waiting) {
          // Late authoritative text for a turn already marked complete.
          const resolved: ActiveTurn = {
            ...waiting,
            text: event.text,
            finalText: event.text,
            transcriptVersion: waiting.transcriptVersion + 1,
          };
          setAwaiting(event.speaker, resolved);
          return finalize(resolved, event.text, resolved.interrupted);
        }
        const base = ensureActive(event.speaker);
        setActive(event.speaker, {
          ...base,
          text: event.text,
          finalText: event.text,
          transcriptVersion: base.transcriptVersion + 1,
        });
        return [];
      }

      case "turnCompleted": {
        const active = state.active[event.speaker];
        if (event.speaker === "assistant" && assistantGate === "collecting") {
          assistantGate = "awaitingNewTurn";
        }
        if (!active) return [];

        // Interrupted with an undeterminable heard boundary: we cannot prove
        // which words reached the user, so none of them may be extracted.
        if (active.interrupted && active.heardChars === null) {
          setActive(event.speaker, null);
          return [];
        }

        const next: ActiveTurn = { ...active, turnCompleted: true, phase: "awaitingFinal" };
        setActive(event.speaker, null);
        if (next.finalText !== null) return finalize(next, next.finalText, next.interrupted);
        // No authoritative text yet. Park the turn and wait — but not forever.
        setAwaiting(event.speaker, next);
        return [
          {
            type: "scheduleFinalizationDeadline",
            speaker: event.speaker,
            turnId: next.turnId,
            transcriptGeneration: event.transcriptGeneration,
          },
        ];
      }

      case "finalizationDeadline": {
        const waiting = state.awaiting[event.speaker];
        // Already finalized by a late final transcript — no phantom turn.
        if (!waiting || waiting.turnId !== event.turnId) return [];
        return finalize(waiting, waiting.finalText ?? waiting.text, waiting.interrupted);
      }

      case "playbackAdvanced": {
        const active = state.active.assistant;
        if (!active || active.interrupted) return [];
        setActive("assistant", { ...active, heardChars: event.heardChars });
        return [];
      }

      case "assistantInterrupted": {
        const effects: TurnEffect[] = [{ type: "flushPlayback" }];
        assistantGate = "collecting";
        const active = state.active.assistant;
        if (!active) return effects;

        if (event.heardChars === null) {
          // Boundary unknown: keep the turn marked so turnCompleted discards it.
          setActive("assistant", {
            ...active,
            interrupted: true,
            heardChars: null,
            finalText: null,
          });
          return effects;
        }
        const heard = truncateToHeard(active.text, event.heardChars);
        setActive("assistant", {
          ...active,
          interrupted: true,
          heardChars: event.heardChars,
          text: heard,
          // Locking finalText here is what prevents later output transcription
          // from re-attaching the unheard tail.
          finalText: heard,
          transcriptVersion: active.transcriptVersion + 1,
        });
        return effects;
      }

      case "provisionalExtractionSettled": {
        const turn = findActive(event.key.turnId);
        if (
          !sessionMatches(event.key) ||
          !turn ||
          turn.transcriptVersion !== event.key.transcriptVersion ||
          turn.generation !== event.key.generation
        ) {
          return rejectStale();
        }
        // Display state only. Deliberately touches nothing else.
        state = { ...state, preview: event.preview };
        return [];
      }

      case "durableExtractionSucceeded": {
        const head = state.pending[0];
        // All five identity fields must still match the turn at the head of the
        // queue, and that turn must belong to the notebook currently open.
        // Cancellation is best-effort; THIS is the rule that decides whether a
        // result may change anything.
        if (
          !head ||
          head.notebookId !== state.notebookId ||
          head.turnId !== event.key.turnId ||
          head.sessionId !== event.key.sessionId ||
          head.notebookId !== event.key.notebookId ||
          head.transcriptVersion !== event.key.transcriptVersion ||
          head.generation !== event.key.generation
        ) {
          return rejectStale();
        }
        inFlight = null;
        // Store the result before committing: a restart here reuses it rather
        // than paying for — and possibly receiving a different — model result.
        const updated = replaceHead({ stage: "extracted", extraction: event.payload });
        return [{ type: "persistTurn", turn: updated }, ...driveQueue()];
      }

      case "durableExtractionFailed": {
        const head = state.pending[0];
        if (!head || head.turnId !== event.key.turnId || head.notebookId !== event.key.notebookId) {
          return rejectStale();
        }
        return dropHead();
      }

      case "commitStarted": {
        const head = state.pending[0];
        if (!head || head.turnId !== event.turnId) return rejectStale();
        replaceHead({ stage: "commitPending", baseRevision: event.baseRevision });
        return [];
      }

      case "commitCommitted": {
        const head = state.pending[0];
        if (!head || head.turnId !== event.turnId) return rejectStale();
        state = { ...state, revision: event.revision };
        return dropHead();
      }

      case "commitConflict": {
        const head = state.pending[0];
        if (!head || head.turnId !== event.turnId) return rejectStale();
        // A conflict performed no write, so no ledger row exists and the same
        // request id stays valid. Hold the queue until the authoritative
        // snapshot is back, then replay every pending turn in original order.
        state = { ...state, revision: event.currentRevision };
        return [{ type: "reloadSnapshot", turnId: head.turnId }];
      }

      case "snapshotReloaded": {
        state = { ...state, revision: event.revision };
        inFlight = null;
        if (state.pending.length > 0) replaceHead({ baseRevision: event.revision });
        return driveQueue();
      }

      case "commitUnknown": {
        const head = state.pending[0];
        if (!head || head.turnId !== event.turnId) return rejectStale();
        // Outcome genuinely unknown. Retry the identical commit with the same
        // request id: the server ledger replays the stored result if it already
        // committed, and applies it exactly once otherwise.
        inFlight = null;
        return driveQueue();
      }

      case "commitRejected": {
        const head = state.pending[0];
        if (!head || head.turnId !== event.turnId) return rejectStale();
        return dropHead();
      }

      case "restored": {
        const usable = event.turns.filter((turn) => turn.stage !== "committed");
        state = { ...state, pending: [...usable, ...state.pending] };
        return driveQueue();
      }

      default:
        return [];
    }
  }

  return {
    get state() {
      return state;
    },
    /**
     * Utterances still being transcribed or awaiting their authoritative
     * final, oldest first — display-only, never canonical. Merged with
     * `conversation` by `startedAt`, nothing vanishes between "the reply
     * started" and "the user's final arrived".
     */
    get inProgress(): ConversationTurn[] {
      return [
        state.awaiting.user,
        state.active.user,
        state.awaiting.assistant,
        state.active.assistant,
      ]
        .filter((turn): turn is ActiveTurn => turn != null && turn.text.trim() !== "")
        .map((turn) => ({
          turnId: turn.turnId,
          role: turn.speaker,
          text: turn.text.trim(),
          createdAt: turn.startedAt,
          startedAt: turn.startedAt,
        }))
        .sort((a, b) => compareInstants(a.startedAt, b.startedAt));
    },
    dispatch: reduce,
    checkpoint: () => structuredClone({ version: 1, state, inFlight, assistantGate }),
  };
}
