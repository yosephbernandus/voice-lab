import { spawn } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const kernel = path.join(here, "browser_kernels.mjs");
const operations = ["packet", "mulaw", "downsample"];
const fixture = { operations, packet: "fixed header boundaries, flags, versions, lengths, ArrayBuffer types", mulaw: "all signed PCM16 values and all byte values", downsample: "supported rates, impulse, multitone, streaming prefixes" };
const sha = value => createHash("sha256").update(JSON.stringify(value)).digest("hex");

function run(side) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [kernel, side], { env: process.env });
    let stdout = "", stderr = "";
    child.stdout.on("data", chunk => { stdout += chunk; });
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.on("error", reject);
    child.stdin.end(JSON.stringify({ operations }));
    child.on("close", code => {
      if (code !== 0) return reject(new Error(`${side} kernel exited ${code}: ${stderr}`));
      try { resolve({ output: JSON.parse(stdout), stderr }); } catch (error) { reject(new Error(`${side} invalid JSON: ${error.message}\n${stdout}`)); }
    });
  });
}

function firstDifference(a, b, path = "$") {
  if (Object.is(a, b)) return null;
  if (typeof a !== typeof b || a === null || b === null) return { path, source: a, reference: b };
  if (Array.isArray(a) !== Array.isArray(b)) return { path, source: a, reference: b };
  if (Array.isArray(a)) {
    if (a.length !== b.length) return { path: `${path}.length`, source: a.length, reference: b.length };
    for (let i = 0; i < a.length; i++) { const difference = firstDifference(a[i], b[i], `${path}[${i}]`); if (difference) return difference; }
    return null;
  }
  if (typeof a === "object") {
    const keys = [...new Set([...Object.keys(a), ...Object.keys(b)])].sort();
    for (const key of keys) { const difference = firstDifference(a[key], b[key], `${path}.${key}`); if (difference) return difference; }
    return null;
  }
  return { path, source: a, reference: b };
}

const [source, reference] = await Promise.all([run("source"), run("reference")]);
const sourceResults = source.output.results, referenceResults = reference.output.results;
const mismatches = operations.map(operation => ({ operation, difference: firstDifference(sourceResults[operation], referenceResults[operation]) })).filter(entry => entry.difference);
const observation = {
  fixture,
  fixtureDigest: sha(fixture),
  execution: { source: "node conformance/browser_kernels.mjs source", reference: "node conformance/browser_kernels.mjs reference", sourceStderr: source.stderr, referenceStderr: reference.stderr },
  provenance: { source: source.output.modules, reference: reference.output.modules },
  outputDigests: { source: source.output.resultDigest, reference: reference.output.resultDigest },
  mismatches,
  match: mismatches.length === 0,
};
const outputDir = path.join(here, "results");
await mkdir(outputDir, { recursive: true });
const outputPath = path.join(outputDir, `browser-${new Date().toISOString().replaceAll(/[-:.TZ]/g, "").slice(0, 14)}.json`);
await writeFile(outputPath, JSON.stringify({ ...observation, source: sourceResults, reference: referenceResults }, null, 2) + "\n");
process.stdout.write(JSON.stringify({ match: observation.match, output: outputPath, fixtureDigest: observation.fixtureDigest, outputDigests: observation.outputDigests, mismatches }) + "\n");
process.exitCode = observation.match ? 0 : 1;
