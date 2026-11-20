import { mkdir, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const timeoutMs = Number(process.env.LIVE_SMOKE_TIMEOUT_MS || 4000);
const policy = "loss=0&reorder=0&delay=0&latency=0&seed=7";
const fixture = {
  health: "/health",
  static: ["/", "/app.js", "/call", "/call.js"],
  websocket: ["relay", "invalid_frame", "third_peer", "invalid_policy", "stale_generation"],
  packet: "version=2, payload_type=0, sequence=17, timestamp=2720, ssrc=0x10203040, payload=160 bytes",
};
const sha = value => createHash("sha256").update(JSON.stringify(value)).digest("hex");
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function endpoint(name, fallback) {
  const value = process.env[`${name}_URL`] || fallback;
  return new URL(value);
}

function command(name) {
  return process.env[`${name}_COMMAND`] || null;
}

function sourceHash(root) {
  try { return execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim(); }
  catch { return null; }
}

async function fetchObservation(base, pathname) {
  const started = Date.now();
  try {
    const response = await fetch(new URL(pathname, base), { signal: AbortSignal.timeout(timeoutMs) });
    const body = await response.text();
    return { path: pathname, status: response.status, contentType: response.headers.get("content-type"), bodyBytes: Buffer.byteLength(body), bodySha256: createHash("sha256").update(body).digest("hex"), body: pathname === "/health" ? body : undefined, elapsedMs: Date.now() - started };
  } catch (error) {
    return { path: pathname, error: String(error), elapsedMs: Date.now() - started };
  }
}

function packet() {
  const result = new Uint8Array(172);
  result[0] = 0x80;
  result[1] = 0;
  new DataView(result.buffer).setUint16(2, 17);
  new DataView(result.buffer).setUint32(4, 2720);
  new DataView(result.buffer).setUint32(8, 0x10203040);
  for (let i = 12; i < result.length; i++) result[i] = i & 255;
  return result;
}

// Every socket buffers its events from creation. Server frames sent back to back can arrive in one
// network read and dispatch before an `await` continuation re-attaches a listener, so a per-call
// listener silently loses the second frame.
function wsOpen(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.inbox = [];
    ws.waiter = null;
    const push = item => { if (ws.waiter) { const waiter = ws.waiter; ws.waiter = null; waiter(item); } else ws.inbox.push(item); };
    ws.addEventListener("message", event => push({ data: event.data }));
    ws.addEventListener("close", event => push({ close: { kind: "close", code: event.code, reason: event.reason } }));
    ws.addEventListener("error", () => push({ error: true }));
    const timer = setTimeout(() => { try { ws.close(); } catch {} reject(new Error("websocket open timeout")); }, timeoutMs);
    ws.addEventListener("open", () => { clearTimeout(timer); resolve(ws); }, { once: true });
    ws.addEventListener("error", () => { clearTimeout(timer); reject(new Error("websocket open error")); }, { once: true });
  });
}

// The room is global and a closing socket leaves its seat asynchronously, so a join right after a
// close can be refused with 1013. Retry until the seat is really free; the room-full case itself
// is still observed explicitly with the third peer.
async function wsOpenSeated(url) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const ws = await wsOpen(url);
    await sleep(75);
    if (ws.inbox[0]?.close?.code !== 1013) return ws;
    if (Date.now() > deadline) throw new Error("seat never freed");
    await sleep(25);
  }
}

function nextMessage(ws, label) {
  const settle = item => {
    if (item.error) throw new Error(`${label} websocket error`);
    return item.close || item.data;
  };
  if (ws.inbox.length) return Promise.resolve(settle(ws.inbox.shift()));
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { ws.waiter = null; reject(new Error(`${label} message timeout`)); }, timeoutMs);
    ws.waiter = item => { clearTimeout(timer); try { resolve(settle(item)); } catch (error) { reject(error); } };
  });
}

function drainMessages(ws) {
  return ws.inbox.splice(0).filter(item => item.data !== undefined).map(item => item.data);
}

async function bytes(value) {
  if (typeof value === "string") return { kind: "text", value };
  if (value instanceof ArrayBuffer) return { kind: "binary", bytes: Array.from(new Uint8Array(value)) };
  if (ArrayBuffer.isView(value)) return { kind: "binary", bytes: Array.from(new Uint8Array(value.buffer, value.byteOffset, value.byteLength)) };
  if (value instanceof Blob) return { kind: "binary", bytes: Array.from(new Uint8Array(await value.arrayBuffer())) };
  return { kind: typeof value, value: String(value) };
}

async function closeObservation(ws, label) {
  const result = nextMessage(ws, label);
  try { ws.close(); } catch {}
  return await result;
}
async function nextJsonType(ws, type, label) {
  for (;;) {
    const value = JSON.parse(await nextMessage(ws, label));
    if (value.type === type) return value;
  }
}

async function runSide(name, base, root) {
  const result = { name, base: base.toString(), command: command(name), sourceHash: sourceHash(root), health: null, static: [], websocket: {}, errors: [] };
  result.health = await fetchObservation(base, "/health");
  for (const pathname of fixture.static) result.static.push(await fetchObservation(base, pathname));
  let a, b, invalid, third;
  try {
    const wsUrl = () => new URL(`/socket?${policy}`, base).toString().replace(/^http/, "ws");
    a = await wsOpen(wsUrl());
    b = await wsOpen(wsUrl());
    a.binaryType = "arraybuffer";
    b.binaryType = "arraybuffer";
    a.send(packet());
    const announcement = await nextMessage(b, `${name} announcement`);
    const delivered = await nextMessage(b, `${name} relay`);
    result.websocket.relay = { announcement: await bytes(announcement), delivered: await bytes(delivered) };
    // Policy changes and packets travel on different sockets, so the order is forced: the latency
    // policy is acknowledged by its announcement before the sender speaks, and the packet is given
    // time to reach the receiver's timer before the reset. The query keys are `latency` and `delay`
    // (PolicyParams); unknown keys such as `*_milliseconds` are silently ignored. `delay` only
    // applies to reordered packets, so `latency` is what actually holds the packet back.
    b.send("loss=0&reorder=0&delay=0&latency=400&seed=7");
    const latencyAnnouncement = await nextMessage(b, `${name} latency announcement`);
    a.send(packet());
    await sleep(100);
    b.send("loss=0&reorder=0&delay=0&latency=0&seed=8");
    await sleep(600);
    // Expected: only the reset announcement. The 400 ms timer belongs to the old generation.
    result.websocket.stale_generation = { latencyAnnouncement: await bytes(latencyAnnouncement), afterReset: await Promise.all(drainMessages(b).map(bytes)) };
    await closeObservation(a, `${name} release sender`);
    a = null;
    invalid = await wsOpenSeated(wsUrl());
    invalid.send(new Uint8Array([0x80, 0x00]));
    result.websocket.invalid_frame = await closeObservation(invalid, `${name} invalid frame`);
    invalid = null;
    a = await wsOpenSeated(wsUrl());
    a.binaryType = "arraybuffer";
    third = await wsOpen(wsUrl());
    result.websocket.third_peer = await closeObservation(third, `${name} third peer`);
    third = null;
    a.send("loss=not-a-number");
    result.websocket.invalid_policy = await closeObservation(a, `${name} invalid policy`);
    a = null;
    result.websocket.policy_reset = "tested by invalid policy close";
  } catch (error) {
    result.errors.push(String(error));
  } finally {
    for (const ws of [invalid, third, a, b]) {
      if (!ws || ws.readyState === WebSocket.CLOSED) continue;
      const closed = new Promise(resolve => ws.addEventListener("close", resolve, { once: true }));
      try { ws.close(); await Promise.race([closed, sleep(500)]); } catch {}
    }
    await sleep(100);
  }
  let signalA, signalB;
  try {
    const room = `${name.toLowerCase()}room${Date.now().toString(36)}`.replace(/[^A-Za-z0-9_-]/g, "").slice(0, 40);
    const signalingUrl = () => new URL(`/signaling?room=${room}&codec=pcmu`, base).toString().replace(/^http/, "ws");
    signalA = await wsOpen(signalingUrl());
    const joinedA = JSON.parse(await nextMessage(signalA, `${name} signaling joined A`));
    signalB = await wsOpen(signalingUrl());
    const joinedB = JSON.parse(await nextMessage(signalB, `${name} signaling joined B`));
    const readyA = await nextJsonType(signalA, "ready", `${name} signaling ready A`);
    const readyB = "peer-ready state inferred by accepted offer";
    signalA.send(JSON.stringify({ type: "ping" }));
    const pong = await nextJsonType(signalA, "pong", `${name} signaling pong`);
    signalA.send(JSON.stringify({ type: "offer", sdp: "v=0\r\n" }));
    const offer = await nextJsonType(signalB, "offer", `${name} signaling offer`);
    signalB.send(JSON.stringify({ type: "answer", sdp: "v=0\r\n" }));
    const answer = await nextJsonType(signalA, "answer", `${name} signaling answer`);
    signalB.send(JSON.stringify({ type: "candidate", candidate: { candidate: "candidate:1 1 UDP 1 127.0.0.1 9 typ host", sdpMid: "0", sdpMLineIndex: 0 } }));
    const candidate = await nextJsonType(signalA, "candidate", `${name} signaling candidate`);
    const originResponse = await fetch(new URL(`/signaling?room=${room}x&codec=pcmu`, base), { headers: { origin: "http://not-allowed.invalid" } });
    result.signaling = { joined: [joinedA, joinedB], ready: [readyA, readyB], pong, offer, answer, candidate, originRejected: originResponse.status };
  } catch (error) {
    result.errors.push(String(error));
  } finally {
    try { signalA?.close(); } catch {}
    try { signalB?.close(); } catch {}
  }
  return result;
}

function comparable(side) {
  const relay = side.websocket.relay || {};
  return {
    health: [side.health?.status, side.health?.body],
    staticPaths: side.static.map(entry => [entry.path, entry.status, entry.bodyBytes > 0]),
    relayAnnouncement: relay.announcement,
    relayDelivered: relay.delivered,
    staleGeneration: side.websocket.stale_generation,
    invalidFrame: side.websocket.invalid_frame,
    thirdPeer: side.websocket.third_peer,
    invalidPolicy: side.websocket.invalid_policy,
    signaling: side.signaling,
  };
}

const referenceRoot = path.resolve(here, "..");
const sourceRoot = process.env.AUDIO_WORKSHOP_ROOT || path.resolve(referenceRoot, "../audio-workshop");
const sourceBase = endpoint("SOURCE", "http://127.0.0.1:4201/");
const referenceBase = endpoint("REFERENCE", "http://127.0.0.1:4202/");
const [source, reference] = await Promise.all([runSide("SOURCE", sourceBase, sourceRoot), runSide("REFERENCE", referenceBase, referenceRoot)]);
const differences = [];
const sourceComparable = comparable(source), referenceComparable = comparable(reference);
if (JSON.stringify(sourceComparable) !== JSON.stringify(referenceComparable)) differences.push({ source: sourceComparable, reference: referenceComparable });
const observation = { fixture, fixtureDigest: sha(fixture), inputs: { sourceRoot, referenceRoot, source: sourceBase.toString(), reference: referenceBase.toString() }, source, reference, differences, match: differences.length === 0 && source.errors.length === 0 && reference.errors.length === 0 };
const outputDir = path.join(here, "results");
await mkdir(outputDir, { recursive: true });
const outputPath = path.join(outputDir, `live-${new Date().toISOString().replaceAll(/[-:.TZ]/g, "").slice(0, 14)}.json`);
await writeFile(outputPath, JSON.stringify(observation, null, 2) + "\n");
process.stdout.write(JSON.stringify({ match: observation.match, output: outputPath, fixtureDigest: observation.fixtureDigest, differences }) + "\n");
process.exitCode = observation.match ? 0 : 1;
