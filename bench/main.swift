import Foundation
import StemAnalysis
import StemSeparation

// Usage: stembench <audio-or-video> [runs] [2|4]
// Splits into a temp dir and prints wall clock + realtime factor per run (plan: 3 back-to-back runs for thermals).
let args = CommandLine.arguments
guard args.count > 1 else { print("usage: stembench <file> [runs] [2|4]"); exit(2) }
let src = URL(fileURLWithPath: args[1])
let runs = args.count > 2 ? Int(args[2]) ?? 1 : 1
let layout: StemLayout = args.count > 3 && args[3] == "2" ? .two : .four
let models = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Models").standardized

let t0 = Date()
let cascade = try CascadePipeline(
    vocals: MelBandRoformerSeparator(modelURL: models.appendingPathComponent("melband-roformer.mlmodelc")),
    residual: HTDemucsSeparator(modelURL: models.appendingPathComponent("htdemucs.mlmodelc")))
print(String(format: "model load %.2fs", Date().timeIntervalSince(t0)))
for run in 1...runs {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("stembench-\(run)")
    let r = try await cascade.run(SplitRequest(source: src, outputDirectory: out, layout: layout))
    print(String(format: "run %d (%@-stem): %.1fs audio in %.2fs (%.1fx realtime) → %@", run,
                 r.stems.count == 2 ? "2" : "4", r.duration, r.elapsed, r.duration / r.elapsed, out.path))
}

// Analysis + transcription on the last run's stems.
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stembench-\(runs)")
let stemNames = layout == .two ? ["vocals", "instrumental"] : ["drums", "bass", "other", "vocals"]
let stems = Dictionary(uniqueKeysWithValues: stemNames.map { ($0, dir.appendingPathComponent("\($0).wav")) })
var t = Date()
let inputs = StemAnalyzer.inputs(stems: stems)
let analysis = try StemAnalyzer.analyze(rhythm: inputs.rhythm, harmony: inputs.harmony)
print(String(format: "analysis %.2fs: %.1f BPM (conf %.2f), key %@ %@ (conf %.2f, runner-up %@), %d chord segments",
             Date().timeIntervalSince(t), analysis.tempo?.bpm ?? 0, analysis.tempo?.confidence ?? 0,
             analysis.key?.key.longName ?? "—", analysis.key?.key.camelot ?? "", analysis.key?.confidence ?? 0,
             analysis.key?.runnerUp.name ?? "—", analysis.chords.count))
print("chords:", analysis.chords.prefix(16).map { "\($0.chord?.name ?? "N")" }.joined(separator: " "))
let transcriber = try NoteTranscriber(modelURL: models.appendingPathComponent("basic-pitch.mlmodelc"))
for stem in StemAnalyzer.transcribable where stems[stem] != nil {
    t = Date()
    let notes = try StemAnalyzer.transcribe(stem: stem, url: stems[stem]!, with: transcriber)
    let range = notes.isEmpty ? "—" : "\(notes.map(\.pitch).min()!)–\(notes.map(\.pitch).max()!)"
    print(String(format: "notes %@: %d notes, range %@, %.2fs", stem, notes.count, range, Date().timeIntervalSince(t)))
}
