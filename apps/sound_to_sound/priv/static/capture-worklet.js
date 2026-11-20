import { AntiAliasedDownsampler } from "./downsample.js";
import { encodeSample } from "./mulaw.js";
import { HEADER_BYTES, PACKET_BYTES, writeHeader } from "./packet.js";

// ponytail: four in-flight packets cap worklet memory; raise BUFFER_COUNT only after measuring sustained WebSocket stalls.
const BUFFER_COUNT = 4;

class SoundCaptureProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.downsampler = new AntiAliasedDownsampler(sampleRate, 8000);
    this.buffers = new Array(BUFFER_COUNT);
    this.views = new Array(BUFFER_COUNT);
    this.payloads = new Array(BUFFER_COUNT);
    this.messages = new Array(BUFFER_COUNT);
    this.available = new Uint8Array(BUFFER_COUNT);
    for (let i = 0; i < BUFFER_COUNT; i++) {
      const buffer = new ArrayBuffer(PACKET_BYTES);
      this.buffers[i] = buffer;
      this.views[i] = new DataView(buffer);
      this.payloads[i] = new Uint8Array(buffer, HEADER_BYTES);
      this.messages[i] = { type: "packet", slot: i, buffer };
      this.available[i] = 1;
    }
    this.currentSlot = 0;
    this.available[0] = 0;
    this.peak = 0;
    this.level = { type: "level", peak: 0 };
    this.packet = this.buffers[0];
    this.view = this.views[0];
    this.payload = this.payloads[0];
    this.position = 0;
    this.sequenceNumber = 0;
    this.timestamp = 0;
    this.ssrc = 0;
    this.running = false;
    this.starved = false;
    this.starvationMessage = { type: "state", value: "buffer-starved" };
    this.port.onmessage = ({ data }) => {
      if (data?.type === "start") {
        this.running = true;
        this.ssrc = data.ssrc ?? 0;
      } else if (data?.type === "stop") {
        this.running = false;
      } else if (data?.type === "recycle" && Number.isInteger(data.slot) && data.slot >= 0 && data.slot < BUFFER_COUNT && data.buffer instanceof ArrayBuffer) {
        const slot = data.slot;
        this.buffers[slot] = data.buffer;
        this.views[slot] = new DataView(data.buffer);
        this.payloads[slot] = new Uint8Array(data.buffer, HEADER_BYTES);
        this.messages[slot].buffer = data.buffer;
        this.available[slot] = 1;
        if (this.currentSlot < 0) this.acquireBuffer();
      }
    };
  }

  acquireBuffer() {
    for (let i = 0; i < BUFFER_COUNT; i++) {
      if (!this.available[i]) continue;
      this.available[i] = 0;
      this.currentSlot = i;
      this.packet = this.buffers[i];
      this.view = this.views[i];
      this.payload = this.payloads[i];
      this.position = 0;
      this.starved = false;
      return true;
    }
    this.currentSlot = -1;
    return false;
  }

  process(inputs) {
    if (!this.running || this.currentSlot < 0) {
      if (this.running && !this.starved) {
        this.starved = true;
        this.port.postMessage(this.starvationMessage);
      }
      return true;
    }
    const channel = inputs[0]?.[0];
    if (!channel) return true;
    for (let i = 0; i < channel.length; i++) {
      const output = this.downsampler.push(channel[i] * 32768);
      if (output === null) continue;
      const magnitude = output < 0 ? -output : output;
      if (magnitude > this.peak) this.peak = magnitude;
      this.payload[this.position++] = encodeSample(output);
      if (this.position === 160) {
        writeHeader(this.view, this.sequenceNumber, this.timestamp, this.ssrc);
        this.messages[this.currentSlot].buffer = this.packet;
        this.port.postMessage(this.messages[this.currentSlot], [this.packet]);
        this.level.peak = this.peak / 32768;
        this.port.postMessage(this.level);
        this.peak = 0;
        this.currentSlot = -1;
        this.packet = null;
        this.view = null;
        this.payload = null;
        this.sequenceNumber = (this.sequenceNumber + 1) & 0xffff;
        this.timestamp = (this.timestamp + 160) >>> 0;
        this.acquireBuffer();
        if (this.currentSlot < 0) break;
      }
    }
    return true;
  }
}

registerProcessor("sound-capture", SoundCaptureProcessor);
