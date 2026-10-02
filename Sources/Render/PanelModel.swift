// PanelModel.swift — display-state value types shared by the live panel and the offscreen mockup.
// Pure values, no AppKit. Everything the renderer draws comes from one PanelState.
// (Final spec, Phase 2 synthesis: derived from design A's model + B/C grafts.)
import Foundation

/// kern.memorystatus_vm_pressure_level → AM colour class (4 red, 2 yellow, anything else green).
enum PressureLevel: Int, Codable, Sendable {
    case normal = 1, warning = 2, critical = 4
    init(kernel v: Int) { self = v == 4 ? .critical : (v == 2 ? .warning : .normal) }
    var word: String { switch self { case .normal: "正常"; case .warning: "警告"; case .critical: "嚴重" } }
}

/// One point of the pressure graph: one per wall-clock second (max value / most severe level of that second).
struct PressureSample: Codable, Sendable {
    var t: Double              // seconds (sampler clock)
    var percent: Double?       // 100 − kern.memorystatus_level, clamped 0…100; nil = source failed → gap
    var level: PressureLevel?
    var simulated: Bool = false
}

/// A displayed memory value: the exact AM-formatted string ("18.52 GB", "39.3 MB", "0 bytes") or a failed source ("—").
enum Shown: Equatable, Sendable {
    case text(String)
    case failed
    /// "18.52 GB" → ("18.52", "GB"); NSByteCountFormatter may use U+00A0.
    var parts: (number: String, unit: String)? {
        guard case .text(let s) = self else { return nil }
        let norm = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        if let sp = norm.lastIndex(of: " ") { return (String(norm[..<sp]), String(norm[norm.index(after: sp)...])) }
        return (norm, "")
    }
}

struct MemoryDisplay: Sendable {
    var physical: Shown
    var used: Shown
    var cached: Shown
    var swap: Shown
    var app: Shown
    var wired: Shown
    var compressed: Shown
    var pressurePercent: Int?          // nil → "—" + grey "未知" pill
    var pressureLevel: PressureLevel?
    var pressureSimulated = false
}

enum DeviceKind: String, Sendable { case keyboard, trackpad, mouse, airpods, other
    var label: String { switch self { case .keyboard: "鍵盤"; case .trackpad: "軌跡板"; case .mouse: "滑鼠"; case .airpods: "AIRPODS"; case .other: "裝置" } }
    var isHID: Bool { self != .airpods }
}

/// ok = fresh reading; failed = the source read threw (injected or real) → bright "—";
/// unavailable = device connected but this part did not report (e.g. case closed) → dim "—";
/// stale = connection unknown because system_profiler has not succeeded for > 45 s (spec §6.4 path 3) → grey row "—"
/// (criterion #5: a possibly disconnected device turns grey within 60 s).
enum CellState: Equatable, Sendable { case ok(Int, charging: Bool), failed, unavailable, stale }

struct BatteryCell: Sendable { var label: String; var state: CellState }

/// connected = listed under system_profiler device_connected (white numbers);
/// nearby = AirPods NOT connected to this Mac but with fresh evidence (an IOPS change seen by the panel within
///          --nearby-fresh-seconds, or the case's own BLE entry under device_connected) → GREY numbers + 「附近」;
/// offline = 「離線」 word, never a number.
enum Presence: String, Sendable { case connected, nearby, offline }

struct DeviceGroup: Sendable {
    var kind: DeviceKind
    var name: String               // full UTF-8 product name (logged; shown only via ownerTag)
    var ownerTag: String?          // "ALEX" / "小明" when two devices share a kind
    var presence: Presence         // HID rows are only ever .connected / .offline
    var cells: [BatteryCell]       // 1 for HID devices, 3 (左耳/右耳/充電盒) for AirPods
    /// true only for .connected (nearby and offline groups are NOT connected to this Mac)
    var connected: Bool { presence == .connected }
    /// connected or nearby: the group shows its cells (offline shows only 「離線」)
    var showsCells: Bool { presence != .offline }
}

extension DeviceGroup {
    /// Two-state initialiser kept for callers that only know connected / offline.
    init(kind: DeviceKind, name: String, ownerTag: String?, connected: Bool, cells: [BatteryCell]) {
        self.init(kind: kind, name: name, ownerTag: ownerTag, presence: connected ? .connected : .offline, cells: cells)
    }
}

struct PanelState: Sendable {
    var memory: MemoryDisplay
    var history: [PressureSample]  // oldest first, 1 per second
    var now: Double
    var historyCoverage: Double    // seconds of history collected since start (≥ 600 → "十分鐘前" axis label)
    var devices: [DeviceGroup]     // already ordered (HID first, then AirPods groups)
    var batteryPage = 0            // AirPods-group page (HID rows are pinned on every page)
    var clock: String              // HH:MM:SS of the displayed sample of the ACTIVE view (1 s resolution on screen)
    var sampleStale = false        // no sample of the active view's source for > 5 s → white "停滯"/"STALE" chip
    var simulationBadge: String? = nil   // non-nil while any injection is active → magenta frame + named badge (already localized)
    // ---- v2 (multi-view). Trailing + defaulted: every existing memberwise call site keeps compiling and draws the
    //      memory view in Traditional Chinese with the battery column, exactly as before. ----
    var view: ViewKind = .memory
    var lang: Lang = .zh
    var batteryVisible = true
    var cpu: CPUDisplay = .blank
    var cpuHistory: HistoryView<CPUPoint> = HistoryView()
    var net: NetDisplay = .blank
    var netHistory: HistoryView<NetPoint> = HistoryView()
    var sysCoverage: Double = 0    // seconds since SystemSampler start, ≤ 900 (CPU / network axis "收集中")
}

// MARK: - v2: views, language, CPU / network display values

enum ViewKind: String, CaseIterable, Sendable {
    case memory, cpu, network
    /// log / DSP token
    var token: String { switch self { case .memory: "mem"; case .cpu: "cpu"; case .network: "net" } }
    var next: ViewKind { switch self { case .memory: .cpu; case .cpu: .network; case .network: .memory } }
    init?(token: String) { guard let v = ViewKind.allCases.first(where: { $0.token == token || $0.rawValue == token }) else { return nil }; self = v }
}

/// Resolved display language (the setting itself is LanguagePref system|zh|en, Sources/Core/Settings.swift).
enum Lang: String, CaseIterable, Sendable { case zh, en }

/// AM CPU-tab footer values, already formatted: percentages = AM paddedPercent ("4.99%", "100.00%"),
/// counts = AM integerFormatter ("4,783"). `.failed` → bright "—".
struct CPUDisplay: Sendable {
    var system: Shown, user: Shown, idle: Shown
    var threads: Shown, processes: Shown
    static let blank = CPUDisplay(system: .failed, user: .failed, idle: .failed, threads: .failed, processes: .failed)
}

/// AM Network-tab footer values, already formatted for the active language:
/// download / upload = AM SMNetworkSpeedFormatter ("156.59 kb/s", "156.59 kb/秒"; bits, decimal, 2 decimals);
/// packets = integerFormatter ("27,833,717"; per-second values too); received / sent = ByteCountFormatter .file ("22.76 GB").
struct NetDisplay: Sendable {
    var download: Shown, upload: Shown
    var packetsIn: Shown, packetsOut: Shown, packetsInRate: Shown, packetsOutRate: Shown
    var received: Shown, sent: Shown
    static let blank = NetDisplay(download: .failed, upload: .failed, packetsIn: .failed, packetsOut: .failed,
                                  packetsInRate: .failed, packetsOutRate: .failed, received: .failed, sent: .failed)
}

/// A point stamped with its wall second (`t` = floor of the sample's wall time).
protocol SecondPoint { var t: Double { get set } }
/// One CPU LOAD graph point per wall second: per-core-averaged percentages (0…100); nil = source failed → gap.
struct CPUPoint: Sendable, SecondPoint { var t: Double; var system: Float?; var user: Float?; var simulated = false }
/// One network DATA graph point per wall second: bytes/s received / sent; nil = no rate (first sample, failure) → gap.
struct NetPoint: Sendable, SecondPoint { var t: Double; var rx: Double?; var tx: Double?; var simulated = false }

/// Main-thread ring of one point per wall second for the CPU / network graphs. Append is O(1) and never moves the
/// stored points; readers take a `HistoryView` (ring reference + absolute end index), so building a PanelState never
/// copies the 900 points. The extra `slack` slots keep a captured view intact for `slack` further appends (≈ 1 min),
/// longer than any view is held (PanelView keeps the last drawn state for SIGUSR1).
/// Main thread only, enforced with dispatchPrecondition (it is @unchecked Sendable only so that PanelState, which
/// carries a HistoryView, stays Sendable).
final class SecondRing<P: SecondPoint>: @unchecked Sendable {
    let visible: Int
    let capacity: Int
    private var storage: ContiguousArray<P?>
    private(set) var end = 0                       // absolute index one past the newest point
    private var start = 0                          // lowest absolute index that may still be valid (raised by a step back)
    init(visible: Int = 900, slack: Int = 64) {
        self.visible = visible; capacity = visible + slack
        storage = ContiguousArray(repeating: nil, count: visible + slack)
    }
    func append(_ p: P) { dispatchPrecondition(condition: .onQueue(.main)); storage[end % capacity] = p; end += 1 }
    /// Replace the newest point (same wall second arriving twice).
    func replaceLast(_ p: P) { guard end > 0 else { append(p); return }; dispatchPrecondition(condition: .onQueue(.main)); storage[(end - 1) % capacity] = p }
    static var stepBackSeconds: Double { 2 }   // same jitter allowance as PressureHistory.stepBackSeconds
    enum Put: Equatable { case appended, replaced, steppedBack(dropped: Int) }
    /// The Store's only writer. Newer second → append; same second, or ≤ 2 s older (jitter) → replace the newest point;
    /// > 2 s older (wall clock stepped back) → drop every stored point at or after the new second, then append (the
    /// graph continues on the new timeline; PressureHistory's rule). Never leaves points out of time order, so the
    /// renderer's runs()/stepRects never meet x1 ≤ x0.
    @discardableResult
    func put(_ p: P) -> Put {
        guard let l = last else { append(p); return .appended }
        if p.t > l.t { append(p); return .appended }
        if p.t >= l.t - Self.stepBackSeconds { var q = p; q.t = l.t; replaceLast(q); return .replaced }   // folded into the newest second
        var dropped = 0
        start = max(start, end - capacity)         // slots below the old window are stale storage, never valid again
        while end > start, let q = at(end - 1), q.t >= p.t { end -= 1; dropped += 1 }
        append(p)
        return .steppedBack(dropped: dropped)
    }
    var last: P? { end > 0 ? storage[(end - 1) % capacity] : nil }
    var count: Int { min(end - max(start, end - capacity, 0), visible) }
    /// Point at absolute index `i`, nil when not written yet, already overwritten, or dropped by a step back.
    func at(_ i: Int) -> P? { (i >= 0 && i < end && i >= start && i >= end - capacity) ? storage[i % capacity] : nil }
    func view() -> HistoryView<P> { dispatchPrecondition(condition: .onQueue(.main)); return HistoryView(ring: self, end: end, count: count) }
}

struct HistoryView<P: SecondPoint>: @unchecked Sendable {
    let ring: SecondRing<P>?
    let end: Int
    let count: Int
    init() { ring = nil; end = 0; count = 0 }
    init(ring: SecondRing<P>, end: Int, count: Int) { self.ring = ring; self.end = end; self.count = count }
    /// Oldest first; points overwritten since the view was taken are skipped.
    func forEach(_ body: (P) -> Void) {
        guard let r = ring else { return }
        for i in (end - count)..<end { if let p = r.at(i) { body(p) } }
    }
    var last: P? { ring?.at(end - 1) }
}
