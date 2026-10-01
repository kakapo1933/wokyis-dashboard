// AppController.swift — window / full-screen state machine (spec §9.2), NSWindowDelegate, occlusion, wiring of
// sampler / battery / store / view / signals (spec §3, §10). Owner: app agent.
//
//   waitingForDisplay ─(start / SIGUSR2, Wokyis found)→ creating ─(window.screen == Wokyis)→ enteringFS
//   enteringFS ─(didEnterFullScreen + 1280×720 @1x on the Wokyis)→ running (focus handed back to the previous app)
//   enteringFS ─(didFailToEnterFullScreen, ≤ 3 tries, 5 s apart)→ creating
//   running ─(user leaves full screen)→ windowed ─(SIGUSR2)→ enteringFS          (never re-enters on its own)
//   running/windowed ─(screen change: Wokyis gone or window.screen ≠ Wokyis)→ waitingForUser (window closed) ─(SIGUSR2)→ creating
//   waitingForDisplay / waitingForUser ─(auto-recovery: Wokyis located again, screen configuration unchanged for
//     --auto-recover-stable-seconds (3 s) since the last screen event, entering the waiting phase and the last automatic
//     attempt — monotonic clock)→ creating
//     eligible: waitingForDisplay (no Wokyis at start / display_missing / created_off_wokyis / moved_off_wokyis) and
//     waitingForUser closed by display_changed, windowed_off_wokyis or fs_verify_failed with the window off the Wokyis;
//     never: --auto-recover no, the user left full screen (windowed, or closed while windowed — until a SIGUSR2),
//     fs_failed (own 5 s retries; fsFailures ≥ 3 stays manual), any phase other than the two waiting ones (in flight /
//     running / exiting); at most 3 automatic attempts per sliding 10 min (then ERR auto_recover_limit, manual only).
//     Decision: AppController.autoRecoverDecision (pure, selftested); re-evaluated on every checkScreens, on entering a
//     waiting phase and by a one-shot timer when the stable window ends (cancelled by any new screen event; re-checks
//     the screen signature before acting). WIN event=auto_recover_scheduled stable_s= in_s= (in_s=0.00 when the window
//     had already elapsed) / auto_recover attempt=n. prevApp is kept across attempts (previousApp rule, as fs_retry).
//   any ─(SIGINT/SIGTERM/SIGHUP/Cmd+Q)→ exiting: leave full screen (≤ 2 s) → stop sources, reap children → STOP → exit 0
//   (an AppKit terminate request — Cmd+Q, quit Apple Event, logout / restart / shut down — is answered .terminateLater
//   and confirmed with reply(toApplicationShouldTerminate: true) once STOP is written, so it never cancels a logout)
// The panel never activates itself (criterion 9) and never re-enters full screen by itself after the user left it; the
// only automatic (re)entries are the start, the fs_failed retries and the auto-recovery above, each going through
// creating → enteringFS on the Wokyis (never a window on the LG). Only the App menu's Quit.
// Focus is handed back once, and only after an entry the panel started (create / SIGUSR2): a user green-button
// re-entry from windowed keeps the focus where the user put it (prevApp is one-shot).
// Single instance: launch refuses (ERR already_running, exit 1) while run/panel.pid names another live WokyisPanel;
// exit empties panel.pid only when it still holds this pid.
import AppKit

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    enum Phase: String { case waitingForDisplay, creating, enteringFS, running, windowed, waitingForUser, exiting }

    let config: Config
    let log: EventLog
    let injector: Injector
    let table: SysctlTable

    private(set) var phase: Phase = .waitingForDisplay
    private var store: Store!
    private let view = PanelView(frame: NSRect(x: 0, y: 0, width: Layout.W, height: Layout.H))
    private var window: NSWindow?
    private var wokyis: WokyisScreen?
    private var prevApp: NSRunningApplication?
    private var fsFailures = 0
    private var createGeneration = 0
    private var exitingFSForClose = false
    private var fsVerifyCause = "size_scale"

    private var sampler: MemorySampler?
    private var battery: BatteryMonitor?
    private var signals: Signals?
    private var tick: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var wsObservers: [NSObjectProtocol] = []
    private var screenCheckWork: DispatchWorkItem?
    private var screenCheckFirst: Date?
    private var loss = ScreenLossConfirm()
    private var tickBoundary: Double = 0
    private var screenSig = ""
    private var lastHist = Date.distantPast
    private var lastHealth = Date.distantPast
    private var occluded = true
    private var injectorGeneration: UInt64 = .max
    private var stopReason = ""
    private var terminatePending = false      // AppKit is waiting for reply(toApplicationShouldTerminate:)
    // auto-recovery (see header; decision in autoRecoverDecision)
    private var lastCloseReason = "start"     // why of the last closeWindow (fs_verify_failed carries _off_wokyis)
    private var userWindowed = false          // the user left full screen; cleared by SIGUSR2 / a user re-entry
    // auto-recovery times are monotonic seconds (Self.monoNow, CLOCK_MONOTONIC: immune to wall-clock steps, counts sleep)
    private var lastScreenEventAt = AppController.monoNow()   // last reconfiguration / window-screen event
    private var lastWaitEnteredAt = AppController.monoNow()   // entered waitingForUser / waitingForDisplay (close settles)
    private var autoAttempts: [Double] = []   // automatic attempts in the sliding window
    private var autoRecoverWork: DispatchWorkItem?
    private var autoNote: String?             // last never/limit reason logged in this waiting episode
    private var inShouldTerminate = false     // finishExit ran synchronously inside applicationShouldTerminate

    init(config: Config, log: EventLog, injector: Injector) {
        self.config = config; self.log = log; self.injector = injector
        self.table = SysctlTable(names: SysctlTable.standardNames, broken: Set(config.breakMIBs))
    }

    // MARK: launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = Self.livePanelPID(in: pidURL) {
            // another panel owns run/panel.pid: never take the file over (the scripts would lose that panel)
            log.event("ERR", "src=pidfile err=already_running pid=\(other) path=\(EventLog.q(pidURL.path)) action=exit")
            log.event("STOP", "reason=already_running uptime_s=0 samples=0 draws=0 sp_child_at_stop=-")
            log.flushSync()
            exit(1)
        }
        writePID(String(getpid()))
        installMenu()
        store = Store(config: config, startedAt: StartInfo.launchedAt)
        view.log = log
        view.visibleOnScreen = false

        let s = MemorySampler(hz: config.memHz, auditHz: config.auditHz, table: table, injector: injector, log: log) { [weak self] m in
            DispatchQueue.main.async { self?.onSample(m) }
        }
        let b = BatteryMonitor(config: config, injector: injector, log: log) { [weak self] g in
            DispatchQueue.main.async { self?.onGroups(g) }
        }
        sampler = s; battery = b
        s.start(); b.start()

        let sig = Signals(queue: .main) { [weak self] n in self?.onSignal(n) }
        sig.install([SIGINT, SIGTERM, SIGHUP, SIGUSR1, SIGUSR2])
        signals = sig
        if !sig.inheritedIgnored.isEmpty { log.line("HEALTH", "signals_inherited_ignored=\(sig.inheritedIgnored.map(Signals.name).joined(separator: ",")) reason=nohup") }

        startTick()
        installObservers()
        screenSig = DisplayLocator.signature()
        log.event("WIN", "event=auto_recover_config enabled=\(config.autoRecover ? 1 : 0) stable_s=\(StartInfo.fmt(config.autoRecoverStableSeconds)) "
                  + "limit=\(Self.autoRecoverLimit) window_s=\(Int(Self.autoRecoverWindow))")
        tryCreate(reason: "start")
    }

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit WokyisPanel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    /// 1 Hz tick aligned to wall-clock seconds (+30 ms, after the .000 MEM sample): history, staleness, paging, graph,
    /// SUM (stdout), HIST and HEALTH (every 60 s). One-shot MONOTONIC deadline re-armed every tick for the next wall
    /// second (MemorySampler's grid rule): a wall-clock step back cannot stall the tick for the size of the step
    /// (a walltime timer keeps its absolute wall target); a step back of > 1 s re-grids (`WARN clock_step src=tick`).
    private func startTick() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.onTick(Date())
            self.armTick()
        }
        tick = t
        armTick()
        t.resume()
    }

    static let tickOffset = 0.03

    /// Next tick: wall second `boundary`, fired at boundary + 30 ms, `delay` s from `now` (never before the last
    /// boundary + 1 s, except after a backward step, which restarts the grid from `now`).
    static func nextTick(now: Double, lastBoundary: Double) -> (boundary: Double, delay: Double, steppedBack: Bool) {
        let (b, stepped) = MemorySampler.nextBoundary(now: now - tickOffset, lastBoundary: lastBoundary, period: 1)
        return (b, max(0, b + tickOffset - now), stepped)
    }

    private func armTick() {
        guard let t = tick else { return }   // cancelled (exiting)
        let now = Date().timeIntervalSince1970
        let n = Self.nextTick(now: now, lastBoundary: tickBoundary)
        if n.steppedBack { log.event("WARN", "clock_step src=tick dir=back by_s=\(String(format: "%.3f", tickBoundary - now)) regrid=1") }
        tickBoundary = n.boundary
        t.schedule(deadline: .now() + .nanoseconds(Int((n.delay * 1e9).rounded())), repeating: .never, leeway: .milliseconds(20))
    }

    private func installObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleScreenCheck(source: "screen_params")
        })
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        let ws = NSWorkspace.shared.notificationCenter
        wsObservers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.log.event("WIN", "event=wake")
            self.sampler?.sampleNow()
            self.battery?.pollNow(reason: "wake")
        })
        wsObservers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.log.event("WIN", "event=sleep")
        })
    }

    // MARK: data flow (main)

    private func onSample(_ m: MemSample) {
        guard phase != .exiting else { return }
        let now = Date()
        store.apply(m, now: now)
        syncSimulation(now)
        push(now)
    }

    private func onGroups(_ g: [DeviceGroup]) {
        guard phase != .exiting else { return }
        let now = Date()
        store.applyBattery(g, now: now)
        push(now)
    }

    private func syncSimulation(_ now: Date) {
        let gen = injector.generation
        let badge = injector.badge
        if gen != injectorGeneration || badge != store.badge {
            injectorGeneration = gen
            store.setSimulation(badge: badge, now: now)
        }
    }

    private func push(_ now: Date) {
        guard !store.dirty.isEmpty else { return }
        view.update(store.panelState(now: now), dirty: store.dirty, memSeq: store.latest?.seq)
        store.clearDirty()
    }

    private func onTick(_ now: Date) {
        guard phase != .exiting else { return }
        if let w = window { setOcclusion(visible: w.occlusionState.contains(.visible), source: "tick") }   // safety net
        syncSimulation(now)
        store.tick1Hz(now: now)
        push(now)
        log.summary(SummaryFormat.body(sample: store.latest, groups: store.groups, sim: injector.active), at: now)
        if !EventLog.throttled(now, lastHist, 60.05) {
            lastHist = now
            let p = store.historyPoints
            let span = (p.last?.t ?? 0) - (p.first?.t ?? 0)
            let gaps = zip(p.dropFirst(), p).filter { $0.t - $1.t > 1.5 }.count
            log.line("HIST", "n=\(p.count) span_s=\(Int(span)) coverage_s=\(Int(min(now.timeIntervalSince(store.startedAt), 900))) "
                     + "gaps=\(gaps) nil_points=\(p.filter { $0.percent == nil }.count) sim_points=\(p.filter(\.simulated).count)")
        }
        if !EventLog.throttled(now, lastHealth, 60.05) {
            lastHealth = now
            let h = ProcessHealth.sample()
            let st = log.stats()
            let d = view.takeDrawStats()
            let late = sampler?.stats().lateP99Ms.map { String(format: "%.1f", $0) } ?? "-"
            log.line("HEALTH", String(format: "cpu_s=%.3f footprint_mb=%.1f rss_mb=%.1f draws=%llu draw_ms_avg=%@ timer_late_p99_ms=%@ occluded=%d log_mb=%.2f samples=%llu phase=%@",
                                      h?.cpuSeconds ?? -1, h?.footprintMB ?? -1, h?.rssMB ?? -1, d.draws,
                                      d.avgMs.map { String(format: "%.3f", $0) } ?? "-", late, occluded ? 1 : 0,
                                      Double(st.bytes) / 1_048_576, store.samples, phase.rawValue))
        }
    }

    // MARK: window lifecycle (spec §9)

    private func setPhase(_ p: Phase, _ why: String) {
        guard p != phase else { return }
        log.event("WIN", "event=phase from=\(phase.rawValue) to=\(p.rawValue) why=\(why)")
        phase = p
        loss.reset()   // a suspect from the previous phase never counts as the first of two agreeing checks
        if p == .waitingForUser || p == .waitingForDisplay {
            autoNote = nil
            lastWaitEnteredAt = Self.monoNow()   // the stable window never starts before the close it follows
            // evaluated after the current transition has finished (never re-entrantly inside closeWindow / tryCreate)
            DispatchQueue.main.async { [weak self] in self?.evaluateAutoRecover(trigger: "phase") }
        } else {
            cancelAutoRecover(reason: nil)
        }
    }

    private func winDetail() -> String {
        guard let w = window else { return "window=none" }
        let c = w.contentView?.frame.size ?? .zero
        let f = w.frame
        return "wid=\(w.windowNumber) screen=\(EventLog.q(w.screen?.localizedName ?? "nil")) id=\(w.screen.flatMap(DisplayLocator.displayID) ?? 0) "
            + "frame=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height)) content=\(Int(c.width))x\(Int(c.height)) "
            + "scale=\(StartInfo.fmt(Double(w.backingScaleFactor))) fs=\(w.styleMask.contains(.fullScreen) ? 1 : 0)"
    }

    private func windowOnWokyis() -> Bool {
        guard let w = window, let k = wokyis, let s = w.screen, let id = DisplayLocator.displayID(of: s) else { return false }
        return id == k.displayID
    }

    /// waitingForDisplay / waitingForUser → creating (start or SIGUSR2 only).
    private func tryCreate(reason: String) {
        guard phase == .waitingForDisplay || phase == .waitingForUser else { return }
        guard let k = DisplayLocator.locate(override: config.displayID) else {
            log.event("WIN", "event=display_missing reason=\(reason) override=\(config.displayID.map { String($0) } ?? "-") screens=\(EventLog.q(DisplayLocator.signature()))")
            setPhase(.waitingForDisplay, "no_wokyis")
            return
        }
        wokyis = k
        log.event("WIN", "event=display_found reason=\(reason) \(DisplayLocator.describe(k))")
        let front = NSWorkspace.shared.frontmostApplication
        prevApp = Self.previousApp(front: front, frontPID: front?.processIdentifier, kept: prevApp)   // fs_retry: panel may be frontmost
        setPhase(.creating, reason)
        createGeneration += 1
        let gen = createGeneration

        // Global AppKit coordinates, centred 800×450 on the Wokyis. NOT init(…screen:) — that makes contentRect
        // screen-relative (phase-1 incident: the window landed on the LG).
        let f = k.appKitFrame
        let content = NSRect(x: f.midX - 400, y: f.midY - 225, width: 800, height: 450)
        let w = NSWindow(contentRect: content, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.setFrame(w.frameRect(forContentRect: content), display: false)
        w.title = "WokyisPanel"
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenPrimary]
        w.backgroundColor = NSColor(cgColor: Theme.bg) ?? .black
        w.contentView = view
        w.delegate = self
        window = w
        occluded = true
        view.visibleOnScreen = false
        guard windowOnWokyis() else {
            log.event("WIN", "event=wrong_screen stage=create \(winDetail())")
            closeWindow(to: .waitingForDisplay, why: "created_off_wokyis")
            return
        }
        w.orderFrontRegardless()
        log.event("WIN", "event=window_created prev_app=\(EventLog.q(prevApp?.localizedName ?? "-")) \(winDetail())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, gen == self.createGeneration, self.phase == .creating, let w = self.window else { return }
            guard self.windowOnWokyis() else {
                self.log.event("WIN", "event=wrong_screen stage=before_fs \(self.winDetail())")
                self.closeWindow(to: .waitingForDisplay, why: "moved_off_wokyis")
                return
            }
            self.setPhase(.enteringFS, "toggle")
            self.log.event("WIN", "event=enter_fs \(self.winDetail())")
            w.toggleFullScreen(nil)
        }
    }

    /// `cause` (fs_verify_failed only): off_wokyis / size_scale — only off_wokyis is eligible for auto-recovery.
    private func closeWindow(to next: Phase, why: String, cause: String? = nil) {
        lastCloseReason = cause.map { "\(why)_\($0)" } ?? why
        if let w = window {
            w.delegate = nil
            w.orderOut(nil)
            w.contentView = nil
            w.close()
            log.event("WIN", "event=closed why=\(why)\(cause.map { " cause=\($0)" } ?? "")")
        }
        window = nil
        occluded = true
        view.visibleOnScreen = false
        setPhase(next, why)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let w = window else { return }
        let size = w.contentView?.frame.size ?? .zero
        let ok = windowOnWokyis() && size == NSSize(width: Layout.W, height: Layout.H) && w.backingScaleFactor == 1
        log.event("WIN", "event=did_enter_fs ok=\(ok ? 1 : 0) \(winDetail())")
        if phase == .exiting { finishExitSoon(); return }
        guard ok else {
            // not the Wokyis / not 1280×720 @1x → leave full screen and close; never stay on the LG
            fsVerifyCause = windowOnWokyis() ? "size_scale" : "off_wokyis"
            exitingFSForClose = true
            w.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.exitingFSForClose else { return }
                self.exitingFSForClose = false
                self.closeWindow(to: .waitingForUser, why: "fs_verify_failed", cause: self.fsVerifyCause)
            }
            return
        }
        fsFailures = 0
        userWindowed = false   // full screen again (panel entry or the user's green button)
        let entry = phase
        setPhase(.running, "did_enter_fs")
        setOcclusion(visible: w.occlusionState.contains(.visible), source: "did_enter_fs")
        store.markAll()
        push(Date())
        if Self.restoresFocus(entryPhase: entry) {
            restoreFocus()
        } else {
            prevApp = nil   // the user re-entered full screen (green button): the focus stays where the user put it
            log.event("WIN", "event=focus_restore skipped=1 reason=user_toggle from=\(entry.rawValue)")
        }
    }

    /// Focus goes back only after an entry the panel started (create / SIGUSR2 → enteringFS), never after a user toggle.
    static func restoresFocus(entryPhase: Phase) -> Bool { entryPhase == .enteringFS }

    /// The app to hand the focus back to: the frontmost app, unless that is the panel itself — then the one recorded
    /// earlier is kept (fs_retry after a failed entry, SIGUSR2 while the panel is frontmost).
    static func previousApp<A>(front: A?, frontPID: pid_t?, kept: A?, own: pid_t = getpid()) -> A? {
        (front == nil || frontPID == own) ? kept : front
    }

    private func restoreFocus() {
        defer { prevApp = nil }   // one-shot: never re-activate an app recorded hours earlier
        guard config.focusRestore, let p = prevApp, !p.isTerminated, p.processIdentifier != getpid() else {
            log.event("WIN", "event=focus_restore skipped=1 enabled=\(config.focusRestore ? 1 : 0)")
            return
        }
        let ok = p.activate()
        log.event("WIN", "event=focus_restored app=\(EventLog.q(p.localizedName ?? "?")) pid=\(p.processIdentifier) ok=\(ok ? 1 : 0)")
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fsFailures += 1
        log.event("WIN", "event=fs_failed n=\(fsFailures) \(winDetail())")
        guard phase != .exiting else { finishExitSoon(); return }
        closeWindow(to: .waitingForUser, why: "fs_failed")
        if fsFailures < 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.phase == .waitingForUser else { return }
                self.tryCreate(reason: "fs_retry_\(self.fsFailures)")
            }
        } else {
            log.event("ERR", "src=window err=fs_failed n=\(fsFailures) action=wait_for_sigusr2")
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        log.event("WIN", "event=exit_fs \(winDetail())")
        if phase == .exiting { finishExitSoon(); return }
        if exitingFSForClose {
            exitingFSForClose = false
            closeWindow(to: .waitingForUser, why: "fs_verify_failed", cause: fsVerifyCause)
            return
        }
        if phase == .running || phase == .enteringFS {
            log.event("WIN", "event=user_exit_fs")
            userWindowed = true                    // no auto-recovery until a SIGUSR2 / a user re-entry
            setPhase(.windowed, "user_exit_fs")   // never re-enter by ourselves
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let w = window else { return }
        setOcclusion(visible: w.occlusionState.contains(.visible), source: "notification")
    }

    /// Occluded: no invalidation (Store, history and log continue). Visible again: one full redraw of the current state.
    private func setOcclusion(visible vis: Bool, source: String) {
        guard let w = window, vis == occluded else { return }   // only on a change
        occluded = !vis
        view.visibleOnScreen = vis
        log.event("WIN", "event=\(vis ? "visible" : "occluded") occluded=\(vis ? 0 : 1) source=\(source) active_space=\(w.isOnActiveSpace ? 1 : 0)")
        if vis {
            store.markAll()
            push(Date())
        }
    }

    func windowDidChangeScreen(_ notification: Notification) { scheduleScreenCheck(source: "window_screen") }

    // MARK: screen changes

    /// Trailing debounce: the check runs 1.5 s after the LAST reconfiguration event of a burst (at most 5 s after the
    /// first one, so a stream of events cannot postpone it forever).
    fileprivate func scheduleScreenCheck(source: String) {
        let now = Date()
        lastScreenEventAt = Self.monoNow()          // any screen event restarts the auto-recovery stability window
        cancelAutoRecover(reason: "screen_event source=\(source)")
        if screenCheckFirst == nil { screenCheckFirst = now }
        let wait = max(0.1, min(1.5, 5.0 - now.timeIntervalSince(screenCheckFirst!)))
        screenCheckWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.screenCheckWork = nil; self.screenCheckFirst = nil
            self.checkScreens(source: source)
        }
        screenCheckWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: w)
    }

    private func checkScreens(source: String) {
        let sig = DisplayLocator.signature()
        let changed = sig != screenSig
        screenSig = sig
        if changed { log.event("WIN", "event=display_changed source=\(source) screens=\(EventLog.q(sig))") }
        defer { evaluateAutoRecover(trigger: "screen_check") }   // every check, all phases (acts only while waiting)
        guard phase == .running || phase == .windowed else { return }
        let k = DisplayLocator.locate(override: config.displayID)
        let onIt: Bool = {
            guard let k, let w = window, let s = w.screen, let id = DisplayLocator.displayID(of: s) else { return false }
            return id == k.displayID
        }()
        if k == nil || !onIt {
            // confirm with a second check ≥ 1 s later (a mid-reconfiguration snapshot must not close the window)
            guard loss.observeLost(Date()) else {
                log.event("WIN", "event=wokyis_lost_suspect wokyis=\(k.map(DisplayLocator.describe) ?? "none") \(winDetail())")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.checkScreens(source: "confirm") }
                return
            }
            log.event("WIN", "event=wokyis_lost wokyis=\(k.map(DisplayLocator.describe) ?? "none") \(winDetail())")
            if let w = window, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
            closeWindow(to: .waitingForUser, why: "display_changed")
        } else if let k {
            if loss.observeOK() { log.event("WIN", "event=wokyis_back source=\(source) \(winDetail())") }
            wokyis = k
            if changed { store.markAll(); push(Date()) }
        }
    }

    // MARK: auto-recovery (user decision 2026-10-02, incident logs/panel-20261001-145033.log 16:37)

    static let autoRecoverLimit = 3
    static let autoRecoverWindow: TimeInterval = 600
    /// waitingForUser close reasons that come from the window not being on the Wokyis (display change / moved off).
    static let autoRecoverCloseReasons: Set<String> = ["display_changed", "moved_off_wokyis", "created_off_wokyis",
                                                       "windowed_off_wokyis", "fs_verify_failed_off_wokyis"]

    struct AutoRecoverDecision: Equatable {
        enum Action: String { case never, wait, recover, limit }
        let action: Action
        let reason: String
        var waitS: Double? = nil     // .wait with a stable window to finish: seconds until it ends (nil = next screen event)
        var schedule: Bool { action == .wait && waitS != nil || action == .recover }
    }

    /// Pure auto-recovery decision. `stableFor` = autoRecoverStableFor (seconds since the last screen event, entering the
    /// waiting phase and the last automatic attempt); `recentAttempts` / `now` = monotonic seconds (monoNow; any age,
    /// only those within autoRecoverWindow count).
    static func autoRecoverDecision(phase: Phase, lastCloseReason: String, userWindowed: Bool, fsFailures: Int,
                                    wokyisPresent: Bool, stableFor: Double, recentAttempts: [Double], now: Double,
                                    enabled: Bool, stableSeconds: Double) -> AutoRecoverDecision {
        guard enabled else { return .init(action: .never, reason: "disabled") }
        guard phase == .waitingForUser || phase == .waitingForDisplay else { return .init(action: .never, reason: "phase_\(phase.rawValue)") }
        if userWindowed { return .init(action: .never, reason: "user_left_fs") }
        if fsFailures >= 3 { return .init(action: .never, reason: "fs_failed_manual") }
        if phase == .waitingForUser && !autoRecoverCloseReasons.contains(lastCloseReason) {
            return .init(action: .never, reason: lastCloseReason == "fs_failed" ? "fs_retry_pending" : "close_\(lastCloseReason)")
        }
        guard wokyisPresent else { return .init(action: .wait, reason: "no_wokyis") }
        if stableFor < stableSeconds { return .init(action: .wait, reason: "unstable", waitS: stableSeconds - stableFor) }
        if attemptsInWindow(recentAttempts, now: now).count >= autoRecoverLimit { return .init(action: .limit, reason: "auto_recover_limit") }
        return .init(action: .recover, reason: "stable")
    }

    static func attemptsInWindow(_ a: [Double], now: Double) -> [Double] {
        a.filter { now - $0 < autoRecoverWindow }
    }

    /// Stable-window length: since the latest of the last screen event, entering the waiting phase (so a close made by
    /// a confirm check that is itself ≥ stableSeconds after the last event still waits a full window and goes through the
    /// timer's signature re-check) and the last automatic attempt. All monotonic seconds.
    static func autoRecoverStableFor(now: Double, lastScreenEvent: Double, waitEntered: Double, lastAttempt: Double?) -> Double {
        now - max(lastScreenEvent, waitEntered, lastAttempt ?? -.infinity)
    }

    /// Monotonic seconds (CLOCK_MONOTONIC on macOS keeps counting while asleep and never steps with the wall clock).
    static func monoNow() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

    private func cancelAutoRecover(reason: String?) {
        guard let w = autoRecoverWork else { return }
        w.cancel(); autoRecoverWork = nil
        if let reason { log.event("WIN", "event=auto_recover_cancelled reason=\(reason)") }
    }

    private func evaluateAutoRecover(trigger: String) {
        let now = Self.monoNow()
        autoAttempts = Self.attemptsInWindow(autoAttempts, now: now)
        let present = DisplayLocator.locate(override: config.displayID) != nil
        let stableFor = Self.autoRecoverStableFor(now: now, lastScreenEvent: lastScreenEventAt, waitEntered: lastWaitEnteredAt,
                                                  lastAttempt: autoAttempts.last)
        let d = Self.autoRecoverDecision(phase: phase, lastCloseReason: lastCloseReason, userWindowed: userWindowed,
                                         fsFailures: fsFailures, wokyisPresent: present, stableFor: stableFor,
                                         recentAttempts: autoAttempts, now: now, enabled: config.autoRecover,
                                         stableSeconds: config.autoRecoverStableSeconds)
        guard phase == .waitingForUser || phase == .waitingForDisplay else { return }   // other phases: never, silent
        switch d.action {
        case .never:
            if autoNote != d.reason {
                autoNote = d.reason
                log.event("WIN", "event=auto_recover_off reason=\(d.reason) phase=\(phase.rawValue) close_reason=\(lastCloseReason)")
            }
        case .wait:
            guard let wait = d.waitS else {   // no Wokyis: the next screen event re-evaluates
                if autoNote != d.reason {
                    autoNote = d.reason
                    log.event("WIN", "event=auto_recover_wait reason=\(d.reason) phase=\(phase.rawValue) close_reason=\(lastCloseReason)")
                }
                return
            }
            guard autoRecoverWork == nil else { return }   // a pending timer re-evaluates (any screen event cancels it)
            let sig = screenSig
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.autoRecoverWork = nil
                let cur = DisplayLocator.signature()
                guard cur == sig, cur == self.screenSig else {
                    self.log.event("WIN", "event=auto_recover_cancelled reason=signature_changed screens=\(EventLog.q(cur))")
                    self.scheduleScreenCheck(source: "auto_recover")
                    return
                }
                self.evaluateAutoRecover(trigger: "timer")
            }
            autoRecoverWork = w
            log.event("WIN", "event=auto_recover_scheduled stable_s=\(StartInfo.fmt(config.autoRecoverStableSeconds)) "
                      + "in_s=\(String(format: "%.2f", wait)) phase=\(phase.rawValue) close_reason=\(lastCloseReason) trigger=\(trigger)")
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.05, execute: w)
        case .limit:
            if autoNote != d.reason {
                autoNote = d.reason
                log.event("ERR", "src=window err=auto_recover_limit n=\(autoAttempts.count) window_s=\(Int(Self.autoRecoverWindow)) action=wait_for_sigusr2")
            }
        case .recover:
            if autoRecoverWork == nil && trigger != "timer" {
                // the stable window had already elapsed at this evaluation: still log the documented scheduled line
                log.event("WIN", "event=auto_recover_scheduled stable_s=\(StartInfo.fmt(config.autoRecoverStableSeconds)) "
                          + "in_s=0.00 phase=\(phase.rawValue) close_reason=\(lastCloseReason) trigger=\(trigger)")
            }
            autoAttempts.append(now)
            log.event("WIN", "event=auto_recover attempt=\(autoAttempts.count) trigger=\(trigger) phase=\(phase.rawValue) "
                      + "close_reason=\(lastCloseReason) stable_s=\(String(format: "%.2f", stableFor))")
            // prevApp is kept: tryCreate takes the frontmost app, or keeps the one recorded before a failed entry when the
            // panel itself is frontmost (same rule as fs_retry), so the focus still goes back to the user's app once
            tryCreate(reason: "auto_recover")
        }
    }

    // MARK: signals / exit

    private func onSignal(_ n: Int32) {
        switch n {
        case SIGUSR1: snapshot()
        case SIGUSR2: fullscreenRequest()
        default: beginExit(reason: Signals.name(n))
        }
    }

    private func fullscreenRequest() {
        log.event("WIN", "event=sigusr2 phase=\(phase.rawValue)")
        userWindowed = false   // the user asked for full screen; the auto-recovery attempt count is NOT reset
        switch phase {
        case .windowed:
            guard let w = window, windowOnWokyis() else { closeWindow(to: .waitingForUser, why: "windowed_off_wokyis"); tryCreate(reason: "sigusr2"); return }
            let front = NSWorkspace.shared.frontmostApplication
            prevApp = Self.previousApp(front: front, frontPID: front?.processIdentifier, kept: prevApp)
            setPhase(.enteringFS, "sigusr2")
            w.toggleFullScreen(nil)
        case .waitingForUser, .waitingForDisplay:
            fsFailures = 0
            prevApp = nil   // a new user request: only the automatic fs_retry keeps the app recorded before a failed entry
            tryCreate(reason: "sigusr2")
        default: break
        }
    }

    /// SIGUSR1: offscreen render of the state that is on screen (last committed draw; the current Store state when
    /// nothing has been drawn yet or the window is occluded) + rects/perglyph/boxes/state.json in run/.
    private func snapshot() {
        let now = Date()
        let useDrawn = !occluded && view.drawnState != nil
        let s = useDrawn ? view.drawnState! : store.panelState(now: now)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss.SSS"
        let url = config.runDirURL.appendingPathComponent("snapshot-\(f.string(from: now)).png")
        do {
            let o = try Snapshot.render(s, to: url, dumpRects: true)
            log.event("SNAP", "path=\(EventLog.q(url.path)) source=\(useDrawn ? "drawn" : "store") dsp_seq=\(view.dspSeq) mem_seq=\((useDrawn ? view.drawnMemSeq : store.latest?.seq).map { String($0) } ?? "-") layout_problems=\(o.layoutProblems.count)")
        } catch {
            log.event("ERR", "src=snapshot err=\(EventLog.q("\(error)"))")
        }
    }

    /// Cmd+Q, quit Apple Event, logout / restart / shut down: never cancel (a cancel aborts the user's logout).
    /// .terminateLater while full screen is left (≤ 2 s) and sources are stopped; finishExit then replies true.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if finished { return .terminateNow }
        terminatePending = true
        inShouldTerminate = true
        beginExit(reason: "quit")          // no-op when already exiting (signal); finishExit may run synchronously
        inShouldTerminate = false
        return finished ? .terminateNow : .terminateLater
    }

    private func beginExit(reason: String) {
        guard phase != .exiting else { return }
        stopReason = reason
        log.event("WIN", "event=exiting reason=\(reason) \(winDetail())")
        setPhase(.exiting, reason)
        tick?.cancel(); tick = nil
        if let w = window, w.styleMask.contains(.fullScreen) {
            w.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.finishExit() }   // ≤ 2 s
        } else {
            finishExit()
        }
    }

    private func finishExitSoon() {
        DispatchQueue.main.async { [weak self] in self?.finishExit() }
    }

    private var finished = false
    private func finishExit() {
        guard !finished else { return }
        finished = true
        if let w = window { w.delegate = nil; w.orderOut(nil); w.close() }
        window = nil
        sampler?.stop()
        let child = battery?.childPID
        battery?.stop()                   // kills and reaps a running system_profiler
        injector.stop()
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        wsObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        releasePID()
        log.event("STOP", "reason=\(stopReason) uptime_s=\(Int(Date().timeIntervalSince(StartInfo.launchedAt))) samples=\(store?.samples ?? 0) "
                  + "draws=\(view.draws) sp_child_at_stop=\(child.map { String($0) } ?? "-")")
        log.flushSync()
        if terminatePending {
            // AppKit terminates the process itself (applicationWillTerminate → exit) once it has the answer
            if !inShouldTerminate { NSApp.reply(toApplicationShouldTerminate: true) }
            return
        }
        exit(0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !finished { stopReason = stopReason.isEmpty ? "terminate" : stopReason; finishExit() }
    }

    private var pidURL: URL { config.runDirURL.appendingPathComponent("panel.pid") }

    /// Empties run/panel.pid only while it still names this process (never another panel's file).
    private func releasePID() {
        let content = (try? String(contentsOf: pidURL, encoding: .utf8)) ?? ""
        if Self.pidFileOwned(content: content) { writePID("") }
        else { log.event("WARN", "pidfile_kept content=\(EventLog.q(content.trimmingCharacters(in: .whitespacesAndNewlines))) own=\(getpid())") }
    }

    static func pidFileOwned(content: String, own: pid_t = getpid()) -> Bool {
        pid_t(content.trimmingCharacters(in: .whitespacesAndNewlines)) == own
    }

    /// The pid in run/panel.pid when it names a live WokyisPanel other than this process (stale pid / reused pid → nil).
    static func livePanelPID(in url: URL, own: pid_t = getpid(),
                             name: (pid_t) -> String? = AppController.processName) -> pid_t? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return otherLivePanel(content: s, own: own, name: name)
    }
    static func otherLivePanel(content: String, own: pid_t, name: (pid_t) -> String?) -> pid_t? {
        guard let p = pid_t(content.trimmingCharacters(in: .whitespacesAndNewlines)), p > 0, p != own else { return nil }
        return name(p) == "WokyisPanel" ? p : nil
    }
    /// Short process name (comm) of a live pid, nil when there is no such process.
    static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    private func writePID(_ s: String) {
        let url = pidURL
        do {
            try FileManager.default.createDirectory(at: config.runDirURL, withIntermediateDirectories: true)
            try (s.isEmpty ? "" : s + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log.event("ERR", "src=pidfile err=\(EventLog.q("\(error)"))")
        }
    }
}

/// OPS-5 two-observation rule for "window no longer on the Wokyis": the first lost observation is only a suspect; a
/// second one ≥ 1 s later confirms. Reset on every phase change, so a suspect left behind by a phase that ended
/// (SIGUSR2 re-create, exit) can never turn a later single transient observation into a close.
struct ScreenLossConfirm {
    private(set) var since: Date?
    /// A lost observation; true = confirmed (an earlier suspect ≥ 1 s ago), false = suspect (schedule a confirm).
    mutating func observeLost(_ now: Date) -> Bool {
        if let s = since, now.timeIntervalSince(s) >= 1.0 { since = nil; return true }
        if since == nil { since = now }
        return false
    }
    /// The window is on the Wokyis; true when this clears a pending suspect.
    mutating func observeOK() -> Bool { defer { since = nil }; return since != nil }
    mutating func reset() { since = nil }
}

/// CGDisplayRegisterReconfigurationCallback → debounced screen check on main.
private func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ user: UnsafeMutableRawPointer?) {
    guard let user, !flags.contains(.beginConfigurationFlag) else { return }
    let c = Unmanaged<AppController>.fromOpaque(user).takeUnretainedValue()
    DispatchQueue.main.async { c.scheduleScreenCheck(source: "cg_reconfig") }
}
