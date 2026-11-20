import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.dirname(fileURLToPath(import.meta.url));
const referenceRoot = path.resolve(root, "..");
const sourceRoot = path.resolve(process.env.AUDIO_WORKSHOP_ROOT || path.resolve(referenceRoot, "../audio-workshop"));
const side = process.argv[2];
if (side !== "source" && side !== "reference") throw new Error("usage: browser_kernels.mjs source|reference");
const appRoot = side === "source" ? sourceRoot : referenceRoot;
const modulePath = rel => path.join(appRoot, rel);
const digest = value => createHash("sha256").update(JSON.stringify(value)).digest("hex");
const bytes = hex => Uint8Array.from(hex.match(/../g) || [], x => parseInt(x, 16)).buffer;
const packetInput = value => value?.kind === "uint8-array" ? Uint8Array.from(value.values) : value?.kind === "not-array-buffer" ? Uint8Array.of(0) : bytes(value);
const safe = fn => { try { return { ok: true, value: fn() }; } catch (error) { return { ok: false, error: { name: error?.name, message: error?.message } }; } };

const packetModule = await import(modulePath("apps/sound_to_sound/priv/static/packet.js"));
const mulawModule = await import(modulePath("apps/sound_to_sound/priv/static/mulaw.js"));
const downsampleModule = await import(modulePath("apps/sound_to_sound/priv/static/downsample.js"));
const parsePacket = packetModule.packet || packetModule.parse;
const encodeSample = mulawModule.encodeSample;
const decodeSample = mulawModule.decodeSample;
const { AntiAliasedDownsampler } = downsampleModule;

function packetCases() {
  const make = (length, version = 2, flags = 0, seq = 0xffff, timestamp = 0xffffffff, ssrc = 0xffffffff) => {
    const data = new Uint8Array(length);
    if (length >= 12) { data[0] = version << 6; data[1] = flags; new DataView(data.buffer).setUint16(2, seq); new DataView(data.buffer).setUint32(4, timestamp); new DataView(data.buffer).setUint32(8, ssrc); }
    return data.buffer;
  };
  const cases = [make(172), make(172, 0), make(172, 1), make(172, 3), make(172, 2, 8), make(172, 2, 255), make(0), make(11), make(171), make(173), new Uint8Array(172), new Uint8Array(172).subarray(0), "not-array-buffer"];
  return cases.map(value => safe(() => { const parsed = parsePacket(value); return parsed && { sequenceNumber: parsed.sequenceNumber, timestamp: parsed.timestamp, ssrc: parsed.ssrc, payload: Array.from(parsed.payload) }; }));
}

function mulawCases() {
  const encoded = new Array(65536); for (let i = -32768; i <= 32767; i++) encoded[i + 32768] = encodeSample(i);
  const decoded = new Array(256); for (let i = 0; i < 256; i++) decoded[i] = decodeSample(i);
  const edgeInputs = [-Infinity, -32769, -32768.5, -32768, -1.5, -0.5, 0, 0.5, 1.5, 32767, 32767.5, 32768, Infinity, NaN];
  return { input: { pcm16: { start: -32768, end: 32767 }, bytes: { start: 0, end: 255 }, edgeInputs }, encoded, decoded, edgeEncoded: edgeInputs.map(encodeSample) };
}


function downsampleCases() {
  const rates = [8000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 192000];
  const cases = [];
  for (const inputRate of rates) {
    for (const kind of ["impulse", "multitone"]) {
      const count = Math.min(inputRate / 10, 4096); const samples = [];
      for (let i = 0; i < count; i++) samples.push(kind === "impulse" ? (i === 0 ? 1 : 0) : Math.sin(2 * Math.PI * 440 * i / inputRate) + 0.25 * Math.sin(2 * Math.PI * 7000 * i / inputRate));
      const converter = new AntiAliasedDownsampler(inputRate, 8000); const output = [];
      for (let i = 0; i < samples.length; i++) { const value = converter.push(samples[i]); if (value !== null) output.push(value); }
      cases.push({ inputRate, kind, inputCount: samples.length, outputCount: output.length, output });
    }
  }
  const validation = [[0, 8000], [8000, 0], [192001, 8000], [4000, 8000], [44100, 22050]].map(([input, output]) => safe(() => new AntiAliasedDownsampler(input, output)));
  return { cases, validation };
}

const operations = { packet: packetCases, mulaw: mulawCases, downsample: downsampleCases };
const input = JSON.parse(await new Response(process.stdin).text());
const selected = input.operations || Object.keys(operations);
const results = {}; for (const name of selected) results[name] = operations[name]();
const modules = {}; for (const [name, rel] of Object.entries({ packet: "apps/sound_to_sound/priv/static/packet.js", mulaw: "apps/sound_to_sound/priv/static/mulaw.js", downsample: "apps/sound_to_sound/priv/static/downsample.js" })) modules[name] = { path: modulePath(rel), sha256: createHash("sha256").update(await readFile(modulePath(rel))).digest("hex") };
process.stdout.write(JSON.stringify({ side, modules, results, resultDigest: digest(results) }));
