# StemSplitter for Mac

Drop a song or video → 4 stems (Mel-Band RoFormer vocals + htdemucs instrumental residual)
+ key, BPM, chords and notes → pitch it, add FX → drag stems or MIDI into any DAW.
Paste a Spotify or YouTube link (⌘U) and the track lands in the same pipeline via the
local spotDL install. On-device. Plan: [PLAN.md](PLAN.md).

## Link downloads (spotDL)

Optional. Needs a one-time install on the Mac:

```sh
brew install ffmpeg && pipx install spotdl
```

File ▸ Download from Link… (⌘U) validates a Spotify track/album/playlist or YouTube
URL, runs your `spotdl` (found in `~/.local/bin` or Homebrew paths), and shows per-job
progress with cancel/retry. MP3s — Spotify metadata, YouTube audio — keep in
`~/Library/Application Support/StemSplitter/Downloads/` and split like dropped files;
re-pasting a known link skips the download and focuses the existing song.

## Setup (once)

Models are generated, not committed.

```sh
cd tools
uv venv --python 3.11 .venv
uv pip install --python .venv/bin/python torch==2.5.1 torchaudio==2.5.1 demucs coremltools==8.3 numpy soundfile
uv pip install --python .venv/bin/python einops beartype rotary_embedding_torch librosa
.venv/bin/python convert_htdemucs.py      # → Models/htdemucs.mlpackage (120 MB) + parity fixtures
# KimberleyJSN Mel-Band RoFormer (MIT weights) — implementation vendored in tools/msst:
curl -sL -o MelBandRoformer.ckpt "https://huggingface.co/KimberleyJSN/melbandroformer/resolve/main/MelBandRoformer.ckpt"
.venv/bin/python convert_melband.py       # → Models/melband-roformer.mlpackage (437 MB) + parity fixtures
./fetch_basic_pitch.sh                    # → Models/basic-pitch.mlpackage
cd ..
# Compiled copies for `swift test` / stembench (the app compiles its own):
xcrun coremlcompiler compile Models/htdemucs.mlpackage Models/
xcrun coremlcompiler compile Models/melband-roformer.mlpackage Models/
xcrun coremlcompiler compile Models/basic-pitch.mlpackage Models/
```

`xcode-select` points at CommandLineTools on this machine, so prefix Xcode commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Build and run

```sh
xcodegen generate
xcodebuild -project StemSplitterMac.xcodeproj -scheme StemSplitter -derivedDataPath .build/dd build
open .build/dd/Build/Products/Debug/StemSplitter.app
```

## Test and benchmark

```sh
swift test                                    # 23 tests; model tests skip if Models/ is missing
swift build -c release --product stembench
.build/release/stembench song.mp3 3           # split ×3 (thermals) + analysis + transcription timings
```

## Layout

| Path | What |
|---|---|
| `Sources/StemSeparation` | Decode (any audio/video) → cascade: Mel-Band RoFormer pulls vocals (8 s segments, complex band-mask, Swift STFT/scatter/iSTFT), htdemucs splits the instrumental residual. 25 % triangle overlap-add → 24-bit WAVs + peaks. |
| `Sources/StemAnalysis` | BPM (drums), key + chords (bass+other), notes (basic-pitch), MIDI writer. Accelerate only. |
| `Sources/StemMix` | One AVAudioEngine graph for playback *and* offline export: per-stem EQ/delay/reverb, master pitch/tempo/EQ. |
| `Sources/StemLink` | Spotify/YouTube link parsing + spotDL subprocess runner (locate, progress lines, cancel). |
| `App/` | SwiftUI app: library, queue, zoomable timeline, inspector, drag-out, Services menu, Photos import, link-download screen. |
| `tools/` | Model conversion (`convert_melband.py`, `convert_htdemucs.py`; MIT model code vendored in `tools/msst`). |

Library lives in `~/Music/StemSplitter/<song>/`: stems, `peaks-*.f32`, `analysis.json`,
`notes-*.json`, `mix.json`, `song.json`. Plain files are the database.

## Measured (M3 Max)

- Split (2-stem, roformer): 5:25 song in 47.6 s (6.8× realtime).
- Split (4-stem, cascade): same song in 62.2 s (5.2× realtime); htdemucs alone was 38×.
- Model: roformer ~0.78 s per 8 s segment on GPU; htdemucs 130 ms per 7.8 s.
- Analysis 0.3 s. Transcription 0.6 s per stem.
- Core ML vs fp32 torch: roformer mask 47 dB; htdemucs drums 32 / bass 30 / other 63 / vocals 67 dB SNR (mixed precision, see converter headers).
