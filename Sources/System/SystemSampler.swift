// SystemSampler.swift — sysQ, 1 Hz wall-clock-aligned CPU + network sampling, CPU / NET log, ERR / RECOVER / WARN
// (spec §5.1–§5.3, §9.1, §9.2).
//
// * sysQ: serial, QoS .utility. One one-shot DispatchSourceTimer re-armed for the next whole wall second (+0 ms,
//   MemorySampler.nextBoundary(period: 1), monotonic deadline, leeway 20 ms; a backward wall-clock step re-grids with
//   `WARN clock_step src=sys`). Runs regardless of the visible view (the history needs every second).
// * Every tick (SysEngine.tick): one Injector snapshot → SysInject; CPU ticks (cpu.load) → CPUDelta; processor-set
//   counts (cpu.tasks) → plausibility / proc_listallpids fallback; IFMIB (net.if) → NetFilter → NetDelta. Each source
//   yields Reading.value / .skipped(reason) / .failed(err). Injected `fail` goes through the same .failed path as a
//   real error (and clears that source's baseline, so the first good read after it is a clean baseline); injected
//   `garbage` replaces the reading and goes through the normal validation (CPUSource / NetSource headers).
//   The SysSample is delivered with DispatchQueue.main.async { onSample } (never after stop() returned).
// * Logs (all file-only): `CPU …` and `NET …` every tick at sample level; at summary level one line per kind per
//   `summarySeconds` (the sampler's own gate, same rule as MEM; `.skipped` lines are sample level only).
//   ERR (event) on failure onset and on a token change, ERR repeat (line) every 60 s while it persists, RECOVER (event)
//   when it clears — keys cpu.load / cpu.tasks / net.if. WARN (event) at most once per key per 60 s.
// * sampleNow(reason: "wake") resets both baselines first: the wake sample only re-establishes them.
// * SysFormat: AM-identical display strings for StateBuilder (percent 2 decimals half-up, integer grouping,
//   ByteCountFormatter .file, speed in bits via L10n.speed) and the CPUDisplay / NetDisplay mapping.
// Owner: sampler agent.
import Foundation

// MARK: - Injection + readers (test seams)

/// The injection state of the three SystemSampler sources for one tick (taken from ONE Injector snapshot).
struct SysInject: Equatable, Sendable {
    var failCPU = false, failTasks = false, failNet = false
    var garbageCPU = false, garbageTasks = false, garbageNet = false
    var any: Bool { failCPU || failTasks || failNet || garbageCPU || garbageTasks || garbageNet }
    /// Per-graph "simulated" (the series a graph plots is injected): CPU graph ← cpu.load, network graph ← net.if.
    /// cpu.tasks feeds no graph, so it marks neither (same per-series rule as MemSample.simulated / the pressure graph).
    var cpuSeries: Bool { failCPU || garbageCPU }
    var netSeries: Bool { failNet || garbageNet }

    init() {}
    /// Reads `fail` / `garbage` membership directly, so it works whatever Injector.mode(_:) whitelists.
    init(_ s: Injector.Snapshot) {
        failCPU = s.fail.contains(SourceID.cpuLoad.rawValue)
        failTasks = s.fail.contains(SourceID.cpuTasks.rawValue)
        failNet = s.fail.contains(SourceID.netIF.rawValue)
        garbageCPU = s.garbage.contains(.cpuLoad)
        garbageTasks = s.garbage.contains(.cpuTasks)
        garbageNet = s.garbage.contains(.netIF)
    }
}

/// Source reads used by SysEngine (live: CPUReader / NetReader / CLOCK_UPTIME_RAW; tests: synthetic data).
struct SysReaders {
    var cpuTicks: () -> Result<CPUTicks, SourceError>
    var tasks: () -> Result<(threads: Int, processes: Int), SourceError>
    var processCount: () -> Int?
    var net: () -> Result<[IfCounters], SourceError>
    var uptimeNs: () -> UInt64
    var clockHz: Int

    static func live(cpu: CPUReader, net: NetReader) -> SysReaders {
        SysReaders(cpuTicks: { cpu.ticks() }, tasks: { cpu.tasks() }, processCount: { CPUReader.processCount() },
                   net: { net.read() }, uptimeNs: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }, clockHz: cpu.clockHz)
    }
}

// MARK: - Engine (sysQ only; pure apart from the readers and the emit sink)

final class SysEngine {
    struct Line: Equatable { let kind: String; let body: String; let event: Bool }

    let level: LogLevel
    let summarySeconds: Double
    let emit: (Line, Date) -> Void
    private(set) var cpu = CPUDelta()
    private(set) var net = NetDelta()
    private(set) var seq: UInt64 = 0
    private var errs: [String: ErrState] = [:]
    private var warnLast: [String: (at: Date, n: Int)] = [:]
    private var lastCPULine: Date?
    private var lastNETLine: Date?

    private struct ErrState { let src: String; var token: String; let since: Date; var lastLogged: Date; var n: Int }

    init(level: LogLevel, summarySeconds: Double, emit: @escaping (Line, Date) -> Void) {
        self.level = level; self.summarySeconds = summarySeconds; self.emit = emit
    }

    /// Wake / explicit reset: the next read of each source only re-establishes its baseline.
    func resetBaselines() { cpu.reset(); net.reset() }

    func tick(_ r: SysReaders, inject: SysInject, simActive: Bool, tWall: Date) -> SysSample {
        let c0 = r.uptimeNs()
        var failures: [String: String] = [:]   // src → err token
        var warns: [(String, String)] = []

        // cpu.load
        let cpuR: Reading<CPUReading>
        if inject.failCPU {
            cpuR = .failed(err: SourceError.injected(SourceID.cpuLoad.rawValue).logToken); cpu.reset()
        } else {
            switch r.cpuTicks() {
            case .success(let t):
                let (res, w) = cpu.feed(t, ns: r.uptimeNs(), hz: r.clockHz, garbage: inject.garbageCPU)
                cpuR = res
                if let w { warns.append(w) }
            case .failure(let e):
                cpuR = .failed(err: e.logToken); cpu.reset()
            }
        }
        if case .failed(let e) = cpuR { failures[SourceID.cpuLoad.rawValue] = e }

        // cpu.tasks
        let tasksR: Reading<TaskCounts>
        if inject.failTasks {
            tasksR = .failed(err: SourceError.injected(SourceID.cpuTasks.rawValue).logToken)   // no fallback: "—" stays visible
        } else {
            var raw = r.tasks()
            if inject.garbageTasks { raw = .success((threads: 0, processes: 795)) }
            switch raw {
            case .success(let v):
                if CPUFormula.tasksPlausible(threads: v.threads, processes: v.processes) {
                    tasksR = .value(TaskCounts(threads: v.threads, processes: v.processes))
                } else {
                    tasksR = .failed(err: "implausible")
                    warns.append(("cpu_tasks_implausible", "cpu_tasks_implausible threads=\(v.threads) procs=\(v.processes)"))
                }
            case .failure(let e):
                if let p = r.processCount(), p > 0 {
                    tasksR = .value(TaskCounts(threads: nil, processes: p))
                    warns.append(("cpu_tasks_fallback", "cpu_tasks_fallback err=\(e.logToken) procs=\(p)"))
                } else {
                    tasksR = .failed(err: e.logToken)
                }
            }
        }
        if case .failed(let e) = tasksR { failures[SourceID.cpuTasks.rawValue] = e }

        // net.if
        let netR: Reading<NetReading>
        if inject.failNet {
            netR = .failed(err: SourceError.injected(SourceID.netIF.rawValue).logToken); net.reset()
        } else {
            switch r.net() {
            case .success(let all):
                let (res, ws) = net.feed(all.filter(NetFilter.included), ns: r.uptimeNs(), garbage: inject.garbageNet)
                netR = res
                warns += ws
            case .failure(let e):
                netR = .failed(err: e.logToken); net.reset()
            }
        }
        if case .failed(let e) = netR { failures[SourceID.netIF.rawValue] = e }

        let c1 = r.uptimeNs()
        seq += 1
        let s = SysSample(seq: seq, tWall: tWall, durUs: Int((c1 &- c0) / 1000), cpu: cpuR, tasks: tasksR, net: netR,
                          cpuSimulated: inject.cpuSeries, netSimulated: inject.netSeries)

        if wants(&lastCPULine, at: tWall, skipped: isSkipped(cpuR)) { emit(Line(kind: "CPU", body: SysEngine.cpuBody(s, simActive: simActive), event: false), tWall) }
        if wants(&lastNETLine, at: tWall, skipped: isSkipped(netR)) { emit(Line(kind: "NET", body: SysEngine.netBody(s, simActive: simActive), event: false), tWall) }
        trackErrors(failures, at: tWall)
        for (k, b) in warns { warn(k, b, at: tWall) }
        return s
    }

    private func isSkipped<T>(_ r: Reading<T>) -> Bool { if case .skipped = r { return true }; return false }

    /// Summary level: one line per kind per `summarySeconds` (by the line's own timestamp), skip lines dropped.
    private func wants(_ last: inout Date?, at: Date, skipped: Bool) -> Bool {
        guard level == .summary else { return true }
        if skipped || EventLog.throttled(at, last, summarySeconds) { return false }
        last = at
        return true
    }

    // MARK: log bodies

    private static func p2(_ v: Double) -> String { L10n.fmt2(v) }
    private static func rate(_ v: Double?) -> String { v.map { String(Int64(max(0, $0).rounded(.toNearestOrAwayFromZero))) } ?? "-" }

    /// `CPU seq= dur_us= sys=4.99 user=16.65 idle=78.36 nice=0.00 cores=12 threads=4783 procs=795 sim=0 fail=- skip=-`
    static func cpuBody(_ s: SysSample, simActive: Bool) -> String {
        var b = "seq=\(s.seq) dur_us=\(s.durUs)"
        if case .value(let c) = s.cpu {
            b += " sys=\(p2(c.system)) user=\(p2(c.user)) idle=\(p2(c.idle)) nice=\(p2(c.nice)) cores=\(c.cores)"
        } else {
            b += " sys=- user=- idle=- nice=- cores=-"
        }
        if case .value(let t) = s.tasks { b += " threads=\(t.threads.map(String.init) ?? "-") procs=\(t.processes)" } else { b += " threads=- procs=-" }
        b += " sim=\(simActive ? 1 : 0)"
        var fail: [String] = []
        if s.cpu.isFailed { fail.append(SourceID.cpuLoad.rawValue) }
        if s.tasks.isFailed { fail.append(SourceID.cpuTasks.rawValue) }
        b += " fail=" + (fail.isEmpty ? "-" : fail.joined(separator: ","))
        if case .skipped(let why) = s.cpu { b += " skip=\(why)" } else { b += " skip=-" }
        return b
    }

    /// `NET seq= dur_us= ifaces=14 pkt_in= pkt_out= pkt_in_s=612 pkt_out_s=148 rx= tx= rx_bps=739000 tx_bps=19574 sim=0 fail=- skip=-`
    /// (rx_bps / tx_bps are BYTES per second, rounded; unknown rates `-`).
    static func netBody(_ s: SysSample, simActive: Bool) -> String {
        var b = "seq=\(s.seq) dur_us=\(s.durUs)"
        if case .value(let n) = s.net {
            b += " ifaces=\(n.ifaces) pkt_in=\(n.pktIn) pkt_out=\(n.pktOut) pkt_in_s=\(rate(n.pktInRate)) pkt_out_s=\(rate(n.pktOutRate))"
            b += " rx=\(n.bytesIn) tx=\(n.bytesOut) rx_bps=\(rate(n.rxRate)) tx_bps=\(rate(n.txRate))"
        } else {
            b += " ifaces=- pkt_in=- pkt_out=- pkt_in_s=- pkt_out_s=- rx=- tx=- rx_bps=- tx_bps=-"
        }
        b += " sim=\(simActive ? 1 : 0) fail=" + (s.net.isFailed ? SourceID.netIF.rawValue : "-")
        if case .skipped(let why) = s.net { b += " skip=\(why)" } else { b += " skip=-" }
        return b
    }

    // MARK: ERR / RECOVER / WARN (same rules as MemorySampler)

    private func trackErrors(_ current: [String: String], at: Date) {
        for (src, token) in current.sorted(by: { $0.key < $1.key }) {
            if var st = errs[src] {
                st.n += 1
                if st.token != token {
                    st.token = token; st.lastLogged = at
                    emit(Line(kind: "ERR", body: "src=\(src) err=\(token)", event: true), at)
                } else if at.timeIntervalSince(st.lastLogged) >= 60 {
                    st.lastLogged = at
                    emit(Line(kind: "ERR", body: "src=\(src) err=\(token) repeat=1 n=\(st.n) for_s=\(Int(at.timeIntervalSince(st.since)))", event: false), at)
                }
                errs[src] = st
            } else {
                errs[src] = ErrState(src: src, token: token, since: at, lastLogged: at, n: 1)
                emit(Line(kind: "ERR", body: "src=\(src) err=\(token)", event: true), at)
            }
        }
        for (src, st) in errs.sorted(by: { $0.key < $1.key }) where current[src] == nil {
            errs[src] = nil
            emit(Line(kind: "RECOVER", body: "src=\(src) failed_s=\(String(format: "%.1f", at.timeIntervalSince(st.since))) n=\(st.n)", event: true), at)
        }
    }

    private func warn(_ key: String, _ body: String, at: Date) {
        if let l = warnLast[key], EventLog.throttled(at, l.at, 60.05) { warnLast[key] = (l.at, l.n + 1); return }
        let suppressed = warnLast[key]?.n ?? 0
        warnLast[key] = (at, 0)
        emit(Line(kind: "WARN", body: body + (suppressed > 0 ? " suppressed=\(suppressed)" : ""), event: true), at)
    }
}

// MARK: - SystemSampler (timer + delivery)

final class SystemSampler: @unchecked Sendable {
    let injector: Injector
    let log: EventLog
    let onSample: @Sendable (SysSample) -> Void

    let sysQ = DispatchQueue(label: "wokyis.sys", qos: .utility)
    // --- sysQ-only state ---
    private let cpuReader: CPUReader     // holds the cached pset port (released in its deinit)
    private let netReader: NetReader
    private let readers: SysReaders
    private let engine: SysEngine
    private var timer: DispatchSourceTimer?
    private var running = false
    private var lastBoundary: Double = 0
    private var durs: [Int] = []
    // --- delivery gate (any thread) ---
    private let gate = NSLock()
    private var delivering = false

    /// `onSample` is called on MAIN, never after stop() returned.
    init(injector: Injector, log: EventLog, onSample: @escaping @Sendable (SysSample) -> Void) {
        self.injector = injector; self.log = log; self.onSample = onSample
        let c = CPUReader(), n = NetReader()
        cpuReader = c; netReader = n
        readers = SysReaders.live(cpu: c, net: n)
        engine = SysEngine(level: log.level, summarySeconds: log.summarySeconds) { [log] l, at in
            if l.event { log.event(l.kind, l.body, at: at) } else { log.line(l.kind, l.body, at: at) }
        }
    }

    /// Starts the 1 Hz timer (idempotent). The first sample is taken at the next whole wall second.
    func start() {
        gate.lock(); delivering = true; gate.unlock()
        sysQ.sync {
            guard !running else { return }
            running = true
            let t = DispatchSource.makeTimerSource(flags: [], queue: sysQ)
            t.setEventHandler { [weak self] in self?.fire() }
            timer = t
            lastBoundary = 0
            arm()
            t.resume()
        }
    }

    /// Stops the timer; after return no further onSample calls are made. Must not be called on sysQ.
    func stop() {
        gate.lock(); delivering = false; gate.unlock()
        sysQ.sync {
            running = false
            timer?.cancel(); timer = nil
        }
    }

    /// One extra sample as soon as possible (`reason` = "wake" resets both baselines). Does not change the tick grid.
    func sampleNow(reason: String) {
        sysQ.async { [weak self] in
            guard let self, self.running else { return }
            if reason == "wake" { self.engine.resetBaselines() }
            self.tick(boundary: nil)
        }
    }

    /// (samples taken, p99 tick duration in µs over the last 240 ticks). Thread-safe.
    func stats() -> (samples: UInt64, durP99Us: Int?) {
        sysQ.sync {
            let s = durs.sorted()
            let p99 = s.isEmpty ? nil : s[min(s.count - 1, Int((Double(s.count) * 0.99).rounded(.up)) - 1)]
            return (engine.seq, p99)
        }
    }

    // MARK: timer (sysQ)

    private func arm() {
        let now = Date().timeIntervalSince1970
        let (next, stepped) = MemorySampler.nextBoundary(now: now, lastBoundary: lastBoundary, period: 1)
        if stepped { log.event("WARN", "clock_step src=sys dir=back by_s=\(String(format: "%.3f", lastBoundary - now)) regrid=1") }
        lastBoundary = next
        timer?.schedule(deadline: .now() + .nanoseconds(Int((max(0, next - now) * 1e9).rounded())), repeating: .never,
                        leeway: .milliseconds(20))
    }

    private func fire() {
        guard running else { return }
        tick(boundary: lastBoundary)
        if running { arm() }
    }

    private func tick(boundary: Double?) {
        var tWall = Date()
        // A timer that fires a hair before its whole-second boundary still belongs to that second (history t = floor).
        if let b = boundary, tWall.timeIntervalSince1970 < b, b - tWall.timeIntervalSince1970 < 0.05 { tWall = Date(timeIntervalSince1970: b) }
        let snap = injector.snapshot(now: tWall)
        let s = engine.tick(readers, inject: SysInject(snap), simActive: !snap.isEmpty, tWall: tWall)
        durs.append(s.durUs)
        if durs.count > 240 { durs.removeFirst(durs.count - 240) }
        let deliver = onSample
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.gate.lock(); let ok = self.delivering; self.gate.unlock()
            if ok { deliver(s) }
        }
    }
}

// MARK: - Display formatting (AM Activity Monitor footer; spec §4, §5.2–§5.3)

enum SysFormat {
    /// AM paddedPercent: 2 decimals, half-up ("4.99%", 99.995 → "100.00%").
    static func percent(_ v: Double) -> String { L10n.fmt2(v) + "%" }
    /// AM integerFormatter ("4,783").
    static func count(_ n: UInt64) -> String { L10n.int(Double(n)) }
    /// packets/s: rounded half away from zero first, then grouped ("611.5" → "612").
    static func perSecond(_ v: Double) -> String { L10n.int(max(0, v).rounded(.toNearestOrAwayFromZero)) }
    /// AM speed: bytes/s × 8 in bits, decimal units, 2 decimals, "/s" or "/秒"; 999.995 promotes to "1.00" of the next unit.
    static func speed(_ bytesPerSecond: Double, _ lang: Lang) -> String { L10n.speed(bytesPerSecond: bytesPerSecond, lang) }

    /// AM fileSizeFormatter (Data received / sent): ByteCountFormatter .file (decimal: KB 0 / MB 1 / GB+ 2 decimals,
    /// zero padded, "999 bytes"); follows the system region like AM and the memory view (spec §4).
    static func file(_ bytes: UInt64) -> String {
        fileLock.lock(); defer { fileLock.unlock() }
        return fileFormatter.string(fromByteCount: Int64(clamping: bytes))
    }
    private static let fileLock = NSLock()
    private static let fileFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file; f.allowedUnits = .useAll; f.zeroPadsFractionDigits = true
        f.allowsNonnumericFormatting = false; f.formattingContext = .listItem
        return f
    }()

    /// CPU footer strings; nil reading → "—" for those cells (threads nil = pset fallback → "—").
    static func cpu(_ c: CPUReading?, tasks: TaskCounts?) -> CPUDisplay {
        func s(_ v: String?) -> Shown { v.map(Shown.text) ?? .failed }
        return CPUDisplay(system: s(c.map { percent($0.system) }), user: s(c.map { percent($0.user) }), idle: s(c.map { percent($0.idle) }),
                          threads: s(tasks?.threads.map { count(UInt64(max(0, $0))) }),
                          processes: s(tasks.map { count(UInt64(max(0, $0.processes))) }))
    }

    /// Network footer strings; nil reading → all "—"; nil rates (baseline just set) → "—" for the four rate cells.
    static func net(_ n: NetReading?, _ lang: Lang) -> NetDisplay {
        func s(_ v: String?) -> Shown { v.map(Shown.text) ?? .failed }
        return NetDisplay(download: s(n?.rxRate.map { speed($0, lang) }), upload: s(n?.txRate.map { speed($0, lang) }),
                          packetsIn: s(n.map { count($0.pktIn) }), packetsOut: s(n.map { count($0.pktOut) }),
                          packetsInRate: s(n?.pktInRate.map(perSecond)), packetsOutRate: s(n?.pktOutRate.map(perSecond)),
                          received: s(n.map { file($0.bytesIn) }), sent: s(n.map { file($0.bytesOut) }))
    }
}

// MARK: - Self test (`--selftest`; pure: synthetic ticks / counters / clock, plus one live read of each source)

enum SystemSelfTest {
    static func run() -> [SelfTestCase] {
        cpuFormula() + cpuGuards() + tasksPlausible() + netFilter() + netRates() + engineInjection() + logFormat()
            + formatCases() + setHz() + liveRead()
    }

    private static func close(_ a: Double?, _ b: Double, _ eps: Double = 1e-9) -> Bool { a.map { abs($0 - b) <= eps } ?? false }
    private static func reason<T>(_ r: Reading<T>) -> String? { if case .skipped(let w) = r { return w }; return nil }
    private static func err<T>(_ r: Reading<T>) -> String? { if case .failed(let e) = r { return e }; return nil }
    private static let sec: UInt64 = 1_000_000_000

    // MARK: cpu.formula — per-core mean (not tick weighted), tot==0 cores excluded, n==0 → skipped, u32 wrap, nice
    static func cpuFormula() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        // core0: user 50 / idle 50 (tot 100); core1: user 10 (tot 10); core2: no ticks
        let old = CPUTicks(rows: [[1000, 500, 8000, 0], [2000, 100, 9000, 0], [7, 7, 7, 7]])
        let new = CPUTicks(rows: [[1050, 500, 8050, 0], [2010, 100, 9000, 0], [7, 7, 7, 7]])
        let r = CPUFormula.average(old: old, new: new)
        let weightedUser = 100.0 * 60 / 110
        out.append(SelfTestCase("cpu.formula.mean_not_weighted",
                                close(r?.user, 75) && close(r?.idle, 25) && close(r?.system, 0) && abs(75 - weightedUser) > 20 && r?.cores == 3,
                                "user=\(r?.user ?? -1) weighted=\(weightedUser)"))
        // nice separate, the four states sum to 100
        let rn = CPUFormula.average(old: CPUTicks(rows: [[0, 0, 0, 0]]), new: CPUTicks(rows: [[20, 10, 60, 10]]))
        out.append(SelfTestCase("cpu.formula.nice", close(rn?.nice, 10) && close(rn?.user, 20) && close(rn?.system, 10)
                                && close((rn?.system ?? 0) + (rn?.user ?? 0) + (rn?.idle ?? 0) + (rn?.nice ?? 0), 100)))
        // u32 wrap: user went UInt32.max − 4 → 5 (Δ 10), idle Δ 90
        let rw = CPUFormula.average(old: CPUTicks(rows: [[UInt32.max - 4, 0, 100, 0]]), new: CPUTicks(rows: [[5, 0, 190, 0]]))
        out.append(SelfTestCase("cpu.formula.u32_wrap", close(rw?.user, 10) && close(rw?.idle, 90), "user=\(rw?.user ?? -1)"))
        // n == 0 → nil → .skipped(no_ticks), never NaN
        let same = CPUTicks(rows: [[1, 2, 3, 4], [5, 6, 7, 8]])
        var d = CPUDelta()
        _ = d.feed(same, ns: 10 * sec, hz: 100)
        let (z, _) = d.feed(same, ns: 11 * sec, hz: 100)
        out.append(SelfTestCase("cpu.formula.no_ticks", CPUFormula.average(old: same, new: same) == nil && reason(z) == "no_ticks"))
        return out
    }

    // MARK: cpu.guards — baseline, dt < 0.5 s, cores changed, gap, garbage (N+1), hz limit
    static func cpuGuards() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        func busy(_ base: CPUTicks, _ perCore: UInt32, user: UInt32 = 30) -> CPUTicks {   // every core advances perCore ticks
            var t = base.ticks
            for c in 0..<base.cores { t[c * 4 + CPUTicks.user] &+= user; t[c * 4 + CPUTicks.idle] &+= perCore - user }
            return CPUTicks(ticks: t)
        }
        var d = CPUDelta()
        let t0 = CPUTicks(rows: [[100, 100, 100, 0], [100, 100, 100, 0]])
        let (r0, w0) = d.feed(t0, ns: 100 * sec, hz: 100)
        let t1 = busy(t0, 30)
        let (r1, _) = d.feed(t1, ns: 100 * sec + 300_000_000, hz: 100)
        let baseKept = d.base?.ns == 100 * sec && d.base?.ticks == t0
        let t2 = busy(t0, 100)
        let (r2, _) = d.feed(t2, ns: 101 * sec, hz: 100)
        out.append(SelfTestCase("cpu.guards.baseline_dt_short",
                                reason(r0) == "baseline" && w0 == nil && reason(r1) == "dt_short" && baseKept && close(r2.value?.user, 30),
                                "r1=\(reason(r1) ?? "-") kept=\(baseKept) user=\(r2.value?.user ?? -1)"))
        // core count change → reset to the new reading + WARN; next sample reports
        let t3 = CPUTicks(rows: [[1, 1, 1, 0], [1, 1, 1, 0], [1, 1, 1, 0]])
        let (r3, w3) = d.feed(t3, ns: 102 * sec, hz: 100)
        let (r4, _) = d.feed(busy(t3, 100), ns: 103 * sec, hz: 100)
        out.append(SelfTestCase("cpu.guards.cores_changed", reason(r3) == "cores_changed" && w3?.1 == "cpu_cores_changed from=2 to=3"
                                && r4.value?.cores == 3, w3?.1 ?? "-"))
        // dt > 5 s → reset (baseline = this reading) + WARN reason=gap
        let t5 = busy(t3, 700)
        let (r5, w5) = d.feed(t5, ns: 110 * sec, hz: 100)
        let (r6, _) = d.feed(busy(t5, 100), ns: 111 * sec, hz: 100)
        out.append(SelfTestCase("cpu.guards.gap", reason(r5) == "gap" && (w5?.1.hasPrefix("cpu_delta_reset reason=gap") ?? false)
                                && d.base != nil && r6.value != nil, w5?.1 ?? "-"))
        // hz limit: Σd 140 in 1 s passes, 160 is garbage (1.5 × 100 × 1)
        var h = CPUDelta()
        let a0 = CPUTicks(rows: [[0, 0, 0, 0]])
        _ = h.feed(a0, ns: 10 * sec, hz: 100)
        let (ok140, _) = h.feed(busy(a0, 140), ns: 11 * sec, hz: 100)
        let (bad160, wb) = h.feed(busy(busy(a0, 140), 160), ns: 12 * sec, hz: 100)
        out.append(SelfTestCase("cpu.guards.hz_limit", ok140.value != nil && reason(bad160) == "garbage" && h.base == nil
                                && (wb?.1.contains("reason=garbage") ?? false), wb?.1 ?? "-"))
        // real backwards counters (u32 wrap → huge Σd) → garbage, baseline cleared, next real read = baseline, then value
        var g = CPUDelta()
        let g0 = CPUTicks(rows: [[5000, 5000, 5000, 0]])
        _ = g.feed(g0, ns: 20 * sec, hz: 100)
        let (gb, _) = g.feed(g0.steppedBack(10), ns: 21 * sec, hz: 100)
        let (gr, _) = g.feed(busy(g0, 200), ns: 22 * sec, hz: 100)
        let (gv, _) = g.feed(busy(busy(g0, 200), 100), ns: 23 * sec, hz: 100)
        out.append(SelfTestCase("cpu.guards.backwards", reason(gb) == "garbage" && reason(gr) == "baseline" && gv.value != nil))
        // injected garbage for N = 2 consecutive ticks → exactly N + 1 = 3 samples dropped, then values again
        var j = CPUDelta()
        var tt = CPUTicks(rows: [[100, 100, 100, 0], [100, 100, 100, 0]])
        var ns = 30 * sec
        _ = j.feed(tt, ns: ns, hz: 100)
        var seq: [String] = []
        for k in 0..<6 {
            tt = busy(tt, 100); ns += sec
            let (r, _) = j.feed(tt, ns: ns, hz: 100, garbage: k == 1 || k == 2)
            seq.append(r.value != nil ? "v" : (reason(r) ?? "?"))
        }
        out.append(SelfTestCase("cpu.guards.garbage_n_plus_1", seq == ["v", "garbage", "garbage", "baseline", "v", "v"], seq.joined(separator: ",")))
        // wake / reset → next read is a baseline only
        j.reset()
        tt = busy(tt, 100); ns += sec
        let (rw, _) = j.feed(tt, ns: ns, hz: 100)
        out.append(SelfTestCase("cpu.guards.reset", reason(rw) == "baseline"))
        return out
    }

    // MARK: cpu.tasks_plausible
    static func tasksPlausible() -> [SelfTestCase] {
        let bad: [(Int, Int)] = [(0, 795), (500, 795), (100, 0), (20_000_000, 795), (4783, -1), (10_000_001, 10_000_001)]
        let good: [(Int, Int)] = [(4783, 795), (795, 795), (10_000_000, 1)]
        let badOK = bad.allSatisfy { !CPUFormula.tasksPlausible(threads: $0.0, processes: $0.1) }
        let goodOK = good.allSatisfy { CPUFormula.tasksPlausible(threads: $0.0, processes: $0.1) }
        return [SelfTestCase("cpu.tasks_plausible", badOK && goodOK)]
    }

    // MARK: net.filter — AM truth table
    static func netFilter() -> [SelfTestCase] {
        let up = UInt32(IFF_UP), lo = UInt32(IFF_LOOPBACK), p2p = UInt32(IFF_POINTOPOINT)
        let table: [(String, UInt32, UInt8, Bool)] = [
            ("lo0", up | lo | UInt32(IFF_MULTICAST), 0x18, false),
            ("utun0", up | p2p, 0x35, false),            // VPN tunnel (P2P, not cellular)
            ("gif0", p2p | UInt32(IFF_MULTICAST), 0x37, false),
            ("pdp_ip0", up | p2p, 0xff, true),           // cellular P2P is counted
            ("anpi0", up | UInt32(IFF_BROADCAST), 0x06, false),
            ("anpi3", 0, 0x06, false),
            ("bridge0", up | UInt32(IFF_BROADCAST), 0xd1, true),
            ("en0", up | UInt32(IFF_BROADCAST), 0x06, true),
            ("en5", 0, 0x06, true),                      // down: no IFF_UP check
            ("awdl0", up, 0x06, true),
            ("stf0", 0, 0x39, true),
        ]
        var bad: [String] = []
        for (n, f, t, want) in table where NetFilter.included(name: n, flags: f, type: t) != want { bad.append(n) }
        return [SelfTestCase("net.filter", bad.isEmpty, bad.joined(separator: ","))]
    }

    // MARK: net.rates — per-interface deltas, decreases, appear / disappear, first / gap / dt_short, garbage, 64-bit
    static func netRates() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        func ifc(_ i: Int32, _ n: String, _ ip: UInt64, _ op: UInt64, _ ib: UInt64, _ ob: UInt64) -> IfCounters {
            IfCounters(index: i, name: n, flags: UInt32(IFF_UP), type: 6, ipackets: ip, opackets: op, ibytes: ib, obytes: ob)
        }
        var d = NetDelta()
        let big: UInt64 = 22_758_680_252   // > 2³²
        let a = [ifc(4, "en0", 1000, 500, big, 93_632_064_060), ifc(9, "en1", 10, 10, 1000, 1000)]
        let (r0, _) = d.feed(a, ns: 50 * sec)
        let v0 = r0.value
        out.append(SelfTestCase("net.rates.first", v0 != nil && v0?.rxRate == nil && v0?.pktInRate == nil && v0?.bytesIn == big + 1000
                                && v0?.bytesOut == 93_632_064_060 + 1000 && v0?.ifaces == 2))
        let b = [ifc(4, "en0", 1010, 505, big + 1000, 93_632_064_060 + 500), ifc(9, "en1", 12, 10, 1100, 1000)]
        let (r1, w1) = d.feed(b, ns: 51 * sec)
        let v1 = r1.value
        out.append(SelfTestCase("net.rates.per_interface", close(v1?.rxRate, 1100) && close(v1?.txRate, 500) && close(v1?.pktInRate, 12)
                                && close(v1?.pktOutRate, 5) && w1.isEmpty, "rx=\(v1?.rxRate ?? -1)"))
        // dt < 0.5 s → skipped, baseline unchanged; the next normal read is measured from the kept baseline
        let c = [ifc(4, "en0", 1020, 505, big + 1500, 93_632_064_060 + 500), ifc(9, "en1", 12, 10, 1100, 1000)]
        let (rs, _) = d.feed(c, ns: 51 * sec + 200_000_000)
        let (r2, _) = d.feed(c, ns: 52 * sec)
        out.append(SelfTestCase("net.rates.dt_short", reason(rs) == "dt_short" && close(r2.value?.rxRate, 500) && close(r2.value?.pktInRate, 10)))
        // dt scaling (0.5 s exactly is valid)
        let c2 = [ifc(4, "en0", 1020, 505, big + 2500, 93_632_064_060 + 500), ifc(9, "en1", 12, 10, 1100, 1000)]
        let (r3, _) = d.feed(c2, ns: 52 * sec + 500_000_000)
        out.append(SelfTestCase("net.rates.dt_scale", close(r3.value?.rxRate, 2000)))
        // counter decrease on en0 ibytes → 0 for that counter + WARN; en1 still counted
        let e = [ifc(4, "en0", 1030, 505, 10, 93_632_064_060 + 500), ifc(9, "en1", 12, 10, 1300, 1000)]
        let (r4, w4) = d.feed(e, ns: 53 * sec + 500_000_000)
        out.append(SelfTestCase("net.rates.decrease", close(r4.value?.rxRate, 200) && close(r4.value?.pktInRate, 10)
                                && w4.count == 1 && w4.first?.0 == "net_counter_reset:en0:ibytes"
                                && (w4.first?.1.hasPrefix("net_counter_reset if=en0 field=ibytes") ?? false), w4.map(\.1).joined(separator: "|")))
        // appear (huge counters, no spike), disappear (no negative), same name on a new index = new interface
        let f = [ifc(4, "en0", 1030, 505, 110, 93_632_064_060 + 500), ifc(9, "en1", 12, 10, 1300, 1000),
                 ifc(30, "utunX", 1, 1, 9_000_000_000_000, 9_000_000_000_000)]
        let (r5, _) = d.feed(f, ns: 54 * sec + 500_000_000)
        let g = [ifc(4, "en0", 1030, 505, 210, 93_632_064_060 + 500), ifc(31, "utunX", 1, 1, 1, 1)]
        let (r6, w6) = d.feed(g, ns: 55 * sec + 500_000_000)
        out.append(SelfTestCase("net.rates.appear_disappear", close(r5.value?.rxRate, 100) && r5.value?.ifaces == 3
                                && close(r6.value?.rxRate, 100) && close(r6.value?.txRate, 0) && w6.isEmpty && r6.value?.ifaces == 2,
                                "r5=\(r5.value?.rxRate ?? -1) r6=\(r6.value?.rxRate ?? -1)"))
        // dt > 5 s → baseline only (rates nil, totals present); then normal again
        let h = [ifc(4, "en0", 1040, 505, 1210, 93_632_064_060 + 500)]
        let (r7, _) = d.feed(h, ns: 62 * sec)
        let h2 = [ifc(4, "en0", 1040, 505, 1310, 93_632_064_060 + 600)]
        let (r8, _) = d.feed(h2, ns: 63 * sec)
        out.append(SelfTestCase("net.rates.gap", r7.value != nil && r7.value?.rxRate == nil && r7.value?.bytesIn == 1210 && close(r8.value?.rxRate, 100)))
        // injected garbage: ibytes = baseline − 1 → download 0 + WARN; the next sample is a normal delta from the REAL reading
        let k1 = [ifc(4, "en0", 1050, 505, 2310, 93_632_064_060 + 700)]
        let (rg, wg) = d.feed(k1, ns: 64 * sec, garbage: true)
        let k2 = [ifc(4, "en0", 1060, 505, 2410, 93_632_064_060 + 800)]
        let (rn, _) = d.feed(k2, ns: 65 * sec)
        out.append(SelfTestCase("net.rates.garbage", close(rg.value?.rxRate, 0) && close(rg.value?.txRate, 100) && wg.count == 1
                                && close(rn.value?.rxRate, 100), "rx=\(rg.value?.rxRate ?? -1) next=\(rn.value?.rxRate ?? -1)"))
        // reset (wake) → baseline only
        d.reset()
        let (rr, _) = d.feed(k2, ns: 66 * sec)
        out.append(SelfTestCase("net.rates.reset", rr.value != nil && rr.value?.rxRate == nil))
        return out
    }

    // MARK: engine — injection paths, fallback, ERR / RECOVER / WARN
    final class Fake {
        var ns: UInt64 = 1000 * 1_000_000_000
        var ticks = CPUTicks(rows: [[1000, 1000, 1000, 0], [1000, 1000, 1000, 0]])
        var cpuErr: SourceError?
        var tasks: Result<(threads: Int, processes: Int), SourceError> = .success((threads: 4783, processes: 795))
        var procs: Int? = 800
        var ifs: [IfCounters] = [IfCounters(index: 4, name: "en0", flags: UInt32(IFF_UP), type: 6, ipackets: 10, opackets: 10, ibytes: 10_000, obytes: 5000),
                                 IfCounters(index: 1, name: "lo0", flags: UInt32(IFF_LOOPBACK | IFF_UP), type: 0x18, ipackets: 9, opackets: 9, ibytes: 9, obytes: 9)]
        var netErr: SourceError?
        var t = Date(timeIntervalSince1970: 1_790_000_000)
        var lines: [(SysEngine.Line, Date)] = []
        lazy var engine = SysEngine(level: .sample, summarySeconds: 10) { [unowned self] l, at in self.lines.append((l, at)) }
        var readers: SysReaders {
            SysReaders(cpuTicks: { [unowned self] in self.cpuErr.map { .failure($0) } ?? .success(self.ticks) },
                       tasks: { [unowned self] in self.tasks }, processCount: { [unowned self] in self.procs },
                       net: { [unowned self] in self.netErr.map { .failure($0) } ?? .success(self.ifs) },
                       uptimeNs: { [unowned self] in self.ns }, clockHz: 100)
        }
        /// Advance 1 s: every core 100 ticks (20 user / 10 system / 70 idle), en0 +1000 B in / +500 B out.
        @discardableResult
        func step(_ inject: SysInject = SysInject()) -> SysSample {
            ns += 1_000_000_000; t = t.addingTimeInterval(1)
            var x = ticks.ticks
            for c in 0..<ticks.cores { x[c * 4] &+= 20; x[c * 4 + 1] &+= 10; x[c * 4 + 2] &+= 70 }
            ticks = CPUTicks(ticks: x)
            ifs[0].ibytes += 1000; ifs[0].obytes += 500; ifs[0].ipackets += 3; ifs[0].opackets += 2
            return engine.tick(readers, inject: inject, simActive: inject.any, tWall: t)
        }
        func kinds(_ k: String) -> [String] { lines.filter { $0.0.kind == k }.map(\.0.body) }
    }

    static func engineInjection() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        // normal: baseline, then values; loopback filtered
        let f = Fake()
        let s0 = f.step(), s1 = f.step()
        out.append(SelfTestCase("sys.engine.normal", reason(s0.cpu) == "baseline" && s0.net.value?.rxRate == nil
                                && close(s1.cpu.value?.user, 20) && close(s1.cpu.value?.system, 10) && close(s1.cpu.value?.idle, 70)
                                && s1.tasks.value == TaskCounts(threads: 4783, processes: 795)
                                && close(s1.net.value?.rxRate, 1000) && close(s1.net.value?.txRate, 500) && s1.net.value?.ifaces == 1
                                && s1.net.value?.bytesIn == 12_000 && !s1.cpuSimulated && !s1.netSimulated && s1.seq == 2))
        // fail cpu.load (injected): .failed, ERR onset (event), sim; persists → no new event; cleared → RECOVER,
        // the first good read is a baseline (no gap WARN), then values
        var inj = SysInject(); inj.failCPU = true
        let sf = f.step(inj)
        f.step(inj)
        let errs = f.lines.filter { $0.0.kind == "ERR" }
        let sb = f.step(), sv = f.step()
        let rec = f.kinds("RECOVER")
        out.append(SelfTestCase("sys.inject.fail_cpu", err(sf.cpu) == "injected" && sf.cpuSimulated && !sf.netSimulated && sf.tasks.value != nil
                                && errs.count == 1 && errs[0].0.event && errs[0].0.body == "src=cpu.load err=injected"
                                && rec.count == 1 && (rec.first?.hasPrefix("src=cpu.load failed_s=2.0 n=2") ?? false)
                                && reason(sb.cpu) == "baseline" && sv.cpu.value != nil && f.kinds("WARN").isEmpty,
                                (errs.map(\.0.body) + rec).joined(separator: "|")))
        // fail cpu.tasks (injected): "—" even though the proc_listallpids fallback would work
        var it = SysInject(); it.failTasks = true
        let st = f.step(it)
        out.append(SelfTestCase("sys.inject.fail_tasks", err(st.tasks) == "injected" && st.cpu.value != nil
                                && f.kinds("ERR").last == "src=cpu.tasks err=injected"))
        f.step()
        // garbage cpu.tasks → threads 0 / procs 795 → implausible, WARN once per 60 s
        var ig = SysInject(); ig.garbageTasks = true
        let sg = f.step(ig); f.step(ig)
        let wt = f.kinds("WARN").filter { $0.hasPrefix("cpu_tasks_implausible") }
        out.append(SelfTestCase("sys.inject.garbage_tasks", err(sg.tasks) == "implausible" && !sg.cpuSimulated && !sg.netSimulated
                                && wt == ["cpu_tasks_implausible threads=0 procs=795"] && f.kinds("ERR").last == "src=cpu.tasks err=implausible", wt.joined(separator: "|")))
        f.step()
        // garbage cpu.load for 2 ticks → N + 1 = 3 dropped samples, WARN cpu_delta_reset reason=garbage
        var ic = SysInject(); ic.garbageCPU = true
        let gseq = [f.step(ic), f.step(ic), f.step(), f.step()].map { $0.cpu.value != nil ? "v" : (reason($0.cpu) ?? "?") }
        out.append(SelfTestCase("sys.inject.garbage_cpu", gseq == ["garbage", "garbage", "baseline", "v"]
                                && f.kinds("WARN").contains { $0.hasPrefix("cpu_delta_reset reason=garbage") }, gseq.joined(separator: ",")))
        // garbage net.if → download 0 + WARN net_counter_reset; next normal
        var inn = SysInject(); inn.garbageNet = true
        let gn = f.step(inn), nn = f.step()
        out.append(SelfTestCase("sys.inject.garbage_net", close(gn.net.value?.rxRate, 0) && close(gn.net.value?.txRate, 500)
                                && f.kinds("WARN").contains { $0.hasPrefix("net_counter_reset if=en0 field=ibytes") } && close(nn.net.value?.rxRate, 1000)))
        // fail net.if (injected) → .failed, ERR; recovery → totals with nil rates, then rates
        var ifl = SysInject(); ifl.failNet = true
        let fn = f.step(ifl), n1 = f.step(), n2 = f.step()
        out.append(SelfTestCase("sys.inject.fail_net", err(fn.net) == "injected" && f.kinds("ERR").contains("src=net.if err=injected")
                                && fn.netSimulated && !fn.cpuSimulated && fn.cpu.value != nil && gn.netSimulated && !gn.cpuSimulated
                                && n1.net.value != nil && n1.net.value?.rxRate == nil && close(n2.net.value?.rxRate, 1000)
                                && f.kinds("RECOVER").contains { $0.hasPrefix("src=net.if") }))
        // real errors: pset kr=5 → proc_listallpids fallback (threads nil) + WARN; no fallback → .failed(kr=5);
        // host_processor_info kr → .failed; ifcount errno → .failed
        f.tasks = .failure(.kern(5))
        let fb = f.step()
        f.procs = nil
        let fx = f.step()
        f.tasks = .success((threads: 4783, processes: 795)); f.procs = 800
        f.cpuErr = .kern(3); f.netErr = .errno(1, "ifcount")
        let fe = f.step()
        f.cpuErr = nil; f.netErr = nil
        out.append(SelfTestCase("sys.real_errors", fb.tasks.value == TaskCounts(threads: nil, processes: 800)
                                && f.kinds("WARN").contains("cpu_tasks_fallback err=kr=5 procs=800") && err(fx.tasks) == "kr=5"
                                && err(fe.cpu) == "kr=3" && err(fe.net) == "errno=1" && !fe.cpuSimulated && !fe.netSimulated
                                && f.kinds("ERR").contains("src=cpu.load err=kr=3") && f.kinds("ERR").contains("src=net.if err=errno=1")))
        // ERR repeat: a failure persisting 60 s writes one repeat line (file-only)
        let r = Fake()
        r.step(); r.netErr = .errno(5, "ifdata.3")
        for _ in 0..<61 { r.step() }
        let rep = r.lines.filter { $0.0.kind == "ERR" }
        out.append(SelfTestCase("sys.err_repeat", rep.count == 2 && rep[0].0.event && !rep[1].0.event
                                && rep[1].0.body == "src=net.if err=errno=5 repeat=1 n=61 for_s=60", rep.map(\.0.body).joined(separator: "|")))
        // Injector snapshot → SysInject (fail via the real parser; garbage read straight from the snapshot set)
        let ij = Injector(runDir: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wokyis-selftest-unused"), log: nil)
        let exp = EventLog.timestamp(Date().addingTimeInterval(300))
        _ = ij.apply(Data("{\"version\":1,\"expires\":\"\(exp)\",\"fail\":[\"cpu.load\",\"net.if\"]}".utf8), now: Date())
        let si = SysInject(ij.snapshot())
        var snap = Injector.Snapshot(); snap.garbage = [.cpuLoad, .cpuTasks, .netIF]
        let sg2 = SysInject(snap)
        out.append(SelfTestCase("sys.inject.snapshot", si.failCPU && si.failNet && !si.failTasks && !si.garbageCPU && si.any
                                && sg2.garbageCPU && sg2.garbageTasks && sg2.garbageNet && !sg2.failCPU && !SysInject().any))
        return out
    }

    // MARK: log format + summary-level decimation
    static func logFormat() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        let ok = SysSample(seq: 7, tWall: t, durUs: 312,
                           cpu: .value(CPUReading(system: 4.994, user: 16.649, idle: 78.357, nice: 0, cores: 12)),
                           tasks: .value(TaskCounts(threads: 4783, processes: 795)),
                           net: .value(NetReading(pktIn: 27_833_717, pktOut: 68_441_461, bytesIn: 22_758_680_252, bytesOut: 93_632_064_060,
                                                  pktInRate: 611.5, pktOutRate: 148.2, rxRate: 739_000.4, txRate: 19_574, ifaces: 14)),
                           cpuSimulated: false, netSimulated: false)
        let c = SysEngine.cpuBody(ok, simActive: false), n = SysEngine.netBody(ok, simActive: false)
        out.append(SelfTestCase("sys.log.cpu", c == "seq=7 dur_us=312 sys=4.99 user=16.65 idle=78.36 nice=0.00 cores=12 threads=4783 procs=795 sim=0 fail=- skip=-", c))
        out.append(SelfTestCase("sys.log.net", n == "seq=7 dur_us=312 ifaces=14 pkt_in=27833717 pkt_out=68441461 pkt_in_s=612 pkt_out_s=148 rx=22758680252 tx=93632064060 rx_bps=739000 tx_bps=19574 sim=0 fail=- skip=-", n))
        let bad = SysSample(seq: 8, tWall: t, durUs: 9, cpu: .failed(err: "injected"), tasks: .value(TaskCounts(threads: nil, processes: 800)),
                            net: .skipped(reason: "dt_short"), cpuSimulated: true, netSimulated: false)
        let c2 = SysEngine.cpuBody(bad, simActive: true), n2 = SysEngine.netBody(bad, simActive: true)
        out.append(SelfTestCase("sys.log.failed", c2 == "seq=8 dur_us=9 sys=- user=- idle=- nice=- cores=- threads=- procs=800 sim=1 fail=cpu.load skip=-"
                                && n2 == "seq=8 dur_us=9 ifaces=- pkt_in=- pkt_out=- pkt_in_s=- pkt_out_s=- rx=- tx=- rx_bps=- tx_bps=- sim=1 fail=- skip=dt_short",
                                c2 + " | " + n2))
        let nf = SysSample(seq: 9, tWall: t, durUs: 1, cpu: .skipped(reason: "baseline"), tasks: .failed(err: "implausible"), net: .failed(err: "errno=1"), cpuSimulated: false, netSimulated: false)
        let c3 = SysEngine.cpuBody(nf, simActive: false), n3 = SysEngine.netBody(nf, simActive: false)
        out.append(SelfTestCase("sys.log.skip", c3.hasSuffix("threads=- procs=- sim=0 fail=cpu.tasks skip=baseline") && n3.hasSuffix("fail=net.if skip=-"), c3 + " | " + n3))
        // summary level: one CPU / NET line per 10 s, skip lines dropped, every line file-only; sample level keeps all
        func count(_ level: LogLevel) -> (cpu: Int, net: Int, events: Int) {
            let f = Fake()
            f.engine = SysEngine(level: level, summarySeconds: 10) { [unowned f] l, at in f.lines.append((l, at)) }
            for _ in 0..<25 { f.step() }
            let cpu = f.lines.filter { $0.0.kind == "CPU" }, net = f.lines.filter { $0.0.kind == "NET" }
            return (cpu.count, net.count, (cpu + net).filter { $0.0.event }.count)
        }
        let sm = count(.summary), sa = count(.sample)
        // summary: CPU first tick is a skip (baseline) → lines at ticks 2, 12, 22; NET first tick is a value → 1, 11, 21
        out.append(SelfTestCase("sys.log.summary_gate", sm.cpu == 3 && sm.net == 3 && sa.cpu == 25 && sa.net == 25 && sm.events == 0 && sa.events == 0,
                                "summary=\(sm.cpu)/\(sm.net) sample=\(sa.cpu)/\(sa.net)"))
        return out
    }

    // MARK: formatters (AM)
    static func formatCases() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        let pct: [(Double, String)] = [(4.994, "4.99%"), (4.995, "5.00%"), (16.649, "16.65%"), (99.995, "100.00%"), (100, "100.00%"), (0, "0.00%")]
        let pBad = pct.filter { SysFormat.percent($0.0) != $0.1 }.map { "\($0.0)→\(SysFormat.percent($0.0))" }
        out.append(SelfTestCase("sys.fmt.pct", pBad.isEmpty, pBad.joined(separator: ",")))
        let ints: [(String, String)] = [(SysFormat.count(4783), "4,783"), (SysFormat.count(795), "795"), (SysFormat.count(1_234_567_890), "1,234,567,890"),
                                        (SysFormat.perSecond(611.5), "612"), (SysFormat.perSecond(0.4), "0"), (SysFormat.perSecond(999_999.4), "999,999"),
                                        (SysFormat.perSecond(-3), "0")]
        let iBad = ints.filter { $0.0 != $0.1 }.map(\.0)
        out.append(SelfTestCase("sys.fmt.int", iBad.isEmpty, iBad.joined(separator: ",")))
        let sp: [(Double, Lang, String)] = [(0, .en, "0.00 bit/s"), (124.9, .en, "999.20 bit/s"), (125, .zh, "1.00 kb/秒"), (19_574, .en, "156.59 kb/s"),
                                            (124_999.4, .en, "1.00 Mb/s"), (739_000, .zh, "5.91 Mb/秒"), (125_000_000, .en, "1.00 Gb/s")]
        let sBad = sp.filter { SysFormat.speed($0.0, $0.1) != $0.2 }.map { SysFormat.speed($0.0, $0.1) }
        out.append(SelfTestCase("sys.fmt.speed", sBad.isEmpty, sBad.joined(separator: ",")))
        // ByteCountFormatter .file follows the system region (spec §4): exact strings where "." is the decimal separator
        let file: [(UInt64, String)] = [(999, "999 bytes"), (1000, "1 KB"), (999_500, "1.0 MB"), (12_345_678, "12.3 MB"),
                                         (999_950_000, "1.00 GB"), (22_756_185_858, "22.76 GB"), (1_000_000_000_000, "1.00 TB")]
        let norm = { (s: String) in s.replacingOccurrences(of: "\u{00A0}", with: " ") }
        if (Locale.current.decimalSeparator ?? ".") == "." && (Locale.current.language.languageCode?.identifier ?? "en") == "en" {
            let fBad = file.filter { norm(SysFormat.file($0.0)) != $0.1 }.map { norm(SysFormat.file($0.0)) }
            out.append(SelfTestCase("fmt.file", fBad.isEmpty, fBad.joined(separator: ",")))
        } else {
            let all = file.allSatisfy { Shown.text(SysFormat.file($0.0)).parts.map { !$0.number.isEmpty && !$0.unit.isEmpty } ?? false }
            out.append(SelfTestCase("fmt.file", all, "locale \(Locale.current.identifier): number + unit only"))
        }
        // display mapping
        let cd = SysFormat.cpu(CPUReading(system: 4.994, user: 16.649, idle: 78.357, nice: 0, cores: 12), tasks: TaskCounts(threads: nil, processes: 795))
        let cb = SysFormat.cpu(nil, tasks: nil)
        out.append(SelfTestCase("sys.fmt.cpu_display", cd.system == .text("4.99%") && cd.user == .text("16.65%") && cd.idle == .text("78.36%")
                                && cd.threads == .failed && cd.processes == .text("795") && cb.system == .failed && cb.processes == .failed))
        let nr = NetReading(pktIn: 27_833_717, pktOut: 68_441_461, bytesIn: 999, bytesOut: 1000, pktInRate: nil, pktOutRate: nil, rxRate: nil, txRate: nil, ifaces: 3)
        let nd = SysFormat.net(nr, .zh)
        let nd2 = SysFormat.net(NetReading(pktIn: 1, pktOut: 2, bytesIn: 3, bytesOut: 4, pktInRate: 611.5, pktOutRate: 0, rxRate: 739_000, txRate: 19_574, ifaces: 1), .en)
        out.append(SelfTestCase("sys.fmt.net_display", nd.download == .failed && nd.packetsInRate == .failed && nd.packetsIn == .text("27,833,717")
                                && nd.received.parts?.unit == "bytes" && nd2.download == .text("5.91 Mb/s") && nd2.upload == .text("156.59 kb/s")
                                && nd2.packetsInRate == .text("612") && nd2.packetsOutRate == .text("0") && SysFormat.net(nil, .en).sent == .failed))
        return out
    }

    // MARK: sampler.set_hz (MemorySampler, spec §5.4)
    static func setHz() -> [SelfTestCase] {
        let a = MemorySampler.retune(hz: 4, auditHz: 0.2, ticksSinceAudit: 17)   // initial every = 20
        let b = MemorySampler.retune(hz: 1, auditHz: 0.2, ticksSinceAudit: 17)   // 20 → 5, counter clamped to 4
        let c = MemorySampler.retune(hz: 4, auditHz: 0.2, ticksSinceAudit: b.ticksSinceAudit)   // 5 → 20, counter kept
        let off = MemorySampler.retune(hz: 1, auditHz: 0, ticksSinceAudit: 3)                // --audit-hz 0: no Int(inf) trap
        let rate = a.auditEvery == 20 && a.ticksSinceAudit == 17 && b.auditEvery == 5 && b.ticksSinceAudit == 4
            && c.auditEvery == 20 && c.ticksSinceAudit == 4 && off.auditEvery == 0 && off.ticksSinceAudit == 0
            && MemorySampler.auditEvery(hz: 4, auditHz: 0) == 0 && MemorySampler.auditEvery(hz: 4, auditHz: 4) == 1
        // after a switch lastBoundary is reset → the next tick is on the new grid
        let g1 = MemorySampler.nextBoundary(now: 12.3, lastBoundary: 0, period: 1).next
        let g4 = MemorySampler.nextBoundary(now: 12.3, lastBoundary: 0, period: 0.25).next
        let stale = MemorySampler.nextBoundary(now: 12.3, lastBoundary: 12.25, period: 1).next   // without the reset: 13.25
        return [SelfTestCase("sampler.set_hz", rate && g1 == 13 && g4 == 12.5 && stale == 13.25,
                             "a=\(a) b=\(b) c=\(c) off=\(off) g1=\(g1) g4=\(g4)")]
    }

    // MARK: one live read of each source (no timer, no files)
    static func liveRead() -> [SelfTestCase] {
        let cpu = CPUReader(), net = NetReader()
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let ticks = cpu.ticks(), tasks = cpu.tasks(), ifs = net.read(), procs = CPUReader.processCount()
        let us = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000
        var cores = 0, th = 0, pr = 0, inc = 0, all = 0
        if case .success(let t) = ticks { cores = t.cores }
        if case .success(let v) = tasks { th = v.threads; pr = v.processes }
        if case .success(let l) = ifs { all = l.count; inc = l.filter(NetFilter.included).count }
        let lo = (try? ifs.get())?.first { $0.name == "lo0" }
        let ok = cores > 0 && CPUFormula.tasksPlausible(threads: th, processes: pr) && inc > 0 && (lo.map { !NetFilter.included($0) } ?? true)
            && (procs ?? 0) > 0 && cpu.clockHz > 0
        return [SelfTestCase("sys.live_read", ok, "cores=\(cores) threads=\(th) procs=\(pr) proc_listallpids=\(procs ?? -1) ifaces=\(inc)/\(all) hz=\(cpu.clockHz) us=\(us)"),
                portsStable(cpu)]
    }

    /// spec §5.1 r2 / §10.3: the cached host + pset ports mean no per-read uref growth; CPUReader.deinit releases the pset.
    static func portsStable(_ cpu: CPUReader) -> SelfTestCase {
        let task = mach_task_self_
        func refs(_ name: mach_port_name_t) -> mach_port_urefs_t {
            var r: mach_port_urefs_t = 0
            return mach_port_get_refs(task, name, MACH_PORT_RIGHT_SEND, &r) == KERN_SUCCESS ? r : 0
        }
        func nameCount() -> Int {
            var names: mach_port_name_array_t?, types: mach_port_type_array_t?
            var nc: mach_msg_type_number_t = 0, tc: mach_msg_type_number_t = 0
            guard mach_port_names(task, &names, &nc, &types, &tc) == KERN_SUCCESS else { return -1 }
            if let names { vm_deallocate(task, vm_address_t(bitPattern: names), vm_size_t(Int(nc) * MemoryLayout<mach_port_name_t>.stride)) }
            if let types { vm_deallocate(task, vm_address_t(bitPattern: types), vm_size_t(Int(tc) * MemoryLayout<mach_port_type_t>.stride)) }
            return Int(nc)
        }
        let host = mach_host_self()                                  // +1 uref, dropped below
        var pset = processor_set_name_t()
        let pk = processor_set_default(host, &pset)                  // +1 uref, dropped below
        let h0 = refs(host), p0 = refs(pset), n0 = nameCount()
        for _ in 0..<50 { _ = cpu.ticks(); _ = cpu.tasks() }
        for _ in 0..<5 { let r = CPUReader(); _ = r.tasks() }        // create + release
        let h1 = refs(host), p1 = refs(pset), n1 = nameCount()
        mach_port_deallocate(task, host)
        if pk == KERN_SUCCESS { mach_port_deallocate(task, pset) }
        return SelfTestCase("sys.ports_stable", pk == KERN_SUCCESS && h0 > 0 && h0 == h1 && p0 == p1 && n0 == n1 && n0 > 0,
                            "host_urefs=\(h0)→\(h1) pset_urefs=\(p0)→\(p1) names=\(n0)→\(n1)")
    }
}
