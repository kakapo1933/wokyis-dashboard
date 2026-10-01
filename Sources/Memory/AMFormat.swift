// AMFormat.swift — Activity Monitor byte strings (ByteCountFormatter, spec §5.3) + the memory self-test hook.
// Formatter settings are AM's (reverse-engineered, Phase 1): countStyle .memory (1024-based), allowedUnits .useAll,
// zeroPadsFractionDigits, no non-numeric formatting ("Zero KB"), formattingContext .listItem; locale = system.
// MemorySelfTest is part of `SelfTest.runQuick()` (START line) → no files, no timers, NO host_statistics64 call
// (HostAudit is exercised with a fake host function).
// Owner: memory agent.
import Foundation

enum AMFormat {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory; f.allowedUnits = .useAll; f.zeroPadsFractionDigits = true
        f.allowsNonnumericFormatting = false; f.formattingContext = .listItem
        return f
    }()
    private static let lock = NSLock()

    static func string(_ bytes: Int64) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(fromByteCount: bytes)
    }

    /// spec §5.3 (Phase 2 `data/fmt.txt`, measured with locale en_TW).
    static let selfTestCases: [(Int64, String)] = [
        (0, "0 bytes"), (1023, "1,023 bytes"), (1024, "1 KB"), (1_047_552, "1,023 KB"), (1_048_575, "1.0 MB"),
        (41_156_608, "39.3 MB"), (41_680_896, "39.8 MB"), (1_073_217_536, "1,023.5 MB"), (1_073_614_848, "1,023.9 MB"),
        (1_073_741_823, "1.00 GB"), (3_293_773_824, "3.07 GB"), (19_883_098_112, "18.52 GB"), (25_769_803_776, "24.00 GB"),
    ]
}

/// Memory-module self-test hook called by `--selftest` and `SelfTest.runQuick()` (pure; see file header).
enum MemorySelfTest {
    typealias Raw = [String: Result<Int64, SourceError>]
    static let P: Int64 = 16384

    static func run() -> [SelfTestCase] {
        formatCases() + tableCases() + formulaCases() + pressureCases() + historyCases() + auditCases() + logFormatCases()
    }

    // MARK: AMFormat

    static func formatCases() -> [SelfTestCase] {
        var bad: [String] = []
        for (v, want) in AMFormat.selfTestCases {
            let got = AMFormat.string(v).replacingOccurrences(of: "\u{00A0}", with: " ")
            if got != want { bad.append("\(v)→'\(got)'≠'\(want)'") }
        }
        return [SelfTestCase("mem.amformat.13", bad.isEmpty && AMFormat.selfTestCases.count == 13,
                             bad.isEmpty ? "13/13 locale=\(Locale.current.identifier)" : bad.joined(separator: "; "))]
    }

    // MARK: SysctlTable (live, read-only sysctl)

    static func tableCases() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        let t = SysctlTable(names: SysctlTable.standardNames, broken: [])
        let mem = MemoryFormulas.value(t.read("hw.memsize")) ?? 0
        out.append(SelfTestCase("mem.sysctl.resolve", t.resolvedCount == t.names.count && mem > 0,
                                "mibs=\(t.resolvedCount)/\(t.names.count) memsize=\(mem) missing=\(t.unresolved.joined(separator: ","))"))
        let swapOK: Bool = { if case .success(let v) = t.readSwapUsed() { return v >= 0 }; return false }()
        out.append(SelfTestCase("mem.sysctl.swapusage", swapOK))
        let b = SysctlTable(names: SysctlTable.standardNames, broken: ["hw.memsize", "vm.swapusage"])
        var brokenENOENT = false
        if case .failure(.errno(let e, _)) = b.read("hw.memsize") { brokenENOENT = e == ENOENT }
        var swapBroken = false
        if case .failure(.errno(let e, _)) = b.readSwapUsed() { swapBroken = e == ENOENT }
        let isolated = MemoryFormulas.value(b.read("vm.page_wired_count")) != nil && MemoryFormulas.value(b.read("hw.pagesize")) != nil
        out.append(SelfTestCase("mem.sysctl.break_mib", brokenENOENT && swapBroken && isolated && b.resolvedCount == b.names.count - 1,
                                "memsize ENOENT=\(brokenENOENT) swap ENOENT=\(swapBroken) others ok=\(isolated) mibs=\(b.resolvedCount)/\(b.names.count)"))
        var unknown = false
        if case .failure = t.read("vm.not_in_table") { unknown = true }
        out.append(SelfTestCase("mem.sysctl.unknown_name", unknown))
        return out
    }

    // MARK: formulas

    static let memsize: Int64 = 25_769_803_776      // 24 GiB = 1 572 864 pages
    static func fixture() -> Raw {
        let v: [String: Int64] = [
            "hw.pagesize": P, "hw.memsize": memsize,
            "vm.page_free_count": 1000, "vm.page_free_cpu_count": 200,
            "vm.mte.free.kernel_tagged": 10, "vm.mte.free.cpu_claimed": 20, "vm.mte.free.cpu_kernel_tagged": 30, "vm.mte.cell.inactive": 40,
            "vm.page_pageable_external_count": 100_000, "vm.page_cpu_pageable_external_count": 5_000,
            "vm.page_purgeable_count": 2_000, "vm.page_purgeable_wired_count": 500,
            "vm.page_pageable_internal_count": 400_000, "vm.page_cpu_pageable_internal_count": 10_000,
            "vm.page_wired_count": 200_000, "vm.page_throttled_count": 100,
            "vm.mte.compress_ts_pages_used": 300_000, "vm.mte.compress_non_ts_pages_used": 1_000,
            "kern.memorystatus_level": 52, "kern.memorystatus_vm_pressure_level": 1,
        ]
        return v.mapValues { .success($0) }
    }
    static let swapBytes: Int64 = 41_680_896
    static func calc(_ raw: Raw, mode: FreeMode = .mte, residual: Int64 = MemoryFormulas.noResidual, previous: MemoryBytes? = nil,
                     swap: Result<Int64, SourceError> = .success(swapBytes)) -> (MemoryBytes, [String]) {
        let r = MemoryFormulas.compute(raw: raw, memsize: raw["hw.memsize"] ?? .failure(.errno(ENOENT, "hw.memsize")), swap: swap,
                                       mode: mode, residualPages: residual, previous: previous)
        return (r.0, r.warnings)
    }
    static func failedSet(_ b: MemoryBytes) -> Set<Field> { Set(Field.allCases.filter { b[$0] == nil }) }
    static func fmt(_ s: Set<Field>) -> String { s.map(\.rawValue).sorted().joined(separator: ",") }

    static func formulaCases() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        let raw = fixture()
        let (b, w) = calc(raw)
        let want: [Field: Int64] = [
            .physical: memsize, .used: (1_572_864 - 1_300 - 105_000) * P, .cached: 107_500 * P, .swap: swapBytes,
            .app: 407_500 * P, .wired: 200_100 * P, .compressed: 301_000 * P,
        ]
        let mism = Field.allCases.filter { b[$0] != want[$0] }
        out.append(SelfTestCase("mem.formula.values", mism.isEmpty && w.isEmpty,
                                mism.map { "\($0.rawValue)=\(b[$0].map(String.init) ?? "nil")≠\(want[$0]!)" }.joined(separator: "; ") + w.joined(separator: ",")))

        // calibrated mode: F = free + free_cpu + R
        let (bc, _) = calc(raw, mode: .calibrated, residual: 2_000)
        out.append(SelfTestCase("mem.formula.calibrated", bc[.used] == (1_572_864 - 3_200 - 105_000) * P, "used=\(bc[.used].map(String.init) ?? "nil")"))
        let (bn, wn) = calc(raw, mode: .calibrated)
        out.append(SelfTestCase("mem.formula.calibrated_no_residual", failedSet(bn) == [.used] && wn.contains("free_fallback reason=calibrated_no_residual"),
                                fmt(failedSet(bn))))

        // failure dependencies (real errno failures)
        let deps: [(String, Set<Field>)] = [
            ("vm.page_free_count", [.used]), ("vm.page_free_cpu_count", [.used]),
            ("vm.page_pageable_external_count", [.used, .cached]), ("vm.page_cpu_pageable_external_count", [.used, .cached]),
            ("vm.page_purgeable_count", [.cached, .app]), ("vm.page_purgeable_wired_count", [.cached, .app]),
            ("vm.page_pageable_internal_count", [.app]), ("vm.page_cpu_pageable_internal_count", [.app]),
            ("vm.page_wired_count", [.wired]), ("vm.page_throttled_count", [.wired]),
            ("vm.mte.compress_ts_pages_used", [.compressed]), ("vm.mte.compress_non_ts_pages_used", [.compressed]),
            ("hw.memsize", [.physical, .used]), ("hw.pagesize", [.used, .cached, .app, .wired, .compressed]),
            ("kern.memorystatus_level", []), ("kern.memorystatus_vm_pressure_level", []),
        ]
        var depBad: [String] = []
        for (name, exp) in deps {
            var r = raw; r[name] = .failure(.errno(ENOENT, name))
            let got = failedSet(calc(r).0)
            if got != exp { depBad.append("\(name)→{\(fmt(got))}≠{\(fmt(exp))}") }
        }
        let gotSwap = failedSet(calc(raw, swap: .failure(.errno(ENOENT, "vm.swapusage"))).0)
        if gotSwap != [.swap] { depBad.append("vm.swapusage→{\(fmt(gotSwap))}") }
        // injected mem.vm = every vm.* MIB failed → only physical and swap survive
        var vmAll = raw
        for k in raw.keys where k.hasPrefix("vm.") { vmAll[k] = .failure(.injected("mem.vm")) }
        let gotVM = failedSet(calc(vmAll).0)
        if gotVM != [.used, .cached, .app, .wired, .compressed] { depBad.append("mem.vm→{\(fmt(gotVM))}") }
        out.append(SelfTestCase("mem.formula.dependencies", depBad.isEmpty, depBad.isEmpty ? "\(deps.count + 2) cases" : depBad.joined(separator: "; ")))

        // MTE free MIB: real missing → calibrated fallback when residual known; injected → used failed
        var mteMissing = raw; mteMissing["vm.mte.cell.inactive"] = .failure(.errno(ENOENT, "vm.mte.cell.inactive"))
        let (m1, w1) = calc(mteMissing, residual: 100)
        let (m2, _) = calc(mteMissing)
        var mteInj = raw; mteInj["vm.mte.cell.inactive"] = .failure(.injected("mem.mib:vm.mte.cell.inactive"))
        let (m3, _) = calc(mteInj, residual: 100)
        out.append(SelfTestCase("mem.formula.mte_missing",
                                m1[.used] == (1_572_864 - 1_300 - 105_000) * P && w1.contains("free_fallback reason=mte_mib_missing")
                                    && failedSet(m2) == [.used] && failedSet(m3) == [.used],
                                "fallback used=\(m1[.used].map(String.init) ?? "nil") noResidual={\(fmt(failedSet(m2)))} injected={\(fmt(failedSet(m3)))}"))

        // AM guards
        var neg = raw; neg["vm.page_pageable_external_count"] = .success(2_000_000)   // used < 0
        var prev = MemoryBytes.allFailed; prev[.used] = 123 * P; prev[.app] = 456 * P
        let (g1, gw1) = calc(neg, previous: prev)
        let (g2, _) = calc(neg)
        var iu = raw; iu["vm.page_purgeable_count"] = .success(900_000)                // I < U
        let (g3, gw3) = calc(iu, previous: prev)
        let (g4, _) = calc(iu)
        out.append(SelfTestCase("mem.formula.guards",
                                g1[.used] == 123 * P && gw1.contains("guard_hold field=used") && g2[.used] == nil
                                    && g3[.app] == 456 * P && gw3.contains("guard_hold field=app") && g4[.app] == nil,
                                "used hold=\(g1[.used].map(String.init) ?? "nil") app hold=\(g3[.app].map(String.init) ?? "nil")"))
        return out
    }

    // MARK: pressure

    static func pressureCases() -> [SelfTestCase] {
        func p(_ l: Int64, _ k: Int64) -> String {
            guard let r = MemoryFormulas.pressure(level: .success(l), kernelPressure: .success(k)) else { return "nil" }
            return "\(r.pct)/\(r.level.rawValue)"
        }
        let got = [p(52, 1), p(-5, 2), p(130, 4), p(0, 0), p(100, 3)]
        let want = ["48/1", "100/2", "0/4", "100/1", "0/1"]
        let failed = MemoryFormulas.pressure(level: .failure(.injected("mem.level")), kernelPressure: .success(1)) == nil
            && MemoryFormulas.pressure(level: .success(50), kernelPressure: .failure(.errno(ENOENT, "x"))) == nil
        return [SelfTestCase("mem.pressure", got == want && failed, got.joined(separator: " "))]
    }

    // MARK: history

    static func historyCases() -> [SelfTestCase] {
        var h = PressureHistory()
        h.add(pct: 40, level: .normal, simulated: false, wallSecond: 1000)
        h.add(pct: 55, level: .warning, simulated: false, wallSecond: 1000)
        h.add(pct: 50, level: .normal, simulated: true, wallSecond: 1000)
        h.add(pct: nil, level: nil, simulated: false, wallSecond: 1000)
        let openOnly = h.points().isEmpty
        h.add(pct: nil, level: nil, simulated: false, wallSecond: 1001)
        let p1 = h.points()
        let merged = p1.count == 1 && p1[0].t == 1000 && p1[0].percent == 55 && p1[0].level == .warning && p1[0].simulated
        h.add(pct: nil, level: nil, simulated: false, wallSecond: 1001)
        h.closeThrough(wallSecond: 1002)
        let p2 = h.points()
        let gap = p2.count == 2 && p2[1].percent == nil && p2[1].level == nil && !p2[1].simulated
        h.closeThrough(wallSecond: 1003)                                   // nothing open → no-op
        var big = PressureHistory()
        for s in 0..<1000 { big.add(pct: s % 100, level: .normal, simulated: false, wallSecond: 5000 + s) }
        big.closeThrough(wallSecond: 7000)
        let bp = big.points()
        let cap = bp.count == 900 && bp.first?.t == 5100 && bp.last?.t == 5999 && big.coverageSeconds == 900
        // wall clock stepped back 60 s: the timeline restarts at the new second, later samples keep adding points
        var cs = PressureHistory()
        for s in 0..<10 { cs.add(pct: 40, level: .normal, simulated: false, wallSecond: 9000 + s) }
        cs.add(pct: 70, level: .warning, simulated: false, wallSecond: 8950)   // step back
        for s in 1...5 { cs.add(pct: 41, level: .normal, simulated: false, wallSecond: 8950 + s) }
        cs.closeThrough(wallSecond: 8956)
        let ct = cs.points().map { Int($0.t) }
        let stepOK = ct == Array(8950...8955) && cs.points().first?.level == .warning
        var jit = PressureHistory()                                              // ≤ 2 s back → folded (jitter)
        jit.add(pct: 40, level: .normal, simulated: false, wallSecond: 100)
        jit.add(pct: 90, level: .critical, simulated: false, wallSecond: 99)
        jit.closeThrough(wallSecond: 101)
        let jitOK = jit.points().count == 1 && jit.points()[0].t == 100 && jit.points()[0].percent == 90
        // sampler grid: normal tick, late tick (skip missed), backward step (regrid), forward step
        func nb(_ now: Double, _ last: Double) -> (Double, Bool) { let r = MemorySampler.nextBoundary(now: now, lastBoundary: last, period: 0.25); return (r.next, r.steppedBack) }
        let g1 = nb(1000.001, 1000.0), g2 = nb(1000.9, 1000.0), g3 = nb(970.0, 1000.0), g4 = nb(1100.1, 1000.0), g5 = nb(999.99, 1000.0)
        let gridOK = g1 == (1000.25, false) && g2 == (1001.0, false) && g3 == (970.25, true) && g4 == (1100.25, false) && g5 == (1000.25, false)
        return [SelfTestCase("mem.history", openOnly && merged && gap && h.points().count == 2 && h.coverageSeconds == 2 && cap,
                             "open=\(openOnly) merge=\(merged) gap=\(gap) cap=\(cap) n=\(bp.count)"),
                SelfTestCase("mem.history.clock_step_back", stepOK && jitOK, "points=\(ct) jitter=\(jitOK)"),
                SelfTestCase("mem.sampler.grid_clock_step", gridOK, "\([g1, g2, g3, g4, g5])")]
    }

    // MARK: audit (fake host — never calls host_statistics64)

    static func auditCases() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        var snap = fixture(); snap[HostAudit.specName] = .success(300)
        // consistent host: free − spec = F_mte (1300); internal/external/... match the fixture
        var hv = HostVM(free: 1_600, speculative: 300, internalPages: 410_000, external: 105_000, wire: 200_100, purgeable: 2_500,
                        compressor: 301_000, faults: 1, lookups: 1, zeroFill: 1, pageins: 1)
        var hostResult: Result<HostVM, SourceError> = .success(hv)
        let a = HostAudit(host: { hostResult })
        let r1 = a.run(snapshot: { snap })
        let ok1 = r1.map { $0.fresh && !$0.sameAsPrev && $0.diffPages.values.allSatisfy { $0 == 0 } && $0.diffPages.count == 5 } ?? false
            && a.lastFreeErr == 0 && a.residualPages == 100 && a.mode == .mte
        out.append(SelfTestCase("mem.audit.fresh_adopted", ok1, r1.map { "fresh=\($0.fresh) diff=\($0.diffPages.map { "\($0.key.rawValue)=\($0.value)" }.sorted())" } ?? "nil"))
        let r2 = a.run(snapshot: { snap })                                  // same counters → cached
        out.append(SelfTestCase("mem.audit.same_as_prev", r2.map { $0.sameAsPrev && $0.diffPages.isEmpty && $0.ageMs != nil } ?? false && a.lastFreeErr == nil))
        hv.faults += 1; hv.internalPages += 1_000; hostResult = .success(hv)
        let r3 = a.run(snapshot: { snap })                                  // internal outside bracket → not fresh
        out.append(SelfTestCase("mem.audit.not_fresh", r3.map { !$0.fresh && !$0.sameAsPrev && $0.diffPages.isEmpty } ?? false))
        hostResult = .failure(.kern(5))
        let r4 = a.run(snapshot: { snap })
        out.append(SelfTestCase("mem.audit.host_error", r4 == nil && a.lastError == .kern(5) && a.mode == .mte))

        // mode switching: freeErr 100 → calibrated only once the 12-window is full; then 0 → back to mte after 12 ≤32
        var n: UInt64 = 10
        var host = hv; host.internalPages = 410_000
        let b = HostAudit(host: { n += 1; var h = host; h.faults = n; return .success(h) })
        host.free = 1_600 + 100
        var switchedAt: Int?
        for i in 1...12 { _ = b.run(snapshot: { snap }); if switchedAt == nil && b.mode == .calibrated { switchedAt = i } }
        let sw1 = b.lastSwitch
        host.free = 1_600
        var backAt: Int?
        for i in 1...30 { _ = b.run(snapshot: { snap }); if backAt == nil && b.mode == .mte { backAt = i } }
        out.append(SelfTestCase("mem.audit.mode_switch", switchedAt == 12 && sw1?.reason == "median" && sw1?.median == 100 && backAt != nil && backAt! >= 12,
                                "to_calibrated_at=\(switchedAt.map(String.init) ?? "-") back_to_mte_at=\(backAt.map(String.init) ?? "-") resid=\(b.residualPages)"))

        // MTE free MIB really missing → calibrated at once
        var miss = snap; miss["vm.mte.cell.inactive"] = .failure(.errno(ENOENT, "vm.mte.cell.inactive"))
        let c = HostAudit(host: { n += 1; var h = host; h.faults = n; return .success(h) })
        _ = c.run(snapshot: { miss })
        out.append(SelfTestCase("mem.audit.mib_missing", c.mode == .calibrated && c.lastSwitch?.reason == "mib_missing" && c.residualPages == 100,
                                "mode=\(c.mode.rawValue) resid=\(c.residualPages)"))
        return out
    }

    // MARK: MEM line

    static func logFormatCases() -> [SelfTestCase] {
        let (b, _) = calc(fixture(), swap: .failure(.errno(ENOENT, "vm.swapusage")))
        var strings: [Field: String?] = [:]
        for f in Field.allCases { strings[f] = .some(b[f].map(AMFormat.string)) }
        let s = MemSample(seq: 7, tWall: Date(), durUs: 9, bytes: b, strings: strings, pressure: (48, .normal), simulated: false,
                          failed: ["mem.mib:vm.swapusage"], mode: .mte)
        let body = MemorySampler.memBody(s, injectorActive: false)
        let ok = body.hasPrefix("seq=7 dur_us=9 mode=mte sim=0 phys=25769803776 \"24.00 GB\" used=") && body.contains(" swap=- \"—\" ")
            && body.hasSuffix(" pct=48 lvl=1 fail=mem.mib:vm.swapusage")
        return [SelfTestCase("mem.log.mem_line", ok, ok ? "" : body)]
    }
}
