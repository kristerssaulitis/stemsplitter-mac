import Foundation

/// A region of a stem's audio placed on the timeline, as in Ableton's arrangement / Logic's regions.
/// Edits rewrite clip lists (instant, undoable); audio files are never touched. Times are seconds.
public struct Clip: Codable, Equatable, Sendable {
    public var start: Double     // timeline position
    public var offset: Double    // where the clip's audio begins in the source file
    public var length: Double
    public var reversed = false  // plays source [offset, offset + length) backwards

    public init(start: Double, offset: Double, length: Double, reversed: Bool = false) {
        self.start = start
        self.offset = offset
        self.length = length
        self.reversed = reversed
    }

    public var end: Double { start + length }

    /// Source-file time heard at timeline time `t`.
    public func sourceTime(_ t: Double) -> Double { reversed ? offset + (end - t) : offset + (t - start) }

    /// The part of this clip inside timeline [a, b], or nil.
    public func slice(_ a: Double, _ b: Double) -> Clip? {
        let lo = max(a, start), hi = min(b, end)
        guard hi - lo > Clips.epsilon else { return nil }
        return Clip(start: lo, offset: reversed ? offset + (end - hi) : offset + (lo - start), length: hi - lo, reversed: reversed)
    }
}

/// Clip-list edits. Each returns a new list sorted by start with no overlaps.
public enum Clips {
    static let epsilon = 1e-4
    static let minLength = 0.01

    public static func whole(_ duration: Double) -> [Clip] { [Clip(start: 0, offset: 0, length: duration)] }

    public static func at(_ clips: [Clip], _ t: Double) -> Int? { clips.firstIndex { $0.start <= t && t < $0.end } }

    /// Removes the audio in `r`, leaving a gap (no time shift).
    public static func carve(_ clips: [Clip], _ r: ClosedRange<Double>) -> [Clip] {
        sorted(clips.flatMap { [$0.slice(-.infinity, r.lowerBound), $0.slice(r.upperBound, .infinity)].compactMap { $0 } })
    }

    public static func split(_ clips: [Clip], at t: Double) -> [Clip] {
        sorted(clips.flatMap { c in
            c.start + epsilon < t && t < c.end - epsilon ? [c.slice(c.start, t)!, c.slice(t, c.end)!] : [c]
        })
    }

    /// Keeps only the audio in `r`.
    public static func crop(_ clips: [Clip], _ r: ClosedRange<Double>) -> [Clip] {
        sorted(clips.compactMap { $0.slice(r.lowerBound, r.upperBound) })
    }

    /// Mirrors `r` in place: the audio inside plays backwards.
    public static func reverse(_ clips: [Clip], _ r: ClosedRange<Double>) -> [Clip] {
        let inside = crop(clips, r).map { c -> Clip in
            var m = c
            m.start = r.lowerBound + r.upperBound - c.end
            m.reversed.toggle()
            return m
        }
        return sorted(carve(clips, r) + inside)
    }

    /// Copies `r` and lays the copy right after it, over whatever was there (Ableton ⌘D).
    public static func duplicate(_ clips: [Clip], _ r: ClosedRange<Double>, duration: Double) -> [Clip] {
        let len = r.upperBound - r.lowerBound
        let copy = crop(clips, r).map { c -> Clip in var m = c; m.start += len; return m }
        return place(copy, into: carve(clips, r.upperBound...(r.upperBound + len)), duration: duration)
    }

    /// Lays `new` over `clips`, overwriting what's under it, clipped to 0...duration.
    public static func place(_ new: [Clip], into clips: [Clip], duration: Double) -> [Clip] {
        var out = clips
        for c in new { out = carve(out, c.start...c.end) }
        return crop(out + new, 0...duration)
    }

    /// Drags one edge of clip `i` to `t`. A clip can grow only as far as its source audio goes.
    public static func trim(_ clips: [Clip], index i: Int, leftEdge: Bool, to t: Double,
                            sourceLength: Double, duration: Double) -> [Clip] {
        var c = clips[i], rest = clips
        rest.remove(at: i)
        if leftEdge {
            // Growing left reaches earlier source audio (later, when reversed).
            let room = c.reversed ? sourceLength - (c.offset + c.length) : c.offset
            let newStart = min(max(t, c.start - room, 0), c.end - minLength)
            let d = c.start - newStart
            if !c.reversed { c.offset -= d }
            c.start = newStart
            c.length += d
        } else {
            let room = c.reversed ? c.offset : sourceLength - (c.offset + c.length)
            let newEnd = max(min(t, c.end + room, duration), c.start + minLength)
            let d = newEnd - c.end
            if c.reversed { c.offset -= d }
            c.length += d
        }
        return place([c], into: rest, duration: duration)
    }

    /// Slides clip `i` by `delta`, overwriting what it lands on. Stays inside the song.
    public static func move(_ clips: [Clip], index i: Int, by delta: Double, duration: Double) -> [Clip] {
        var c = clips[i], rest = clips
        rest.remove(at: i)
        c.start = min(max(0, c.start + delta), max(0, duration - c.length))
        return place([c], into: rest, duration: duration)
    }

    static func sorted(_ c: [Clip]) -> [Clip] { c.sorted { $0.start < $1.start } }
}
