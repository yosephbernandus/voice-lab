const BIAS = 0x84;
const CLIP = 8159;
const ENDS = [0x3f, 0x7f, 0xff, 0x1ff, 0x3ff, 0x7ff, 0xfff, 0x1fff];
export function encodeSample(sample) {
  let value = sample >> 2;
  const mask = value < 0 ? 0x7f : 0xff;
  if (value < 0) value = -value;
  const magnitude = Math.min(value, CLIP) + (BIAS >> 2);
  let segment = 8;
  for (let i = 0; i < ENDS.length; i++) if (magnitude <= ENDS[i]) { segment = i; break; }
  if (segment === 8) return 0x7f ^ mask;
  return ((segment << 4) | ((magnitude >> (segment + 1)) & 15)) ^ mask;
}
export function decodeSample(byte) {
  const inverted = (~byte) & 255;
  const magnitude = (((inverted & 15) << 3) + BIAS) << ((inverted & 0x70) >> 4);
  return (inverted & 0x80) ? BIAS - magnitude : magnitude - BIAS;
}
export function encode(samples, output = new Uint8Array(samples.length)) { for (let i = 0; i < samples.length; i++) output[i] = encodeSample(samples[i]); return output; }
export function decode(bytes, output = new Int16Array(bytes.length)) { for (let i = 0; i < bytes.length; i++) output[i] = decodeSample(bytes[i]); return output; }
