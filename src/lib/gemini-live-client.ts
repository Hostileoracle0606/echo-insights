/**
 * Raw WebSocket client for the Gemini Live API.
 *
 * Why raw WS instead of @google/genai: the SDK pulls in ~200KB. The protocol
 * is a small set of JSON messages over wss; rolling our own keeps the deploy
 * thin.
 *
 * Protocol summary:
 *   - setup            (client → server, once, immediately on open)
 *   - realtimeInput    (client → server, audio chunks while user is talking)
 *   - clientContent    (client → server, text turns or session-start kicks)
 *   - serverContent    (server → client, transcripts, audio chunks, turn signals)
 *   - toolCall         (server → client, when the model invokes a tool)
 *   - toolResponse     (client → server, response to a toolCall)
 *
 * Audio formats are fixed by Gemini Live:
 *   - Input:  16-bit PCM little-endian, 16kHz mono, base64-encoded
 *   - Output: 16-bit PCM little-endian, 24kHz mono, base64-encoded
 */

const ENDPOINT_BASE =
  "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";

export type GeminiVoice = "Aoede" | "Charon" | "Fenrir" | "Kore" | "Puck";

/**
 * Function declaration in the shape Gemini Live's setup expects.
 * `parameters` follows OpenAPI 3.0 schema with UPPERCASE type names
 * ("OBJECT", "STRING", "ARRAY", ...) — that's a quirk of this API
 * compared to OpenAI's lowercase JSON Schema.
 */
export interface GeminiFunctionDeclaration {
  name: string;
  description?: string;
  parameters?: Record<string, unknown>;
}

export interface GeminiToolCall {
  id: string;
  name: string;
  args: Record<string, unknown>;
}

export interface GeminiLiveConfig {
  apiKey: string;
  /** Model ID, e.g. "gemini-3.1-flash-live-preview". */
  model: string;
  /** System instruction text — the agent's persona/policy. */
  systemInstruction?: string;
  /**
   * Function declarations the model can invoke during the session. When
   * provided, the model will emit `toolCall` messages and pause its turn
   * until we respond with `respondToTool`.
   */
  tools?: GeminiFunctionDeclaration[];
  voice?: GeminiVoice;
  /**
   * Server-side VAD tuning. Live's automatic activity detection handles
   * turn-taking for us; tweak silenceDurationMs upward (e.g. 1200) if the
   * model still cuts the user off mid-thought.
   */
  silenceDurationMs?: number;
  /**
   * VAD sensitivity. Gemini Live only accepts these prefixed enum values —
   * passing "LOW"/"MEDIUM"/"HIGH" (unprefixed) closes the WS with code 1007.
   * There is no MEDIUM tier — pick LOW or HIGH.
   */
  startOfSpeechSensitivity?:
    | "START_SENSITIVITY_LOW"
    | "START_SENSITIVITY_HIGH"
    | "START_SENSITIVITY_UNSPECIFIED";
  endOfSpeechSensitivity?:
    | "END_SENSITIVITY_LOW"
    | "END_SENSITIVITY_HIGH"
    | "END_SENSITIVITY_UNSPECIFIED";
}

export interface GeminiLiveEvents {
  onSetupComplete?: () => void;
  /** Raw 24kHz PCM audio chunk from the agent. Base64-decoded ArrayBuffer. */
  onAgentAudio?: (chunk: ArrayBuffer) => void;
  /** Partial or final user-side transcript. */
  onUserTranscript?: (text: string) => void;
  /** Partial or final agent-side transcript. */
  onAgentTranscript?: (text: string) => void;
  /** Server signals the model finished speaking this turn. */
  onTurnComplete?: () => void;
  /**
   * Server detected the user started speaking while the agent was speaking;
   * any agent audio still in our playback queue should be flushed.
   */
  onInterrupted?: () => void;
  /**
   * Model invoked a registered tool. The handler must call `respondToTool`
   * with the same id/name to unblock the model's turn.
   */
  onToolCall?: (call: GeminiToolCall) => void;
  onError?: (message: string) => void;
  onClose?: (info: { code: number; reason: string; wasClean: boolean }) => void;
}

const base64ToArrayBuffer = (b64: string): ArrayBuffer => {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
};

const arrayBufferToBase64 = (buffer: ArrayBuffer): string => {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  // chunk to avoid String.fromCharCode argument limits
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
};

export class GeminiLiveClient {
  private ws: WebSocket | null = null;
  private setupSent = false;
  private closed = false;

  constructor(
    private readonly config: GeminiLiveConfig,
    private readonly events: GeminiLiveEvents = {},
  ) {}

  get isOpen(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  async connect(): Promise<void> {
    if (this.ws) return;
    const url = `${ENDPOINT_BASE}?key=${encodeURIComponent(this.config.apiKey)}`;
    const ws = new WebSocket(url);
    this.ws = ws;

    const opened = new Promise<void>((resolve, reject) => {
      const failTimer = setTimeout(() => reject(new Error("Gemini Live connect timeout")), 8000);
      ws.addEventListener("open", () => {
        clearTimeout(failTimer);
        resolve();
      }, { once: true });
      ws.addEventListener("error", () => {
        clearTimeout(failTimer);
        reject(new Error("Gemini Live WebSocket error during connect"));
      }, { once: true });
    });

    ws.addEventListener("message", (event) => this.handleMessage(event));
    ws.addEventListener("close", (event) => {
      this.closed = true;
      this.events.onClose?.({
        code: event.code,
        reason: event.reason,
        wasClean: event.wasClean,
      });
    });
    ws.addEventListener("error", () => {
      this.events.onError?.("Gemini Live WebSocket error");
    });

    await opened;
    this.sendSetup();
  }

  private sendSetup() {
    if (!this.ws || this.setupSent) return;
    const setup: Record<string, unknown> = {
      model: this.config.model.startsWith("models/")
        ? this.config.model
        : `models/${this.config.model}`,
      generationConfig: {
        responseModalities: ["AUDIO"],
        speechConfig: {
          voiceConfig: {
            prebuiltVoiceConfig: { voiceName: this.config.voice ?? "Aoede" },
          },
        },
      },
      inputAudioTranscription: {},
      outputAudioTranscription: {},
      realtimeInputConfig: {
        automaticActivityDetection: {
          startOfSpeechSensitivity:
            this.config.startOfSpeechSensitivity ?? "START_SENSITIVITY_LOW",
          endOfSpeechSensitivity: this.config.endOfSpeechSensitivity ?? "END_SENSITIVITY_LOW",
          silenceDurationMs: this.config.silenceDurationMs ?? 1200,
          prefixPaddingMs: 200,
        },
      },
    };
    if (this.config.systemInstruction) {
      setup.systemInstruction = {
        parts: [{ text: this.config.systemInstruction }],
      };
    }
    if (this.config.tools && this.config.tools.length > 0) {
      // Live API expects tools as an array of tool groups, each containing
      // a `functionDeclarations` array. We surface a flat list to callers
      // and wrap into the protocol shape here.
      setup.tools = [{ functionDeclarations: this.config.tools }];
    }
    this.ws.send(JSON.stringify({ setup }));
    this.setupSent = true;
  }

  /**
   * Reply to a `toolCall` from the model. Must be called for every call id
   * the model emits, otherwise the model's turn will hang waiting for the
   * tool result. `response` is the structured payload; we wrap it into the
   * `{ result: ... }` envelope the API expects.
   */
  respondToTool(id: string, name: string, response: unknown) {
    if (!this.isOpen) return;
    this.ws!.send(
      JSON.stringify({
        toolResponse: {
          functionResponses: [
            { id, name, response: { result: response } },
          ],
        },
      }),
    );
  }

  /** Send a 16kHz PCM audio chunk. ArrayBuffer of little-endian Int16 samples. */
  sendAudio(pcm16: ArrayBuffer) {
    if (!this.isOpen) return;
    const b64 = arrayBufferToBase64(pcm16);
    this.ws!.send(
      JSON.stringify({
        realtimeInput: {
          audio: { data: b64, mimeType: "audio/pcm;rate=16000" },
        },
      }),
    );
  }

  /**
   * Send a text turn from the user. Used for the dock typing path and for
   * kicking the agent on session-start ("introduce yourself").
   *
   * IMPORTANT: gemini-3.1-flash-live-preview silently ignores `clientContent`
   * text turns — it only responds to `realtimeInput.text` (the streaming
   * counterpart of `realtimeInput.audio`). Older models like
   * gemini-2.5-flash-native-audio accept either path, so realtimeInput.text
   * is the safer default. The model treats one realtimeInput.text frame as a
   * complete user turn and emits an audio response.
   */
  sendText(text: string, _opts: { turnComplete?: boolean } = {}) {
    if (!this.isOpen) return;
    this.ws!.send(JSON.stringify({ realtimeInput: { text } }));
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    try {
      this.ws?.close();
    } catch {
      /* ignore */
    }
    this.ws = null;
  }

  private handleMessage(event: MessageEvent) {
    let parsed: unknown;
    try {
      // Gemini Live sometimes ships frames as Blob; handle both.
      if (typeof event.data === "string") {
        parsed = JSON.parse(event.data);
      } else if (event.data instanceof Blob) {
        // Defer Blob handling — we re-fire after FileReader.
        event.data.text().then((text) => {
          try {
            this.dispatchMessage(JSON.parse(text));
          } catch (e) {
            console.warn("[gemini-live] failed to parse Blob frame", e);
          }
        });
        return;
      } else {
        return;
      }
    } catch (e) {
      console.warn("[gemini-live] failed to parse frame", e);
      return;
    }
    this.dispatchMessage(parsed);
  }

  private dispatchMessage(msg: unknown) {
    if (!msg || typeof msg !== "object") return;
    const m = msg as Record<string, any>;

    if (m.setupComplete) {
      this.events.onSetupComplete?.();
      return;
    }

    const sc = m.serverContent;
    if (sc) {
      // Audio chunks live under modelTurn.parts[].inlineData.data
      const parts = sc.modelTurn?.parts ?? [];
      for (const part of parts) {
        const inline = part?.inlineData;
        if (inline?.data) {
          try {
            this.events.onAgentAudio?.(base64ToArrayBuffer(inline.data));
          } catch (e) {
            console.warn("[gemini-live] failed to decode agent audio", e);
          }
        }
      }
      const inputText: string | undefined = sc.inputTranscription?.text;
      if (inputText) this.events.onUserTranscript?.(inputText);
      const outputText: string | undefined = sc.outputTranscription?.text;
      if (outputText) this.events.onAgentTranscript?.(outputText);
      if (sc.interrupted) this.events.onInterrupted?.();
      if (sc.turnComplete) this.events.onTurnComplete?.();
      return;
    }

    if (m.toolCall) {
      const calls = (m.toolCall.functionCalls ?? []) as Array<{
        id: string;
        name: string;
        args?: Record<string, unknown>;
      }>;
      for (const call of calls) {
        if (!call?.id || !call?.name) continue;
        this.events.onToolCall?.({
          id: call.id,
          name: call.name,
          args: call.args ?? {},
        });
      }
      return;
    }

    if (m.error) {
      const message = typeof m.error === "string" ? m.error : JSON.stringify(m.error);
      this.events.onError?.(message);
    }
  }
}
