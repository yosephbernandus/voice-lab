import path from "node:path";
import { fileURLToPath } from "node:url";
const input = JSON.parse(await new Response(process.stdin).text());
const side = process.argv[2];
if (side !== "source" && side !== "reference") throw new Error("usage: source_sound.mjs source|reference");
const referenceRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const root = side === "source" ? path.resolve(process.env.AUDIO_WORKSHOP_ROOT || path.join(referenceRoot, "../audio-workshop")) : referenceRoot;
const packetModule = await import(`${root}/apps/sound_to_sound/priv/static/packet.js`);
const jitterModule = await import(`${root}/apps/sound_to_sound/priv/static/jitter-buffer.js`);
const packetParser = side === "source" ? packetModule.packet : packetModule.parse;
const bytes = hex => Uint8Array.from((hex.match(/../g) || []).map(x => parseInt(x, 16))).buffer;
const inputValue = value => {
  if (value && value.kind === "uint8-array") return Uint8Array.from(value.values);
  if (value && value.kind === "not-array-buffer") return Uint8Array.from([0]).buffer;
  return bytes(value);
};
const view = value => {
  const parsed = packetParser(inputValue(value));
  if (!parsed) return null;
  return {
    sequenceNumber: parsed.sequenceNumber,
    timestamp: parsed.timestamp,
    ssrc: parsed.ssrc,
    payload: Array.from(parsed.payload),
  };
};
const sourceJitter = scenario => {
  const buffer = new jitterModule.PacketJitterBuffer(scenario.windowPackets ?? 3, scenario.options ?? {});
  return scenario.events.map(event => {
    if (event.op === "push") {
      const result = buffer.push(inputValue(event.hex));
      return { op: "push", result, state: buffer.state, stats: { ...buffer.statisticsSnapshot() } };
    }
    const frame = buffer.nextFrame();
    return {
      op: "next",
      result: frame === undefined ? "undefined" : frame === null ? null : frame.sequenceNumber,
      state: buffer.state,
      stats: { ...buffer.statisticsSnapshot() },
    };
  });
};
const referenceJitter = scenario => {
  const buffer = new jitterModule.PacketJitterBuffer(scenario.windowPackets ?? 3, scenario.options ?? {});
  return scenario.events.map(event => {
    if (event.op === "push") {
      const result = buffer.push(inputValue(event.hex));
      return { op: "push", result, state: buffer.state, stats: { ...buffer.statisticsSnapshot() } };
    }
    const frame = buffer.nextFrame();
    return {
      op: "next",
      result: frame === undefined ? "undefined" : frame === null ? null : frame.sequenceNumber,
      state: buffer.state,
      stats: { ...buffer.statisticsSnapshot() },
    };
  });
};
const jitter = side === "source" ? sourceJitter : referenceJitter;
process.stdout.write(JSON.stringify({
  side,
  parser: input.parser.map(view),
  jitter: input.jitter.map(jitter),
}));
