<!-- /autoplan restore point: "/Users/kristers/.gstack/projects/kristers/stemsplitter-mac-autoplan-restore-20261001-080905.md" -->
## Implementation plan
# StemSplitter for Mac — Plan

Status: APPROVED (autoplan) · 2026-10-01 · Sister project to `../stemsplitter` (iOS)

## Implementation status (2026-10-01)

Phases 0–4 are built and running. See README.md for build steps and measurements.

- **Done:**
  - htdemucs converted to Core ML. STFT/iSTFT run in Swift and match torch (>80 dB).
  - Streaming split: 6:09 song in 9.8 s on M3 Max.
  - BPM / key / Camelot / chords, all following the pitch control.
  - basic-pitch notes with piano-roll lanes and MIDI drag-out.
  - Per-stem EQ/delay/reverb and master pitch/tempo/EQ, with one graph for playback and export. The null test passes.
  - Stem drag-out. Export to WAV/AIFF/FLAC (16/24/32f, source/44.1/48 kHz) and video with swapped audio.
  - Queue with cancel, library in ~/Music, Services menu, Open With / Dock drop, Photos import, split-part (trim).
  - Timeline zoom: pinch, ⌘= / ⌘− / ⌘0, zoom to selection, time ruler, follow-playhead.
  - 23 unit tests.
- **Deviations:**
  - *Not a monorepo.* `../stemsplitter` was being edited by another session and stopped compiling, which broke this build through the path dependency. The Mac package is standalone. AudioDecoder duplicates ~60 lines of StemCore.AudioExtractor. Re-unify when both apps share one package.
  - *Mixed precision.* Plain fp16 costs bass about 23 dB of agreement with torch, because the freq and time branches partly cancel. The default is fp16 conv/matmul with fp32 elsewhere: 30 dB or better, 130 ms per segment, 120 MB.
- **Not done:**
  - Pricing gate / StoreKit (needs an App Store Connect product, and would lock dogfooding).
  - Playing finished chunks during a split (a split takes about 10 s, so little value).
  - 20-song accuracy fixtures for BPM/key/chords (needs labeled songs).
  - Base-M1 benchmark (no M1 here).

## One-liner

Drag any song or video onto the window → 4 stems + key + BPM + chords in seconds → pitch it, add FX, read the notes → drag stems or MIDI straight into your DAW. On-device, no account, no upload.

**Positioning (from review):** StemLab has stems + FX but no key, BPM, chords, or MIDI. Logic/Ableton have stems but are DAWs. We are "stems that understand the music": separation feeds analysis, because transcription is far better on an isolated stem than on a full mix.

## Founder request (2026-10-01, supersedes v2/"no" list where they conflict)

"Drag a video/mp3 → stems + key + BPM. Pitch it. Add reverb, delay, EQ. See chords / melody / notes."
Reference: StemLab (apps.apple.com/us/app/stemlab-stem-splitter-vocals/id6762580115).

So v1 now also includes:
- Key + BPM detection on drop.
- Pitch shift (semitones) on playback and export.
- Per-stem or master FX: reverb, delay, EQ.
- Chords, melody, and notes view (chord timeline + note/piano-roll of a stem, MIDI export).

## Market reality (read first)

The Mac is more crowded than iPhone. Stem separation is already built into tools producers own:

| Competitor | Stems | Price | Weakness we exploit |
|---|---|---|---|
| Logic Pro 11 Stem Splitter | 4 (+ guitar/piano in 11.2) | $199 | Logic only. Heavy for "just grab the vocal". |
| Ableton Live 12.3 stem separation | 4 | Suite tier | Ableton only. |
| FL Studio stem separation | 4 | DAW price | FL only. |
| UVR5 (Ultimate Vocal Remover) | many | free | Ugly, Python, confusing model zoo, slow setup. |
| Demucs CLI | 4/6 | free | Terminal only. |
| Moises / LALAL.AI / Fadr | 4–10 | subscription | Cloud upload, accounts, waiting. |
| iZotope RX / SpectraLayers | pro | $$$ | Overkill, expensive. |
| StemLab (iOS app on Mac) | 6 + per-stem FX/pitch | $1.99/wk–$59.99 | iPad UI on Mac, macOS 26.2+, 367 MB. No key/BPM, no chords, no MIDI, no drag-out, no batch. |

**Wedge:** a DAW-agnostic utility that's faster to use than opening your DAW. It's for Ableton/FL/Bitwig/Reaper users who don't own Logic, DJs, and people sampling from videos. The pitch is speed of the *workflow*, not of the model.

**Kill criterion:** if the founder (who may own Logic) still reaches for Logic's splitter after 2 weeks of dogfooding, the wedge is wrong.

## What changes vs the iOS plan

| Constraint | iOS | Mac |
|---|---|---|
| Speed headroom | iPhone 12 ANE, thermal limits | M1+ GPU/ANE, fans. 4-stem htdemucs is realistic in v1. |
| Background | Foreground-only / BGContinuedProcessingTask | Not a problem. Queue runs while you work. |
| Input | Photos videos | Any file: drag-drop, Open, Photos library, Finder right-click |
| Output | Share sheet | **Drag stems out** to Finder/DAW. Export folder. |
| Batch | No | Yes. Drop 20 files, walk away. |
| Window | One screen | Real timeline with a mixer |
| Pricing norm | Weekly subs | One-time purchase is what Mac users expect |

## v1 scope

**Input**
- Drag-drop onto the window or Dock icon. File → Open. Photos library (`PhotosPicker` works on macOS).
- Anything AVFoundation decodes: MP3, WAV, AIFF, FLAC, M4A/AAC, ALAC, MP4, MOV.
- Finder Quick Action: right-click file → "Split Stems" (App Intent / Services). This is the Mac version of the share-sheet idea and costs far less here.

**Separation**
- 4-stem default: vocals, drums, bass, other.
- 2-stem mode: vocals + instrumental (faster).
- Queue with per-item progress and cancel. Cancelling discards partial output.
- Trim/region before splitting. Selecting 20 s of a 6-minute clip makes the split much faster.

**Result view**
- Stacked waveforms on one shared timeline.
- Per-stem volume, solo, mute (`AVAudioEngine` mixer nodes).
- A/B loop. Drag on the waveform to select a region. Space to play.
- For video sources: video preview synced above the timeline.

**Output**
- **Drag a stem row out** to Finder or a DAW track (`NSItemProvider` file promise). This is the headline Mac feature.
- Export: individual stems, selected region only, or mixdown at current fader levels.
- Formats: WAV, AIFF, FLAC. Sample rate: match source (default), 44.1, 48. Bit depth: 16 / 24 / 32-float.
- Video export with replaced audio (karaoke / vocals-only video).
- Configurable naming: `{name} - {stem}.wav`.

**Analysis (runs automatically after split, < 3 s for a 3-min song)**
- BPM: onset envelope from the **drums stem** → autocorrelation tempogram, 60–200 range. Shows ½× / 2× toggle (octave errors are the common failure). No drums detected → "—", never a guess.
- Key: 12-bin chroma from **bass + other** stems (drums excluded) → Krumhansl/Temperley profile correlation over 24 keys. Shows key, Camelot code (8A), and confidence; low confidence shows the runner-up (usually relative major/minor). Atonal/drum-only → "—".
- Chords: beat-synchronous chroma → template match (maj, min, 7, maj7, m7, dim, sus2/4) + Viterbi smoothing. Shown as a chord lane on the timeline.
- Key, BPM, and chords follow the pitch control: +2 st turns "A minor" into "B minor" everywhere, including filenames.

**Transcription (notes / melody)**
- Model: Spotify basic-pitch (Apache-2.0, ships a Core ML model, ~22 kHz input, polyphonic, "best on one instrument at a time" → stems are the ideal input).
- Melody = vocals stem, reduced to one note at a time. Bass line = bass stem. Harmony = other stem (polyphonic).
- Piano-roll lane per stem, toggled on the timeline. Plays in sync with audio.
- **Drag a MIDI clip out** (per stem, or selected region) to Finder/DAW. Hand-written SMF writer, no dependency.
- Runs in background after analysis; lazily on first open for files > 15 min.

**Mix & FX (AVAudioEngine built-ins, zero dependencies)**
- Per stem: volume, pan, solo, mute, 3-band EQ (`AVAudioUnitEQ`), delay (`AVAudioUnitDelay`, time in ms or beat-synced to detected BPM), reverb (`AVAudioUnitReverb`, factory preset + wet/dry).
- Master: pitch ±12 semitones and tempo 50–150 % (`AVAudioUnitTimePitch`), master EQ.
- Bypass per effect. Reset per stem. No presets, compressor, saturation, or recording in v1.
- Export renders the same graph offline (manual rendering mode) → what you hear is what you export.

**Library**
- Sidebar of past splits, persisted to `~/Music/StemSplitter/{song}/`. Plain files on disk act as the database. No Core Data.

## v2+ (not now)

- 6-stem (add guitar, piano) once model quality allows.
- (moved to v1: BPM + key, pitch/tempo, FX, chords, notes/MIDI.)
- Chord chart export (PDF/text lead sheet).
- FX presets, compressor, saturation.
- CLI (`stemsplit song.mp3`) and Shortcuts actions for power users.
- Watch folder (auto-split anything dropped into a folder).
- AU/VST plugin. Large effort, skip unless users ask.
- Recording over the track: no. That's the DAW's job.

## UI

Native SwiftUI, dark-first. Three regions in one `NavigationSplitView`. Chords and notes live **on the timeline**, not on a separate screen: you see them while you listen.

```
┌──────────────┬──────────────────────────────────────────────────┬────────────────┐
│ LIBRARY      │ concert_042.mov · 3:12   124 BPM [½×][2×]        │ INSPECTOR      │
│              │ A minor · 8A · conf 0.82    Pitch [-][+2 st][+]  │ [Stem FX|Export│
│ ▸ Queue (2)  │ ┌──────────── video (if source is video) ──────┐ │ ── Vocals ──── │
│  song_a  62% │ └──────────────────────────────────────────────┘ │ EQ  L ▬○ M ○▬  │
│  song_b  —   │ ──A━━━━━━━━━━━━━━━━━━B────────────── ▶ ↻ 100%    │     H ▬▬○      │
│              │ CHORDS │ Bm   │ G    │ D    │ A    │ Bm   │      │ Delay ☑ 1/8 ●  │
│ ▸ Recent     │ ≡ Vocals [S][M][♪] ▁▃▇▅▂▇▃▁▅▇▂▃▅▁▃▇▅▂            │   fb 30% mix 20│
│  concert_042 │     ♪ ▬ ▬▬  ▬ ▬▬▬  ▬   (melody piano-roll)       │ Reverb ☑ Hall  │
│  beat_ref    │ ≡ Drums  [S][M]    ▇▁▇▁▇▁▇▁▇▁▇▁▇▁▇▁▇▁▇            │   wet 25%      │
│              │ ≡ Bass   [S][M][♪] ▃▃▅▅▃▃▅▅▃▃▅▅▃▃▅▅▃            │ [Bypass][Reset]│
│              │ ≡ Other  [S][M][♪] ▂▅▃▇▂▅▃▇▂▅▃▇▂▅▃▇▂            │                │
│              │ ↑ drag ≡ = audio stem · drag ♪ lane = MIDI clip   │                │
└──────────────┴──────────────────────────────────────────────────┴────────────────┘
```

- **Header** always shows BPM, key, Camelot, pitch. Pitch changes rewrite key + chords live.
- **[♪]** toggles that stem's piano-roll lane. Lanes show a spinner while transcription runs, then fill in.
- **Inspector** has two tabs: Stem FX (for the selected stem, or Master) and Export.
- **States:** empty (whole window is a drop target: "Drop a song or video. Nothing leaves your Mac."), splitting (waveform fills left to right, finished regions play), analyzing (header shows "Detecting key…" skeleton, < 3 s), transcribing (♪ lanes spin, rest of UI usable), failed (inline per-feature: "No beat found" for BPM, "No clear key" for key; never blocks the stems).
- **Keyboard first:** Space play · S solo · M mute · 1–4 select stem · N toggle notes · I/O loop · ⌘↑/⌘↓ pitch ±1 st · ⌘E export · ⌘⇧E mixdown · ⌘O open.
- Monospaced numbers. One accent color. Each stem gets its own hue for waveform and notes only.
- Accessibility: every control has a VoiceOver label; key/BPM/chord are readable text, not images; contrast ≥ 4.5:1 on dark.

## Architecture

**Decision (review, taste):** don't create a new `StemKit` package. `../stemsplitter` already has `StemCore` (Foundation-only, declares `.macOS(.v14)`): chunker, OLA, 24-bit streaming `WAVWriter`, `ETACalibrator`, `PipelineEvent`/`StemError` contracts. Add the macOS app as a second target in that repo (monorepo), and add two new library targets.

```
stemsplitter/                         (existing repo, becomes the monorepo)
  Package.swift
  Sources/StemCore/      EXISTING. Decode, chunk, OLA, WAVWriter, contracts (FROZEN).
     + Engine/MultiStemSeparator.swift   NEW protocol: chunk → N waveforms (htdemucs shape).
                                         Existing StemModel is a 2-stem *mask* contract; htdemucs
                                         outputs 4 waveforms directly, so it can't conform.
  Sources/StemAnalysis/  NEW (pure Swift + Accelerate, no AVFoundation playback)
     Chroma.swift        vDSP FFT → 12-bin chroma frames
     TempoDetector.swift onset envelope → tempogram → BPM + beat grid
     KeyDetector.swift   chroma profile → 24-key correlation → key, camelot, confidence
     ChordTracker.swift  beat-sync chroma → templates → Viterbi
     NoteTranscriber.swift  basic-pitch Core ML → note events
     MIDIWriter.swift    note events → SMF type 1 bytes
  Sources/StemMix/       NEW (macOS + iOS)
     MixGraph.swift      AVAudioEngine graph, one builder used for playback AND offline export
     ExportRenderer.swift manual rendering mode → WAVWriter
  Apps/Mac/              NEW SwiftUI app target (sandboxed)
  Apps/iOS/              existing App/ moves here later, not now
```

**Pipeline**

```
drop file
  │
  ▼
AudioExtractor (StemCore) ─► MultiStemSeparator (htdemucs, chunked) ─► 4× WAV on disk + peaks
                                                                          │
              ┌───────────────────────────────┬───────────────────────────┤
              ▼                               ▼                           ▼
   TempoDetector(drums)        KeyDetector + ChordTracker        NoteTranscriber
   → BPM, beats                (bass+other, beat-synced)         (vocals, bass, other)
              └──────────────┬────────────────┘                  background, lazy > 15 min
                             ▼                                            ▼
                      analysis.json  ◄──────────────────────── notes-<stem>.json
                  (beside the WAVs; the library reads it)
```

**Playback / export graph (one builder, two modes)**

```
per stem:  PlayerNode ─► EQ(3-band) ─► Delay ─► Reverb ─► StemMixer(vol, pan, mute)
                                                                │
all stems ──────────────────────────────────────────────► MainMixer ─► TimePitch(st, rate) ─► MasterEQ ─► Output
                                                                                  (export: manual rendering → WAVWriter)
```

- **Decode:** existing `AudioExtractor` (`AVAssetReader` → Float32, `AVAudioConverter` → 44.1k, mono → dual-mono).
- **Model:** htdemucs (MIT). Spike decides runtime: Core ML (`coremltools`) vs MLX port. No PyTorch bundled.
- **Pipeline:** chunk with overlap, overlap-add, stream to disk. Never hold full song × 4 stems in RAM.
- **Analysis input:** reads stems from disk at 22.05 kHz mono (analysis doesn't need 44.1 stereo). A 10-min song's chroma is ~26k frames × 12 floats ≈ 1.2 MB. Fine in RAM.
- **Pitch:** applied on the master so stems never drift apart. `AVAudioUnitTimePitch` is clean to roughly ±5 st; UI allows ±12 with no warning (user decides by ear).
- **Delay beat-sync:** delay time = 60/BPM × note value; follows tempo control.
- **Waveforms:** peaks cached beside the WAVs at write time.
- **Storage:** `~/Music/StemSplitter/{song}/` holds `{stem}.wav`, `peaks.bin`, `analysis.json`, `notes-{stem}.json`, `mix.json` (FX settings). Plain files are the database. `analysis.json` carries a `version` field; a newer analyzer re-runs on open when the version is older.
- **Engine config change** (headphones unplugged, output device switch): observe `AVAudioEngineConfigurationChange`, rebuild graph from `mix.json`, keep playhead.

## Success criteria

- **Speed spike (day 1–2):** 3-minute song, 4 stems, under 30 s on a base M1. 3 back-to-back runs (thermal). 2-stem under 15 s.
- **Quality:** blind listen vs Logic Pro Stem Splitter and UVR5 on 5 tracks, incl. 2 phone concert clips. Must not lose clearly to Logic.
- **Analysis accuracy** (fixture set of 20 songs with known BPM/key from public metadata + 5 synthetic): BPM within ±1 on ≥ 18/20 counting ½×/2× as correct, exact on ≥ 15/20. Key exact on ≥ 15/20, exact-or-relative on ≥ 18/20. Analysis < 3 s per 3-min song on M1.
- **Chords:** on 5 hand-labeled pop songs, ≥ 70 % of beats correct at maj/min level.
- **Transcription:** vocal melody MIDI of 5 songs, played back in a DAW, is recognizably the tune (founder judgment) on ≥ 4/5. basic-pitch < 10 s per stem per 3 min.
- **FX/export:** all FX bypassed + pitch 0 → exported stem null-tests against the source stem (peak diff < -90 dBFS). Exported mix = what you heard.
- **Workflow:** drop file → stem *or* MIDI dragged into Ableton in under 45 s, zero dialogs.
- Handles: no-audio video, 2-hour DJ set (streams; transcription lazy), cancel mid-split, corrupt file, a cappella (BPM "—"), drum loop (key "—").
- App size under 200 MB (htdemucs ~80 MB + basic-pitch ~1 MB). Crash-free through all paths.

## Distribution and pricing

- **Recommended: Mac App Store.** Same $99 developer account as iOS. Sandboxing works fine (open panel, drag-drop, file promises are sandbox-safe). Universal purchase with iOS possible later.
- Alternative: Developer ID + notarization, sold direct (Paddle/Lemon Squeezy).
- **Price:** one-time $29–39. Free tier: 2-stem + key/BPM. Paid: 4-stem, FX/pitch export, chords, MIDI, batch, drag-out. StemLab's $59.99 lifetime is the anchor; we add analysis it doesn't have.

## Open questions

1. Does the founder own Logic? If yes, does this still get used? (kill criterion)
2. Core ML vs MLX: decided by the spike.
3. Mac first or iOS first? (Review: Mac first. The new features are desk features.)
4. Name. Shared brand across both apps?
5. Minimum macOS: 15. (`AVAudioUnit*` effects and manual rendering all exist on 15.)

## Build order (each phase ships something usable)

| Phase | Deliverable | Human | CC |
|---|---|---|---|
| 0 | Spike: htdemucs Core ML vs MLX, benchmark on M1 | 3 d | 1 d |
| 1 | Mac target, drop → 4 stems, mixer, drag-out, export | 1 w | 1–2 d |
| 2 | StemAnalysis: BPM, key, chords + fixtures | 1 w | 1 d |
| 3 | StemMix: per-stem EQ/delay/reverb, master pitch/tempo, offline export | 4 d | 1 d |
| 4 | Transcription: basic-pitch Core ML, piano-roll lanes, MIDI drag-out | 1 w | 1–2 d |
| 5 | Polish, App Store, pricing gate | 4 d | 1 d |

## This week

1. Spike: convert htdemucs to Core ML *and* try an MLX port. Benchmark on the M1 floor.
2. Spike (half day): run basic-pitch Core ML on a Demucs vocal stem vs the full mix. Confirms the "stems make transcription better" bet.
3. Blind listen vs Logic + UVR5. Send 3 producer friends the before/after + a MIDI of the melody. Record who asks for the app.

## Review record

Run: /autoplan 2026-10-01 · mode SELECTIVE EXPANSION · single-reviewer mode.
Coverage notes: Codex outside voice **unavailable** (CLI `broken_install`: vendor binary ENOENT; fix `npm install -g @openai/codex`). Native Claude subagent voices **unavailable**: autoplan `phase-publication-hook` denied every `Read`/`Agent` phase-entry call ("Native parent evidence has not reached the journal yet", 6 attempts) in this desktop session. Methodology loaded via Bash instead. All consensus cells N/A.

### Phase 1 — CEO review

**0A Premise challenge**
- P1 "Wedge = DAW-agnostic stem utility." Weak alone: Logic/Ableton/FL ship splitters, UVR5 is free. Founder's new asks fix it. StemLab (closest Mac-available rival) has stems + FX but **no key, BPM, chords or MIDI**. "Stems that understand the music" is a wedge nobody owns. Accepted with reframed one-liner.
- P2 "FX chain is the DAW's job" (original plan). Overridden by founder request. Kept narrow: built-in AU effects only (pitch/tempo, 3-band EQ, delay, reverb). Cost is near zero because `AVAudioUnit*` exist; risk is scope creep toward StemLab's 6-effect chain + presets. Compressor/saturation/presets deferred.
- P3 "Transcription is hard." True on full mixes. basic-pitch docs: "works best on one instrument at a time". Stems remove that problem. This is the product's unfair advantage, not a side feature.
- Do-nothing cost: founder keeps bouncing between Moises (stems), tunebat-style sites (key/BPM), Chordify (chords), and a DAW (pitch/FX). 4 tools, uploads, accounts.

**0B Existing code leverage**

| Sub-problem | Existing code | Reuse |
|---|---|---|
| Decode video/audio → 44.1k float | `../stemsplitter/Sources/StemCore` `AudioExtractor` path | Direct |
| Chunk + overlap-add | `StemCore/Engine/OLA.swift` | Direct |
| Streaming 24-bit WAV, RF64 | `StemCore/Engine/WAVWriter.swift` | Direct |
| ETA calibration | `StemCore/Support/ETACalibrator.swift` | Direct |
| Event stream to UI | `Contracts/PipelineEvent.swift` (FROZEN) | Direct |
| 4-stem model contract | `Engine/StemModel.swift` is a 2-stem **mask** contract (`StereoVocalMask`) | No. New `MultiStemSeparator` beside it |
| Playback | `StemUI/StemPlayback.swift` is AVPlayer + AVAudioSession (iOS) | No. New `StemMix` AVAudioEngine graph |
| Key/BPM/chords/notes/MIDI/FX | none | New |

**0C Dream state**
```
CURRENT                         THIS PLAN                              12-MONTH IDEAL
iOS 2-stem app (in build),  ──► Mac app: 4 stems + key/BPM/chords  ──► One engine on Mac+iOS; 6 stems;
no Mac app, no analysis         + pitch/FX + melody/bass MIDI,         lead-sheet export; Shortcuts/CLI;
                                drag audio or MIDI into any DAW        watch folder; universal purchase
```

**0D Approaches**
- A) Requested plan: everything on one timeline, built-in AU FX, basic-pitch, own DSP for key/BPM/chords. **Chosen (P1 completeness, P4 reuse of platform + Apache model).**
- B) Smallest: stems + key/BPM only, defer FX and notes. Rejected: contradicts founder request.
- C) Bundle Essentia for analysis. Rejected: AGPL-3.0 conflicts with closed-source App Store. aubio is GPL; same problem. Own DSP is ~400 LOC with Accelerate.

**0E Mode:** SELECTIVE EXPANSION (new capability on a planned product).

**0F/0G Cherry-picks**

| # | Expansion | Effort | Decision |
|---|---|---|---|
| E1 | MIDI drag-out per stem / region | S | Accept (headline; in blast radius) |
| E2 | Camelot code next to key (DJs) | S | Accept |
| E3 | Tempo 50–150 % (same `AVAudioUnitTimePitch`) | S | Accept |
| E4 | Beat-synced delay from detected BPM | S | Accept |
| E5 | Key/BPM in export filenames | S | Accept (was v2) |
| E6 | Pitch shift rewrites displayed key + chords | S | Accept |
| E7 | Chord chart / lead sheet PDF | M | Defer → TODOS |
| E8 | 6-stem (guitar, piano) | L | Defer → TODOS (model quality) |
| E9 | FX presets, compressor, saturation | M | Defer → TODOS |
| E10 | Metronome click aligned to beat grid | S | Defer → TODOS (taste) |

**0I Temporal interrogation**
- Hour 1: htdemucs output shape (4 × stereo waveform) vs existing mask contract. Answered: new protocol.
- Hour 2–3: chroma frame size and beat-sync alignment; Viterbi transition penalty tuning needs labeled fixtures before code.
- Hour 4–5: `AVAudioEngine` manual rendering with 4 player nodes must start sample-aligned; schedule all with one `AVAudioTime`.
- Hour 6+: basic-pitch Core ML expects 22.05 kHz mono, 2 s windows with overlap; note stitching at window seams.

**Section 1 Architecture.** Diagrams in plan body (module tree, pipeline, mix graph). Coupling: StemAnalysis depends only on StemCore decode + Accelerate + Core ML; StemMix depends on AVFoundation only. App depends on all three. No cycles. SPOF: the separator; analysis/FX/notes degrade independently if it's slow but need its stems. Finding F1: original plan's `StemKit` duplicates `StemCore` → replaced by monorepo (taste T1). Finding F2: playback and export must share one graph builder or WYSIWYG breaks → `MixGraph` single builder (accepted). Rollback: per-feature; analysis/notes failures never block stems.

**Section 2 Error & Rescue Registry**

| Codepath | Failure | Error | Rescued | User sees |
|---|---|---|---|---|
| TempoDetector | no periodic onsets (a cappella, ambient) | `AnalysisError.noBeat` | Y | BPM "—" + "No steady beat" tooltip |
| TempoDetector | octave error | n/a (wrong value) | Y via UI | ½× / 2× buttons |
| KeyDetector | flat chroma (drums only, noise) | `AnalysisError.noTonalCenter` | Y | Key "—" |
| KeyDetector | relative major/minor tie | low confidence | Y | Key + runner-up |
| ChordTracker | no beats | falls back to fixed 0.5 s frames | Y | Chords still shown |
| NoteTranscriber | Core ML load fail | `StemError.modelLoad` (existing) | Y | ♪ lanes disabled, "Notes unavailable" |
| NoteTranscriber | file > 15 min | not run eagerly | Y | ♪ shows "Transcribe" button |
| MIDIWriter | empty note list | writes valid empty SMF | Y | drag still works, clip empty |
| MixGraph | engine start fails | `MixError.engineStart(OSStatus)` | Y | alert + retry |
| MixGraph | config change (device unplug) | notification | Y | auto-rebuild, playback pauses |
| ExportRenderer | render error mid-file | `MixError.render(OSStatus)` | Y | delete partial, alert |
| ExportRenderer | disk full | `StemError.diskFull` (existing) | Y | delete partial, existing message |
| analysis.json | missing/corrupt/old version | decode error | Y | silently re-run analysis |

No catch-alls. Each error logs codepath + file id + OSStatus via `os.Logger` (subsystem `app.stemsplitter`, category per module).

**Section 3 Security.** No network, no accounts. New input surfaces: dropped files (AVFoundation parses; sandbox limits blast radius), `analysis.json`/`mix.json` read back (Codable; corrupt → re-run, never crash). File promises write only to the drop destination the user chose. Core ML models bundled and code-signed. No findings beyond keeping App Sandbox on and entitlements minimal (user-selected read/write, Music folder).

**Section 4 Data flow & edge cases.** Shadow paths: empty stem (silent bass) → key uses other only; chroma all-zero → "—". Async ordering: analysis and transcription write separate files; the UI subscribes per file, so completion order doesn't matter. Pitch change during export: export snapshots `mix.json` at start (accepted). Double drop of the same file: library keys by content hash; second drop focuses existing item. Delete library item while transcribing: cancel task first, then delete folder.

**Section 5 Code quality.** Keep each detector a pure function `([Float], sampleRate) -> Result` for testability. No protocol for one detector. MIDI writer is one file, no dependency.

**Section 6 Tests.** See Eng test plan file. Key regression: null test on export with all FX bypassed.

**Section 7 Performance.** Analysis on 22.05 kHz mono: FFT 4096/hop 2048 → ~1.9k frames per 3 min; trivial. basic-pitch on 3 stems ≈ 3× model passes; run sequentially at `.utility` QoS so playback stays smooth. Offline export of 4 stems with FX: expect > 20× realtime on M1.

**Section 8 Observability.** Local only: `os.Logger` + signposts around split, each detector, transcription, export. A hidden "Copy diagnostics" menu item dumps versions, timings, analysis confidences for bug reports. No telemetry (privacy promise).

**Section 9 Deployment.** App Store. Analyzer versioned in `analysis.json`; changing algorithms re-analyzes old library items on open. Rollback = previous build via App Store Connect phased release.

**Section 10 Trajectory.** Reversibility 4/5. Monorepo makes iOS reuse of StemAnalysis + StemMix free (both Foundation/AVFoundation, iOS-compatible). Platform potential: analysis.json enables lead sheets, Shortcuts, CLI later.

**Section 11 Design.** Chords/notes on the timeline, not a separate screen (accepted). State map:

| Feature | Loading | Empty | Error | Success | Partial |
|---|---|---|---|---|---|
| Stems | waveform fill | drop target | inline error card | 4 lanes | finished chunks playable |
| BPM/Key | skeleton text | — | "—" + tooltip | value + conf | runner-up shown |
| Chords | lane shimmer | no lane | "—" lane | chord blocks | low-conf chords dimmed |
| Notes | ♪ spinner | "No notes found" | "Notes unavailable" | piano roll | per-stem as each finishes |
| Export | progress bar | n/a | alert, partial deleted | Finder reveal | n/a |

Run `/plan-design-review` before Phase 1 UI build.

**NOT in scope:** lead-sheet export, 6 stems, FX presets/compressor/saturation, metronome, recording, AU/VST plugin, CLI/Shortcuts, watch folder, cloud anything.

**Completion summary (CEO):** premises 3 challenged (1 reframed, 1 overridden by founder, 1 turned into advantage); 10 expansions (6 accepted, 4 deferred); 13 error rows, 0 open gaps; 1 taste decision (T1 monorepo).

<!-- autoplan-accepted:ceo -->
- v1 includes key, BPM, chords, pitch ±12 st, tempo 50–150 %, per-stem 3-band EQ/delay/reverb, master EQ, melody/bass/harmony transcription with MIDI drag-out. Verified by success-criteria fixtures and manual Ableton drag test.
- Analysis uses stems as input (drums → BPM; bass+other → key/chords; vocals/bass/other → notes).
- Analysis failures never block stems; each shows "—" with a reason.
- No AGPL/GPL dependencies (Essentia, aubio, Rubber Band excluded).
- Export renders the same graph as playback; FX-bypassed export null-tests against source.
<!-- /autoplan-accepted:ceo -->

### Phase 2 — Design review

| Dimension | Score | Note |
|---|---|---|
| Information hierarchy | 8 | Header (BPM/key/pitch) → timeline → inspector. Clear. |
| States coverage | 8 | Table above; per-feature failures inline. |
| Interaction clarity | 7 | Two drag sources (≡ audio, ♪ MIDI) need distinct drag previews (waveform vs note icon). Accepted. |
| Consistency | 8 | Stem hue reused for notes. |
| Accessibility | 7 | VoiceOver labels + keyboard map; piano roll needs an accessible summary ("Vocals melody, 214 notes, range A3–E5"). Accepted. |
| Delight | 8 | Pitch rewrites key/chords live; beat-synced delay. |
| AI-slop risk | 9 | Specific, DAW-like layout; no generic cards. |

Litmus: first-time user drops a file and sees stems + key + chords with zero clicks → pass.

<!-- autoplan-accepted:design -->
- Distinct drag previews for audio stem vs MIDI clip.
- Piano-roll lane exposes a VoiceOver summary (note count, range).
- Low-confidence chords render dimmed; key shows runner-up when confidence < 0.6.
<!-- /autoplan-accepted:design -->

### Phase 2.5 — DX review

Scope triggered by term matches ("library" = music library, "CLI" = deferred v2). End-user app, no API, no SDK. Developer journey = contributor building the monorepo: TTHW target < 5 min (`open Package.swift` or Xcode project, run Mac scheme). Existing README already documents `DEVELOPER_DIR` workaround. Scores: getting started 8, docs 7 (add Mac section), errors n/a, API n/a, upgrade n/a, tooling 8, community n/a, empathy 7.

<!-- autoplan-accepted:dx -->
- README gains a "Mac app" section: build command, model download script, how to run analysis fixtures.
<!-- /autoplan-accepted:dx -->

### Phase 3 — Eng review

**Scope challenge.** ~20 new files across 3 targets + app. Above the 15-file threshold, but each phase in Build order is independently shippable, so reduction = sequencing, not cutting.

**Code-path → test map**
```
AudioExtractor (existing tests) ─► MultiStemSeparator ── T: 4 outputs sum to input within -60 dB (mock model)
                                     │
   Chroma ── T: pure A440 sine → bin A dominant
   TempoDetector ── T: synthetic click 120 BPM → 120±1; silence → noBeat; 60 vs 120 octave toggle
   KeyDetector ── T: synthetic I-IV-V-I in each of 24 keys → exact; white noise → noTonalCenter
   ChordTracker ── T: C-G-Am-F synthetic → labels per beat; no beats → 0.5 s fallback
   NoteTranscriber ── T: fixture WAV of C major scale → 8 notes, pitches exact, onsets ±30 ms
   MIDIWriter ── T: write → parse header/track bytes; empty list → valid file
   MixGraph ── T: all bypassed offline render null-test < -90 dBFS; pitch +12 → spectral peak doubles
   ExportRenderer ── T: disk-full injection → partial file deleted; cancel → partial deleted
   analysis.json ── T: corrupt/old version → re-run
   UI ── manual: drag stem + MIDI into Ableton; unplug headphones mid-play
```

**Failure modes registry (critical gaps flagged)**

| Mode | Likelihood | Handled | Gap? |
|---|---|---|---|
| htdemucs Core ML conversion fails (ops unsupported) | Med | MLX fallback in spike | No |
| basic-pitch window-seam duplicate notes | Med | merge notes with same pitch overlapping < 50 ms | No |
| Players start misaligned → phasey mix | Low | single start `AVAudioTime` | No |
| TimePitch artifacts at ±12 | High | accepted, user judges | No |
| Analysis wrong on live/rubato music | Med | confidence + "—" | No |
| Library folder moved/deleted by user in Finder | Med | sidebar drops missing items on refresh | No |

0 critical gaps.

Test plan written to `~/.gstack/projects/kristers/kristers-stemsplitter-mac-eng-review-test-plan-20261001.md`.

**What already exists:** see CEO 0B table. **NOT in scope:** same as CEO.

**Completion summary (Eng):** architecture accepted with monorepo (taste T1); new `MultiStemSeparator` contract (existing mask contract can't express 4-stem waveforms); 10 test groups; 6 failure modes, 0 critical gaps.

<!-- autoplan-accepted:eng -->
- New `MultiStemSeparator` protocol in StemCore; FROZEN `Contracts/` untouched.
- Detectors are pure functions with synthetic-signal unit tests listed in the code-path map.
- One `MixGraph` builder for playback and export; all players start on one `AVAudioTime`.
- `analysis.json` versioned; older/corrupt → re-run.
- Engine config change rebuilds graph from `mix.json`.
<!-- /autoplan-accepted:eng -->

<!-- AUTONOMOUS DECISION LOG -->
## Decision Audit Trail

| # | Phase | Decision | Classification | Principle | Rationale | Rejected |
|---|---|---|---|---|---|---|
| 1 | CEO | Mode SELECTIVE EXPANSION | Mechanical | override | autoplan rule | others |
| 2 | CEO | Founder features into v1 | Mechanical | user direction | explicit request | keep as v2 |
| 3 | CEO | Approach A, own DSP | Mechanical | P1, P4 | GPL/AGPL libs block App Store | Essentia, aubio |
| 4 | CEO | basic-pitch for notes | Mechanical | P4 | Apache-2.0, ships Core ML | train own |
| 5 | CEO | Accept E1–E6 | Mechanical | P2 | in blast radius, S effort | — |
| 6 | CEO | Defer E7–E10 | Mechanical | P3 | outside v1 blast radius | — |
| 7 | Eng | Monorepo instead of new StemKit | Taste | P4 DRY | StemCore exists, macOS-ready | separate repo + path dep |
| 8 | Eng | New MultiStemSeparator protocol | Mechanical | P5 | mask contract can't fit htdemucs | edit FROZEN contract |
| 9 | Eng | Pitch on master, not per stem | Mechanical | P5 | keeps stems aligned | per-stem pitch |
| 10 | Design | Chords/notes on timeline | Mechanical | P1 | see while listening | separate screen |
