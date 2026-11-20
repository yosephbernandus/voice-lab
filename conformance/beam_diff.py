#!/usr/bin/env python3
from __future__ import annotations
import hashlib, json, os, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REFERENCE_ROOT = Path(os.environ.get("VOICE_LAB_REFERENCE_ROOT", HERE.parent)).resolve()
SOURCE_ROOT = Path(os.environ.get("AUDIO_WORKSHOP_ROOT", REFERENCE_ROOT.parent / "audio-workshop")).resolve()
DRIVER = HERE / "beam_driver.exs"
OUTPUT_DIR = Path(os.environ.get("BEAM_RESULTS_DIR", HERE / "results"))

def fixture_hex():
    samples = [((i * 977 + i * i * 13) % 65536) - 32768 for i in range(160 * 4 + 37)]
    return b"".join(int(x).to_bytes(2, "little", signed=True) for x in samples).hex()

def corpus():
    policies = [("clean", 0.0, 0.0, 0, 0), ("loss", 0.22, 0.0, 0, 0), ("reorder", 0.0, 0.34, 40, 0), ("mixed", 0.18, 0.28, 60, 20), ("latency", 0.0, 0.0, 0, 180)]
    pcm = fixture_hex(); cases = []
    for seed in (0, 7, 42, 19):
        for name, loss, reorder, delay, latency in policies:
            cases.append({"id": f"sound/{name}/seed-{seed}", "fixture": f"fixture://sound/{name}/seed-{seed}", "pcm_hex": pcm, "seed": seed, "loss": loss, "reorder": reorder, "delay_milliseconds": delay, "latency_milliseconds": latency, "strategy": "repeat"})
    return {"cases": cases}

def identity(root):
    def git(*args):
        p = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
        return p.stdout.strip() if p.returncode == 0 else f"error:{p.stderr.strip()}"
    return {"revision": git("rev-parse", "HEAD"), "status": git("status", "--short")}

def hashes(root):
    names = ["impairment.ex", "pipeline.ex", "jitter_buffer.ex", "concealment.ex", "packet.ex", "mulaw.ex"]
    result = {}
    for name in names:
        path = root / "apps/sound_to_sound/lib/voice_lab" / name
        result[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
    return result

def execute(root, encoded):
    app = root / "apps/sound_to_sound"
    command = ["nix", "develop", f"path:{root}", "-c", "mix", "run", "--no-start", str(DRIVER)]
    p = subprocess.run(command, cwd=app, input=encoded, text=True, capture_output=True)
    observation = None; parse_error = None
    lines = [line for line in p.stdout.splitlines() if line.strip()]
    if lines:
        try: observation = json.loads(lines[-1])
        except json.JSONDecodeError as error: parse_error = str(error)
    return {"root": str(root), "cwd": str(app), "command": command, "started_at": datetime.now(timezone.utc).isoformat(), "exit_code": p.returncode, "stderr": p.stderr, "stdout": p.stdout, "observation": observation, "parse_error": parse_error, "revision": identity(root), "module_hashes": hashes(root)}

def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True); input_value = corpus(); encoded = json.dumps(input_value, separators=(",", ":"))
    source = execute(SOURCE_ROOT, encoded); reference = execute(REFERENCE_ROOT, encoded)
    (OUTPUT_DIR / "beam-source.json").write_text(json.dumps(source, indent=2) + "\n")
    (OUTPUT_DIR / "beam-reference.json").write_text(json.dumps(reference, indent=2) + "\n")
    mismatches = []
    if source["exit_code"] == 0 and reference["exit_code"] == 0 and source["observation"] is not None and reference["observation"] is not None:
        left = {x["id"]: x for x in source["observation"]}; right = {x["id"]: x for x in reference["observation"]}
        for case in input_value["cases"]:
            key = case["id"]
            if left.get(key) != right.get(key): mismatches.append({"id": key, "source": left.get(key), "reference": right.get(key)})
    else: mismatches.append({"id": "__prerequisite__", "reason": "source or reference did not produce valid JSON"})
    result = {"input": input_value, "source": source, "reference": reference, "mismatches": mismatches, "case_count": len(input_value["cases"]), "match_count": len(input_value["cases"]) - len(mismatches), "match": not mismatches and source["exit_code"] == 0 and reference["exit_code"] == 0}
    (OUTPUT_DIR / "beam-diff.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"cases": result["case_count"], "matches": result["match_count"], "mismatches": len(mismatches), "output": str(OUTPUT_DIR / "beam-diff.json")}))
    return 0 if result["match"] else 1

if __name__ == "__main__": sys.exit(main())
