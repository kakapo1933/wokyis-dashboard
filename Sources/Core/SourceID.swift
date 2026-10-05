// SourceID.swift — identifiers of every data source that can fail (really or by injection), the shared error type,
// and the memory field keys. Spec §4 (Core/SourceID.swift). Owner: core.
import Foundation

enum SourceID: String, CaseIterable, Sendable {
    case memPhysical = "mem.physical", memVM = "mem.vm", memSwap = "mem.swap", memLevel = "mem.level",
         memPressure = "mem.pressure", memAudit = "mem.audit", batHID = "bat.hid", batIOPS = "bat.iops", batSP = "bat.sp",
         // v2 (spec §9.2): SystemSampler sources. Appended → v1 ids keep their order (badge / CTL ordering).
         cpuLoad = "cpu.load", cpuTasks = "cpu.tasks", netIF = "net.if",
         // per-app traffic of the network view's side column (ProcNetSource). `fail` only.
         netProc = "net.proc"

    /// Traditional-Chinese name used in the v1 simulation badge (`Injector.badge`, CTL / status.sh). Same strings as
    /// `L10n.sourceName(_, .zh)`, which is the single table (spec §9.2); the on-screen badge uses L10n directly.
    var badgeName: String { L10n.sourceName(rawValue, .zh) }
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
