// SourceID.swift — identifiers of every data source that can fail (really or by injection), the shared error type,
// and the memory field keys. Spec §4 (Core/SourceID.swift). Owner: core.
import Foundation

enum SourceID: String, CaseIterable, Sendable {
    case memPhysical = "mem.physical", memVM = "mem.vm", memSwap = "mem.swap", memLevel = "mem.level",
         memPressure = "mem.pressure", memAudit = "mem.audit", batHID = "bat.hid", batIOPS = "bat.iops", batSP = "bat.sp"

    /// Traditional-Chinese name used in the simulation badge (spec §7.4). Latin is upper-cased by the renderer anyway.
    var badgeName: String {
        switch self {
        case .memPhysical: "實體記憶體"
        case .memVM: "記憶體計數"
        case .memSwap: "交換檔"
        case .memLevel: "壓力值"
        case .memPressure: "壓力等級"
        case .memAudit: "稽核"
        case .batHID: "HID"
        case .batIOPS: "AIRPODS 電量"
        case .batSP: "藍牙連線"
        }
    }
}

enum SourceError: Error, Sendable, Equatable {
    case injected(String), errno(Int32, String), kern(Int32), subprocess(Int32),
         timeout, parse(String), missingSymbol(String)

    /// Value of the `err=` token in `ERR` log lines (spec §12): injected|errno=2|kr=5|rc=1|timeout|parse|missing_symbol
    var logToken: String {
        switch self {
        case .injected: "injected"
        case .errno(let e, _): "errno=\(e)"
        case .kern(let k): "kr=\(k)"
        case .subprocess(let rc): "rc=\(rc)"
        case .timeout: "timeout"
        case .parse: "parse"
        case .missingSymbol: "missing_symbol"
        }
    }
    var isInjected: Bool { if case .injected = self { return true }; return false }
}

enum Field: String, CaseIterable, Sendable { case physical, used, cached, swap, app, wired, compressed }
