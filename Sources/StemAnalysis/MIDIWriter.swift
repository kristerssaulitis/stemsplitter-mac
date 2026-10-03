import Foundation

/// Standard MIDI File, type 1: track 0 = tempo + 4/4, track 1 = notes on channel 1.
public enum MIDIWriter {
    public static let ticksPerQuarter = 480

    public static func data(notes: [NoteEvent], bpm: Double, name: String = "Notes") -> Data {
        let tempo = bpm > 0 ? bpm : 120
        func ticks(_ seconds: Double) -> Int { max(0, Int((seconds * tempo / 60 * Double(ticksPerQuarter)).rounded())) }

        var conductor = Data()
        let usPerQuarter = Int((60_000_000 / tempo).rounded())
        conductor += varLen(0) + [0xFF, 0x51, 0x03] + [UInt8((usPerQuarter >> 16) & 0xFF), UInt8((usPerQuarter >> 8) & 0xFF), UInt8(usPerQuarter & 0xFF)]
        conductor += varLen(0) + [0xFF, 0x58, 0x04, 4, 2, 24, 8]
        conductor += varLen(0) + [0xFF, 0x2F, 0x00]

        // Note-offs before note-ons at the same tick, so repeated pitches retrigger.
        var events: [(tick: Int, order: Int, bytes: [UInt8])] = []
        for n in notes where (0...127).contains(n.pitch) {
            let on = ticks(n.start), off = max(on + 1, ticks(n.end))
            let vel = UInt8(max(1, min(127, Int((n.velocity * 127).rounded()))))
            events.append((on, 1, [0x90, UInt8(n.pitch), vel]))
            events.append((off, 0, [0x80, UInt8(n.pitch), 0]))
        }
        events.sort { $0.tick != $1.tick ? $0.tick < $1.tick : $0.order < $1.order }
        var track = Data()
        let title = Array(name.utf8.prefix(127))
        track += varLen(0) + [0xFF, 0x03, UInt8(title.count)] + title
        var last = 0
        for e in events {
            track += varLen(e.tick - last) + e.bytes
            last = e.tick
        }
        track += varLen(0) + [0xFF, 0x2F, 0x00]

        var file = Data("MThd".utf8) + be32(6) + be16(1) + be16(2) + be16(ticksPerQuarter)
        file += Data("MTrk".utf8) + be32(conductor.count) + conductor
        file += Data("MTrk".utf8) + be32(track.count) + track
        return file
    }

    static func varLen(_ value: Int) -> Data {
        var v = value, bytes = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0)
            v >>= 7
        }
        return Data(bytes)
    }

    static func be32(_ v: Int) -> Data { Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    static func be16(_ v: Int) -> Data { Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
}
