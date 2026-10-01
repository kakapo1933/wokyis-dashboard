// HostAudit.swift — bracketed host_statistics64 audit + free-mode switching (spec §5.4).
// The ONLY host_statistics64 caller in the process (called on memQ, every round(memHz/auditHz) ticks).
//
//   sysctl snapshot A → host_statistics64(HOST_VM_INFO64) → sysctl snapshot B
//   fresh      : host internal / external within [min(A,B) − 64, max(A,B) + 64] pages, speculative within ±8
//   sameAsPrev : faults, lookups, zero_fill_count, pageins identical to the previous host result (cached → dropped)
//   adopted    : fresh ∧ ¬sameAsPrev → host AM formulas vs sysctl formulas on (A+B)/2, per field (pages, host − sysctl);
//                freeErr = (free_count − speculative_count) − F_mte;  residual = (free_count − speculative_count) − (free + free_cpu)
//   mode       : mte → calibrated when median |freeErr| of the last 12 adopted audits > 64 pages (window full), or when a
//                MTE free MIB is really missing; calibrated → mte after 12 consecutive adopted audits whose window median ≤ 32.
//   residualPages = median residual of the last 12 adopted audits (MemoryFormulas.noResidual until the first one).
// A failed host call (kr ≠ 0) → run() returns nil and `lastError` is set; nothing else changes.
// `host` is injectable so --selftest never calls host_statistics64.
// Owner: memory agent.
import Foundation

/// The host_statistics64 fields the audit uses.
struct HostVM: Sendable, Equatable {
    var free: Int64, speculative: Int64, internalPages: Int64, external: Int64, wire: Int64, purgeable: Int64, compressor: Int64
    var faults: UInt64, lookups: UInt64, zeroFill: UInt64, pageins: UInt64
}

final class HostAudit {
    static let window = 12
    static let switchToCalibratedAbove = 64
    static let switchBackAtOrBelow = 32
    static let bracketTol: Int64 = 64
    static let specTol: Int64 = 8
    static let specName = "vm.page_speculative_count"

    struct ModeSwitch: Sendable { let from: FreeMode; let to: FreeMode; let median: Int?; let reason: String }

    /// Default free mode, decided by gate G2 (spec §14 step 2: median |freeErr| ≤ 16 and p99 ≤ 64 pages → mte).
    /// G2 run 2026-10-01 06:18–06:24 (330 s, --audit-hz 1, 324 adopted audits): median 0, p99 14, max 51 pages,
    /// 0 mode switches → .mte. Evidence: evidence/g2/stats.txt. The runtime audit still switches to calibrated on drift.
    static let defaultMode: FreeMode = .mte

    private(set) var mode: FreeMode = HostAudit.defaultMode
    private(set) var residualPages: Int64 = MemoryFormulas.noResidual
    /// Set by the latest run(): host call error (run returned nil).
    private(set) var lastError: SourceError?
    /// Set by the latest run() when it switched mode.
    private(set) var lastSwitch: ModeSwitch?
    /// freeErr of the latest run() (nil when not adopted or MTE MIBs missing).
    private(set) var lastFreeErr: Int?
    /// Median |freeErr| of the current window (nil when empty).
    var windowMedian: Int? { HostAudit.median(errWindow) }
    private(set) var runs = 0, adopted = 0, freshCount = 0, sameCount = 0

    private let host: () -> Result<HostVM, SourceError>
    private var prev: HostVM?
    private var prevAt: UInt64 = 0
    private var errWindow: [Int] = []
    private var residWindow: [Int64] = []
    private var okStreak = 0

    init(host: @escaping () -> Result<HostVM, SourceError> = HostAudit.liveHost) { self.host = host }

    private static let hostPort = mach_host_self()
    static func liveHost() -> Result<HostVM, SourceError> {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &s) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(hostPort, HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return .failure(.kern(kr)) }
        return .success(HostVM(free: Int64(s.free_count), speculative: Int64(s.speculative_count), internalPages: Int64(s.internal_page_count),
                               external: Int64(s.external_page_count), wire: Int64(s.wire_count), purgeable: Int64(s.purgeable_count),
                               compressor: Int64(s.compressor_page_count), faults: s.faults, lookups: s.lookups,
                               zeroFill: s.zero_fill_count, pageins: s.pageins))
    }

    static func median(_ a: [Int]) -> Int? {
        guard !a.isEmpty else { return nil }
        let s = a.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : Int((Double(s[n / 2 - 1]) + Double(s[n / 2])) / 2.0)
    }
    static func median64(_ a: [Int64]) -> Int64? {
        guard !a.isEmpty else { return nil }
        let s = a.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : Int64((Double(s[n / 2 - 1]) + Double(s[n / 2])) / 2.0)
    }

    /// snapshot() is called twice (before / after the host call). nil = host call failed (see lastError).
    func run(snapshot: () -> [String: Result<Int64, SourceError>]) -> AuditResult? {
        lastError = nil; lastSwitch = nil; lastFreeErr = nil
        let a = snapshot()
        let hr = host()
        let t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let b = snapshot()
        let h: HostVM
        switch hr {
        case .failure(let e): lastError = e; return nil
        case .success(let v): h = v
        }
        runs += 1
        let same = prev.map { $0.faults == h.faults && $0.lookups == h.lookups && $0.zeroFill == h.zeroFill && $0.pageins == h.pageins } ?? false
        let ageMs: Int? = same && prevAt > 0 ? Int((t - prevAt) / 1_000_000) : nil
        prev = h; prevAt = t

        func v(_ s: [String: Result<Int64, SourceError>], _ names: [String]) -> Int64? { MemoryFormulas.value(MemoryFormulas.sum(s, names)) }
        func inBracket(_ x: Int64, _ p: Int64?, _ q: Int64?, _ tol: Int64) -> Bool {
            guard let p, let q else { return false }
            return x >= min(p, q) - tol && x <= max(p, q) + tol
        }
        let fresh = inBracket(h.internalPages, v(a, MemoryFormulas.iNames), v(b, MemoryFormulas.iNames), HostAudit.bracketTol)
            && inBracket(h.external, v(a, MemoryFormulas.eNames), v(b, MemoryFormulas.eNames), HostAudit.bracketTol)
            && inBracket(h.speculative, v(a, [HostAudit.specName]), v(b, [HostAudit.specName]), HostAudit.specTol)
        if fresh { freshCount += 1 }
        if same { sameCount += 1 }

        func isMissing(_ s: [String: Result<Int64, SourceError>]) -> Bool {
            if case .failure(let e) = MemoryFormulas.sum(s, MemoryFormulas.fMTE) { return !e.isInjected }
            return false
        }
        let mteMissing = isMissing(a) || isMissing(b)

        var diff: [Field: Int] = [:]
        if fresh && !same {
            adopted += 1
            func avg(_ names: [String]) -> Double? {
                guard let x = v(a, names), let y = v(b, names) else { return nil }
                return (Double(x) + Double(y)) / 2
            }
            let hostFree = Double(h.free - h.speculative)
            if let base = avg(MemoryFormulas.fBase) {
                residWindow.append(Int64((hostFree - base).rounded()))
                if residWindow.count > HostAudit.window { residWindow.removeFirst(residWindow.count - HostAudit.window) }
                residualPages = HostAudit.median64(residWindow) ?? MemoryFormulas.noResidual
            }
            let fMte: Double? = { guard let x = avg(MemoryFormulas.fBase), let y = avg(MemoryFormulas.fMTE) else { return nil }; return x + y }()
            if let fMte, !mteMissing {
                let err = Int((hostFree - fMte).rounded())
                lastFreeErr = err
                errWindow.append(abs(err))
                if errWindow.count > HostAudit.window { errWindow.removeFirst(errWindow.count - HostAudit.window) }
            }
            // per-field comparison (pages): host AM formula − sysctl formula on (A+B)/2 (used with the CURRENT mode's F)
            let fMode: Double? = {
                if mode == .mte, let fMte { return fMte }
                if let base = avg(MemoryFormulas.fBase), residualPages != MemoryFormulas.noResidual { return base + Double(residualPages) }
                return nil
            }()
            let E = avg(MemoryFormulas.eNames), U = avg(MemoryFormulas.uNames), I = avg(MemoryFormulas.iNames)
            let W = avg(MemoryFormulas.wNames), C = avg(MemoryFormulas.cNames)
            if let mem = avg(["hw.memsize"]), let P = avg(["hw.pagesize"]), P > 0, let E, let fMode {
                let phys = (mem / P).rounded(.down)
                diff[.used] = Int(((phys - hostFree - Double(h.external)) - (phys - fMode - E)).rounded())
            }
            if let E, let U { diff[.cached] = Int((Double(h.external + h.purgeable) - (E + U)).rounded()) }
            if let I, let U { diff[.app] = Int((Double(h.internalPages - h.purgeable) - (I - U)).rounded()) }
            if let W { diff[.wired] = Int((Double(h.wire) - W).rounded()) }
            if let C { diff[.compressed] = Int((Double(h.compressor) - C).rounded()) }
        }

        // mode switching
        let med = HostAudit.median(errWindow)
        if mteMissing {
            okStreak = 0
            if mode == .mte { switchTo(.calibrated, median: med, reason: "mib_missing") }
        } else if fresh && !same && lastFreeErr != nil {
            switch mode {
            case .mte:
                if errWindow.count >= HostAudit.window, let m = med, m > HostAudit.switchToCalibratedAbove {
                    switchTo(.calibrated, median: m, reason: "median")
                }
            case .calibrated:
                if let m = med, m <= HostAudit.switchBackAtOrBelow { okStreak += 1 } else { okStreak = 0 }
                if okStreak >= HostAudit.window { switchTo(.mte, median: med, reason: "median") }
            }
        }
        return AuditResult(fresh: fresh, sameAsPrev: same, ageMs: ageMs, diffPages: diff, freeErrPages: lastFreeErr ?? 0)
    }

    private func switchTo(_ m: FreeMode, median: Int?, reason: String) {
        lastSwitch = ModeSwitch(from: mode, to: m, median: median, reason: reason)
        mode = m; okStreak = 0
    }
}
