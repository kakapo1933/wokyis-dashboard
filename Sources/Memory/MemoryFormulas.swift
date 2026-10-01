// MemoryFormulas.swift — spec §5.2 formulas + Activity Monitor guards + failure dependencies.
// Pure function of one sysctl snapshot (pages → bytes with P = hw.pagesize read once at start).
//
//   Physical   = hw.memsize
//   Used       = (memsize/P − F − E) × P      F(mte) = free + free_cpu + mte.free.{kernel_tagged,cpu_claimed,cpu_kernel_tagged} + mte.cell.inactive
//                                              F(calibrated) = free + free_cpu + R   (R = HostAudit.residualPages)
//   Cached     = (E + U) × P                  E = pageable_external + cpu_pageable_external
//   App        = (I − U) × P                  U = purgeable + purgeable_wired;  I = pageable_internal + cpu_pageable_internal
//   Wired      = W × P                        W = wired + throttled
//   Compressed = C × P                        C = mte.compress_ts_pages_used + mte.compress_non_ts_pages_used
//   Swap       = vm.swapusage.xsu_used
//
// Failure dependencies (only dependent fields fail): F→used; E→used,cached; U→cached,app; I→app; W→wired;
// C→compressed; hw.memsize→physical,used; vm.swapusage→swap; hw.pagesize→every page-derived field.
// A MTE free MIB that is really missing (not injected) in mte mode → this sample uses the calibrated F when a
// residual is known (warning `mte_mib_missing`), otherwise used fails. An injected MTE MIB failure → used fails.
// AM guards: used < 0 or > memsize → keep previous used (`guard_hold field=used`; no previous → failed);
// I < U or app > memsize → keep previous app (`guard_hold field=app`).
// Owner: memory agent.
import Foundation

enum MemoryFormulas {
    /// Sentinel for "no residual measured yet" (calibrated F impossible → used fails).
    static let noResidual = Int64.min

    static let fBase = ["vm.page_free_count", "vm.page_free_cpu_count"]
    static let fMTE = ["vm.mte.free.kernel_tagged", "vm.mte.free.cpu_claimed", "vm.mte.free.cpu_kernel_tagged", "vm.mte.cell.inactive"]
    static let eNames = ["vm.page_pageable_external_count", "vm.page_cpu_pageable_external_count"]
    static let uNames = ["vm.page_purgeable_count", "vm.page_purgeable_wired_count"]
    static let iNames = ["vm.page_pageable_internal_count", "vm.page_cpu_pageable_internal_count"]
    static let wNames = ["vm.page_wired_count", "vm.page_throttled_count"]
    static let cNames = ["vm.mte.compress_ts_pages_used", "vm.mte.compress_non_ts_pages_used"]
    static let levelName = "kern.memorystatus_level"
    static let pressureName = "kern.memorystatus_vm_pressure_level"

    /// Sum of the named results; the first failure wins.
    static func sum(_ raw: [String: Result<Int64, SourceError>], _ names: [String]) -> Result<Int64, SourceError> {
        var t: Int64 = 0
        for n in names {
            switch raw[n] ?? .failure(.errno(ENOENT, n)) {
            case .success(let v): t &+= v
            case .failure(let e): return .failure(e)
            }
        }
        return .success(t)
    }
    static func value(_ r: Result<Int64, SourceError>?) -> Int64? { if case .success(let v)? = r { return v }; return nil }

    /// Free pages F for the given mode; nil = cannot be computed. `fellBack` = mte MIB really missing → calibrated F used.
    static func freePages(_ raw: [String: Result<Int64, SourceError>], mode: FreeMode, residualPages: Int64)
        -> (pages: Int64?, fellBack: Bool, reason: String?) {
        guard let base = value(sum(raw, fBase)) else { return (nil, false, nil) }
        let calibrated: Int64? = residualPages == noResidual ? nil : base + residualPages
        switch mode {
        case .calibrated:
            return (calibrated, false, calibrated == nil ? "calibrated_no_residual" : nil)
        case .mte:
            switch sum(raw, fMTE) {
            case .success(let m): return (base + m, false, nil)
            case .failure(let e):
                if e.isInjected { return (nil, false, nil) }
                return (calibrated, calibrated != nil, calibrated == nil ? "mte_mib_missing_no_residual" : "mte_mib_missing")
            }
        }
    }

    static func compute(raw: [String: Result<Int64, SourceError>], memsize: Result<Int64, SourceError>,
                        swap: Result<Int64, SourceError>, mode: FreeMode, residualPages: Int64,
                        previous: MemoryBytes?) -> (MemoryBytes, warnings: [String]) {
        var out = MemoryBytes.allFailed
        var warnings: [String] = []
        let mem = value(memsize)
        out[.physical] = mem
        out[.swap] = value(swap)

        guard let P = value(raw["hw.pagesize"]), P > 0 else { return (out, warnings) }
        let E = value(sum(raw, eNames)), U = value(sum(raw, uNames)), I = value(sum(raw, iNames))
        let W = value(sum(raw, wNames)), C = value(sum(raw, cNames))

        if let E, let U { out[.cached] = (E + U) * P }
        if let W { out[.wired] = W * P }
        if let C { out[.compressed] = C * P }

        // App with AM guard
        if let I, let U {
            let app = (I - U) * P
            if I < U || (mem != nil && app > mem!) {
                warnings.append("guard_hold field=app")
                out[.app] = previous?[.app]
            } else { out[.app] = app }
        }

        // Used with AM guard
        let f = freePages(raw, mode: mode, residualPages: residualPages)
        if let r = f.reason { warnings.append("free_fallback reason=\(r)") }
        if let mem, let E, let F = f.pages {
            let used = (mem / P - F - E) * P
            if used < 0 || used > mem {
                warnings.append("guard_hold field=used")
                out[.used] = previous?[.used]
            } else { out[.used] = used }
        }
        return (out, warnings)
    }

    /// Pressure: pct = clamp(100 − kern.memorystatus_level, 0, 100); level from kern.memorystatus_vm_pressure_level.
    static func pressure(level: Result<Int64, SourceError>, kernelPressure: Result<Int64, SourceError>) -> (pct: Int, level: PressureLevel)? {
        guard let l = value(level), let k = value(kernelPressure) else { return nil }
        return (Int(max(0, min(100, 100 - l))), PressureLevel(kernel: Int(k)))
    }
}
