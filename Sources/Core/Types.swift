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
