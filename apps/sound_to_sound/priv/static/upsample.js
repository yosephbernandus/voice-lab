export class SampleClockUpsampler {
  constructor(outputSampleRate, inputSampleRate) { this.outputSampleRate = outputSampleRate; this.inputSampleRate = inputSampleRate; this.phase = 0; }
  shouldAdvance() { this.phase += this.inputSampleRate; if (this.phase < this.outputSampleRate) return false; this.phase -= this.outputSampleRate; return true; }
}
