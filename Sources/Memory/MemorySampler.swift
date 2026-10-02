// MemorySampler.swift — memQ wall-clock-aligned timer, sysctl snapshot, injection, audit scheduling,
// MEM / AUD / ERR / RECOVER / WARN log lines (spec §5.1–§5.6, §11, §12, D4).
//
// * memQ: serial, QoS .utility. A one-shot DispatchSourceTimer is re-armed every tick for the next wall-clock
//   boundary k/memHz s (4 Hz → …:00.000 / .250 / .500 / .750), leeway 20 ms; late ticks skip missed boundaries.
//   The deadline is MONOTONIC (DispatchTime, now + distance to the wall boundary), so a wall-clock step can delay a
//   tick by at most one period; a backward step (tick fires > 1 period before its boundary) re-aligns the grid to the
//   new wall time (`WARN clock_step`) instead of waiting until the clock catches up (criterion #6, ≤ 2 s).
// * Every tick: one sysctl snapshot of SysctlTable.standardNames (minus hw.pagesize, read once at start) + vm.swapusage.
//   Each MIB read first runs `injector.checkMIB(name)` and `injector.check(<owning source>)`; injected and real errors
//   share the same Result path → the dependent fields fail IN THIS SAMPLE (MemoryFormulas dependency table).
//   Owning sources: hw.memsize → mem.physical, vm.* → mem.vm, vm.swapusage → mem.swap,
//   kern.memorystatus_level → mem.level, kern.memorystatus_vm_pressure_level → mem.pressure.
// * Pressure override (injector) replaces the real pressure after the read; `MemSample.simulated` = the pressure shown
//   in this sample is simulated (override, or pressure failed by injection) → magenta strip in the history.
// * MEM line for every sample via log.line (EventLog decimates at summary level); ERR on failure onset (event) and every
//   60 s while it persists (line), RECOVER when it clears; WARN (formula guards / fallbacks) at most once per 60 s per key.
// * Audit: on the first tick and then every round(memHz/auditHz) ticks, after the sample: injector.check(.memAudit) → HostAudit.run → AUD line;
//   mode switches → `WARN free_mode from=… to=… median=… reason=…`. The audit reads REAL sysctl values (no injection).
// * v2 setHz(_:) (spec §5.4, owner: sampler agent): the rate is a memQ-only var; switching (4 ↔ 1 Hz) recomputes
//   auditEvery (auditHz 0 → off, no Int(inf) trap), clamps ticksSinceAudit so a longer audit period never postpones
//   the next audit by more than one period, resets lastBoundary and re-arms on the new grid.
// Owner: memory agent.
import Foundation

final class MemorySampler: @unchecked Sendable {
    private(set) var hz: Double                      // memQ only after init (setHz); read with currentHz()
    let auditHz: Double
    let table: SysctlTable
    let injector: Injector
    let log: EventLog
    let onSample: @Sendable (MemSample) -> Void

    let memQ = DispatchQueue(label: "wokyis.mem", qos: .utility)
    // --- memQ-only state ---
    private let full: SysctlTable                    // table.names + vm.page_speculative_count (audit bracket)
    private let tickNames: [String]
    private let audit: HostAudit
    private var auditEvery: Int                      // 0 = off (memQ only)
    private var pageSize: Int64 = 16384
    private var timer: DispatchSourceTimer?
    private var running = false
    private var lastBoundary: Double = 0
    private var seq: UInt64 = 0
    private var ticksSinceAudit = 0
    private var previous: MemoryBytes?
    private var lateMs: [Double] = []
    private var errs: [String: ErrState] = [:]
    private var auditErr: ErrState?
    private var warnLast: [String: (at: Date, n: Int)] = [:]

    private struct ErrState { let src: String; let mib: String?; var token: String; let since: Date; var lastLogged: Date; var n: Int }

    /// `audit` is injectable for tests (default: a live HostAudit).
    init(hz: Double, auditHz: Double, table: SysctlTable, injector: Injector, log: EventLog, audit: HostAudit = HostAudit(),
         onSample: @escaping @Sendable (MemSample) -> Void) {
        self.hz = hz; self.auditHz = auditHz; self.table = table; self.injector = injector; self.log = log; self.onSample = onSample
        self.audit = audit
        var names = table.names
        if !names.contains(HostAudit.specName) { names.append(HostAudit.specName) }
        full = SysctlTable(names: names, broken: table.broken)
        tickNames = table.names.filter { $0 != "hw.pagesize" }
        auditEvery = MemorySampler.auditEvery(hz: hz, auditHz: auditHz)
    }

    // MARK: sampling rate (v2, spec §5.4)

    /// Ticks between audits; 0 = audits off (auditHz ≤ 0, e.g. `--audit-hz 0`).
    static func auditEvery(hz: Double, auditHz: Double) -> Int {
        auditHz > 0 && hz > 0 ? max(1, Int((hz / auditHz).rounded())) : 0
    }

    /// New (auditEvery, ticksSinceAudit) after a rate change: the counter is clamped to `auditEvery − 1`, so the next
    /// audit comes at most one (new) audit period later.
    static func retune(hz: Double, auditHz: Double, ticksSinceAudit: Int) -> (auditEvery: Int, ticksSinceAudit: Int) {
        let every = auditEvery(hz: hz, auditHz: auditHz)
        return (every, min(ticksSinceAudit, max(0, every - 1)))
    }

    /// Switch the sampling rate (4 ↔ 1 Hz; AppController: memory view visible → config.memHz, otherwise
    /// min(1, config.memHz)). Runs on memQ (async; callers on main never wait). Ignores non-positive / unchanged rates.
    func setHz(_ newHz: Double) {
        memQ.async { [weak self] in self?.applyHz(newHz) }
    }

    /// Current sampling rate (HEALTH `mem_hz=`). Must not be called on memQ.
    func currentHz() -> Double { memQ.sync { hz } }

    private func applyHz(_ newHz: Double) {
        guard newHz.isFinite, newHz > 0, newHz != hz else { return }
        hz = newHz
        (auditEvery, ticksSinceAudit) = MemorySampler.retune(hz: newHz, auditHz: auditHz, ticksSinceAudit: ticksSinceAudit)
        lastBoundary = 0
        if running { arm() }
    }

    // MARK: lifecycle

    /// Starts the timer (idempotent). The first sample is taken at the next wall-clock boundary.
    func start() {
        memQ.sync {
            guard !running else { return }
            running = true
            switch full.read("hw.pagesize") {
            case .success(let p) where p > 0: pageSize = p
            case .success(let p): pageSize = Int64(vm_kernel_page_size); log.event("WARN", "pagesize_fallback value=\(p) using=\(pageSize)")
            case .failure(let e): pageSize = Int64(vm_kernel_page_size); log.event("WARN", "pagesize_fallback err=\(e.logToken) using=\(pageSize)")
            }
            let un = table.unresolved
            if !un.isEmpty { log.event("WARN", "mib_unresolved names=\(un.joined(separator: ",")) broken=\(table.broken.sorted().joined(separator: ","))") }
            let unknown = table.broken.subtracting(table.names + [SysctlTable.swapName])
            if !unknown.isEmpty { log.event("WARN", "break_mib_unknown names=\(unknown.sorted().joined(separator: ","))") }
            let t = DispatchSource.makeTimerSource(flags: [], queue: memQ)
            t.setEventHandler { [weak self] in self?.fire() }
            timer = t
            lastBoundary = 0
            ticksSinceAudit = max(0, auditEvery - 1)   // first tick audits too (early mode / residual)
            arm()
            t.resume()
        }
    }

    /// Stops the timer; after return no further onSample calls are made. Must not be called on memQ.
    func stop() {
        memQ.sync {
            running = false
            timer?.cancel(); timer = nil
        }
    }

    /// Take one extra sample as soon as possible (wake from sleep). Does not change the tick grid.
    func sampleNow() { memQ.async { [weak self] in guard let self, self.running else { return }; self.tick(boundary: nil) } }

    /// (samples taken, p99 / max tick lateness in ms over the last 240 ticks). Thread-safe.
    func stats() -> (samples: UInt64, lateP99Ms: Double?, lateMaxMs: Double?, mode: FreeMode) {
        memQ.sync {
            let s = lateMs.sorted()
            let p99 = s.isEmpty ? nil : s[min(s.count - 1, Int((Double(s.count) * 0.99).rounded(.up)) - 1)]
            return (seq, p99, s.last, audit.mode)
        }
    }

    // MARK: timer (memQ)

    private var period: Double { 1.0 / hz }

    /// Next wall-clock boundary after `now`, never before `lastBoundary + period` (skip-missed rule), except after a
    /// backward clock step (`now` more than one period before `lastBoundary`): then the grid restarts from `now`.
    static func nextBoundary(now: Double, lastBoundary: Double, period p: Double) -> (next: Double, steppedBack: Bool) {
        let stepped = lastBoundary > 0 && now < lastBoundary - p
        var next = (floor(now / p) + 1) * p
        if !stepped && next < lastBoundary + p - 1e-6 { next = lastBoundary + p }
        return (next, stepped)
    }

    private func arm() {
        let now = Date().timeIntervalSince1970
        let (next, stepped) = MemorySampler.nextBoundary(now: now, lastBoundary: lastBoundary, period: period)
        if stepped { log.event("WARN", "clock_step dir=back by_s=\(String(format: "%.3f", lastBoundary - now)) regrid=1") }
        lastBoundary = next
        let delay = max(0, next - now)
        timer?.schedule(deadline: .now() + .nanoseconds(Int((delay * 1e9).rounded())), repeating: .never, leeway: .milliseconds(20))
    }

    private func fire() {
        guard running else { return }
        let b = lastBoundary
        tick(boundary: b)
        if running { arm() }
    }

    // MARK: sampling (memQ)

    private static func owner(_ name: String) -> SourceID {
        switch name {
        case "hw.memsize", "hw.pagesize": return .memPhysical
        case SysctlTable.swapName: return .memSwap
        case MemoryFormulas.levelName: return .memLevel
        case MemoryFormulas.pressureName: return .memPressure
        default: return .memVM
        }
    }

    private func readChecked(_ name: String) -> Result<Int64, SourceError> {
        do {
            try injector.checkMIB(name)
            try injector.check(MemorySampler.owner(name))
        } catch let e as SourceError { return .failure(e) } catch { return .failure(.parse("\(error)")) }
        return name == SysctlTable.swapName ? full.readSwapUsed() : full.read(name)
    }

    private func tick(boundary: Double?) {
        let tWall = Date()
        if let b = boundary {
            lateMs.append(max(0, (tWall.timeIntervalSince1970 - b) * 1000))
            if lateMs.count > 240 { lateMs.removeFirst(lateMs.count - 240) }
        }
        let c0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var raw: [String: Result<Int64, SourceError>] = [:]
        raw.reserveCapacity(tickNames.count + 1)
        for n in tickNames { raw[n] = readChecked(n) }
        let swap = readChecked(SysctlTable.swapName)
        let durUs = Int((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - c0) / 1000)
        raw["hw.pagesize"] = .success(pageSize)

        let mode = audit.mode
        let memsize = raw["hw.memsize"] ?? .failure(.errno(ENOENT, "hw.memsize"))
        let (bytes, warnings) = MemoryFormulas.compute(raw: raw, memsize: memsize, swap: swap, mode: mode,
                                                        residualPages: audit.residualPages, previous: previous)
        previous = bytes

        var pressure = MemoryFormulas.pressure(level: raw[MemoryFormulas.levelName] ?? .failure(.errno(ENOENT, MemoryFormulas.levelName)),
                                               kernelPressure: raw[MemoryFormulas.pressureName] ?? .failure(.errno(ENOENT, MemoryFormulas.pressureName)))
        var psim = false
        if pressure == nil {
            for n in [MemoryFormulas.levelName, MemoryFormulas.pressureName] {
                if case .failure(let e)? = raw[n], e.isInjected { psim = true }
            }
        }
        if let o = injector.pressureOverride { pressure = (o.percent, o.level); psim = true }

        // failures of this sample
        var failed: [String] = []
        var current: [String: (src: String, mib: String?, token: String)] = [:]
        func note(_ name: String, _ r: Result<Int64, SourceError>?) {
            guard case .failure(let e)? = r else { return }
            let key: String, src: String, mib: String?
            if case .injected(let id) = e { key = id; src = id; mib = nil } else { key = "mem.mib:" + name; src = MemorySampler.owner(name).rawValue; mib = name }
            if !failed.contains(key) { failed.append(key) }
            if current[key] == nil { current[key] = (src, mib, e.logToken) }
        }
        for n in tickNames { note(n, raw[n]) }
        note(SysctlTable.swapName, swap)

        seq += 1
        var strings: [Field: String?] = [:]
        for f in Field.allCases { strings[f] = .some(bytes[f].map(AMFormat.string)) }
        let sample = MemSample(seq: seq, tWall: tWall, durUs: durUs, bytes: bytes, strings: strings, pressure: pressure,
                               simulated: psim, failed: failed, mode: mode)

        onSample(sample)
        log.line("MEM", MemorySampler.memBody(sample, injectorActive: injector.active), at: tWall)
        trackErrors(current, at: tWall)
        for w in warnings { warn(w, at: tWall) }

        if auditEvery > 0 && boundary != nil {
            ticksSinceAudit += 1
            if ticksSinceAudit >= auditEvery { ticksSinceAudit = 0; runAudit() }
        }
    }

    /// `MEM seq=… dur_us=… mode=mte sim=0 phys=25769803776 "24.00 GB" used=… "…" cached=… swap=… app=… wired=… comp=… pct=48 lvl=1 fail=-`
    /// A failed field is written as `<key>=- "—"`; failed pressure as `pct=- lvl=-`; `psim=1` when the pressure is simulated.
    static func memBody(_ s: MemSample, injectorActive: Bool) -> String {
        var b = "seq=\(s.seq) dur_us=\(s.durUs) mode=\(s.mode.rawValue) sim=\(injectorActive ? 1 : 0)"
        for (f, k) in [(Field.physical, "phys"), (.used, "used"), (.cached, "cached"), (.swap, "swap"), (.app, "app"), (.wired, "wired"), (.compressed, "comp")] {
            if let v = s.bytes[f], let str = s.strings[f] ?? nil { b += " \(k)=\(v) \(EventLog.q(str))" } else { b += " \(k)=- \"—\"" }
        }
        if let p = s.pressure { b += " pct=\(p.pct) lvl=\(p.level.rawValue)" } else { b += " pct=- lvl=-" }
        if s.simulated { b += " psim=1" }
        b += " fail=" + (s.failed.isEmpty ? "-" : s.failed.joined(separator: ","))
        return b
    }

    private func errBody(_ e: ErrState, extra: String) -> String {
        "src=\(e.src) err=\(e.token)" + (e.mib.map { " mib=\($0)" } ?? "") + extra
    }

    private func trackErrors(_ current: [String: (src: String, mib: String?, token: String)], at: Date) {
        for (key, c) in current {
            if var st = errs[key] {
                if st.token != c.token {
                    st.token = c.token; st.lastLogged = at; st.n += 1; errs[key] = st
                    log.event("ERR", errBody(st, extra: ""), at: at)
                } else {
                    st.n += 1
                    if at.timeIntervalSince(st.lastLogged) >= 60 {
                        st.lastLogged = at
                        log.line("ERR", errBody(st, extra: " repeat=1 n=\(st.n) for_s=\(Int(at.timeIntervalSince(st.since)))"), at: at)
                    }
                    errs[key] = st
                }
            } else {
                let st = ErrState(src: c.src, mib: c.mib, token: c.token, since: at, lastLogged: at, n: 1)
                errs[key] = st
                log.event("ERR", errBody(st, extra: ""), at: at)
            }
        }
        for (key, st) in errs where current[key] == nil {
            errs[key] = nil
            log.event("RECOVER", "src=\(st.src)" + (st.mib.map { " mib=\($0)" } ?? "") + " failed_s=\(String(format: "%.1f", at.timeIntervalSince(st.since))) n=\(st.n)", at: at)
        }
    }

    private func warn(_ w: String, at: Date) {
        if let l = warnLast[w], EventLog.throttled(at, l.at, 60.05) { warnLast[w] = (l.at, l.n + 1); return }
        let suppressed = warnLast[w]?.n ?? 0
        warnLast[w] = (at, 0)
        log.event("WARN", w + (suppressed > 0 ? " suppressed=\(suppressed)" : ""), at: at)
    }

    private func auditSnapshot() -> [String: Result<Int64, SourceError>] {
        var s: [String: Result<Int64, SourceError>] = [:]
        for n in full.names where n != "hw.pagesize" { s[n] = full.read(n) }
        s["hw.pagesize"] = .success(pageSize)
        return s
    }

    private func runAudit() {
        let at = Date()
        var err: SourceError?
        do { try injector.check(.memAudit) } catch let e as SourceError { err = e } catch { err = .parse("\(error)") }
        var result: AuditResult?
        if err == nil {
            result = audit.run(snapshot: { auditSnapshot() })
            if result == nil { err = audit.lastError ?? .kern(-1) }
        }
        if let e = err {
            if var st = auditErr {
                st.n += 1
                if st.token != e.logToken { st.token = e.logToken; st.lastLogged = at; log.event("ERR", errBody(st, extra: ""), at: at) }
                else if at.timeIntervalSince(st.lastLogged) >= 60 {
                    st.lastLogged = at
                    log.line("ERR", errBody(st, extra: " repeat=1 n=\(st.n) for_s=\(Int(at.timeIntervalSince(st.since)))"), at: at)
                }
                auditErr = st
            } else {
                let st = ErrState(src: SourceID.memAudit.rawValue, mib: nil, token: e.logToken, since: at, lastLogged: at, n: 1)
                auditErr = st
                log.event("ERR", errBody(st, extra: ""), at: at)
            }
            return
        }
        if let st = auditErr {
            auditErr = nil
            log.event("RECOVER", "src=\(st.src) failed_s=\(String(format: "%.1f", at.timeIntervalSince(st.since))) n=\(st.n)", at: at)
        }
        guard let r = result else { return }
        func d(_ f: Field) -> String { r.diffPages[f].map(String.init) ?? "-" }
        let resid = audit.residualPages == MemoryFormulas.noResidual ? "-" : String(audit.residualPages)
        log.line("AUD", "fresh=\(r.fresh ? 1 : 0) same=\(r.sameAsPrev ? 1 : 0) age_ms=\(r.ageMs.map(String.init) ?? "-") "
                 + "d_used=\(d(.used)) d_cached=\(d(.cached)) d_app=\(d(.app)) d_wired=\(d(.wired)) d_comp=\(d(.compressed)) "
                 + "free_err=\(audit.lastFreeErr.map(String.init) ?? "-") mode=\(audit.mode.rawValue) "
                 + "resid=\(resid) win_med=\(audit.windowMedian.map(String.init) ?? "-")", at: at)
        if let s = audit.lastSwitch {
            log.event("WARN", "free_mode from=\(s.from.rawValue) to=\(s.to.rawValue) median=\(s.median.map(String.init) ?? "-") reason=\(s.reason)", at: at)
        }
    }
}
