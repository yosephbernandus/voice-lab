#!/usr/bin/env python3
"""Execute the same corpus in isolated source and reference Node processes."""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REFERENCE_ROOT = ROOT.parent
SOURCE_ROOT = Path(os.environ.get("AUDIO_WORKSHOP_ROOT", REFERENCE_ROOT.parent / "audio-workshop")).resolve()
MODULES = {
    "source_packet": SOURCE_ROOT / "apps/sound_to_sound/priv/static/packet.js",
    "source_jitter": SOURCE_ROOT / "apps/sound_to_sound/priv/static/jitter-buffer.js",
    "reference_packet": REFERENCE_ROOT / "apps/sound_to_sound/priv/static/packet.js",
    "reference_jitter": REFERENCE_ROOT / "apps/sound_to_sound/priv/static/jitter-buffer.js",
}


def packet(seq: int, timestamp: int = 0, ssrc: int = 1, version: int = 2,
           payload_type: int = 0, length: int = 172) -> str:
    data = bytearray(length)
    if length >= 12:
        data[0] = (version & 3) << 6
        data[1] = payload_type & 0xFF
        data[2:4] = (seq & 0xFFFF).to_bytes(2, "big")
        data[4:8] = (timestamp & 0xFFFFFFFF).to_bytes(4, "big")
        data[8:12] = (ssrc & 0xFFFFFFFF).to_bytes(4, "big")
        for index in range(12, length):
            data[index] = (seq + index) & 0xFF
    return data.hex()


def provenance() -> dict:
    return {
        "source_commit": subprocess.check_output(
            ["git", "-C", str(SOURCE_ROOT), "rev-parse", "HEAD"], text=True
        ).strip(),
        "modules": {
            name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            for name, path in MODULES.items()
        },
    }


def parser_cases() -> list[object]:
    return [
        packet(0),
        packet(65535, 0xFFFFFFFF, 0xFFFFFFFF),
        packet(32768, 0x80000000, 0x80000000),
        packet(1, version=0),
        packet(1, version=1),
        packet(1, version=3),
        packet(1, payload_type=8),
        packet(1, payload_type=255),
        packet(1, length=0),
        packet(1, length=11),
        packet(1, length=171),
        packet(1, length=173),
        {"kind": "uint8-array", "values": [0x80] + [0] * 171},
        {"kind": "not-array-buffer"},
    ]


def pushes(*sequences: int, ssrc: int = 1) -> list[dict]:
    return [{"op": "push", "hex": packet(sequence, sequence * 160, ssrc)} for sequence in sequences]


def scenario(name: str, events: list[dict], **options: object) -> dict:
    value = {"name": name, "events": events}
    value.update(options)
    return value


def jitter_cases() -> list[dict]:
    cases = [
        scenario("startup-and-play", pushes(10, 11, 12) + [{"op": "next"}] * 4),
        scenario("near-ahead-waits", pushes(10, 11, 13) + [{"op": "next"}] * 2 + pushes(12) + [{"op": "next"}] * 3),
        scenario("proven-gap", pushes(10, 11, 13, 14, 15, 16) + [{"op": "next"}] * 5),
        scenario("duplicate-and-late", pushes(10, 11, 12, 12, 9) + [{"op": "next"}] * 3),
        scenario("sequence-wrap", pushes(65534, 65535, 0, 1) + [{"op": "next"}] * 4),
        scenario("ssrc-reset", pushes(10, 11, 12, ssrc=1) + pushes(20, 21, 22, ssrc=2) + [{"op": "next"}] * 3),
        scenario("bounded-queue", pushes(*range(100, 140)) + [{"op": "next"}] * 4, windowPackets=3,
                 options={"maxBufferPackets": 8}),
        scenario("six-empty-recovery", pushes(10, 11, 12) + [{"op": "next"}] * 8 + pushes(30, 31, 32) + [{"op": "next"}] * 4),
        scenario("gap-three-recovery", pushes(10, 11, 12, 20, 21, 22) + [{"op": "next"}] * 8 + pushes(30, 31, 32) + [{"op": "next"}] * 4),
        scenario("recovery-floor", pushes(10, 11, 12, 20, 21, 22) + [{"op": "next"}] * 8 + pushes(10, 30, 31, 32) + [{"op": "next"}] * 4),
        scenario("end-of-stream", pushes(10, 11, 12) + [{"op": "next"}, {"op": "next", "endOfStream": True}] * 3),
    ]
    return cases


def execute(side: str, corpus: dict) -> tuple[dict, str]:
    process = subprocess.run(
        ["node", str(ROOT / "source_sound.mjs"), side],
        input=json.dumps(corpus), text=True, capture_output=True, check=True,
    )
    return json.loads(process.stdout), process.stderr
def impairment_expression() -> str:
    return (
        'packets = for i <- 0..31, do: %VoiceLab.Packet{sequence_number: i, '
        'timestamp: i * 160, ssrc: 7, payload: :binary.copy(<<0>>, 160)}; '
        'policy = VoiceLab.Impairment.policy(loss: 0.2, reorder: 0.3, '
        'delay_milliseconds: 17, seed: 42); '
        'decisions = VoiceLab.Impairment.apply(packets, policy); '
        'encode = fn decision -> case decision do '
        '{:drop, packet} -> %{"kind" => "drop", "sequence_number" => packet.sequence_number}; '
        '{:deliver, packet} -> %{"kind" => "deliver", "sequence_number" => packet.sequence_number}; '
        '{:deliver_after, packet, delay} -> %{"kind" => "deliver_after", '
        '"sequence_number" => packet.sequence_number, "delay_milliseconds" => delay} end end; '
        'IO.puts(Jason.encode!(Enum.map(decisions, encode)))'
    )


def execute_impairment(root: Path) -> dict:
    app = root / "apps/sound_to_sound"
    process = subprocess.run(
        ["nix", "develop", f"path:{root}", "-c", "mix", "run", "-e", impairment_expression()],
        cwd=app, text=True, capture_output=True,
    )
    lines = [line for line in process.stdout.splitlines() if line.strip()]
    return {
        "command": f"nix develop path:{root} -c mix run -e impairment",
        "returncode": process.returncode,
        "stdout": lines[-1] if lines else "",
        "stderr": process.stderr,
    }


def impairment_observation() -> dict:
    return {
        "source": execute_impairment(SOURCE_ROOT),
        "reference": execute_impairment(REFERENCE_ROOT),
    }


def decode_impairment(observation: dict) -> dict:
    return {
        side: json.loads(value["stdout"]) if value["returncode"] == 0 else None
        for side, value in observation.items()
    }


def main() -> int:
    corpus = {"parser": parser_cases(), "jitter": jitter_cases()}
    source, source_stderr = execute("source", corpus)
    reference, reference_stderr = execute("reference", corpus)
    impairment_processes = impairment_observation()
    impairment = decode_impairment(impairment_processes)
    observations = {
        "provenance": provenance(),
        "execution": {
            "source": {"command": "node conformance/source_sound.mjs source", "stderr": source_stderr},
            "reference": {"command": "node conformance/source_sound.mjs reference", "stderr": reference_stderr},
            "impairment": impairment_processes,
        },
        "input": corpus,
        "source": source,
        "reference": reference,
        "impairment": impairment,
        "match": source["parser"] == reference["parser"] and source["jitter"] == reference["jitter"] and impairment["source"] is not None and impairment["source"] == impairment["reference"],
    }
    (ROOT / "observations.json").write_text(json.dumps(observations, indent=2, sort_keys=True) + "\n")
    print(json.dumps({
        "match": observations["match"],
        "parser_cases": len(corpus["parser"]),
        "jitter_scenarios": len(corpus["jitter"]),
        "impairment_decisions": len(impairment["source"] or []),
        "isolated_processes": ["source", "reference"],
        "observation": "conformance/observations.json",
    }))
    return 0 if observations["match"] else 1


if __name__ == "__main__":
    sys.exit(main())

