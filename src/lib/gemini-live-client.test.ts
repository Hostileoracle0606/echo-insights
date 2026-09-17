import { afterEach, describe, expect, it, vi } from "vitest";

import { GeminiLiveClient, type GeminiLiveEvents } from "./gemini-live-client";

class FakeWebSocket {
  static OPEN = 1;
  static instances: FakeWebSocket[] = [];

  readonly url: string;
  readyState = FakeWebSocket.OPEN;
  private listeners = new Map<string, Array<() => void>>();

  constructor(url: string) {
    this.url = url;
    FakeWebSocket.instances.push(this);
    queueMicrotask(() => this.emit("open"));
  }

  addEventListener(type: string, listener: () => void) {
    const listeners = this.listeners.get(type) ?? [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  send() {}
  close() {}

  /** Delivers one server frame as the socket would. */
  deliver(frame: unknown) {
    for (const listener of this.listeners.get("message") ?? [])
      (listener as unknown as (e: { data: string }) => void)({ data: JSON.stringify(frame) });
  }

  private emit(type: string) {
    for (const listener of this.listeners.get(type) ?? []) listener();
  }
}

describe("GeminiLiveClient", () => {
  afterEach(() => {
    FakeWebSocket.instances = [];
    vi.unstubAllGlobals();
  });

  it("connects with a temporary access token instead of a permanent API key", async () => {
    vi.stubGlobal("WebSocket", FakeWebSocket);
    const client = new GeminiLiveClient({
      sessionToken: "auth_tokens/temporary token",
      model: "gemini-3.1-flash-live-preview",
    });

    await client.connect();

    expect(FakeWebSocket.instances[0]?.url).toContain(
      "?access_token=auth_tokens%2Ftemporary%20token",
    );
    expect(FakeWebSocket.instances[0]?.url).toContain(
      ".GenerativeService.BidiGenerateContentConstrained?",
    );
    expect(FakeWebSocket.instances[0]?.url).not.toContain("?key=");
  });
});

describe("server-content event meanings", () => {
  afterEach(() => {
    FakeWebSocket.instances = [];
    vi.unstubAllGlobals();
  });

  async function connected(events: GeminiLiveEvents = {}) {
    vi.stubGlobal("WebSocket", FakeWebSocket);
    const client = new GeminiLiveClient(
      { sessionToken: "auth_tokens/t", model: "gemini-3.1-flash-live-preview" },
      events,
    );
    await client.connect();
    return FakeWebSocket.instances[0];
  }

  it("reports interim user transcription as replaceable text, not an append", async () => {
    const interim: string[] = [];
    const deltas: string[] = [];
    const socket = await connected({
      onInterimUserTranscript: (t) => interim.push(t),
      onUserTranscript: (t) => deltas.push(t),
    });

    socket.deliver({ serverContent: { interimInputTranscription: { text: "I work at Acne" } } });
    socket.deliver({ serverContent: { interimInputTranscription: { text: "I work at Acme" } } });

    expect(interim).toEqual(["I work at Acne", "I work at Acme"]);
    expect(deltas).toEqual([]);
  });

  it("distinguishes a finished input transcription from an incremental chunk", async () => {
    const finals: string[] = [];
    const deltas: string[] = [];
    const socket = await connected({
      onFinalUserTranscript: (t) => finals.push(t),
      onUserTranscript: (t) => deltas.push(t),
    });

    socket.deliver({ serverContent: { inputTranscription: { text: "I work at " } } });
    socket.deliver({ serverContent: { inputTranscription: { text: "Acme.", finished: true } } });

    expect(deltas).toEqual(["I work at "]);
    expect(finals).toEqual(["Acme."]);
  });

  it("emits interruption before turn completion, and generationComplete separately", async () => {
    const order: string[] = [];
    const socket = await connected({
      onInterrupted: () => order.push("interrupted"),
      onTurnComplete: () => order.push("turnComplete"),
      onGenerationComplete: () => order.push("generationComplete"),
    });

    socket.deliver({ serverContent: { generationComplete: true } });
    socket.deliver({ serverContent: { interrupted: true, turnComplete: true } });

    expect(order).toEqual(["generationComplete", "interrupted", "turnComplete"]);
  });
});
