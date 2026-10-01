// Headless.swift — lead decision D5: `--headless [--duration S]`.
// Memory + battery sampling, injector, logging and audit WITHOUT NSApplication (no window, no Dock icon):
// the main thread runs a plain CFRunLoop (so main-queue blocks and main-run-loop IOPS notifications still fire).
// Exits after S seconds or on SIGINT/SIGTERM/SIGHUP (second SIGINT → 130; SIGHUP stays ignored under nohup). Used for gate G2 and tests.
// Owner: core.
import Foundation

final class HeadlessRunner: @unchecked Sendable {   // state touched on main only
    let config: Config
    let log: EventLog
    let injector: Injector
    private var sampler: MemorySampler?
    private var battery: BatteryMonitor?
    private var signals: Signals?
    private var tick: DispatchSourceTimer?
    // main-thread state
    private var latest: MemSample?
    private var groups: [DeviceGroup] = []
    private var history = PressureHistory()
    private var samples: UInt64 = 0
    private var lastHist = Date.distantPast
    private var lastHealth = Date.distantPast
    private var stopping = false

    let table: SysctlTable

    init(config: Config, log: EventLog, injector: Injector, table: SysctlTable) {
        self.config = config; self.log = log; self.injector = injector; self.table = table
    }

    func start() {
        injector.start()
        let s = MemorySampler(hz: config.memHz, auditHz: config.auditHz, table: table, injector: injector, log: log) { [weak self] m in
            DispatchQueue.main.async { self?.apply(m) }
        }
        let b = BatteryMonitor(config: config, injector: injector, log: log) { [weak self] g in
            DispatchQueue.main.async { self?.groups = g }
        }
        sampler = s; battery = b
        s.start(); b.start()

        let sig = Signals(queue: .main) { [weak self] n in self?.shutdown(reason: Signals.name(n)) }
        sig.install([SIGINT, SIGTERM, SIGHUP])
        signals = sig
        if !sig.inheritedIgnored.isEmpty { log.line("HEALTH", "signals_inherited_ignored=\(sig.inheritedIgnored.map(Signals.name).joined(separator: ",")) reason=nohup") }

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick1Hz(Date()) }
        t.resume(); tick = t

        if let d = config.duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.shutdown(reason: "duration") }
        }
    }

    private func apply(_ m: MemSample) {
        latest = m; samples += 1
        history.add(pct: m.pressure?.pct, level: m.pressure?.level, simulated: m.simulated,
                    wallSecond: Int(floor(m.tWall.timeIntervalSince1970)))
    }

    private func tick1Hz(_ now: Date) {
        log.summary(SummaryFormat.body(sample: latest, groups: groups, sim: injector.active), at: now)
        if !EventLog.throttled(now, lastHist, 60.05) {
            lastHist = now
            let p = history.points()
            let span = (p.last?.t ?? 0) - (p.first?.t ?? 0)
            log.line("HIST", "n=\(p.count) span_s=\(Int(span)) coverage_s=\(Int(history.coverageSeconds)) sim_points=\(p.filter(\.simulated).count)")
        }
        if !EventLog.throttled(now, lastHealth, 60.05) {
            lastHealth = now
            let h = ProcessHealth.sample()
            let st = log.stats()
            log.line("HEALTH", String(format: "cpu_s=%.3f footprint_mb=%.1f rss_mb=%.1f draws=0 draw_ms_avg=- timer_late_p99_ms=- occluded=- log_mb=%.2f samples=%llu mode=headless",
                                      h?.cpuSeconds ?? -1, h?.footprintMB ?? -1, h?.rssMB ?? -1, Double(st.bytes) / 1_048_576, samples))
        }
    }

    func shutdown(reason: String) {
        guard !stopping else { return }
        stopping = true
        tick?.cancel()
        sampler?.stop()
        battery?.stop()
        injector.stop()
        log.event("STOP", "reason=\(reason) uptime_s=\(Int(Date().timeIntervalSince(StartInfo.launchedAt))) samples=\(samples)")
        log.flushSync()
        exit(0)
    }
}

enum Headless {
    static func run(config: Config) -> Never {
        let log: EventLog
        do {
            log = try EventLog(dir: config.logDirURL, level: config.logLevel, summarySeconds: config.summarySeconds)
        } catch {
            FileHandle.standardError.write(Data("WokyisPanel: cannot open log dir \(config.logDirURL.path): \(error)\n".utf8))
            exit(73)
        }
        let injector = Injector(runDir: config.runDirURL, log: log)
        log.simActive = { injector.active }
        let quick = SelfTest.runQuick()
        let table = SysctlTable(names: SysctlTable.standardNames, broken: Set(config.breakMIBs))
        log.event("START", StartInfo.startBody(config: config, mode: .headless, selftest: quick.ok ? "ok" : "fail:" + quick.failed.joined(separator: ","),
                                               mibs: "\(table.resolvedCount)/\(table.names.count)")
                  + " log=\(EventLog.q(log.currentFile.path))")
        let runner = HeadlessRunner(config: config, log: log, injector: injector, table: table)
        runner.start()
        withExtendedLifetime(runner) { CFRunLoopRun() }
        exit(0)
    }
}
