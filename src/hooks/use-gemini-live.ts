import { useCallback, useEffect, useRef, useState } from "react";

import {
  GeminiLiveClient,
  type GeminiFunctionDeclaration,
  type GeminiLiveConfig,
  type GeminiToolCall,
  type GeminiVoice,
} from "@/lib/gemini-live-client";
import type { StartLiveSessionOutcome } from "@/lib/notebook-runtime-contract";
import { PcmPlayer } from "@/lib/audio/pcm-player";

import { createTranscriptAssembler } from "@/lib/turn-state/transcript-assembler";
import type { TurnEvent } from "@/lib/turn-state/types";

import captureWorkletUrl from "@/audio/pcm-capture-worklet.js?url";

type MicPermissionState = PermissionState | "unknown" | "unsupported";

interface Options {
  /** Requests a one-use live credential for the active notebook. */
  startLiveSession?: () => Promise<StartLiveSessionOutcome>;
  systemInstruction?: string;
  voice?: GeminiVoice;
  /** Server-side VAD silence threshold. Higher = more patience for thoughtful pauses. */
  silenceDurationMs?: number;
  /** Fired with every incremental user transcript chunk Gemini emits. */
  onUserTranscript?: (chunk: string) => void;
  onAgentTranscript?: (chunk: string) => void;
  /**
   * The turn-state event stream. This replaced the old `onUserSentence`
   * callback, which fired per sentence boundary with the cumulative
   * turn-so-far and let each fire drive a full extract → merge → commit —
   * so sentence one could commit, and then sentence one *plus* two could
   * commit again over the top of it.
   *
   * Events here carry meaning instead: interim text is replaceable, and only
   * an explicit finalization authorizes a durable write.
   */
  onTurnEvent?: (event: TurnEvent) => void;
  /** User barge-in detected by Gemini's VAD; pending agent audio was flushed. */
  onInterrupted?: () => void;
  /**
   * Function declarations the model can invoke. Registered once at setup —
   * changing this array between sessions takes effect on next start().
   */
  tools?: GeminiFunctionDeclaration[];
  /**
   * Async handler invoked when the model calls one of the registered tools.
   * Return value (or its resolved value if a Promise) is sent back as the
   * tool response. Throwing returns `{ error: <message> }` to the model so
   * the dialogue can recover instead of stalling.
   */
  onToolCall?: (call: GeminiToolCall) => unknown | Promise<unknown>;
  onError?: (message: string) => void;
}

const TARGET_SAMPLE_RATE = 16000;

export interface UseGeminiLive {
  supported: boolean;
  permissionState: MicPermissionState;
  /** Has the WebSocket completed setup and is ready to stream? */
  ready: boolean;
  /** Is the mic currently open and streaming to Gemini? */
  listening: boolean;
  /** Is Gemini currently producing audio (i.e. the agent is talking)? */
  speaking: boolean;
  /** Live transcript of what the user just said (cleared on each new turn). */
  userTranscript: string;
  /** Live transcript of what the agent is saying (cleared on each new turn). */
  agentTranscript: string;
  error: string | null;
  /** True when agent voice playback is muted (player volume = 0). */
  muted: boolean;
  start: () => Promise<boolean>;
  stop: () => void;
  /** Send a typed user turn (used by the dock keyboard input). */
  sendText: (text: string) => void;
  /** Manually interrupt the agent's speech (e.g. Esc key). */
  interruptAgent: () => void;
  setMuted: (value: boolean) => void;
}

export function useGeminiLive(opts: Options = {}): UseGeminiLive {
  const [supported, setSupported] = useState(false);
  const [permissionState, setPermissionState] = useState<MicPermissionState>("unknown");
  const [ready, setReady] = useState(false);
  const [listening, setListening] = useState(false);
  const [speaking, setSpeaking] = useState(false);
  const [userTranscript, setUserTranscript] = useState("");
  const [agentTranscript, setAgentTranscript] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [muted, setMutedState] = useState(false);

  // Latest callbacks via refs so the start() closure stays stable.
  const optsRef = useRef(opts);
  optsRef.current = opts;

  const clientRef = useRef<GeminiLiveClient | null>(null);
  const playerRef = useRef<PcmPlayer | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const audioCtxRef = useRef<AudioContext | null>(null);
  const sourceNodeRef = useRef<MediaStreamAudioSourceNode | null>(null);
  const workletNodeRef = useRef<AudioWorkletNode | null>(null);

  // True once Gemini's setup-complete frame has arrived. Used by onClose to
  // distinguish a server-side rejection (closed BEFORE setup) from a normal
  // disconnect (closed AFTER setup). The first case usually means the API
  // temporary credential, quota, or model name is wrong and deserves a louder error.
  const setupCompletedRef = useRef(false);

  // Turn assembly lives in a pure, platform-free module so web and Flutter
  // apply the same rules; the hook only owns audio and React state.
  const assemblerRef = useRef(createTranscriptAssembler());
  const agentBufferRef = useRef("");
  /**
   * Playback watermark: characters of agent text whose audio has actually
   * been played. Driven by the same audio-clock reveal that lip-syncs the
   * transcript, so it is a measurement rather than an estimate.
   */
  const agentHeardCharsRef = useRef(0);
  /** True when no audio clock was available, so "heard" cannot be determined. */
  const agentHeardUnknownRef = useRef(false);

  // Lip-sync the visible agent transcript to the audio playback clock. Each
  // text chunk arrives over the same WebSocket as audio, but text lands in
  // React state instantly while audio rides PcmPlayer's scheduled queue —
  // so without this, transcript runs ahead of speech by the audio buffer
  // depth (often 1-3 seconds). We snapshot the buffer at arrival paired
  // with the player's scheduledTail (audio-context time when the just-
  // queued audio finishes), and a rAF loop reveals each snapshot once
  // currentTime catches up. Result: words appear as they're spoken.
  const agentRevealQueueRef = useRef<Array<{ snapshot: string; revealAt: number }>>([]);
  const agentRevealRafRef = useRef<number | null>(null);

  const cancelAgentReveal = useCallback(() => {
    if (agentRevealRafRef.current !== null) {
      cancelAnimationFrame(agentRevealRafRef.current);
      agentRevealRafRef.current = null;
    }
    agentRevealQueueRef.current = [];
  }, []);

  const tickAgentReveal = useCallback(() => {
    agentRevealRafRef.current = null;
    const player = playerRef.current;
    const queue = agentRevealQueueRef.current;
    if (!player || queue.length === 0) return;
    const now = player.getCurrentTime();
    let revealed: string | null = null;
    while (queue.length > 0 && queue[0].revealAt <= now) {
      revealed = queue.shift()!.snapshot;
    }
    if (revealed !== null) {
      setAgentTranscript(revealed);
      // This text's audio has now been played: advance the heard watermark.
      agentHeardCharsRef.current = revealed.length;
      optsRef.current.onTurnEvent?.({
        type: "playbackAdvanced",
        heardChars: revealed.length,
      });
    }
    if (queue.length > 0) {
      agentRevealRafRef.current = requestAnimationFrame(tickAgentReveal);
    }
  }, []);

  const scheduleAgentReveal = useCallback(() => {
    if (agentRevealRafRef.current !== null) return;
    agentRevealRafRef.current = requestAnimationFrame(tickAgentReveal);
  }, [tickAgentReveal]);

  useEffect(() => {
    const ok =
      typeof window !== "undefined" &&
      typeof WebSocket !== "undefined" &&
      typeof AudioContext !== "undefined" &&
      Boolean(navigator.mediaDevices?.getUserMedia) &&
      Boolean(opts.startLiveSession);
    setSupported(ok);
  }, [opts.startLiveSession]);

  useEffect(() => {
    if (typeof navigator === "undefined" || !navigator.permissions?.query) return;
    let mounted = true;
    let status: PermissionStatus | null = null;
    navigator.permissions
      .query({ name: "microphone" as PermissionName })
      .then((s) => {
        if (!mounted) return;
        status = s;
        setPermissionState(s.state);
        s.onchange = () => setPermissionState(s.state);
      })
      .catch(() => setPermissionState("unknown"));
    return () => {
      mounted = false;
      if (status) status.onchange = null;
    };
  }, []);

  const teardown = useCallback(async () => {
    try {
      workletNodeRef.current?.disconnect();
    } catch {
      /* ignore */
    }
    workletNodeRef.current = null;

    try {
      sourceNodeRef.current?.disconnect();
    } catch {
      /* ignore */
    }
    sourceNodeRef.current = null;

    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;

    if (audioCtxRef.current) {
      try {
        await audioCtxRef.current.close();
      } catch {
        /* ignore */
      }
      audioCtxRef.current = null;
    }

    clientRef.current?.close();
    clientRef.current = null;

    if (playerRef.current) {
      await playerRef.current.dispose();
      playerRef.current = null;
    }

    setListening(false);
    setReady(false);
    setSpeaking(false);
    agentBufferRef.current = "";
    agentHeardCharsRef.current = 0;
    agentHeardUnknownRef.current = false;
    assemblerRef.current.reset();
    // A torn-down session can no longer publish into a new one.
    optsRef.current.onTurnEvent?.({ type: "sessionEnded" });
    cancelAgentReveal();
  }, [cancelAgentReveal]);

  useEffect(() => {
    return () => {
      void teardown();
    };
  }, [teardown]);

  const start = useCallback(async (): Promise<boolean> => {
    setError(null);
    if (clientRef.current) return true;

    const requestLiveSession = optsRef.current.startLiveSession;
    if (!requestLiveSession) {
      setError("The secure live-session route is not configured.");
      return false;
    }

    let stream: MediaStream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, channelCount: 1 },
      });
      setPermissionState("granted");
    } catch (err) {
      if (err instanceof DOMException) {
        if (err.name === "NotAllowedError" || err.name === "SecurityError") {
          setPermissionState("denied");
          setError("Microphone permission is blocked. Allow microphone access and try again.");
          return false;
        }
        if (err.name === "NotFoundError") {
          setError("No microphone was found.");
          return false;
        }
      }
      setError("Microphone access failed.");
      return false;
    }
    streamRef.current = stream;

    let audioCtx: AudioContext;
    try {
      // Prefer 16kHz native — eliminates resampling. Falls back to default if unsupported.
      audioCtx = new AudioContext({ sampleRate: TARGET_SAMPLE_RATE });
    } catch {
      audioCtx = new AudioContext();
    }
    audioCtxRef.current = audioCtx;

    try {
      await audioCtx.audioWorklet.addModule(captureWorkletUrl);
    } catch (err) {
      console.error("[gemini-live] worklet load failed", err);
      setError("Audio worklet failed to load.");
      await teardown();
      return false;
    }

    const player = new PcmPlayer();
    playerRef.current = player;
    await player.resume();
    player.onSpeakingChange(setSpeaking);
    if (muted) player.setVolume(0);

    let liveSession: StartLiveSessionOutcome;
    try {
      liveSession = await requestLiveSession();
    } catch (err) {
      console.error("[gemini-live] temporary credential request failed", err);
      setError("Could not start a secure live session. Please sign in again and retry.");
      await teardown();
      return false;
    }
    if (liveSession.status === "rejected") {
      const message =
        liveSession.code === "notFound"
          ? "The active notebook is no longer available."
          : liveSession.code === "rateLimited"
            ? "Too many live sessions were started. Wait a moment and retry."
            : "The live voice provider is temporarily unavailable.";
      setError(message);
      await teardown();
      return false;
    }

    const config: GeminiLiveConfig = {
      sessionToken: liveSession.sessionToken,
      model: liveSession.model,
      systemInstruction: optsRef.current.systemInstruction,
      voice: optsRef.current.voice ?? "Aoede",
      silenceDurationMs: optsRef.current.silenceDurationMs ?? 1200,
      tools: optsRef.current.tools,
    };

    setupCompletedRef.current = false;
    assemblerRef.current = createTranscriptAssembler();
    const emit = (events: TurnEvent[]) => {
      for (const event of events) {
        if (event.type === "interimTranscript" && event.speaker === "user") {
          setUserTranscript(event.text);
        }
        optsRef.current.onTurnEvent?.(event);
      }
    };
    const client = new GeminiLiveClient(config, {
      onSetupComplete: () => {
        setupCompletedRef.current = true;
        setReady(true);
      },
      onAgentAudio: (chunk) => {
        playerRef.current?.enqueue(chunk);
      },
      onUserTranscript: (chunk) => {
        optsRef.current.onUserTranscript?.(chunk);
        emit(assemblerRef.current.userChunk(chunk));
      },
      onInterimUserTranscript: (text) => {
        // Provider revised its own guess: replace, never append.
        emit(assemblerRef.current.userInterim(text));
      },
      onFinalUserTranscript: (text) => {
        emit(assemblerRef.current.userFinal(text));
        setUserTranscript("");
      },
      onAgentTranscript: (chunk) => {
        agentBufferRef.current += chunk;
        const snapshot = agentBufferRef.current;
        const player = playerRef.current;
        // If the player isn't ready (very early chunk before resume) or no
        // audio is queued ahead, reveal immediately — there's nothing to
        // sync against. Otherwise pair the snapshot with the audio's
        // scheduled tail at this moment: the just-arrived text corresponds
        // to audio that lands at or just before that timestamp.
        if (!player) {
          setAgentTranscript(snapshot);
          // With no audio clock we cannot prove what was heard.
          agentHeardUnknownRef.current = true;
        } else {
          const now = player.getCurrentTime();
          const tail = player.getScheduledTail();
          const revealAt = Math.max(now, tail);
          if (revealAt <= now) {
            setAgentTranscript(snapshot);
            agentHeardCharsRef.current = snapshot.length;
          } else {
            agentRevealQueueRef.current.push({ snapshot, revealAt });
            scheduleAgentReveal();
          }
        }
        optsRef.current.onAgentTranscript?.(chunk);
        emit(assemblerRef.current.assistantChunk(chunk));
      },
      onFinalAgentTranscript: (text) => {
        emit(assemblerRef.current.assistantFinal(text));
      },
      onTurnComplete: () => {
        emit(assemblerRef.current.turnComplete());
        agentBufferRef.current = "";
        agentHeardCharsRef.current = 0;
        agentHeardUnknownRef.current = false;
        cancelAgentReveal();
        setUserTranscript("");
        setAgentTranscript("");
      },
      onInterrupted: () => {
        playerRef.current?.flush();
        // Only the words whose audio actually played may be finalized. When
        // no audio clock was available the boundary is reported as unknown,
        // and the turn is skipped for durable extraction entirely.
        const heardChars = agentHeardUnknownRef.current ? null : agentHeardCharsRef.current;
        emit(assemblerRef.current.interrupted(heardChars));
        agentBufferRef.current = "";
        cancelAgentReveal();
        setAgentTranscript("");
        optsRef.current.onInterrupted?.();
      },
      onToolCall: (call) => {
        // Run handler async; the model is paused until we respond, so we
        // must always send something back — even an error envelope — to
        // unblock the turn. Without this guarantee, an unhandled exception
        // would leave the dialogue silently hung.
        const handler = optsRef.current.onToolCall;
        if (!handler) {
          console.warn("[gemini-live] toolCall received but no handler registered:", call.name);
          clientRef.current?.respondToTool(call.id, call.name, {
            error: `No handler registered for tool '${call.name}'`,
          });
          return;
        }
        void Promise.resolve()
          .then(() => handler(call))
          .then((result) => {
            clientRef.current?.respondToTool(call.id, call.name, result ?? {});
          })
          .catch((err: unknown) => {
            const message = err instanceof Error ? err.message : String(err);
            console.error("[gemini-live] toolCall handler threw", call.name, err);
            clientRef.current?.respondToTool(call.id, call.name, { error: message });
          });
      },
      onError: (message) => {
        setError(message);
        optsRef.current.onError?.(message);
      },
      onClose: (info) => {
        // Always log the raw close frame — invaluable when Gemini drops
        // the connection silently (rate limit, quota, model rejection
        // typically arrive as a clean close with a code in the 1006/1008
        // range or a custom 4xxx).
        console.warn("[gemini-live] WebSocket closed", info);
        // If the close arrives BEFORE setup-complete, the server rejected
        // the session — a normal close after setup is just the user
        // hanging up. Surface a louder message in the rejection case so
        // the dock doesn't silently collapse into the dynamic-island
        // shrink animation with no explanation.
        if (!setupCompletedRef.current) {
          const reason = info.reason?.trim();
          const message = reason
            ? `Gemini Live closed before setup completed (code ${info.code}): ${reason}`
            : `Gemini Live closed before setup completed (code ${info.code}). Likely a rate limit, quota, or expired temporary credential.`;
          setError(message);
          optsRef.current.onError?.(message);
        }
        setReady(false);
        setListening(false);
        // Server-initiated close (rate limit, idle timeout, daily quota).
        // Run the full teardown so the next mic click can build a fresh
        // client — otherwise clientRef.current still holds the dead one
        // and start()'s `if (clientRef.current) return true` guard turns
        // the click into a no-op. teardown is idempotent and the
        // underlying client.close() is guarded by `this.closed`, so the
        // call back through teardown→client.close→ws-close→onClose can't
        // recurse meaningfully.
        void teardown();
      },
    });
    clientRef.current = client;

    try {
      await client.connect();
    } catch (err) {
      console.error("[gemini-live] connect failed", err);
      setError(err instanceof Error ? err.message : "Could not connect to Gemini Live.");
      await teardown();
      return false;
    }

    const sourceNode = audioCtx.createMediaStreamSource(stream);
    const workletNode = new AudioWorkletNode(audioCtx, "pcm-capture-processor");
    workletNode.port.onmessage = (event) => {
      const buffer = event.data as ArrayBuffer;
      clientRef.current?.sendAudio(buffer);
    };
    sourceNode.connect(workletNode);
    sourceNodeRef.current = sourceNode;
    workletNodeRef.current = workletNode;

    setListening(true);
    return true;
  }, [teardown, muted, cancelAgentReveal, scheduleAgentReveal]);

  const stop = useCallback(() => {
    void teardown();
  }, [teardown]);

  const sendText = useCallback((text: string) => {
    const trimmed = text.trim();
    if (!trimmed) return;
    clientRef.current?.sendText(trimmed);
  }, []);

  const interruptAgent = useCallback(() => {
    playerRef.current?.flush();
    cancelAgentReveal();
  }, [cancelAgentReveal]);

  const setMuted = useCallback((value: boolean) => {
    setMutedState(value);
    playerRef.current?.setVolume(value ? 0 : 1);
  }, []);

  return {
    supported,
    permissionState,
    ready,
    listening,
    speaking,
    userTranscript,
    agentTranscript,
    error,
    muted,
    start,
    stop,
    sendText,
    interruptAgent,
    setMuted,
  };
}
