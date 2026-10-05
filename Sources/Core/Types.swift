// Types.swift — value types exchanged between modules (spec §4). Pure values; cross-thread safe.
// Owner: core. Module agents may ADD helpers in their own files via extensions, but must not change these shapes
// without updating docs/INTERFACES.md.
import AppKit

// MARK: memory

enum FreeMode: String, Sendable { case mte, calibrated }

/// Bytes per field. Key present with nil value = that field FAILED this sample; key absent = not computed (treat as failed).
struct MemoryBytes: Sendable {
    var v: [Field: Int64?]
    init(v: [Field: Int64?] = [:]) { self.v = v }
    /// nil when the field failed or is absent.
    subscript(_ f: Field) -> Int64? {
        get { v[f] ?? nil }
        set { v[f] = .some(newValue) }
    }
    static let allFailed = MemoryBytes(v: Dictionary(uniqueKeysWithValues: Field.allCases.map { ($0, Int64?.none) }))
}

struct MemSample: Sendable {
    let seq: UInt64
    let tWall: Date            // sample START time (MEM log timestamp)
    let durUs: Int
    let bytes: MemoryBytes
    let strings: [Field: String?]                 // AM-formatted strings ("18.52 GB"); nil = failed → "—"
    let pressure: (pct: Int, level: PressureLevel)?   // nil = level or pressure read failed → "—" + 未知 pill
    let simulated: Bool        // pressure override (or any injection) active for this sample
    let failed: [String]       // source ids / "mem.mib:<name>" that failed this sample (for `fail=` in MEM)
    let mode: FreeMode
}

struct AuditResult: Sendable {
    let fresh: Bool
    let sameAsPrev: Bool
    let ageMs: Int?
    let diffPages: [Field: Int]
    let freeErrPages: Int
}

// MARK: battery

struct HIDDevice: Sendable {
    let address: String        // normalised lower-case colon form "02:11:22:33:44:01"
    let name: String           // Product (UTF-8)
    let category: String       // "Keyboard" / "Trackpad" / "Mouse" / other
    let percent: Int
    let statusFlags: Int?
}

enum PodPart: String, Sendable { case left, right, `case`, single }

struct AccPart: Sendable {
    let groupKey: String       // same Product ID + Name without trailing " Case"
    let name: String
    let accessoryID: String
    let part: PodPart
    let percent: Int
    let charging: Bool
    /// IOPS "Power Source ID" of the entry this part came from (changes only when the accessory re-registers, i.e. it
    /// was rediscovered over BLE) and that entry's "Part Identifier" (Combined / Case / Left / Right / nil = single).
    /// Used only for the 「附近」 change detector (BatteryAggregator); never for connection or values.
    var sourceID: Int? = nil
    var entryPart: String? = nil
}

struct BTDevice: Sendable {
    let name: String
    let address: String
    let minorType: String?
    let productID: String?
    let connected: Bool
    let levels: [String: Int]  // "Main" / "Left" / "Right" / "Case"
}

// MARK: app

struct WokyisScreen {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let appKitFrame: NSRect
    let cgBounds: CGRect
}

// MARK: self-test

/// One self-test case result; every module exposes a `…SelfTest.run() -> [SelfTestCase]` hook (docs/INTERFACES.md).
struct SelfTestCase: Sendable {
    let name: String
    let ok: Bool
    let detail: String
    init(_ name: String, _ ok: Bool, _ detail: String = "") { self.name = name; self.ok = ok; self.detail = detail }
}

// MARK: v2 — settings values (spec §7). Behaviour (SettingsStore, Settings.effective / resolve) lives in
// Sources/Core/Settings.swift (owner: app). ViewKind / Lang are declared in Sources/Render/PanelModel.swift.

/// The user's language preference (`ui.language`, `--lang`). Resolved to a display `Lang` by `Settings.resolve`.
enum LanguagePref: String, CaseIterable, Sendable { case system, zh, en }

/// Effective UI settings (defaults < stored < CLI). Default = memory view, battery column on, Traditional Chinese.
struct UISettings: Equatable, Sendable {
    var view: ViewKind = .memory
    var batteryVisible = true
    var language: LanguagePref = .zh
}

/// One settings layer with optional fields (UserDefaults values that exist and are valid; or this run's CLI flags).
struct SettingsLayer: Equatable, Sendable {
    var view: ViewKind? = nil
    var batteryVisible: Bool? = nil
    var language: LanguagePref? = nil
}

/// UserDefaults keys (domain io.github.kakapo1933.wokyis-panel). Written one key at a time, never as a whole layer.
enum SettingsKey: String, CaseIterable, Sendable { case view = "ui.view", batteryVisible = "ui.batteryVisible", language = "ui.language" }

// MARK: v2 — SystemSampler output (spec §5.1). Produced on sysQ (Sources/System/, owner: sampler), consumed on main by
// Store.applySys / StateBuilder (owner: app).

/// Three-state result of one source read: a value, a deliberate skip (baseline just (re)set, dt < 0.5 s, no ticks —
/// keep the previous display, write no history point), or a failure (show "—" now, history gap, ERR/RECOVER).
enum Reading<T: Sendable>: Sendable {
    case value(T)
    case skipped(reason: String)
    case failed(err: String)
    var value: T? { if case .value(let v) = self { return v }; return nil }
    var isFailed: Bool { if case .failed = self { return true }; return false }
}

/// CPU load over the last interval: arithmetic mean of the per-core percentages (AM rule), each 0…100.
struct CPUReading: Sendable, Equatable {
    let system: Double, user: Double, idle: Double, nice: Double
    let cores: Int
}

/// processor_set_statistics counts. `threads` nil = pset failed and `processes` came from the proc_listallpids
/// fallback (threads then show "—").
struct TaskCounts: Sendable, Equatable {
    let threads: Int?
    let processes: Int
}

/// Network totals since boot (sum of the AM-filtered interfaces) and per-second rates. Rates are nil while the
/// baseline was just (re)established (first sample, after wake, dt > 5 s).
struct NetReading: Sendable, Equatable {
    let pktIn: UInt64, pktOut: UInt64, bytesIn: UInt64, bytesOut: UInt64
    let pktInRate: Double?, pktOutRate: Double?, rxRate: Double?, txRate: Double?   // packets/s, bytes/s
    let ifaces: Int
}

/// One app's traffic over the last nettop window (bytes/s), helpers summed under the app's name. Produced by
/// ProcNetMonitor (busiest first, idle apps dropped), consumed on main by Store.applyProcNet.
struct ProcTraffic: Sendable, Equatable {
    let name: String
    let rx: Double, tx: Double
}

/// One SystemSampler tick (1 Hz, wall-clock aligned), delivered to main.
struct SysSample: Sendable {
    let seq: UInt64
    let tWall: Date            // tick START time (CPU / NET log timestamp); history point t = floor(tWall)
    let durUs: Int
    let cpu: Reading<CPUReading>
    let tasks: Reading<TaskCounts>
    let net: Reading<NetReading>
    let cpuSimulated: Bool     // cpu.load fail/garbage injected this tick → CPUPoint.simulated (CPU graph stripe)
    let netSimulated: Bool     // net.if fail/garbage injected this tick → NetPoint.simulated (network graph stripe);
                               // cpu.tasks injections mark neither (no graph plots the counts)
}
