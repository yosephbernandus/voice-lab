import { parse } from "./packet.js";

const MOD = 0x10000;
const HALF = 0x8000;
export const DEFAULT_STARTUP_WINDOW_PACKETS = 3;
export const DEFAULT_MAX_BUFFER_PACKETS = 32;
export const DEFAULT_RECOVERY_GAP_PACKETS = 8;
export const DEFAULT_RECOVERY_CONCEALMENT_PACKETS = 3;
export const DEFAULT_RECOVERY_STARVATION_PACKETS = 6;

const distance = (from, to) => (to - from + MOD) & 0xffff;
const precedes = (left, right) => { const d = distance(left, right); return d > 0 && d < HALF; };

export class PacketJitterBuffer {
  constructor(windowPackets = DEFAULT_STARTUP_WINDOW_PACKETS, options = {}) {
    if (typeof windowPackets === "object") { options = windowPackets; windowPackets = options.windowPackets ?? 3; }
    if (!Number.isInteger(windowPackets) || windowPackets < 1) throw new RangeError("windowPackets must be a positive integer");
    this.windowPackets = windowPackets;
    this.maxBufferPackets = options.maxBufferPackets ?? 32;
    this.recoveryGapPackets = options.recoveryGapPackets ?? 8;
    this.recoveryConcealmentPackets = options.recoveryConcealmentPackets ?? 3;
    this.recoveryStarvationPackets = options.recoveryStarvationPackets ?? 6;
    this.recoveryWindowPackets = options.recoveryWindowPackets ?? windowPackets;
    if (!Number.isInteger(this.maxBufferPackets) || this.maxBufferPackets < windowPackets) throw new RangeError("maxBufferPackets must cover the startup window");
    for (const value of [this.recoveryGapPackets, this.recoveryConcealmentPackets, this.recoveryStarvationPackets, this.recoveryWindowPackets]) {
      if (!Number.isInteger(value) || value < 1) throw new RangeError("recovery thresholds must be positive integers");
    }
    this.reset(null);
  }
  reset(ssrc = null) {
    this.ssrc = ssrc; this.packets = new Map(); this.nextSequenceNumber = 0;
    this.highestSequenceNumber = null; this.recoveryFloor = null; this.initialized = false;
    this.started = false; this.state = "buffering"; this.consecutiveFarAhead = 0;
    this.farAheadDistance = 0; this.consecutiveStarved = 0;
    this.statistics = { received: 0, played: 0, concealed: 0, lateDiscarded: 0, late: 0, duplicate: 0, boundedDrops: 0, recoveries: 0 };
  }
  push(buffer) {
    const item = parse(buffer);
    if (!item) return false;
    if (this.ssrc === null) this.ssrc = item.ssrc;
    if (item.ssrc !== this.ssrc) return false;
    if (!this.initialized) { this.nextSequenceNumber = item.sequenceNumber; this.initialized = true; }
    if (precedes(item.sequenceNumber, this.nextSequenceNumber) || (this.state === "rebuffering" && this.atOrBeforeRecoveryFloor(item.sequenceNumber))) {
      this.statistics.lateDiscarded++; this.statistics.late++; return false;
    }
    if (this.packets.has(item.sequenceNumber)) { this.statistics.duplicate++; return false; }
    if (this.packets.size >= this.maxBufferPackets) {
      const far = this.farthestSequenceNumber();
      if (far === null || distance(this.nextSequenceNumber, item.sequenceNumber) >= distance(this.nextSequenceNumber, far)) { this.statistics.boundedDrops++; return false; }
      this.packets.delete(far); this.statistics.boundedDrops++;
    }
    this.packets.set(item.sequenceNumber, item); this.statistics.received++;
    if (this.highestSequenceNumber === null || precedes(this.highestSequenceNumber, item.sequenceNumber)) this.highestSequenceNumber = item.sequenceNumber;
    return true;
  }
  nextFrame() {
    if (this.state === "buffering") { if (this.packets.size < this.windowPackets) return undefined; this.started = true; this.state = "playing"; }
    if (this.state === "rebuffering") { if (this.packets.size < this.recoveryWindowPackets) return undefined; this.rebase(); return undefined; }
    const item = this.packets.get(this.nextSequenceNumber);
    if (item) { this.packets.delete(this.nextSequenceNumber); this.nextSequenceNumber = (this.nextSequenceNumber + 1) & 0xffff; this.statistics.played++; this.consecutiveFarAhead = 0; this.farAheadDistance = 0; this.consecutiveStarved = 0; return item; }
    const near = this.nearestFutureSequenceNumber(this.nextSequenceNumber), far = this.farthestSequenceNumber();
    if (near === null || far === null) { this.consecutiveStarved++; this.consecutiveFarAhead = 0; this.farAheadDistance = 0; if (this.consecutiveStarved >= this.recoveryStarvationPackets) this.beginRebuffering(); return undefined; }
    const farDistance = distance(this.nextSequenceNumber, far);
    if (farDistance <= this.windowPackets) { this.consecutiveFarAhead = 0; this.farAheadDistance = 0; this.consecutiveStarved = 0; return undefined; }
    this.consecutiveStarved = 0; this.consecutiveFarAhead++; if (this.consecutiveFarAhead === 1) this.farAheadDistance = distance(this.nextSequenceNumber, near);
    if (this.farAheadDistance >= this.recoveryGapPackets && this.packets.size <= this.windowPackets + 1 && this.consecutiveFarAhead >= this.recoveryConcealmentPackets) { this.beginRebuffering(); return undefined; }
    this.nextSequenceNumber = (this.nextSequenceNumber + 1) & 0xffff; this.statistics.concealed++; return null;
  }
  statisticsSnapshot() { return this.statistics; }
  beginRebuffering() { if (this.state === "rebuffering") return; this.state = "rebuffering"; this.recoveryFloor = this.highestSequenceNumber; this.packets.clear(); this.consecutiveFarAhead = 0; this.farAheadDistance = 0; this.consecutiveStarved = 0; }
  rebase() { const n = this.nearestFutureSequenceNumber(this.recoveryFloor ?? this.nextSequenceNumber); if (n === null) return; this.nextSequenceNumber = n; this.state = "playing"; this.started = true; this.recoveryFloor = null; this.consecutiveFarAhead = 0; this.farAheadDistance = 0; this.consecutiveStarved = 0; this.statistics.recoveries++; }
  atOrBeforeRecoveryFloor(n) { return this.recoveryFloor !== null && (n === this.recoveryFloor || precedes(n, this.recoveryFloor)); }
  nearestFutureSequenceNumber(reference) { let best = null, bestDistance = MOD; for (const n of this.packets.keys()) { const d = distance(reference, n); if (d < bestDistance && (d === 0 || d < HALF)) { best = n; bestDistance = d; } } return best; }
  farthestSequenceNumber() { let best = null, bestDistance = -1; for (const n of this.packets.keys()) { const d = distance(this.nextSequenceNumber, n); if (d > bestDistance && d < HALF) { best = n; bestDistance = d; } } return best; }
}
