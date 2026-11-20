// Draws recent frame peaks. Input is scalar worklet telemetry only; this module never
// touches samples, never schedules audio, and a failed draw cannot affect playback.
const FRAMES = 144;           // 2.9 s of 20 ms frames across the scope
const MARGIN = 20;
const MIN_DRAW_INTERVAL = 32; // ms, about 30 fps

const COLORS = { grid: "#304236", input: "#95a58b", output: "#b5e296", received: "#668659", concealed: "#ec977a" };

const MESSAGES = {
  idle: "The trace begins when you do.",
  connecting: "Opening the line…",
  streaming: "Listening to microphone frames…",
  "sending-fixture": "Sending fixture frames…",
  stopped: "Line closed. Start whenever you’re ready.",
  closed: "Connection closed. Start a new session.",
  interrupted: "Audio interrupted. Start a new session.",
  error: "Could not open the line. See the message below.",
};

class Ring {
  constructor() { this.values = new Float32Array(FRAMES); this.flags = new Uint8Array(FRAMES); this.count = 0; }
  push(value, flag = 0) { const slot = this.count++ % FRAMES; this.values[slot] = value; this.flags[slot] = flag; }
  reset() { this.values.fill(0); this.flags.fill(0); this.count = 0; }
  // Oldest to newest of the frames still held, right-aligned on a FRAMES-wide strip.
  at(column) {
    const age = FRAMES - 1 - column;
    return age < Math.min(this.count, FRAMES) ? (this.count - 1 - age) % FRAMES : -1;
  }
}

export function createInstrument(canvas) {
  const context = canvas?.getContext?.("2d");
  const noop = { source() {}, capture() {}, playback() {}, state() {} };
  if (!context) return noop;

  const message = document.querySelector("#scope-message");
  const status = document.querySelector("#trace-status");
  const motion = document.querySelector("#motion");
  const sourceLabel = document.querySelector("#input-source-label");
  const reduced = matchMedia("(prefers-reduced-motion: reduce)");
  const input = new Ring();
  const output = new Ring();

  let width = 0, height = 0;
  let frameRequest = 0, lastDraw = 0;
  let live = false;
  let paused = reduced.matches;

  const column = x => MARGIN + x / (FRAMES - 1) * (width - 2 * MARGIN);

  function drawGrid() {
    context.strokeStyle = COLORS.grid; context.lineWidth = .5;
    context.beginPath();
    for (let x = MARGIN; x < width; x += 32) { context.moveTo(x, 8); context.lineTo(x, height - 25); }
    for (let y = 14; y < height - 25; y += 26) { context.moveTo(MARGIN, y); context.lineTo(width - MARGIN, y); }
    context.stroke();
  }

  // A square-root scale keeps quiet speech visible next to loud peaks.
  function drawPeaks(ring, centerY, color) {
    context.strokeStyle = color; context.lineWidth = 1.3;
    context.beginPath();
    for (let x = 0; x < FRAMES; x++) {
      const slot = ring.at(x);
      const peak = slot < 0 ? 0 : ring.values[slot];
      const half = Math.sqrt(Math.min(1, peak)) * height * .2;
      const px = column(x);
      context.moveTo(px, centerY - half); context.lineTo(px, centerY + half);
    }
    if (ring.count) context.stroke();
  }

  function drawOutcomes() {
    const cell = (width - 2 * MARGIN) / FRAMES;
    for (let x = 0; x < FRAMES; x++) {
      const slot = output.at(x);
      if (slot < 0) continue;
      const left = MARGIN + x * cell;
      const lost = output.flags[slot] === 2;
      context.fillStyle = lost ? COLORS.concealed : COLORS.received;
      if (lost) {
        context.beginPath();
        context.moveTo(left, height - 16); context.lineTo(left + cell / 2, height - 22); context.lineTo(left + cell, height - 16);
        context.closePath(); context.fill();
      } else {
        context.fillRect(left, height - 20, Math.max(1, cell - 1), 3);
      }
    }
  }

  function draw() {
    context.clearRect(0, 0, width, height);
    drawGrid();
    drawPeaks(input, height * .26, COLORS.input);
    drawPeaks(output, height * .66, COLORS.output);
    drawOutcomes();
  }

  function resize() {
    const box = canvas.getBoundingClientRect();
    width = box.width; height = box.height;
    const scale = Math.min(devicePixelRatio || 1, 2);
    canvas.width = Math.round(width * scale); canvas.height = Math.round(height * scale);
    context.setTransform(scale, 0, 0, scale, 0, 0);
    draw();
  }

  // The frame loop runs only while a line is open, motion is allowed and the tab is visible.
  const animating = () => live && !paused && !document.hidden;
  function cancel() { cancelAnimationFrame(frameRequest); frameRequest = 0; }
  function tick(now) {
    frameRequest = 0;
    if (!animating()) return;
    if (now - lastDraw >= MIN_DRAW_INTERVAL) { draw(); lastDraw = now; }
    frameRequest = requestAnimationFrame(tick);
  }
  function wake() { if (!frameRequest && animating()) frameRequest = requestAnimationFrame(tick); }

  function applyMotion() {
    motion.textContent = paused ? "Resume motion" : "Pause motion";
    motion.setAttribute("aria-pressed", String(paused));
    if (paused) { cancel(); draw(); } else wake();
  }

  motion.addEventListener("click", () => { paused = !paused; applyMotion(); });
  reduced.addEventListener("change", () => { paused = reduced.matches; applyMotion(); });
  document.addEventListener("visibilitychange", () => { if (document.hidden) cancel(); else wake(); });
  new ResizeObserver(resize).observe(canvas);
  applyMotion();
  resize();

  return {
    source(label) { if (sourceLabel) sourceLabel.textContent = label; },

    capture(peak) {
      input.push(peak);
      canvas.dataset.inputFrames = String(input.count);
      message.hidden = true;
      wake();
    },

    playback(peak, mode) {
      output.push(peak, mode === "conceal" ? 2 : 1);
      canvas.dataset.outputFrames = String(output.count);
      if (paused) draw();
      status.textContent = paused ? "Motion paused · audio continues" : "Live frame peaks · not a latency measurement";
      wake();
    },

    state(value) {
      live = value === "streaming" || value === "sending-fixture";
      if (value === "connecting") {
        input.reset(); output.reset();
        canvas.dataset.inputFrames = canvas.dataset.outputFrames = "0";
      }
      message.textContent = MESSAGES[value] || "Listening for the first frame…";
      message.hidden = live && input.count > 0;
      status.textContent = live ? (paused ? "Motion paused · audio continues" : "Waiting for audio frames") : "No live audio";
      if (!live) cancel();
      draw();
      wake();
    },
  };
}
