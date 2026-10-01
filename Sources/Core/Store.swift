// Store.swift — main-thread state: latest MemSample, pressure history, battery groups, paging, staleness, simulation
// badge and the set of dirty regions (spec §4, §5.5, §5.6, §6.6, §7.3). Owner: app agent.
//
// Every mutation rebuilds the per-region keys (StateBuilder.regionKeys) and adds the regions whose key changed to
// `dirty`; the 1 Hz tick always dirties `.graph` (the history scrolls). A change of the simulation-frame flag
// (`.chrome` key) dirties every region (full redraw). PanelView consumes `dirty` and the controller calls clearDirty().
import Foundation

final class Store {                              // main thread only
    let config: Config
    let startedAt: Date
    private(set) var dirty: Set<Region> = []

    /// No MEM for longer than this → white "停滯" chip (spec §5.6).
    var staleAfter: TimeInterval = 5
    /// No MEM for longer than this → all seven values and the pressure become "—".
    var blankAfter: TimeInterval = 10

    private(set) var latest: MemSample?
    private(set) var lastArrival: Date?
    private var history = PressureHistory()
    private(set) var groups: [DeviceGroup] = []
    private(set) var batteryPage = 0
    private var pageCount = 1
    private var lastFlip: Date
    private(set) var badge: String?
    private var lastKeys: [Region: String] = [:]
    private(set) var samples: UInt64 = 0

    init(config: Config, startedAt: Date = Date()) {
        self.config = config; self.startedAt = startedAt; self.lastFlip = startedAt
    }

    var historyPoints: [PressureSample] { history.points() }
    var historyCoverageSeconds: Double { history.coverageSeconds }

    // MARK: inputs

    func apply(_ m: MemSample) { apply(m, now: Date()) }

    func apply(_ m: MemSample, now: Date) {
        latest = m; lastArrival = now; samples += 1
        history.add(pct: m.pressure?.pct, level: m.pressure?.level, simulated: m.simulated,
                    wallSecond: Int(floor(m.tWall.timeIntervalSince1970)))
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

    func setSimulation(badge: String?, now: Date = Date()) {
        guard badge != self.badge else { return }
        self.badge = badge
        refresh(now: now)
    }

    /// Close the previous wall second in the history, staleness, page rotation, clock; the graph always scrolls.
    func tick1Hz(now: Date) {
        history.closeThrough(wallSecond: Int(floor(now.timeIntervalSince1970)))
        if pageCount > 1, !EventLog.throttled(now, lastFlip, config.pageSeconds) {   // (clock step back → flips too)
            batteryPage = (batteryPage + 1) % pageCount; lastFlip = now
        }
        dirty.insert(.graph)
        refresh(now: now)
    }

    /// Mark everything for a full redraw (window shown again, occlusion ended, screen change).
    func markAll() { dirty = Set(Region.allCases) }

    // MARK: outputs

    func isStale(now: Date) -> Bool {
        guard let a = lastArrival else { return now.timeIntervalSince(startedAt) > staleAfter }
        return now.timeIntervalSince(a) > staleAfter
    }

    func isBlank(now: Date) -> Bool {
        guard let a = lastArrival else { return true }
        return now.timeIntervalSince(a) > blankAfter
    }

    func panelState(now: Date) -> PanelState {
        let mem = (latest != nil && !isBlank(now: now)) ? StateBuilder.memory(latest!) : StateBuilder.blankMemory
        let clock = latest.map { EventLog.hms($0.tWall) } ?? EventLog.hms(now)
        let coverage = min(max(0, now.timeIntervalSince(startedAt)), Double(PressureHistory.capacity))
        return PanelState(memory: mem, history: history.points(), now: now.timeIntervalSince1970, historyCoverage: coverage,
                          devices: groups, batteryPage: min(batteryPage, max(0, pageCount - 1)), clock: clock,
                          sampleStale: isStale(now: now), simulationBadge: badge)
    }

    /// Called by the controller after PanelView has invalidated the dirty regions.
    func clearDirty() { dirty = [] }

    private func refresh(now: Date) {
        let keys = StateBuilder.regionKeys(panelState(now: now))
        if keys[.chrome] != lastKeys[.chrome] && !lastKeys.isEmpty {
            dirty = Set(Region.allCases)
        } else {
            for (r, k) in keys where lastKeys[r] != k { dirty.insert(r) }
        }
        lastKeys = keys
    }
}
