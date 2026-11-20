import { concealedSample } from "./concealment.js";
import { PacketJitterBuffer } from "./jitter-buffer.js";
import { decodeSample } from "./mulaw.js";
import { SampleClockUpsampler } from "./upsample.js";

const FRAME_SAMPLES = 160;

// Plays 20 ms PCMU frames from the jitter buffer. Every frame, played, concealed or
// waiting, lasts exactly 160 samples at 8 kHz so the buffer is polled once per frame.
class SoundPlaybackProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buffer = new PacketJitterBuffer(3);
    this.clock = new SampleClockUpsampler(sampleRate, 8000);
    this.frame = null;
    this.previousFrame = new Uint8Array(FRAME_SAMPLES);
    this.hasPreviousFrame = false;
    this.index = FRAME_SAMPLES;
    this.mode = "waiting";
    this.strategy = "silence";
    this.sample = 0;
    this.peak = 0;
    this.level = { type: "level", peak: 0, mode: "waiting" };
    this.counters = { type: "buffer", generation: 0, state: "buffering", received: 0, concealed: 0, lateDiscarded: 0, recoveries: 0 };
    this.port.onmessage = ({ data }) => {
      if (data?.type === "packet") {
        this.buffer.push(data.buffer);
        this.report();
      } else if (data?.type === "reset") {
        this.buffer.reset(data.ssrc ?? null);
        this.counters.generation = data.generation ?? this.counters.generation;
        this.frame = null;
        this.hasPreviousFrame = false;
        this.index = FRAME_SAMPLES;
        this.mode = "waiting";
        this.peak = 0;
        this.report(true);
      } else if (data?.type === "strategy") {
        this.strategy = data.value;
      }
    };
  }

  process(_inputs, outputs) {
    const channel = outputs[0]?.[0];
    if (!channel) return true;
    for (let i = 0; i < channel.length; i++) {
      if (this.clock.shouldAdvance()) this.sample = this.nextSample();
      channel[i] = this.sample;
    }
    return true;
  }

  nextSample() {
    if (this.index >= FRAME_SAMPLES) this.loadFrame();
    const at = this.index++;
    let value = 0;
    if (this.mode === "playing") {
      const byte = this.frame[at];
      this.previousFrame[at] = byte;
      if (at === FRAME_SAMPLES - 1) this.hasPreviousFrame = true;
      value = decodeSample(byte);
    } else if (this.mode === "concealing") {
      value = concealedSample(this.strategy, this.previousFrame[at], this.hasPreviousFrame);
    }
    value /= 32768;
    const magnitude = value < 0 ? -value : value;
    if (magnitude > this.peak) this.peak = magnitude;
    if (this.index === FRAME_SAMPLES) this.endFrame();
    return value;
  }

  loadFrame() {
    const packet = this.buffer.nextFrame();
    this.index = 0;
    if (packet) { this.frame = packet.payload; this.mode = "playing"; }
    else if (packet === null) { this.frame = null; this.mode = "concealing"; }
    else { this.frame = null; this.mode = "waiting"; }
    this.report();
  }

  endFrame() {
    this.level.peak = this.peak;
    this.level.mode = this.mode === "concealing" ? "conceal" : this.mode;
    this.port.postMessage(this.level);
    this.peak = 0;
  }

  // Counters post only when they change, so an idle line stays quiet.
  report(force = false) {
    const { state } = this.buffer;
    const stats = this.buffer.statisticsSnapshot();
    const shown = this.counters;
    if (!force && state === shown.state && stats.received === shown.received && stats.concealed === shown.concealed &&
        stats.lateDiscarded === shown.lateDiscarded && stats.recoveries === shown.recoveries) return;
    Object.assign(shown, { state, received: stats.received, concealed: stats.concealed, lateDiscarded: stats.lateDiscarded, recoveries: stats.recoveries });
    this.port.postMessage(shown);
  }
}

registerProcessor("sound-playback", SoundPlaybackProcessor);
