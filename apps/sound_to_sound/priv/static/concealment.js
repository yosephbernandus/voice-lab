import { decodeSample } from "./mulaw.js";
export function concealedSample(strategy, previousByte, hasPreviousFrame) {
  if (!hasPreviousFrame || strategy === "silence") return 0;
  const sample = decodeSample(previousByte);
  return strategy === "fade" ? sample * 0.5 : sample;
}
