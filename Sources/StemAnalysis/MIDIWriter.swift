import AudioToolbox
import Foundation

/// Standard MIDI File via AudioToolbox MusicSequence: type 1, track 0 = tempo,
/// track 1 = notes on channel 1.
public enum MIDIWriter {
    public static let ticksPerQuarter = 480

    public static func data(notes: [NoteEvent], bpm: Double, name: String = "Notes") -> Data {
        let tempo = bpm > 0 ? bpm : 120
        var seq: MusicSequence?
        NewMusicSequence(&seq)
        defer { DisposeMusicSequence(seq!) }
        var tempoTrack: MusicTrack?
        MusicSequenceGetTempoTrack(seq!, &tempoTrack)
        MusicTrackNewExtendedTempoEvent(tempoTrack!, 0, tempo)

        var notesTrack: MusicTrack?
        MusicSequenceNewTrack(seq!, &notesTrack)
        // MusicTimeStamp and note durations are in beats, not seconds.
        let bps = tempo / 60.0
        for n in notes where (0...127).contains(n.pitch) {
            var msg = MIDINoteMessage(channel: 0, note: UInt8(n.pitch),
                                      velocity: UInt8(max(1, min(127, Int((n.velocity * 127).rounded())))),
                                      releaseVelocity: 0, duration: Float(max(0.001, n.end - n.start) * bps))
            MusicTrackNewMIDINoteEvent(notesTrack!, MusicTimeStamp(n.start * bps), &msg)
        }

        var data: Unmanaged<CFData>?
        MusicSequenceFileCreateData(seq!, .midiType, [], Int16(ticksPerQuarter), &data)
        return data!.takeRetainedValue() as Data
    }
}
