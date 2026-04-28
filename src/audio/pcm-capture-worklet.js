/* AudioWorklet processor: captures mono Float32 mic samples and emits 16-bit PCM
 * frames over the message port. Runs on the audio thread, so the main thread
 * only sees buffered Int16 ArrayBuffers ready to base64-encode for Gemini Live.
 *
 * Sample rate is whatever the host AudioContext is running at — caller is
 * expected to construct the AudioContext with sampleRate: 16000 so no
 * resampling is needed here.
 */

const FRAME_SIZE = 1024; // ~64ms at 16kHz; small enough for low latency, large enough not to flood WS.

class PcmCaptureProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buffer = new Int16Array(FRAME_SIZE);
    this.bufferIdx = 0;
  }

  process(inputs) {
    const input = inputs[0];
    if (!input || input.length === 0) return true;
    const channel = input[0];
    if (!channel) return true;

    for (let i = 0; i < channel.length; i += 1) {
      // Float32 (-1..1) → Int16 (-32768..32767)
      const sample = Math.max(-1, Math.min(1, channel[i]));
      this.buffer[this.bufferIdx++] = sample < 0 ? sample * 0x8000 : sample * 0x7fff;
      if (this.bufferIdx >= FRAME_SIZE) {
        // Transfer the underlying ArrayBuffer so we don't allocate per frame.
        const out = this.buffer.buffer;
        this.port.postMessage(out, [out]);
        this.buffer = new Int16Array(FRAME_SIZE);
        this.bufferIdx = 0;
      }
    }
    return true;
  }
}

registerProcessor("pcm-capture-processor", PcmCaptureProcessor);
