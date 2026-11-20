import { createInstrument } from "./instrument.js";
import { PACKET_BYTES } from "./packet.js";

// Fixture provenance: audio-workshop/apps/sound_to_sound/priv/static/talk-a-indonesian.wav, SHA-256 852933ee31e321947e454376b9e529d60424d49e478e31160e944630f596ff36.
const FIXTURE_PATH = "/talk-a-indonesian.wav";
const SOCKET_TIMEOUT_MS = 10_000;

const $ = selector => document.querySelector(selector);
const el = {
  start: $("#start"), fixture: $("#fixture"), stop: $("#stop"), reset: $("#reset-clean"),
  scenario: $("#scenario"), scenarioNote: $("#scenario-note"), strategy: $("#strategy"), strategyNote: $("#strategy-note"),
  loss: $("#loss"), reorder: $("#reorder"), delay: $("#delay"), latency: $("#latency"), seed: $("#seed"),
  state: $("#state"), error: $("#error"), fixtureStatus: $("#fixture-status"),
  sent: $("#sent"), received: $("#received"), concealed: $("#concealed"), late: $("#late-discarded"),
  recoveries: $("#recoveries"), bufferState: $("#buffer-state"), generation: $("#buffer-generation"),
};
const instrument = createInstrument($("#signal-scope"));

const SCENARIOS = {
  clean: { loss: "0", reorder: "0", delay: "0", latency: "0", seed: "42", note: "Clean baseline. Expect a steady voice and no deliberate packet gaps." },
  broken: { loss: "20", reorder: "0", delay: "0", latency: "0", seed: "42", note: "20% packet loss. With the default silence policy, missing frames become audible gaps. Broken and Late may still sound alike because both miss a playback deadline." },
  late: { loss: "0", reorder: "20", delay: "300", latency: "0", seed: "42", note: "20% of frames arrive 300 ms late. With the default silence policy, missed deadlines become audible gaps. Late and Broken may still sound alike even though their causes differ." },
  delayed: { loss: "0", reorder: "0", delay: "0", latency: "500", seed: "42", note: "Every frame waits 500 ms at this listener. Expect a later voice onset and turn-taking delay without deliberate gaps." },
  custom: { note: "Manual policy. Read the values below to predict what this listener will hear." },
};
const STRATEGY_NOTES = {
  silence: "A gap stays silent until a good frame arrives.",
  repeat: "The last good frame is replayed. Listen for the repetition.",
  fade: "The last good frame, played more quietly. No missing information is recovered.",
};

let session = null;      // the one open line, or null
let replaying = null;    // a fixture restart in flight: { cancelled, message }
let applyingScenario = false;

// Range outputs ----------------------------------------------------------
for (const [input, suffix] of [[el.loss, "%"], [el.reorder, "%"], [el.delay, " ms"], [el.latency, " ms"]]) {
  input.addEventListener("input", () => { $(`#${input.id}-value`).textContent = input.value + suffix; });
}
// Lateness only matters for packets reorder selected.
const syncDelayAvailability = () => { el.delay.disabled = Number(el.reorder.value) === 0; };
el.reorder.addEventListener("input", syncDelayAvailability);

// Small view helpers -----------------------------------------------------
function setState(state) {
  el.state.textContent = state;
  document.body.dataset.state = state;
  instrument.state(state);
}
function setError(text) { el.error.hidden = !text; el.error.textContent = text || ""; }
function setFixtureStatus(text) { el.fixtureStatus.hidden = !text; el.fixtureStatus.textContent = text || ""; }
function setReadings({ generation = "—", state = "buffering", received = 0, concealed = 0, lateDiscarded = 0, recoveries = 0 } = {}) {
  el.generation.textContent = String(generation);
  el.bufferState.textContent = state;
  el.received.textContent = String(received);
  el.concealed.textContent = String(concealed);
  el.late.textContent = String(lateDiscarded);
  el.recoveries.textContent = String(recoveries);
}
function refreshButtons() {
  const fixtureRunning = session?.kind === "fixture";
  el.fixture.textContent = fixtureRunning ? "Replay Indonesian fixture" : "Send Indonesian fixture";
  el.fixture.disabled = Boolean(replaying) || Boolean(session && !fixtureRunning);
  el.start.disabled = Boolean(session);
  el.stop.disabled = !session;
}
function scenarioLabel() { return el.scenario.options[el.scenario.selectedIndex]?.text ?? el.scenario.value; }
function comparisonMessage(prefix) { return `${prefix} ${scenarioLabel()}. The full Indonesian phrase will replay from packet 0.`; }
function refreshScenarioNote() {
  el.scenarioNote.textContent = `${(SCENARIOS[el.scenario.value] ?? SCENARIOS.clean).note} This listener configures the sound heard on this device; the sender is unchanged.`;
}

// Policy -----------------------------------------------------------------
// The upgrade query and the live text frame share one shape; the server validates both alike.
function policyQuery() {
  return new URLSearchParams({
    loss: String(Number(el.loss.value) / 100),
    reorder: String(Number(el.reorder.value) / 100),
    delay: el.delay.value,
    latency: el.latency.value,
    seed: el.seed.value,
  });
}
function sendPolicy() {
  if (!applyingScenario && session?.socket?.readyState === WebSocket.OPEN) session.socket.send(policyQuery().toString());
}
function policyChanged(reason) {
  sendPolicy();
  if (session?.kind === "fixture") void replayFixture(reason);
  else if (!session) setFixtureStatus(comparisonMessage(reason === "Scenario changed." ? "Scenario ready." : "Policy ready."));
}
function applyScenario() {
  const scenario = SCENARIOS[el.scenario.value] ?? SCENARIOS.clean;
  applyingScenario = true;
  for (const [key, value] of Object.entries(scenario)) if (key !== "note") $(`#${key}`).value = value;
  for (const input of [el.loss, el.reorder, el.delay, el.latency]) input.dispatchEvent(new Event("input"));
  applyingScenario = false;
  syncDelayAvailability();
  refreshScenarioNote();
  policyChanged("Scenario changed.");
}
for (const input of [el.loss, el.reorder, el.delay, el.latency, el.seed]) {
  // `change`, not `input`: one drag reseeds the impairment once, when released.
  input.addEventListener("change", () => {
    if (!applyingScenario) { el.scenario.value = "custom"; refreshScenarioNote(); }
    policyChanged("Listener policy changed.");
  });
}
el.scenario.addEventListener("change", applyScenario);
el.reset.addEventListener("click", () => {
  el.scenario.value = "clean";
  el.strategy.value = "silence";
  el.strategy.dispatchEvent(new Event("change"));
  applyScenario();
});
el.strategy.addEventListener("change", () => {
  session?.playback?.port.postMessage({ type: "strategy", value: el.strategy.value });
  el.strategyNote.textContent = STRATEGY_NOTES[el.strategy.value];
});

// Session lifecycle ------------------------------------------------------
const live = candidate => session === candidate && !candidate.closed;

el.start.addEventListener("click", () => { if (!session && !replaying) void begin("microphone"); });
el.fixture.addEventListener("click", () => {
  if (replaying) return;
  if (session?.kind === "fixture") void replayFixture("Replay requested.");
  else if (!session) void begin("fixture");
});
el.stop.addEventListener("click", () => {
  if (replaying) replaying.cancelled = true;
  if (session) void finish(session, "stopped");
});

function replayFixture(reason) {
  if (session?.kind !== "fixture" || replaying) return Promise.resolve();
  const transition = { cancelled: false, message: comparisonMessage(reason) };
  replaying = transition;
  setFixtureStatus(transition.message);
  refreshButtons();
  return (async () => {
    try {
      await finish(session, "stopped");
      if (!transition.cancelled) await begin("fixture", transition);
    } finally {
      if (replaying === transition) replaying = null;
      refreshButtons();
    }
  })();
}

async function begin(kind, transition) {
  if (session || transition?.cancelled) return;
  const current = { kind, closed: false, ready: false, sent: 0, generation: 0, abort: new AbortController() };
  session = current;
  setError();
  setState("connecting");
  setFixtureStatus(kind === "fixture" ? transition?.message ?? "Loading Indonesian fixture…" : "");
  instrument.source(kind === "fixture" ? "INDONESIAN FIXTURE" : "YOUR MICROPHONE");
  el.sent.textContent = "0";
  setReadings();
  refreshButtons();

  try {
    let fixtureData;
    if (kind === "microphone") {
      current.mic = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: false, noiseSuppression: false }, video: false });
      // Permission can resolve after Stop; that stream still needs an owner.
      if (!live(current)) { current.mic.getTracks().forEach(track => track.stop()); return; }
      for (const track of current.mic.getTracks()) for (const type of ["mute", "ended"]) track.addEventListener(type, () => interrupt(current));
    } else {
      const response = await fetch(FIXTURE_PATH, { cache: "no-store", signal: current.abort.signal });
      if (!response.ok) throw new Error("Indonesian fixture could not be loaded");
      fixtureData = await response.arrayBuffer();
      if (!live(current)) return;
    }

    const context = new AudioContext();
    current.context = context;
    context.addEventListener("statechange", () => { if (current.prepared && context.state !== "running") interrupt(current); });
    if (context.state === "suspended") await context.resume();
    if (!live(current)) return;
    await Promise.all([context.audioWorklet.addModule("/capture-worklet.js"), context.audioWorklet.addModule("/playback-worklet.js")]);
    if (!live(current)) return;

    let input;
    if (kind === "microphone") {
      input = context.createMediaStreamSource(current.mic);
    } else {
      const destination = context.createMediaStreamDestination();
      current.fixtureSource = context.createBufferSource();
      current.fixtureSource.buffer = await context.decodeAudioData(fixtureData);
      current.fixtureSource.connect(destination);
      current.fixtureSource.onended = () => {
        if (live(current)) setFixtureStatus("Source finished · framed silence keeps the line clean while the receiver drains. Choose another scenario or Replay to hear the full phrase again.");
      };
      input = context.createMediaStreamSource(destination.stream);
      if (!live(current)) return;
    }
    current.input = input;
    current.capture = new AudioWorkletNode(context, "sound-capture");
    current.playback = new AudioWorkletNode(context, "sound-playback");
    current.capture.port.onmessage = ({ data }) => onCapture(current, data);
    current.playback.port.onmessage = ({ data }) => onPlayback(current, data);
    for (const node of [current.capture, current.playback]) node.onprocessorerror = () => finish(current, "error", "Audio processor failed; start again.");
    current.playback.port.postMessage({ type: "strategy", value: el.strategy.value });
    input.connect(current.capture);
    current.sink = context.createGain();
    current.sink.gain.value = 0;
    current.capture.connect(current.sink).connect(context.destination);
    current.playback.connect(context.destination);
    current.prepared = true;

    // Joining the room reroutes the other listener, so audio is acquired first.
    await openSocket(current);
    if (!live(current)) return;
    current.ready = true;
    current.capture.port.postMessage({ type: "start", ssrc: crypto.getRandomValues(new Uint32Array(1))[0] });
    current.fixtureSource?.start();
    setState(kind === "fixture" ? "sending-fixture" : "streaming");
    if (kind === "fixture") setFixtureStatus("Sending Indonesian fixture through live G.711 packets…");
  } catch (error) {
    if (!live(current)) return;
    const message = error?.name === "AbortError" ? "Fixture send cancelled." : error?.message || "Could not open the line.";
    await finish(current, "error", message);
  }
}

function interrupt(target) {
  if (!live(target)) return;
  const action = target.kind === "fixture" ? "Send the Indonesian fixture again." : "Press Start microphone to begin a new session.";
  void finish(target, "interrupted", `Audio interrupted. ${action}`);
}

function onCapture(target, data) {
  if (!live(target) || !target.ready) return;
  if (data?.type === "level") { instrument.capture(data.peak); return; }
  if (data?.type !== "packet") return;
  if (target.socket.readyState === WebSocket.OPEN) {
    target.socket.send(data.buffer);
    el.sent.textContent = String(++target.sent);
  }
  target.capture.port.postMessage({ type: "recycle", slot: data.slot, buffer: data.buffer }, [data.buffer]);
}

function onPlayback(target, data) {
  if (!live(target)) return;
  if (data?.type === "level") instrument.playback(data.peak, data.mode);
  else if (data?.type === "buffer") setReadings(data);
}

function onSocketMessage(target, { data }) {
  if (!live(target)) return;
  if (typeof data === "string") {
    const fields = new URLSearchParams(data);
    const generation = Number(fields.get("stream"));
    const ssrc = Number(fields.get("ssrc"));
    if (!fields.has("stream") || !fields.has("ssrc") || !Number.isSafeInteger(generation) || generation < 1 || !Number.isInteger(ssrc) || ssrc < 0 || ssrc > 0xffffffff) {
      void finish(target, "error", "Invalid stream announcement.");
      return;
    }
    if (generation <= target.generation) return;
    target.generation = generation;
    target.playback?.port.postMessage({ type: "reset", ssrc, generation });
    return;
  }
  // Before the line is ready there is no playback deadline; drop stale audio.
  if (!target.ready || !target.generation || !(data instanceof ArrayBuffer) || data.byteLength !== PACKET_BYTES) return;
  target.playback.port.postMessage({ type: "packet", buffer: data }, [data]);
}

function openSocket(target) {
  const socket = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/socket?${policyQuery()}`);
  target.socket = socket;
  socket.binaryType = "arraybuffer";
  socket.addEventListener("message", event => onSocketMessage(target, event));
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("WebSocket connection timed out")), SOCKET_TIMEOUT_MS);
    socket.addEventListener("open", () => { clearTimeout(timer); resolve(); }, { once: true });
    socket.addEventListener("error", () => { clearTimeout(timer); reject(new Error("WebSocket connection failed")); }, { once: true });
    socket.addEventListener("close", event => {
      clearTimeout(timer);
      reject(new Error("WebSocket closed before startup completed"));
      if (live(target)) void finish(target, "closed", `Connection closed ${event.code}: ${event.reason}`);
    }, { once: true });
  });
}

// Closes only what this session owns, including late async results.
function finish(target, state, message) {
  if (target.closed) return target.cleanup;
  target.closed = true;
  target.ready = false;
  target.abort.abort();
  if (session === target) {
    session = null;
    setState(state);
    if (message) setError(message);
    if (target.kind === "fixture") setFixtureStatus(state === "stopped" ? "Fixture stopped. Send it again whenever you’re ready." : message || "");
    refreshButtons();
  }
  target.capture?.port.postMessage({ type: "stop" });
  try { target.fixtureSource?.stop(); } catch { /* never started */ }
  target.input?.disconnect();
  target.capture?.disconnect();
  target.sink?.disconnect();
  target.playback?.disconnect();
  target.mic?.getTracks().forEach(track => track.stop());
  if (target.socket && target.socket.readyState < WebSocket.CLOSING) target.socket.close();
  target.cleanup = target.context && target.context.state !== "closed"
    ? target.context.close().catch(() => { if (!session) setError("Audio context cleanup failed; reload this page."); })
    : Promise.resolve();
  return target.cleanup;
}

syncDelayAvailability();
refreshScenarioNote();
refreshButtons();
