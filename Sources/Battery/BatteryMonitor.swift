// BatteryMonitor.swift — scheduling of the three battery sources on batQ / spQ (spec §3, §6.1):
// HID 15 s + IOKit notifications, IOPS 15 s + run-loop notifications (installed on main), system_profiler on a fixed
// `spPeriod` grid plus notification-triggered extra runs (debounce 2 s, ≥ 10 s since last start), never backing off.
// Feeds BatteryAggregator and delivers [DeviceGroup] to `onGroups` on the MAIN queue; writes ERR/SP/WARN lines
// (BAT/DEV lines come from the aggregator). Owner: battery agent.
//
// batQ: HID/IOPS reads, aggregator (all aggregator state), 1 s re-merge (sp staleness at 45 s, offline grace), BAT every 15 s.
// spQ : the sp grid timer, extra-run debounce, BTProfilerSource runs (its completion hops to batQ).
import Foundation

final class BatteryMonitor: @unchecked Sendable {
    let config: Config
    let injector: Injector
    let log: EventLog
    let onGroups: @Sendable ([DeviceGroup]) -> Void

    static let readPeriod: TimeInterval = 15
    static let extraDebounce: TimeInterval = 2
    static let extraMinSpacing: TimeInterval = 10

    private let batQ = DispatchQueue(label: "wokyis.bat", qos: .utility)
    private let spQ = DispatchQueue(label: "wokyis.sp", qos: .utility)
    private let acc: AccessorySource
    private let sp: BTProfilerSource
    private let agg: BatteryAggregator
    private var hid: HIDSource?                 // created in start()

    // batQ state
    private var lastHID: Result<[HIDDevice], SourceError> = .success([])
    private var lastAcc: Result<[AccPart], SourceError> = .success([])
    private var lastSP: (devices: [BTDevice], at: Date)?
    private var spLastError: SourceError?
    private var published: String?
    private var readTimer: DispatchSourceTimer?
    private var mergeTimer: DispatchSourceTimer?
    private var batStopped = false

    // spQ state
    private var spTimer: DispatchSourceTimer?
    private var lastSPStart: Date?
    private var extraItem: DispatchWorkItem?
    private var extraPending: String?
    private var spStopped = false

    init(config: Config, injector: Injector, log: EventLog, onGroups: @escaping @Sendable ([DeviceGroup]) -> Void) {
        self.config = config; self.injector = injector; self.log = log; self.onGroups = onGroups
        acc = AccessorySource(injector: injector)
        sp = BTProfilerSource(path: config.spPath, queue: spQ, injector: injector)
        agg = BatteryAggregator(offlineGrace: config.offlineGrace, hidTrustNotify: config.hidTrustNotify,
                                nearbyFresh: config.nearbyFreshSeconds, log: log)
    }

    private var sim: Int { injector.active ? 1 : 0 }

    /// Must be called on the main thread (installs run-loop notifications).
    func start() {
        acc.installNotifications { [weak self] in
            guard let self else { return }
            self.batQ.async { self.onNotify(source: "iops") }
        }
        if !acc.installed.contains("iops_acc") {
            log.event("WARN", "iops_acc_notify=missing installed=\(acc.installed.joined(separator: ",")) sim=\(sim)")
        }
        if AccessorySource.byType == nil { log.event("WARN", "iops_by_type=missing sim=\(sim)") }
        hid = HIDSource(queue: batQ, injector: injector) { [weak self] in self?.onNotify(source: "hid") }

        batQ.async { [self] in
            readSources()
            mergeAndPublish(forceBAT: true)
            let rt = DispatchSource.makeTimerSource(queue: batQ)
            rt.schedule(deadline: .now() + Self.readPeriod, repeating: Self.readPeriod, leeway: .milliseconds(200))
            rt.setEventHandler { [weak self] in
                guard let self, !self.batStopped else { return }
                self.readSources(); self.mergeAndPublish(forceBAT: true)
            }
            rt.resume(); readTimer = rt
            let mt = DispatchSource.makeTimerSource(queue: batQ)
            mt.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            mt.setEventHandler { [weak self] in
                guard let self, !self.batStopped else { return }
                self.mergeAndPublish(forceBAT: false)
            }
            mt.resume(); mergeTimer = mt
        }
        spQ.async { [self] in
            let t = DispatchSource.makeTimerSource(queue: spQ)
            t.schedule(deadline: .now(), repeating: config.spPeriod, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.runSP(trigger: "timer") }
            t.resume(); spTimer = t
        }
    }

    /// Stops timers, removes notifications, kills a running system_profiler child and waits for it.
    func stop() {
        if Thread.isMainThread { acc.removeNotifications() } else { DispatchQueue.main.sync { acc.removeNotifications() } }
        batQ.sync {
            batStopped = true            // later sp completions / notifications are ignored
            readTimer?.cancel(); readTimer = nil
            mergeTimer?.cancel(); mergeTimer = nil
        }
        spQ.sync {
            spStopped = true
            spTimer?.cancel(); spTimer = nil
            extraItem?.cancel(); extraItem = nil
        }
        sp.cancel()
        hid?.stop()
    }

    /// Re-read everything soon (wake from sleep).
    func pollNow(reason: String) {
        batQ.async { [self] in
            guard !batStopped else { return }
            readSources(); mergeAndPublish(forceBAT: true)
        }
        spQ.async { [self] in runSP(trigger: reason) }
    }

    /// pid of a running system_profiler child (stop checks).
    var childPID: pid_t? { sp.childPID }

    // MARK: batQ

    private func readSources() {
        do { lastHID = .success(try hid?.read() ?? []) }
        catch { lastHID = .failure(Self.sourceError(error)); logErr("bat.hid", lastHID) }
        readAcc()
    }

    private func readAcc() {
        do { lastAcc = .success(try acc.read()) }
        catch { lastAcc = .failure(Self.sourceError(error)); logErr("bat.iops", lastAcc) }
    }

    private func onNotify(source: String) {
        guard !batStopped else { return }
        if source == "hid" { readSources() } else { readAcc() }
        mergeAndPublish(forceBAT: false)
        requestExtraSP()
    }

    private func mergeAndPublish(forceBAT: Bool) {
        let groups = agg.merge(hid: lastHID, acc: lastAcc, sp: lastSP, spLastError: spLastError, now: Date())
        agg.logBAT(force: forceBAT)
        let sig = Self.signature(groups)
        if sig != published {
            published = sig
            let cb = onGroups
            DispatchQueue.main.async { cb(groups) }
        }
    }

    private func logErr<T>(_ src: String, _ r: Result<T, SourceError>) {
        guard case .failure(let e) = r else { return }
        var body = "src=\(src) err=\(e.logToken)"
        switch e {
        case .errno(_, let m): body += " detail=\(EventLog.q(m))"
        case .parse(let m): body += " detail=\(EventLog.q(m))"
        case .missingSymbol(let m): body += " detail=\(EventLog.q(m))"
        default: break
        }
        log.event("ERR", body + " sim=\(sim)")
    }

    static func sourceError(_ e: Error) -> SourceError { (e as? SourceError) ?? .parse("\(e)") }

    static func signature(_ gs: [DeviceGroup]) -> String {
        gs.map { g in
            "\(g.kind.rawValue)|\(g.name)|\(g.ownerTag ?? "")|\(g.presence.rawValue)|" + g.cells.map { c in
                switch c.state { case .ok(let p, let ch): return "\(c.label)=\(p)\(ch ? "c" : "")"; case .failed: return "\(c.label)=F"; case .unavailable: return "\(c.label)=na"; case .stale: return "\(c.label)=S" }
            }.joined(separator: ",")
        }.joined(separator: ";")
    }

    // MARK: spQ

    private func runSP(trigger: String) {
        guard !spStopped else { return }
        if sp.inFlight {
            if trigger != "timer" { extraPending = trigger }   // re-evaluated when the running one completes
            return
        }
        let start = Date()
        lastSPStart = start
        sp.poll { [weak self] result, ms in
            guard let self else { return }
            // on spQ
            if let p = self.extraPending, !self.spStopped { self.extraPending = nil; self.scheduleExtra(trigger: p) }
            self.batQ.async { self.spDone(result, ms: ms, start: start, trigger: trigger) }
        }
    }

    /// batQ → spQ: a HID / IOPS notification asks for an extra sp run (debounce 2 s, ≥ 10 s since the last start).
    private func requestExtraSP() {
        spQ.async { [self] in
            guard !spStopped else { return }
            extraItem?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.scheduleExtra(trigger: "notify") }
            extraItem = w
            spQ.asyncAfter(deadline: .now() + Self.extraDebounce, execute: w)
        }
    }

    /// spQ: run now if spacing allows, else at lastStart + 10 s.
    private func scheduleExtra(trigger: String) {
        guard !spStopped else { return }
        let since = lastSPStart.map { Date().timeIntervalSince($0) } ?? .infinity
        if since >= Self.extraMinSpacing { runSP(trigger: trigger); return }
        extraItem?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.scheduleExtra(trigger: trigger) }
        extraItem = w
        spQ.asyncAfter(deadline: .now() + (Self.extraMinSpacing - since) + 0.01, execute: w)
    }

    // MARK: batQ (sp completion)

    private func spDone(_ r: Result<[BTDevice], SourceError>, ms: Int, start: Date, trigger: String) {
        guard !batStopped else { return }
        switch r {
        case .success(let devs):
            lastSP = (devs, start); spLastError = nil
            let c = devs.filter(\.connected).count
            log.line("SP", "rc=0 ms=\(ms) connected=\(c) not_connected=\(devs.count - c) trigger=\(trigger) sim=\(sim)")
        case .failure(let e):
            spLastError = e
            var rc = "-"
            if case .subprocess(let s) = e { rc = String(s) }
            let age = lastSP.map { String(Int(Date().timeIntervalSince($0.at))) } ?? "-"
            log.event("SP", "rc=\(rc) ms=\(ms) err=\(e.logToken) last_ok_age_s=\(age) trigger=\(trigger) sim=\(sim)")
            logErr("bat.sp", Result<Int, SourceError>.failure(e))
        }
        mergeAndPublish(forceBAT: false)
    }
}
