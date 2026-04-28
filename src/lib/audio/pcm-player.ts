/**
 * Streaming PCM playback for Gemini Live's 24kHz Int16 output.
 *
 * Each incoming chunk is scheduled to start where the last one ended, using the
 * AudioContext's own clock. AudioBufferSourceNode is single-use, so we create
 * one per chunk and rely on the browser's GC + onended cleanup.
 *
 * Why not an AudioWorklet for output: chained AudioBufferSourceNodes are simpler,
 * have well-defined timing semantics, and the latency penalty is the worklet's
 * ~3ms render quantum — irrelevant compared to network jitter.
 */

const OUTPUT_SAMPLE_RATE = 24000;

export class PcmPlayer {
  private ctx: AudioContext;
  private gainNode: GainNode;
  /** Audio-clock time at which the next scheduled chunk should start. */
  private nextStartTime = 0;
  private active = new Set<AudioBufferSourceNode>();
  private speakingListeners = new Set<(speaking: boolean) => void>();
  private wasSpeaking = false;

  constructor() {
    this.ctx = new AudioContext();
    this.gainNode = this.ctx.createGain();
    this.gainNode.connect(this.ctx.destination);
  }

  /** Required: must be called inside a user gesture handler before first play. */
  async resume(): Promise<void> {
    if (this.ctx.state === "suspended") {
      await this.ctx.resume();
    }
  }

  /** Push a chunk of 24kHz Int16 PCM (little-endian) for playback. */
  enqueue(pcm16: ArrayBuffer): void {
    const samples = new Int16Array(pcm16);
    if (samples.length === 0) return;

    const audioBuffer = this.ctx.createBuffer(1, samples.length, OUTPUT_SAMPLE_RATE);
    const channel = audioBuffer.getChannelData(0);
    for (let i = 0; i < samples.length; i += 1) {
      channel[i] = samples[i] / (samples[i] < 0 ? 0x8000 : 0x7fff);
    }

    const source = this.ctx.createBufferSource();
    source.buffer = audioBuffer;
    source.connect(this.gainNode);

    // Schedule the chunk: at currentTime if we're behind (drained), otherwise
    // exactly where the last chunk ends. This keeps streamed audio gapless
    // while gracefully recovering from network stalls.
    const startAt = Math.max(this.ctx.currentTime, this.nextStartTime);
    source.start(startAt);
    this.nextStartTime = startAt + audioBuffer.duration;

    this.active.add(source);
    if (!this.wasSpeaking) {
      this.wasSpeaking = true;
      this.speakingListeners.forEach((fn) => fn(true));
    }

    source.onended = () => {
      this.active.delete(source);
      if (this.active.size === 0 && this.wasSpeaking) {
        this.wasSpeaking = false;
        this.speakingListeners.forEach((fn) => fn(false));
      }
    };
  }

  /** Drop any queued/playing audio immediately. Used on barge-in. */
  flush(): void {
    for (const source of this.active) {
      try {
        source.onended = null;
        source.stop();
      } catch {
        /* node may have already finished */
      }
    }
    this.active.clear();
    this.nextStartTime = this.ctx.currentTime;
    if (this.wasSpeaking) {
      this.wasSpeaking = false;
      this.speakingListeners.forEach((fn) => fn(false));
    }
  }

  onSpeakingChange(listener: (speaking: boolean) => void): () => void {
    this.speakingListeners.add(listener);
    return () => this.speakingListeners.delete(listener);
  }

  setVolume(value: number): void {
    this.gainNode.gain.value = Math.max(0, Math.min(1, value));
  }

  /** Audio-context current time. Same clock as scheduled chunk start times,
   * so consumers can compare against snapshots of getScheduledTail() to
   * sync external timelines (e.g. transcript reveal) with playback. */
  getCurrentTime(): number {
    return this.ctx.currentTime;
  }

  /** Time at which the last enqueued chunk will finish — i.e. the leading
   * edge of the playback buffer. A transcript chunk arriving "now" pairs
   * with audio that will be heard between roughly the previous tail and
   * this value. Snapshot this on transcript arrival, then reveal text when
   * getCurrentTime() catches up. */
  getScheduledTail(): number {
    return this.nextStartTime;
  }

  async dispose(): Promise<void> {
    this.flush();
    this.speakingListeners.clear();
    try {
      await this.ctx.close();
    } catch {
      /* ignore */
    }
  }
}
