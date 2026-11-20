const PHASES = 256;
const sinc = x => x === 0 ? 1 : Math.sin(Math.PI * x) / (Math.PI * x);
const window = (i, n) => { const p = 2 * Math.PI * i / (n - 1); return .42 - .5 * Math.cos(p) + .08 * Math.cos(2 * p); };
function table(input, output, taps) {
  const result = new Float64Array(PHASES * taps), cutoff = .9 * .5 * (output / input), center = (taps - 1) / 2;
  for (let phase = 0; phase < PHASES; phase++) { let sum = 0, offset = phase * taps;
    for (let tap = 0; tap < taps; tap++) { const c = 2 * cutoff * sinc(2 * cutoff * (tap + phase / PHASES - center)) * window(tap, taps); result[offset + tap] = c; sum += c; }
    for (let tap = 0; tap < taps; tap++) result[offset + tap] /= sum;
  }
  return result;
}
export class AntiAliasedDownsampler {
  constructor(inputSampleRate, outputSampleRate = 8000) {
    for (const [rate, name] of [[inputSampleRate, "inputSampleRate"], [outputSampleRate, "outputSampleRate"]])
      if (!Number.isInteger(rate) || rate <= 0) throw new RangeError(`${name} must be a positive integer sample rate`);
    if (inputSampleRate > 192000) throw new RangeError("inputSampleRate must not exceed 192000 Hz");
    if (inputSampleRate < outputSampleRate) throw new RangeError(`inputSampleRate (${inputSampleRate}) must be at least outputSampleRate (${outputSampleRate})`);
    this.inputSampleRate = inputSampleRate; this.outputSampleRate = outputSampleRate;
    this.tapCount = Math.max(63, (Math.ceil(63 * inputSampleRate / (6 * outputSampleRate)) | 1));
    this.history = new Float32Array(this.tapCount); this.coefficients = inputSampleRate === outputSampleRate ? null : table(inputSampleRate, outputSampleRate, this.tapCount);
    this.historyWriteIndex = 0; this.inputSampleCount = 0; this.outputSampleCount = 0;
  }
  push(sample) {
    const n = this.tapCount;
    if (!this.inputSampleCount) this.history.fill(sample);
    const newest = this.historyWriteIndex; this.history[newest] = sample; this.historyWriteIndex = (newest + 1) % n; this.inputSampleCount++;
    if (this.inputSampleRate === this.outputSampleRate) return sample;
    if ((this.outputSampleCount + 1) * this.inputSampleRate > this.inputSampleCount * this.outputSampleRate) return null;
    const targetNumerator = (this.outputSampleCount + 1) * this.inputSampleRate - this.outputSampleRate;
    const target = Math.floor(targetNumerator / this.outputSampleRate), remainder = targetNumerator - target * this.outputSampleRate;
    let phase = Math.round(remainder * PHASES / this.outputSampleRate); if (phase === PHASES) phase--;
    let position = (this.historyWriteIndex - 1 - (this.inputSampleCount - 1 - target)) % n; if (position < 0) position += n;
    let output = 0, offset = phase * n;
    for (let tap = 0; tap < n; tap++) { output += this.history[position] * this.coefficients[offset + tap]; if (--position < 0) position = n - 1; }
    this.outputSampleCount++; return output;
  }
}
