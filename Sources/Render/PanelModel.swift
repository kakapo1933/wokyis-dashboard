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
    var clock: String              // HH:MM:SS of the displayed memory sample (1 s resolution on screen)
    var sampleStale = false        // no memory sample for > 5 s → white "停滯" chip
    var simulationBadge: String? = nil   // non-nil while any injection is active → magenta frame + named badge
}
