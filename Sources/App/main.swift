// main.swift — argument parsing and mode dispatch (spec §10 + D4/D5).
//   --selftest            → SelfTest.runAll, exit 0/1
//   --snapshot OUT.png    → offscreen render, exit (no window, no NSApplication)
//   --headless            → Headless.run (no NSApplication, no Dock icon)
//   (default)             → NSApplication (.regular), beginActivity, AppController
// Owner: app agent (initial version by the skeleton step).
import AppKit

_ = StartInfo.launchedAt
signal(SIGPIPE, SIG_IGN)   // stdout may be a pipe whose reader goes away; never die on write

let config: Config
do {
    config = try Config.parse(Array(CommandLine.arguments.dropFirst())).resolvingDirs()   // dirs fixed for the whole run
} catch let e as Config.ParseError {
    if e.description == "help" { print(Config.usage); exit(0) }
    FileHandle.standardError.write(Data("WokyisPanel: \(e.description)\n\(Config.usage)\n".utf8))
    exit(64)
} catch {
    FileHandle.standardError.write(Data("WokyisPanel: \(error)\n".utf8))
    exit(64)
}

switch config.mode {
case .selftest:
    exit(SelfTest.runAll(config: config) ? 0 : 1)
case .snapshot:
    exit(Snapshot.runOffscreen(config: config))
case .headless:
    Headless.run(config: config)
case .app:
    // one panel per user, decided before the log opens: a refused copy must not move current.log
    let lock = InstanceLock.acquire()
    let log: EventLog
    do {
        log = try EventLog(dir: config.logDirURL, level: config.logLevel, summarySeconds: config.summarySeconds,
                           linkCurrent: lock != .busy, retentionDays: config.logRetentionDays, maxBytes: config.logMaxBytes)
    } catch {
        FileHandle.standardError.write(Data("WokyisPanel: cannot open log dir \(config.logDirURL.path): \(error)\n".utf8))
        exit(73)
    }
    let injector = Injector(runDir: config.runDirURL, log: log)
    log.simActive = { injector.active }
    let quick = SelfTest.runQuick()
    let table = SysctlTable(names: SysctlTable.standardNames, broken: Set(config.breakMIBs))
    // v2 settings (spec §7): defaults < UserDefaults < this run's CLI; only the app mode reads / writes UserDefaults
    let settingsStore = DefaultsSettingsStore()
    let (stored, settingsWarnings) = settingsStore.load()
    let settings = SettingsModel(stored: stored, cli: config.cliLayer, store: settingsStore)
    log.event("START", StartInfo.startBody(config: config, mode: .app, selftest: quick.ok ? "ok" : "fail:" + quick.failed.joined(separator: ","),
                                           mibs: "\(table.resolvedCount)/\(table.names.count)", ui: settings)
              + " log=\(EventLog.q(log.currentFile.path))")
    for w in settingsWarnings { log.event("WARN", "settings_invalid \(w) domain=\(DefaultsSettingsStore.domain)") }
    switch lock {
    case .busy:
        // another copy (the checkout's build or an installed app) drives the Wokyis; name it when LaunchServices knows it
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "-")
            .map { (pid: $0.processIdentifier, terminated: $0.isTerminated, path: $0.bundleURL?.path) }
        let other = AppController.otherInstance(own: getpid(), copies: copies)
        log.event("ERR", "src=instance err=already_running pid=\(other.map { String($0.pid) } ?? "-") path=\(EventLog.q(other?.path ?? "-")) "
                  + "lock=\(EventLog.q(InstanceLock.path)) action=exit")
        log.event("STOP", "reason=already_running uptime_s=0 samples=0 draws=0 sp_child_at_stop=-")
        log.flushSync()
        exit(1)
    case .unavailable(let e):
        log.event("WARN", "src=instance lock_unavailable errno=\(e) path=\(EventLog.q(InstanceLock.path)) action=continue")
    case .acquired:
        break
    }
    injector.start()
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    // App Nap off (spec §3). `.latencyCritical` in addition: without it a background .regular app (window occluded /
    // not frontmost) had its 250 ms wall-clock timer coalesced by up to ~150 ms after the first minute (measured,
    // windowless app-mode run 2026-10-01: lateness p99 10 ms → 149 ms); WOKYIS_ACTIVITY=plain drops it for comparison.
    var activityOptions: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep
    if ProcessInfo.processInfo.environment["WOKYIS_ACTIVITY"] != "plain" { activityOptions.insert(.latencyCritical) }
    let activity = ProcessInfo.processInfo.beginActivity(options: activityOptions,
                                                         reason: "Wokyis panel: continuous memory / battery sampling")
    log.line("HEALTH", "activity_options=0x\(String(activityOptions.rawValue, radix: 16)) latency_critical=\(activityOptions.contains(.latencyCritical) ? 1 : 0)")
    let controller = AppController(config: config, log: log, injector: injector, settings: settings)
    app.delegate = controller
    withExtendedLifetime((controller, activity, lock)) { app.run() }
    log.flushSync()
    exit(0)
}
