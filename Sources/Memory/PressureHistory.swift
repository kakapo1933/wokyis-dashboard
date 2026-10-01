// PressureHistory.swift — 900-slot, 1-per-wall-second ring (spec §5.5).
// Every MEM sample goes into its wall-clock second: max pct, most severe level, simulated OR (nil pct/level only
// when every sample of that second had it nil → graph gap). A sample of a LATER second closes the open one and
// appends it; `closeThrough(wallSecond:)` (main's 1 Hz tick) closes it even when no newer sample arrives.
// Seconds without any sample (sleep, stall) get no point (the renderer draws a gap from the t values).
// Owner: memory agent.
import Foundation

struct PressureHistory {
    static let capacity = 900

    private var ring: [PressureSample] = []      // closed seconds, oldest first, ≤ capacity
    private var open: PressureSample? = nil      // the second currently being accumulated
    private var openSecond: Int = .min

    init() { ring.reserveCapacity(PressureHistory.capacity) }

    private static func severity(_ l: PressureLevel?) -> Int { l?.rawValue ?? 0 }   // normal 1 < warning 2 < critical 4

    /// Backward wall-clock step larger than this (s) restarts the timeline instead of folding samples.
    static let stepBackSeconds = 2

    /// Same wall second → max pct, most severe level, simulated OR. A new (later) second closes the previous one.
    /// A sample ≤ `stepBackSeconds` older than the open second is folded into it (jitter safety); a larger backward
    /// clock step drops the open second and every stored point at or after the new second (they lie in the "future"
    /// of the new timeline) and continues from the new second, so the graph keeps moving.
    mutating func add(pct: Int?, level: PressureLevel?, simulated: Bool, wallSecond: Int) {
        if open != nil, wallSecond < openSecond - PressureHistory.stepBackSeconds {
            open = nil; openSecond = .min
            ring.removeAll { $0.t >= Double(wallSecond) }
        } else if let last = ring.last, open == nil, Double(wallSecond) < last.t - Double(PressureHistory.stepBackSeconds) {
            ring.removeAll { $0.t >= Double(wallSecond) }
        }
        if var o = open, wallSecond <= openSecond {
            if let p = pct { o.percent = max(o.percent ?? -1, Double(p)) }
            if PressureHistory.severity(level) > PressureHistory.severity(o.level) { o.level = level }
            o.simulated = o.simulated || simulated
            open = o
            return
        }
        if let o = open { append(o) }
        open = PressureSample(t: Double(wallSecond), percent: pct.map(Double.init), level: level, simulated: simulated)
        openSecond = wallSecond
    }

    /// Close the open second if it is older than `wallSecond` (call from the 1 Hz tick with the current second).
    mutating func closeThrough(wallSecond: Int) {
        if let o = open, openSecond < wallSecond { append(o); open = nil; openSecond = .min }
    }

    private mutating func append(_ p: PressureSample) {
        ring.append(p)
        if ring.count > PressureHistory.capacity { ring.removeFirst(ring.count - PressureHistory.capacity) }
    }

    /// Closed seconds, oldest first (t = wall second as Double).
    func points() -> [PressureSample] { ring }

    /// Seconds spanned by the stored points (last − first + 1), ≤ 900; 0 when empty.
    var coverageSeconds: Double {
        guard let f = ring.first, let l = ring.last else { return 0 }
        return min(Double(PressureHistory.capacity), l.t - f.t + 1)
    }
}
