// StateBuilder.swift — Store → PanelState pieces, per-region change keys, paging helpers and the DSP battery string
// (spec §2, §5.6, §6.6, §7.3 regions, §7.4, §12 DSP). Pure functions (no AppKit), so --selftest can cover them.
// Owner: app agent.
import Foundation

enum StateBuilder {
    /// A state with every memory value failed ("—"), unknown pressure, no history, no devices.
    static func placeholder(now: Date) -> PanelState {
        PanelState(memory: blankMemory, history: [], now: now.timeIntervalSince1970, historyCoverage: 0, devices: [],
                   clock: EventLog.hms(now))
    }

    static let blankMemory = MemoryDisplay(physical: .failed, used: .failed, cached: .failed, swap: .failed, app: .failed,
                                           wired: .failed, compressed: .failed, pressurePercent: nil, pressureLevel: nil)

    /// The seven values + pressure of one sample. A field whose string is nil (read failed in THIS sample) → "—".
    static func memory(_ m: MemSample) -> MemoryDisplay {
        func shown(_ f: Field) -> Shown {
            if let v = m.strings[f], let t = v { return .text(t) }
            return .failed
        }
        return MemoryDisplay(physical: shown(.physical), used: shown(.used), cached: shown(.cached), swap: shown(.swap),
                             app: shown(.app), wired: shown(.wired), compressed: shown(.compressed),
                             pressurePercent: m.pressure?.pct, pressureLevel: m.pressure?.level,
                             pressureSimulated: m.simulated)
    }

    static func key(_ v: Shown) -> String { if case .text(let t) = v { return t }; return "—" }

    /// Left axis label exactly as the renderer draws it (coverage < 600 s → "收集中 N/10 分鐘").
    static func axisLabel(_ coverage: Double) -> String {
        coverage >= 600 ? "十分鐘前" : "收集中 \(Int(coverage / 60))/10 分鐘"
    }

    /// One string per region; a region is redrawn when its key changes. `.chrome` carries the simulation-frame flag:
    /// when it changes the whole view is redrawn (frame on/off). `.graph` has no key: it scrolls every second (1 Hz tick).
    static func regionKeys(_ s: PanelState) -> [Region: String] {
        let m = s.memory
        let pages = PanelRenderer.pages(s.devices).count
        return [
            .chrome: s.simulationBadge == nil ? "plain" : "sim",
            .used: key(m.used),
            .pressure: "\(m.pressurePercent.map(String.init) ?? "—")|\(m.pressurePercent == nil ? 0 : (m.pressureLevel?.rawValue ?? 0))",
            .axis: axisLabel(s.historyCoverage),
            .sec0: key(m.physical), .sec1: key(m.cached), .sec2: key(m.swap),
            .sec3: key(m.app), .sec4: key(m.wired), .sec5: key(m.compressed),
            .battery: deviceSignature(s.devices) + "#p\(min(s.batteryPage, max(0, pages - 1)))/\(pages)",
            .clock: s.clock + (s.sampleStale ? "|stale" : ""),
            .sim: s.simulationBadge ?? "",
        ]
    }

    /// Everything the battery column draws for a device list.
    static func deviceSignature(_ ds: [DeviceGroup]) -> String {
        ds.map { g in
            "\(g.kind.rawValue):\(g.ownerTag ?? ""):\(g.presence.rawValue):" + g.cells.map { c in
                switch c.state {
                case .ok(let p, let ch): return "\(c.label)=\(p)\(ch ? "c" : "")"
                case .failed: return "\(c.label)=F"
                case .unavailable: return "\(c.label)=U"
                case .stale: return "\(c.label)=S"
                }
            }.joined(separator: ",")
        }.joined(separator: ";")
    }

    /// DSP `bat="kb:100 tp:85 L:100 R:97 C:48c"` — only the devices on the displayed page, in drawing order.
    /// Tokens: N (ok), Nc (charging), F (failed "—"), U (unavailable dim "—"), S (sp stale, grey "—"), off (離線).
    /// HID prefixes kb/tp/ms/hid; with an owner tag (two devices of one kind) `kb[ALEX]:100`; tagged AirPods groups
    /// get a `pods[TAG]` token before their cells. A nearby AirPods group (grey numbers + 「附近」) always gets a
    /// `pods~` / `pods[TAG]~` token before its cells: `pods~ L:97 R:99 C:U`.
    static func dspBattery(_ s: PanelState) -> String {
        if s.devices.isEmpty { return "none" }
        let pages = PanelRenderer.pages(s.devices)
        let page = pages[min(s.batteryPage, pages.count - 1)]
        func tok(_ c: CellState) -> String {
            switch c {
            case .ok(let p, let ch): return "\(p)" + (ch ? "c" : "")
            case .failed: return "F"
            case .unavailable: return "U"
            case .stale: return "S"
            }
        }
        var out: [String] = []
        for b in page {
            switch b {
            case .hid(let d):
                let pre: String
                switch d.kind { case .keyboard: pre = "kb"; case .trackpad: pre = "tp"; case .mouse: pre = "ms"; default: pre = "hid" }
                out.append("\(pre)\(d.ownerTag.map { "[\($0)]" } ?? ""):" + (d.connected ? (d.cells.first.map { tok($0.state) } ?? "-") : "off"))
            case .pods(let d):
                let tag = d.ownerTag.map { "[\($0)]" } ?? ""
                if !d.showsCells { out.append("pods\(tag):off"); continue }
                if d.presence == .nearby { out.append("pods\(tag)~") } else if !tag.isEmpty { out.append("pods\(tag)") }
                let names = ["L", "R", "C"]
                for (i, c) in d.cells.enumerated() { out.append("\(d.cells.count == 3 ? names[i] : "P"):\(tok(c.state))") }
            }
        }
        return out.joined(separator: " ")
    }
}

/// App-module self-test hook (Store / StateBuilder) called by `--selftest`. Pure: no files, no timers, no windows.
enum AppSelfTest {
    static func sample(seq: UInt64, t: Date, used: String? = "18.52 GB", swap: String? = "39.8 MB", pct: Int? = 48,
                       level: PressureLevel = .normal, simulated: Bool = false) -> MemSample {
        var s: [Field: String?] = [:]
        for f in Field.allCases { s[f] = .some("1.00 GB") }
        s[.physical] = .some("24.00 GB"); s[.used] = .some(used); s[.swap] = .some(swap)
        var b = MemoryBytes()
        for f in Field.allCases { b[f] = s[f]! == nil ? nil : 1 << 30 }
        return MemSample(seq: seq, tWall: t, durUs: 10, bytes: b, strings: s, pressure: pct.map { ($0, level) },
                         simulated: simulated, failed: used == nil ? ["mem.mib:vm.page_free_count"] : [], mode: .mte)
    }

    static func kb(_ p: Int, connected: Bool = true) -> DeviceGroup {
        DeviceGroup(kind: .keyboard, name: "KB", ownerTag: nil, connected: connected, cells: [BatteryCell(label: "鍵盤", state: .ok(p, charging: false))])
    }
    static func pods(_ name: String, _ l: Int) -> DeviceGroup {
        DeviceGroup(kind: .airpods, name: name, ownerTag: name, connected: true,
                    cells: [BatteryCell(label: "左耳", state: .ok(l, charging: false)), BatteryCell(label: "右耳", state: .unavailable),
                            BatteryCell(label: "充電盒", state: .ok(40, charging: true))])
    }

    static func run() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        func expect(_ name: String, _ ok: Bool, _ d: String = "") { out.append(SelfTestCase("app.\(name)", ok, d)) }
        var cfg = Config(); cfg.pageSeconds = 8
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let st = Store(config: cfg, startedAt: t0)

        // 1. first sample → every memory region dirty, strings shown verbatim
        st.apply(sample(seq: 1, t: t0), now: t0)
        var s = st.panelState(now: t0)
        expect("store.first_sample", s.memory.used == .text("18.52 GB") && s.memory.pressurePercent == 48 && !s.sampleStale,
               "used=\(StateBuilder.key(s.memory.used))")
        expect("store.first_dirty", [.used, .pressure, .sec0, .sec2, .clock].allSatisfy(st.dirty.contains), "\(st.dirty.map(\.rawValue).sorted())")
        st.clearDirty()

        // 2. only the swap string changes → only sec2 dirty (same second → clock unchanged)
        st.apply(sample(seq: 2, t: t0.addingTimeInterval(0.25), swap: "40.1 MB"), now: t0.addingTimeInterval(0.25))
        expect("store.region_diff", st.dirty == [.sec2], "\(st.dirty.map(\.rawValue).sorted())")
        st.clearDirty()

        // 3. failed field in THIS sample → "—" at once (no old value)
        st.apply(sample(seq: 3, t: t0.addingTimeInterval(0.5), used: nil), now: t0.addingTimeInterval(0.5))
        s = st.panelState(now: t0.addingTimeInterval(0.5))
        expect("store.failed_now", s.memory.used == .failed && st.dirty.contains(.used), "used=\(StateBuilder.key(s.memory.used))")
        st.clearDirty()

        // 4. staleness: > 5 s without MEM → 停滯 chip, values kept; > 10 s → every value and pressure "—"
        st.tick1Hz(now: t0.addingTimeInterval(6))
        s = st.panelState(now: t0.addingTimeInterval(6))
        expect("store.stale_chip", s.sampleStale && s.memory.physical == .text("24.00 GB") && st.dirty.contains(.clock))
        st.clearDirty()
        st.tick1Hz(now: t0.addingTimeInterval(11))
        s = st.panelState(now: t0.addingTimeInterval(11))
        expect("store.stale_blank", s.sampleStale && s.memory.physical == .failed && s.memory.pressurePercent == nil && st.dirty.contains(.sec0))
        st.clearDirty()
        st.apply(sample(seq: 4, t: t0.addingTimeInterval(11.25)), now: t0.addingTimeInterval(11.25))
        s = st.panelState(now: t0.addingTimeInterval(11.25))
        expect("store.stale_recover", !s.sampleStale && s.memory.physical == .text("24.00 GB"))
        st.clearDirty()

        // 5. history: one point per closed second; graph dirty on every tick; coverage label from start time
        expect("store.history", st.historyPoints.count >= 1 && st.dirty.isEmpty, "points=\(st.historyPoints.count)")
        st.tick1Hz(now: t0.addingTimeInterval(12.05))
        expect("store.graph_tick", st.dirty.contains(.graph))
        s = st.panelState(now: t0.addingTimeInterval(125))
        expect("store.coverage", s.historyCoverage == 125 && StateBuilder.axisLabel(s.historyCoverage) == "收集中 2/10 分鐘",
               "\(s.historyCoverage)")
        expect("store.coverage_cap", st.panelState(now: t0.addingTimeInterval(5000)).historyCoverage == 900)
        st.clearDirty()

        // 6. simulation badge on → full redraw (frame); text change → sim region only; off → full redraw
        st.setSimulation(badge: "模擬中：交換檔 讀取失敗", now: t0.addingTimeInterval(12.1))
        expect("store.sim_on_full", Set(Region.allCases).isSubset(of: st.dirty))
        st.clearDirty()
        st.setSimulation(badge: "模擬中：壓力 嚴重 90%", now: t0.addingTimeInterval(12.2))
        expect("store.sim_text", st.dirty == [.sim], "\(st.dirty.map(\.rawValue).sorted())")
        st.clearDirty()
        st.setSimulation(badge: nil, now: t0.addingTimeInterval(12.3))
        expect("store.sim_off_full", Set(Region.allCases).isSubset(of: st.dirty))
        st.clearDirty()

        // 7. battery: groups → battery dirty; paging rotates AirPods every pageSeconds, HID pinned
        st.applyBattery([kb(100), pods("A", 90), pods("B", 80)], now: t0.addingTimeInterval(13))
        s = st.panelState(now: t0.addingTimeInterval(13))
        expect("store.battery_dirty", st.dirty.contains(.battery) && StateBuilder.dspBattery(s) == "kb:100 pods[A] L:90 R:U C:40c",
               StateBuilder.dspBattery(s))
        st.clearDirty()
        st.tick1Hz(now: t0.addingTimeInterval(20))
        expect("store.page_hold", st.panelState(now: t0.addingTimeInterval(20)).batteryPage == 0)
        st.tick1Hz(now: t0.addingTimeInterval(21.1))
        s = st.panelState(now: t0.addingTimeInterval(21.1))
        expect("store.page_flip", s.batteryPage == 1 && st.dirty.contains(.battery) && StateBuilder.dspBattery(s) == "kb:100 pods[B] L:80 R:U C:40c",
               "page=\(s.batteryPage) \(StateBuilder.dspBattery(s))")
        st.clearDirty()
        st.applyBattery([kb(99)], now: t0.addingTimeInterval(22))
        s = st.panelState(now: t0.addingTimeInterval(22))
        expect("store.page_clamp", s.batteryPage == 0 && StateBuilder.dspBattery(s) == "kb:99", StateBuilder.dspBattery(s))
        st.clearDirty()
        st.applyBattery([kb(99, connected: false)], now: t0.addingTimeInterval(23))
        expect("store.offline_token", StateBuilder.dspBattery(st.panelState(now: t0.addingTimeInterval(23))) == "kb:off")
        st.applyBattery([], now: t0.addingTimeInterval(24))
        expect("store.nodev_token", StateBuilder.dspBattery(st.panelState(now: t0.addingTimeInterval(24))) == "none")

        // 8. simulated pressure sample → pressureSimulated, history point flagged
        st.apply(sample(seq: 5, t: t0.addingTimeInterval(30), pct: 92, level: .critical, simulated: true), now: t0.addingTimeInterval(30))
        st.tick1Hz(now: t0.addingTimeInterval(31.05))
        s = st.panelState(now: t0.addingTimeInterval(31.05))
        expect("store.sim_pressure", s.memory.pressureSimulated && s.memory.pressureLevel == .critical
               && (s.history.last?.simulated ?? false) && s.history.last?.percent == 92)

        // 10. app-mode 1 Hz tick grid (monotonic one-shot, re-armed per tick): +30 ms after each wall second; an early
        //     fire never repeats a second; late → skip missed; a clock step back re-grids at once (no D-second stall)
        let a = AppController.nextTick(now: 1000.5, lastBoundary: 0)
        let b = AppController.nextTick(now: 1001.031, lastBoundary: a.boundary)
        let early = AppController.nextTick(now: 1001.99, lastBoundary: 1002)
        let back = AppController.nextTick(now: 942.04, lastBoundary: 1003)
        let late = AppController.nextTick(now: 1004.5, lastBoundary: 1002)
        expect("tick.grid", a.boundary == 1001 && abs(a.delay - 0.53) < 1e-6 && b.boundary == 1002 && abs(b.delay - 0.999) < 1e-6
               && early.boundary == 1003 && !early.steppedBack && late.boundary == 1005 && !late.steppedBack
               && back.steppedBack && back.boundary == 943 && back.delay < 1.0,
               "\([a, b, early, back, late].map { "\($0.boundary)/\(String(format: "%.3f", $0.delay))/\($0.steppedBack)" })")

        // 11. OPS-5 two agreeing checks: a suspect left by an ended phase (reset on phase change) never confirms a later
        //     single observation
        var loss = ScreenLossConfirm()
        let l1 = loss.observeLost(t0)
        loss.reset()
        let l2 = loss.observeLost(t0.addingTimeInterval(3600))
        let l3 = loss.observeLost(t0.addingTimeInterval(3601.5))
        let l4 = loss.observeLost(t0.addingTimeInterval(3700)), ok4 = loss.observeOK(), ok5 = loss.observeOK()
        expect("screen_loss.confirm", !l1 && !l2 && l3 && !l4 && ok4 && !ok5 && loss.since == nil, "\([l1, l2, l3, l4, ok4, ok5])")

        // 12. focus: handed back only after a panel-started entry; the panel being frontmost keeps the earlier app
        let me: pid_t = 4242
        expect("focus.rules", AppController.restoresFocus(entryPhase: .enteringFS) && !AppController.restoresFocus(entryPhase: .windowed)
               && AppController.previousApp(front: "panel", frontPID: me, kept: "Safari", own: me) == "Safari"
               && AppController.previousApp(front: "Terminal", frontPID: 77, kept: "Safari", own: me) == "Terminal"
               && AppController.previousApp(front: nil as String?, frontPID: nil, kept: "Safari", own: me) == "Safari"
               && AppController.previousApp(front: "panel", frontPID: me, kept: nil as String?, own: me) == nil)

        // 13. pid file: launch refuses only for another LIVE WokyisPanel; exit empties the file only while it is ours
        let named: (String?) -> (pid_t) -> String? = { n in { _ in n } }
        expect("pidfile.rules", AppController.otherLivePanel(content: "456\n", own: me, name: named("WokyisPanel")) == 456
               && AppController.otherLivePanel(content: "456\n", own: me, name: named("launchd")) == nil
               && AppController.otherLivePanel(content: "456\n", own: me, name: named(nil)) == nil
               && AppController.otherLivePanel(content: "4242\n", own: me, name: named("WokyisPanel")) == nil
               && AppController.otherLivePanel(content: "", own: me, name: named("WokyisPanel")) == nil
               && AppController.pidFileOwned(content: "4242\n", own: me) && !AppController.pidFileOwned(content: "456\n", own: me)
               && !AppController.pidFileOwned(content: "", own: me)
               && AppController.processName(getpid()) != nil && AppController.processName(Int32.max - 7) == nil)

        // 14. auto-recovery decision (AppController.autoRecoverDecision, pure): every branch
        func ar(_ phase: AppController.Phase, _ reason: String = "display_changed", windowed: Bool = false, fs: Int = 0,
                present: Bool = true, stable: Double = 3.2, attempts: [Double] = [], enabled: Bool = true,
                stableS: Double = 3, now: Double = 10_000) -> AppController.AutoRecoverDecision {
            AppController.autoRecoverDecision(phase: phase, lastCloseReason: reason, userWindowed: windowed, fsFailures: fs,
                                              wokyisPresent: present, stableFor: stable, recentAttempts: attempts, now: now,
                                              enabled: enabled, stableSeconds: stableS)
        }
        func arExpect(_ name: String, _ d: AppController.AutoRecoverDecision, _ action: AppController.AutoRecoverDecision.Action,
                      _ reason: String? = nil, schedule: Bool? = nil) {
            expect("auto_recover.\(name)", d.action == action && (reason == nil || d.reason == reason) && (schedule == nil || d.schedule == schedule),
                   "\(d.action.rawValue)/\(d.reason)/\(d.waitS.map { String(format: "%.2f", $0) } ?? "-")")
        }
        let mono0 = 10_000.0                       // monotonic seconds (AppController.monoNow), synthetic
        let ago: (Double) -> Double = { mono0 - $0 }
        arExpect("display_changed_stable", ar(.waitingForUser), .recover, "stable", schedule: true)
        let un = ar(.waitingForUser, stable: 1.5)
        arExpect("unstable_wait", un, .wait, "unstable", schedule: true)
        expect("auto_recover.unstable_wait_s", abs((un.waitS ?? -1) - 1.5) < 1e-9, "\(un.waitS ?? -1)")
        arExpect("no_wokyis_wait", ar(.waitingForUser, present: false, stable: 60), .wait, "no_wokyis", schedule: false)
        arExpect("start_waiting_for_display", ar(.waitingForDisplay, "start"), .recover, "stable", schedule: true)
        arExpect("display_missing_unstable", ar(.waitingForDisplay, "start", stable: 0.2), .wait, "unstable", schedule: true)
        for r in ["moved_off_wokyis", "created_off_wokyis", "windowed_off_wokyis", "fs_verify_failed_off_wokyis"] {
            arExpect("eligible.\(r)", ar(.waitingForUser, r), .recover, "stable")
        }
        arExpect("fs_verify_size_never", ar(.waitingForUser, "fs_verify_failed_size_scale"), .never, "close_fs_verify_failed_size_scale", schedule: false)
        arExpect("windowed_phase_never", ar(.windowed), .never, "phase_windowed", schedule: false)
        arExpect("user_left_fs_never", ar(.waitingForUser, windowed: true), .never, "user_left_fs")
        arExpect("exiting_never", ar(.exiting), .never, "phase_exiting")
        arExpect("in_flight_never", ar(.creating), .never, "phase_creating")
        arExpect("entering_never", ar(.enteringFS), .never, "phase_enteringFS")
        arExpect("running_never", ar(.running), .never, "phase_running")
        arExpect("fs_failed_3_never", ar(.waitingForUser, "fs_failed", fs: 3), .never, "fs_failed_manual")
        arExpect("fs_failed_3_display_never", ar(.waitingForDisplay, "start", fs: 3), .never, "fs_failed_manual")
        arExpect("fs_retry_pending_never", ar(.waitingForUser, "fs_failed", fs: 1), .never, "fs_retry_pending")
        arExpect("disabled_never", ar(.waitingForUser, enabled: false), .never, "disabled", schedule: false)
        arExpect("limit", ar(.waitingForUser, attempts: [ago(500), ago(300), ago(10)]), .limit, "auto_recover_limit", schedule: false)
        arExpect("limit_slides", ar(.waitingForUser, attempts: [ago(700), ago(300), ago(10)]), .recover, "stable")
        arExpect("below_limit", ar(.waitingForUser, attempts: [ago(300), ago(10)]), .recover, "stable")
        arExpect("custom_stable", ar(.waitingForUser, stable: 5, stableS: 7.5), .wait, "unstable")
        expect("auto_recover.window_prune", AppController.attemptsInWindow([ago(601), ago(599), ago(0)], now: mono0).count == 2)
        // SM-1: a confirm check closes the window 3.0 s after the last screen event → the stable window restarts at the
        // close (wait a full 3 s through the timer), not an immediate recover in the closing run-loop turn
        let closeStable = AppController.autoRecoverStableFor(now: mono0, lastScreenEvent: mono0 - 3.0, waitEntered: mono0, lastAttempt: nil)
        let closeD = ar(.waitingForUser, stable: closeStable)
        expect("auto_recover.close_restarts_window", closeStable == 0 && closeD.action == .wait && closeD.waitS == 3,
               "\(closeStable)/\(closeD.action.rawValue)/\(closeD.waitS ?? -1)")
        expect("auto_recover.stable_for_latest", AppController.autoRecoverStableFor(now: mono0, lastScreenEvent: mono0 - 9,
                                                                                    waitEntered: mono0 - 7, lastAttempt: mono0 - 4) == 4
               && AppController.autoRecoverStableFor(now: mono0, lastScreenEvent: mono0 - 2, waitEntered: mono0 - 7, lastAttempt: nil) == 2)
        // SM-3: the attempt window and stable window are monotonic seconds; the clock itself never goes backwards
        let m1 = AppController.monoNow(), m2 = AppController.monoNow()
        expect("auto_recover.mono_clock", m2 >= m1 && m1 > 0, "\(m1)/\(m2)")
        // F1: a second automatic attempt after a failed entry (panel frontmost) keeps the app recorded by the first
        let firstRec = AppController.previousApp(front: "Music", frontPID: 77, kept: nil as String?, own: me)
        expect("auto_recover.keeps_prev_app", AppController.previousApp(front: "panel", frontPID: me, kept: firstRec, own: me) == "Music")

        // 9. the renderer draws a Store state without layout problems
        if let (r, _) = Snapshot.renderImage(s) {
            let p = r.layoutProblems()
            expect("store.render", p.isEmpty, p.prefix(2).joined(separator: "; "))
        } else { expect("store.render", false, "no bitmap") }
        return out
    }
}
