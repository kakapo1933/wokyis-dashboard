// Store.swift — main-thread state: latest MemSample, pressure history, battery groups, paging, staleness, simulation
// badge, v2 UI settings (view / language / battery column), SystemSampler values + CPU / network histories, and the set
// of dirty regions (spec §4, §5.5, §5.6, §6.6, §7.3; v2 spec §6). Owner: app agent.
//
// Every mutation rebuilds the per-region keys of the ACTIVE view (StateBuilder.regionKeys) and adds the regions whose key
// changed to `dirty`. A change of the `.chrome` key (view, language, battery column, simulation frame) dirties every
// region (full redraw). PanelView consumes `dirty` and the controller calls clearDirty().
// Display-pass merge (v2 spec §6.2, lever L1): the FIRST arrival of the active view's source in a new wall second
// (memory: the .000 MEM; CPU / network: the SysSample) dirties `.graph` in the same refresh as its values (clock and axis
// change their keys in that refresh too) → one pass. The 1 Hz tick dirties `.graph` only when that source has not arrived
// in the current second (failure, stall), so the graph still scrolls and shows the gap.
// Histories: pressure = PressureHistory (v1); CPU / network = SecondRing (reference ring, PanelState carries a
// HistoryView, never a copy). Every second is recorded whatever the view, so a switch shows ≤ 15 min at once.
import Foundation

final class Store {                              // main thread only
    let config: Config
    let startedAt: Date
    private(set) var dirty: Set<Region> = []
    /// WARN clock_step src=sys lines (SecondRing step back). Optional: the selftest runs without a log.
    var log: EventLog?
    /// Badge width test: (text, batteryVisible) → fits the main column (set by the app with a PanelRenderer measurer;
    /// nil → the badge is never collapsed, the renderer's character truncation stays the last resort).
    var badgeFits: ((String, Bool) -> Bool)?

    /// No sample of the active view's source for longer than this → white "停滯"/"STALE" chip (spec §5.6, v2 §5.2).
    var staleAfter: TimeInterval = 5
    /// No sample for longer than this → every value of that view "—".
    var blankAfter: TimeInterval = 10

    // memory
    private(set) var latest: MemSample?          // newest MEM (SUM, HIST, staleness)
    private(set) var shownMem: MemSample?        // the MEM sample the memory values display (--mem-display-hz, L3)
    private var shownMemSlot: Int?
    private(set) var lastArrival: Date?
    private var history = PressureHistory()
    // battery
    private(set) var groups: [DeviceGroup] = []
    private(set) var batteryPage = 0
    private var pageCount = 1
    private var lastFlip: Date
    // simulation badge
    private(set) var badgeParts: BadgeParts?
    private(set) var badge: String?
    // v2 UI
    private(set) var ui = UISettings()
    private(set) var lang: Lang = .zh
    // v2 SystemSampler
    private let cpuRing = SecondRing<CPUPoint>()
    private let netRing = SecondRing<NetPoint>()
    private(set) var cpuShown = CPUDisplay.blank
    private(set) var netShown = NetDisplay.blank
    private var netSpeed: (rx: Double, tx: Double)?   // last shown rates (bytes/s), re-formatted on a language change
    private(set) var latestSys: SysSample?
    private(set) var lastSysArrival: Date?
    private(set) var sysSamples: UInt64 = 0
    // pass merge
    private var activeSecond: Int?               // wall second of the last arrival of the active view's source

    private var lastKeys: [Region: String] = [:]
    private(set) var samples: UInt64 = 0

    init(config: Config, startedAt: Date = Date()) {
        self.config = config; self.startedAt = startedAt; self.lastFlip = startedAt
    }

    var historyPoints: [PressureSample] { history.points() }
    var historyCoverageSeconds: Double { history.coverageSeconds }
    var cpuHistoryCount: Int { cpuRing.count }
    var netHistoryCount: Int { netRing.count }
    /// CPU / network history points in the visible window (HIST cpu_n / net_n): points with a value.
    func sysHistoryStats() -> (cpu: Int, net: Int) {
        var c = 0, n = 0
        cpuRing.view().forEach { if $0.system != nil { c += 1 } }
        netRing.view().forEach { if $0.rx != nil { n += 1 } }
        return (c, n)
    }

    // MARK: inputs

    func apply(_ m: MemSample) { apply(m, now: Date()) }

    func apply(_ m: MemSample, now: Date) {
        latest = m; lastArrival = now; samples += 1
        let sec = Int(floor(m.tWall.timeIntervalSince1970))
        history.add(pct: m.pressure?.pct, level: m.pressure?.level, simulated: m.simulated, wallSecond: sec)
        // L3: memory values follow at most memDisplayHz (sampling stays memHz; .000 always starts a slot)
        let slot = Int(floor(m.tWall.timeIntervalSince1970 * config.memDisplayHz))
        if config.memDisplayHz >= config.memHz || shownMem == nil || slot != shownMemSlot {
            shownMem = m; shownMemSlot = slot
        }
        if ui.view == .memory { activeArrival(sec) }
        refresh(now: now)
    }

    func applyBattery(_ groups: [DeviceGroup]) { applyBattery(groups, now: Date()) }

    func applyBattery(_ groups: [DeviceGroup], now: Date) {
        self.groups = groups
        let n = PanelRenderer.pages(groups).count
        if n != pageCount {                 // page set changed: restart the rotation from the first page
            pageCount = n; batteryPage = 0; lastFlip = now
        } else if batteryPage >= n { batteryPage = 0 }
        refresh(now: now)
    }

    /// v2: the injection's badge parts (Injector.badgeParts); the text is localized and collapsed for the active view,
    /// language and column width, and recomputed only when one of those changes.
    func setSimulation(parts: BadgeParts?, now: Date = Date()) {
        guard parts != badgeParts else { return }
        badgeParts = parts
        recomputeBadge()
        refresh(now: now)
    }

    /// v1 path (selftest): a ready-made badge text.
    func setSimulation(badge: String?, now: Date = Date()) {
        badgeParts = nil
        guard badge != self.badge else { return }
        self.badge = badge
        refresh(now: now)
    }

    private func recomputeBadge() {
        guard let p = badgeParts else { badge = nil; return }
        let bat = ui.batteryVisible
        badge = p.text(lang, view: ui.view, fits: badgeFits.map { f in { f($0, bat) } })
    }

    /// v2: effective UI settings + resolved language. Any change → `.chrome` key changes → full redraw.
    func setUI(_ u: UISettings, lang l: Lang, now: Date) {
        guard u != ui || l != lang else { return }
        let langChanged = l != lang
        ui = u; lang = l
        if langChanged, let sp = netSpeed {
            netShown.download = .text(L10n.speed(bytesPerSecond: sp.rx, l)); netShown.upload = .text(L10n.speed(bytesPerSecond: sp.tx, l))
        }
        if badgeParts != nil { recomputeBadge() }
        activeSecond = nil
        refresh(now: now)
    }

    /// v2: one SystemSampler tick. value → update + history point; skipped → keep the display, no point;
    /// failed → that field "—" at once + a nil point (gap). Rates nil (baseline just set) → keep the shown rates, gap.
    func applySys(_ s: SysSample, now: Date) {
        latestSys = s; lastSysArrival = now; sysSamples += 1
        let sec = floor(s.tWall.timeIntervalSince1970)
        var stepped = 0
        func note(_ r: SecondRing<CPUPoint>.Put) { if case .steppedBack(let d) = r { stepped = max(stepped, d + 1) } }
        func noteN(_ r: SecondRing<NetPoint>.Put) { if case .steppedBack(let d) = r { stepped = max(stepped, d + 1) } }
        switch s.cpu {
        case .value(let c):
            let d = StateBuilder.cpu(c, tasks: nil)
            cpuShown.system = d.system; cpuShown.user = d.user; cpuShown.idle = d.idle
            note(cpuRing.put(CPUPoint(t: sec, system: Float(c.system), user: Float(c.user), simulated: s.cpuSimulated)))
        case .skipped: break
        case .failed:
            cpuShown.system = .failed; cpuShown.user = .failed; cpuShown.idle = .failed
            note(cpuRing.put(CPUPoint(t: sec, system: nil, user: nil, simulated: s.cpuSimulated)))
        }
        switch s.tasks {
        case .value(let t):
            let d = StateBuilder.cpu(nil, tasks: t)
            cpuShown.threads = d.threads; cpuShown.processes = d.processes
        case .skipped: break
        case .failed: cpuShown.threads = .failed; cpuShown.processes = .failed
        }
        switch s.net {
        case .value(let n):
            let d = StateBuilder.net(n, lang: lang)
            netShown.packetsIn = d.packetsIn; netShown.packetsOut = d.packetsOut; netShown.received = d.received; netShown.sent = d.sent
            if let rx = n.rxRate, let tx = n.txRate {
                netSpeed = (rx, tx)
                netShown.download = d.download; netShown.upload = d.upload
                netShown.packetsInRate = d.packetsInRate; netShown.packetsOutRate = d.packetsOutRate
                noteN(netRing.put(NetPoint(t: sec, rx: rx, tx: tx, simulated: s.netSimulated)))
            } else {
                noteN(netRing.put(NetPoint(t: sec, rx: nil, tx: nil, simulated: s.netSimulated)))
            }
        case .skipped: break
        case .failed:
            netShown = .blank; netSpeed = nil
            noteN(netRing.put(NetPoint(t: sec, rx: nil, tx: nil, simulated: s.netSimulated)))
        }
        if stepped > 0 { log?.event("WARN", "clock_step src=sys dir=back dropped=\(stepped - 1)") }
        if ui.view != .memory { activeArrival(Int(sec)) }
        refresh(now: now)
    }

    /// Close the previous wall second in the pressure history, page rotation, staleness; `.graph` only when the active
    /// view's source has not arrived in this second (spec §6.2).
    func tick1Hz(now: Date) {
        let sec = Int(floor(now.timeIntervalSince1970))
        history.closeThrough(wallSecond: sec)
        if pageCount > 1, !EventLog.throttled(now, lastFlip, config.pageSeconds) {   // (clock step back → flips too)
            batteryPage = (batteryPage + 1) % pageCount; lastFlip = now
        }
        if activeSecond != sec { dirty.insert(.graph) }
        refresh(now: now)
    }

    private func activeArrival(_ sec: Int) {
        if activeSecond != sec { activeSecond = sec; dirty.insert(.graph) }
    }

    /// Mark everything for a full redraw (window shown again, occlusion ended, screen change).
    func markAll() { dirty = Set(Region.allCases) }

    // MARK: outputs

    private func arrival(_ v: ViewKind) -> Date? { v == .memory ? lastArrival : lastSysArrival }

    func isStale(view v: ViewKind, now: Date) -> Bool {
        guard let a = arrival(v) else { return now.timeIntervalSince(startedAt) > staleAfter }
        return now.timeIntervalSince(a) > staleAfter
    }

    func isBlank(view v: ViewKind, now: Date) -> Bool {
        guard let a = arrival(v) else { return true }
        return now.timeIntervalSince(a) > blankAfter
    }

    func isStale(now: Date) -> Bool { isStale(view: .memory, now: now) }
    func isBlank(now: Date) -> Bool { isBlank(view: .memory, now: now) }

    func panelState(now: Date) -> PanelState { panelState(now: now, withHistory: true) }

    /// `withHistory: false` (key refresh): no pressure-history array (regionKeys never reads history).
    private func panelState(now: Date, withHistory: Bool) -> PanelState {
        let v = ui.view
        let memShown = shownMem ?? latest
        let mem = (memShown != nil && !isBlank(view: .memory, now: now)) ? StateBuilder.memory(memShown!) : StateBuilder.blankMemory
        let clock: String
        switch v {
        case .memory: clock = memShown.map { EventLog.hms($0.tWall) } ?? EventLog.hms(now)
        case .cpu, .network: clock = latestSys.map { EventLog.hms($0.tWall) } ?? EventLog.hms(now)
        }
        let coverage = min(max(0, now.timeIntervalSince(startedAt)), Double(PressureHistory.capacity))
        var s = PanelState(memory: mem, history: (withHistory && v == .memory) ? history.points() : [], now: now.timeIntervalSince1970,
                           historyCoverage: coverage, devices: groups, batteryPage: min(batteryPage, max(0, pageCount - 1)), clock: clock,
                           sampleStale: isStale(view: v, now: now), simulationBadge: badge)
        s.view = v; s.lang = lang; s.batteryVisible = ui.batteryVisible
        let sysBlank = isBlank(view: .cpu, now: now)
        s.cpu = sysBlank ? .blank : cpuShown
        s.net = sysBlank ? .blank : netShown
        if withHistory { s.cpuHistory = cpuRing.view(); s.netHistory = netRing.view() }
        s.sysCoverage = coverage
        return s
    }

    /// Called by the controller after PanelView has invalidated the dirty regions.
    func clearDirty() { dirty = [] }

    private func refresh(now: Date) {
        let keys = StateBuilder.regionKeys(panelState(now: now, withHistory: false))
        if keys[.chrome] != lastKeys[.chrome] && !lastKeys.isEmpty {
            dirty = Set(Region.allCases)
        } else {
            for (r, k) in keys where lastKeys[r] != k { dirty.insert(r) }
        }
        lastKeys = keys
    }
}
