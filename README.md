# voice-lab

A clean reference implementation of the audio-workshop sound-to-sound application, plus the conformance checks that compare it with the original. The original lives in `/Users/yoseph/workspace/audio-workshop` and is read-only input: nothing here imports its production code, and the checks only read it.

The app relays 172-byte PCMU packets between two browsers through a seeded loss, reorder and delay stage, and plays them back through a jitter buffer with concealment. It also serves a two-peer WebRTC `/call` page.

## Layout

```
apps/sound_to_sound/   Mix app (Bandit, Plug, WebSocket) and the browser assets in priv/static
conformance/           source/reference differential checks and generated results
formal/parser/         Bend proof that the packet parser accepts exactly 172-byte RTP/PCMU packets
docs/adr/              design decisions
SPECIFICATION.md       observable contract and corpus description
IMPLEMENTATION.md      coverage table and verification record
HANDOFF.md             current state
flake.nix, flake.lock  pinned toolchain (Elixir, Node 22, Python 3, jq, git)
```

## Prerequisites

Nix with flakes enabled. Every command below runs inside the pinned shell, so no other tool needs installing, except Bend for the formal proof (see below). The conformance checks that compare against the original need a checkout of audio-workshop. By default they look for it next to this directory (`../audio-workshop`); set `AUDIO_WORKSHOP_ROOT` to use another path.

```sh
nix develop path:.        # interactive shell
nix develop path:. -c <command>   # one command
```

## Run the app

```sh
cd apps/sound_to_sound
nix develop path:../.. -c mix deps.get
nix develop path:../.. -c mix run --no-halt
```

The server listens on port 4200. Set `SOUND_TO_SOUND_PORT` to use another one:

```sh
SOUND_TO_SOUND_PORT=4210 nix develop path:../.. -c mix run --no-halt
```

Open `http://127.0.0.1:4200/` for the sound page (microphone or the bundled fixture, loopback through the relay with the impairment controls) and `http://127.0.0.1:4200/call` in two tabs with the same room for the two-peer call. `/health` returns `ok`.

```ts
Browser capture or fixture
  → downsample and PCMU encode
    → 172-byte packet over /socket
      → relay with listener-owned impairment
        → jitter buffer (play, wait, conceal, rebuffer)
          → PCMU decode and playback worklet
```

## Tests

```sh
cd apps/sound_to_sound
nix develop path:../.. -c mix test --warnings-as-errors   # 70 tests
```

## Conformance checks

Run these from the repository root. All of them need audio-workshop (see `AUDIO_WORKSHOP_ROOT`) and exit non-zero on a mismatch.

```sh
# packet parser, jitter buffer and seeded impairment; 14 parser, 11 jitter, 32 impairment cases
SOUND_TO_SOUND_PORT=4200 AUDIO_WORKSHOP_ROOT=../audio-workshop nix develop path:. -c python3 conformance/run.py

# 20 seeded BEAM cases (impairment, pipeline, concealment) on both Elixir apps
AUDIO_WORKSHOP_ROOT=../audio-workshop nix develop path:. -c python3 conformance/beam_diff.py

# packet, mu-law and downsampler kernels in Node
AUDIO_WORKSHOP_ROOT=../audio-workshop nix develop path:. -c node conformance/browser_protocol.mjs
```

`run.py` starts the Mix apps through `mix run`, so a busy port 4200 only matters if you leave the app running; set `SOUND_TO_SOUND_PORT` to a free port if the run fails with `eaddrinuse`.

`live_smoke.mjs` compares two running servers, so start the original and the reference first, each on its own port:

```sh
# terminal 1, in audio-workshop/apps/sound_to_sound
SOUND_TO_SOUND_PORT=4201 nix develop path:../.. -c mix run --no-halt
# terminal 2, in voice-lab/apps/sound_to_sound
SOUND_TO_SOUND_PORT=4202 nix develop path:../.. -c mix run --no-halt
# terminal 3, in voice-lab
AUDIO_WORKSHOP_ROOT=../audio-workshop SOURCE_URL=http://127.0.0.1:4201/ REFERENCE_URL=http://127.0.0.1:4202/ \
  nix develop path:. -c node conformance/live_smoke.mjs
```

The check is repeatable against the same servers. The harness buffers every frame from socket creation (a per-call listener lost the second of two back-to-back frames), retries joins while a closing socket still holds its seat, and the stale-timer step sets `latency=400`, waits for the policy announcement, sends one packet, resets the policy, and expects only the reset announcement afterwards. The server reads the policy keys `latency` and `delay`; `*_milliseconds` keys are ignored, and `delay` only affects reordered packets. It checks `/health`, static paths, the exact 172-byte relay, policy reset, stale timers, malformed input, a third peer, invalid policy, signaling and cross-origin rejection, and prints `"match":true` when both servers behave the same. `LIVE_SMOKE_TIMEOUT_MS` changes the 4000 ms per-step timeout.

### Evidence files

Everything the checks write is generated and not committed: `conformance/results/` and `conformance/observations.json` are in `.gitignore`, as is the bench output directory. Rerun a check to regenerate its record. `IMPLEMENTATION.md` quotes counts from earlier runs rather than linking to files.

## Offline bench

The bench runs a WAV through the impairment, jitter buffer and each concealment strategy without a browser or a clock, and writes one WAV per strategy plus `results.json`. Queued packets are drained at once, so it is not a timing model.

```sh
cd apps/sound_to_sound
nix develop path:../.. -c mix bench --input priv/static/talk-a-indonesian.wav --output bench_out --seed 42 --loss 0.10 --reorder 0.05 --delay 60
```

## Formal parser proof

`formal/parser/` holds a Bend proof of the law in `LAWS.md`: the parser accepts a packet exactly when it is 172 bytes long with RTP version 2 and payload type 0. It needs Bend 2.0.38, which the flake does not provide; install it separately.

```sh
cd formal/parser
bend PROOF.bend --check-only
bend PROOF.bend --verdict      # ALL PROOFS CHECK
AUDIO_WORKSHOP_ROOT=../../../audio-workshop nix develop path:../.. -c ./run-differential.sh   # DIFFERENTIAL MATCH: 80/80
bend negative/PROOF.bend --check-only                       # expected to fail
```

`run-differential.sh` needs `bend` on the PATH inside the shell, plus `jq` from the flake.

## Known limits

- No physical microphone, speaker or device clock was measured. Browser runs used headless Chromium with a fixture source.
- Safari, Android and iOS browsers were not tried.
- Both call peers ran on localhost host candidates. TURN, venue networks and real packet loss are not covered.
- The proof covers parser acceptance only, not DSP, timing or concurrency.
- Some modules stay close to the original (`wav.ex`, `concealment.js`, `upsample.js`, `packet.js`, `call.js`). Similarity numbers are in `IMPLEMENTATION.md`.
