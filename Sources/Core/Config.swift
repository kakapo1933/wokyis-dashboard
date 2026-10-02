// Config.swift — every command-line flag of spec §10 plus lead decisions D4 (log level) and D5 (headless).
// Owner: core. Parsing is pure (no side effects) so --selftest can exercise it.
import Foundation

enum LogLevel: String, Sendable { case summary, sample }

struct Config: Sendable, Equatable {
    var logDir = "logs"
    var runDir = "run"
    var memHz = 4.0                 // 1…10
    var auditHz = 0.2               // 0 = off; ≤ memHz
    var spPeriod = 20.0             // seconds, ≥ 5
    var spPath = "/usr/sbin/system_profiler"
    var breakMIBs: [String] = []    // --break-mib (repeatable)
    var displayID: UInt32? = nil
    var focusRestore = true         // --no-focus-restore → false
    var autoRecover = true          // --auto-recover yes|no: re-create the window when the Wokyis comes back (AppController)
    var autoRecoverStableSeconds = 3.0   // --auto-recover-stable-seconds S (0.5…60): screen config unchanged this long first
    var hidTrustNotify = false      // --hid-trust-notify yes|no (default no)
    var offlineGrace = 600.0        // seconds
    var nearbyFreshSeconds = 300.0  // 「附近」: an IOPS change seen within this many seconds is fresh evidence; 0 = no nearby state
    var pageSeconds = 8.0           // AirPods page rotation
    var selftest = false
    var snapshotOut: String? = nil  // --snapshot OUT.png (offscreen render, no window)
    var dumpRects = false           // --dump-rects (with --snapshot)
    var logLevel: LogLevel = .summary   // D4
    var summarySeconds = 10.0       // D4: stdout SUM period and summary-level MEM decimation period
    var headless = false            // D5
    var duration: Double? = nil     // D5: headless run length (seconds); nil = until SIGINT/SIGTERM
    var args: [String] = []         // raw argv (without argv[0]) for the START line
    // v2 (spec §7): this run's UI overrides — never written to UserDefaults
    var view: ViewKind? = nil        // --view memory|cpu|network
    var battery: Bool? = nil         // --battery yes|no
    var lang: LanguagePref? = nil    // --lang zh|en|system
    var hotkeys = true               // --hotkeys yes|no (Carbon ⌃⌥⌘ M/P/N/V/B/L)
    var memDisplayHz = 2.0           // --mem-display-hz 4|2|1: memory values redrawn at most this often (L3, spec §11.3; default 2
                                     // since the 2026-10-02 budget run: 4 Hz measured 2.092 % once on memory/en/battery off)

    /// The CLI settings layer (spec §7).
    var cliLayer: SettingsLayer { SettingsLayer(view: view, batteryVisible: battery, language: lang) }

    enum Mode: String, Sendable { case app, headless, selftest, snapshot }
    var mode: Mode {
        if selftest { return .selftest }
        if snapshotOut != nil { return .snapshot }
        if headless { return .headless }
        return .app
    }

    struct ParseError: Error, CustomStringConvertible, Equatable { let description: String }

    static let usage = """
    usage: WokyisPanel [options]
      --log-dir DIR            log directory (default logs)
      --run-dir DIR            run directory: control.json, panel.pid, snapshots (default run)
      --mem-hz N               memory sample rate 1…10 Hz (default 4)
      --audit-hz X             host_statistics64 audit rate, 0 = off (default 0.2, ≤ mem-hz)
      --sp-period S            system_profiler period in seconds, ≥ 5 (default 20)
      --sp-path PATH           system_profiler binary (default /usr/sbin/system_profiler)
      --break-mib NAME         resolve this sysctl as "bogus.NAME" (real failure; repeatable)
      --display-id N           force the Wokyis CGDirectDisplayID
      --no-focus-restore       do not re-activate the previous frontmost app after entering full screen
      --auto-recover yes|no    re-create the window by itself when the Wokyis comes back after it vanished / the window
                               was closed off the Wokyis (≤ 3 tries per 10 min; never after the user left full screen)
                               (default yes)
      --auto-recover-stable-seconds S  screen configuration unchanged (Wokyis present) this long first, 0.5…60 (default 3)
      --hid-trust-notify yes|no  trust IOKit terminated notifications for HID connectivity (default no)
      --offline-grace S        seconds an offline device stays listed (default 600)
      --nearby-fresh-seconds N AirPods not connected to this Mac are shown grey as 「附近」 while the panel saw their IOPS
                               values change within N s (or the case's BLE link is connected); 0 disables (default 300)
      --page-seconds S         AirPods page rotation in seconds (default 8)
      --log-level summary|sample  log volume (default summary; see README)
      --summary-seconds N      stdout SUM period and summary-level MEM decimation (default 10)
      --headless [--duration S]  sampling + injector + logging + audit without any window; exits after S s or on SIGINT/SIGTERM
      --selftest               run built-in self tests and exit (0 = pass)
      --snapshot OUT.png [--dump-rects] [--view V] [--lang L] [--battery yes|no]  offscreen render once (no window) and exit
      --view memory|cpu|network  this run's view (overrides the saved setting; never saved)
      --battery yes|no         this run's Bluetooth battery column (never saved)
      --lang zh|en|system      this run's language (never saved; system = first preferred language zh… → zh, else en)
      --hotkeys yes|no         register the global ⌃⌥⌘ M/P/N/V/B/L hot keys (default yes)
      --mem-display-hz 4|2|1   memory values redrawn at most this often (default 2); sampling stays --mem-hz
    """

    static func parse(_ argv: [String]) throws -> Config {
        var c = Config(); c.args = argv
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < argv.count, !argv[i].hasPrefix("--") || Double(argv[i]) != nil else { throw ParseError(description: "\(flag) needs a value") }
            return argv[i]
        }
        func number(_ flag: String, _ range: ClosedRange<Double>) throws -> Double {
            let s = try value(flag)
            guard let d = Double(s), d.isFinite, range.contains(d) else {
                throw ParseError(description: "\(flag) \(s): expected a number in \(range.lowerBound)…\(range.upperBound)")
            }
            return d
        }
        while i < argv.count {
            let a = argv[i]
            switch a {
            case "--log-dir": c.logDir = try value(a)
            case "--run-dir": c.runDir = try value(a)
            case "--mem-hz": c.memHz = try number(a, 1...10)
            case "--audit-hz": c.auditHz = try number(a, 0...10)
            case "--sp-period": c.spPeriod = try number(a, 5...3600)
            case "--sp-path": c.spPath = try value(a)
            case "--break-mib":
                let n = try value(a)
                guard !n.isEmpty else { throw ParseError(description: "--break-mib needs a sysctl name") }
                c.breakMIBs.append(n)
            case "--display-id":
                let s = try value(a)
                guard let n = UInt32(s) else { throw ParseError(description: "--display-id \(s): expected an unsigned integer") }
                c.displayID = n
            case "--no-focus-restore": c.focusRestore = false
            case "--auto-recover":
                switch try value(a) {
                case "yes": c.autoRecover = true
                case "no": c.autoRecover = false
                case let s: throw ParseError(description: "--auto-recover \(s): expected yes|no")
                }
            case "--auto-recover-stable-seconds": c.autoRecoverStableSeconds = try number(a, 0.5...60)
            case "--hid-trust-notify":
                switch try value(a) {
                case "yes": c.hidTrustNotify = true
                case "no": c.hidTrustNotify = false
                case let s: throw ParseError(description: "--hid-trust-notify \(s): expected yes|no")
                }
            case "--offline-grace": c.offlineGrace = try number(a, 0...86_400)
            case "--nearby-fresh-seconds": c.nearbyFreshSeconds = try number(a, 0...86_400)
            case "--page-seconds": c.pageSeconds = try number(a, 1...3600)
            case "--log-level":
                let s = try value(a)
                guard let l = LogLevel(rawValue: s) else { throw ParseError(description: "--log-level \(s): expected summary|sample") }
                c.logLevel = l
            case "--summary-seconds": c.summarySeconds = try number(a, 1...3600)
            case "--headless": c.headless = true
            case "--duration": c.duration = try number(a, 0.1...(30 * 86_400))
            case "--selftest": c.selftest = true
            case "--snapshot": c.snapshotOut = try value(a)
            case "--dump-rects": c.dumpRects = true
            case "--view":
                let v = try value(a)
                guard let k = ViewKind(rawValue: v) else { throw ParseError(description: "--view \(v): expected memory|cpu|network") }
                c.view = k
            case "--battery":
                switch try value(a) {
                case "yes": c.battery = true
                case "no": c.battery = false
                case let s: throw ParseError(description: "--battery \(s): expected yes|no")
                }
            case "--lang":
                let v = try value(a)
                guard let l = LanguagePref(rawValue: v) else { throw ParseError(description: "--lang \(v): expected zh|en|system") }
                c.lang = l
            case "--hotkeys":
                switch try value(a) {
                case "yes": c.hotkeys = true
                case "no": c.hotkeys = false
                case let s: throw ParseError(description: "--hotkeys \(s): expected yes|no")
                }
            case "--mem-display-hz":
                let v = try value(a)
                guard let d = Double(v), [1.0, 2.0, 4.0].contains(d) else { throw ParseError(description: "--mem-display-hz \(v): expected 4|2|1") }
                c.memDisplayHz = d
            case "-h", "--help": throw ParseError(description: "help")
            default:
                // LaunchServices may pass -psn_… when started via `open`; ignore it.
                if a.hasPrefix("-psn_") { break }
                // NSUserDefaults-style "-Key value" pairs from `open --args` are not used; reject unknown flags explicitly.
                throw ParseError(description: "unknown argument \(a)")
            }
            i += 1
        }
        if c.auditHz > c.memHz { throw ParseError(description: "--audit-hz \(c.auditHz) must be ≤ --mem-hz \(c.memHz)") }
        if c.duration != nil && !c.headless { throw ParseError(description: "--duration is only valid with --headless") }
        if c.dumpRects && c.snapshotOut == nil { throw ParseError(description: "--dump-rects needs --snapshot OUT.png") }
        return c
    }

    /// Log-dir / run-dir: absolute paths as given; relative paths against the current directory — except when the
    /// current directory is "/" (LaunchServices `open build/WokyisPanel.app`), where they resolve against the project
    /// root inferred from the bundle (<root>/build/WokyisPanel.app).
    var logDirURL: URL { Config.resolve(logDir) }
    var runDirURL: URL { Config.resolve(runDir) }
    static func resolve(_ p: String) -> URL {
        if p.hasPrefix("/") { return URL(fileURLWithPath: p, isDirectory: true).standardizedFileURL }
        let cwd = FileManager.default.currentDirectoryPath
        let base: URL
        if cwd == "/" && Bundle.main.bundleURL.pathExtension == "app" {
            base = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        } else {
            base = URL(fileURLWithPath: cwd, isDirectory: true)
        }
        return base.appendingPathComponent(p, isDirectory: true).standardizedFileURL
    }

    /// For the START line.
    var argsQuoted: String { args.joined(separator: " ").replacingOccurrences(of: "\"", with: "'") }
}

enum ConfigSelfTest {
    static func run() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        func expect(_ name: String, _ argv: [String], _ check: (Config) -> Bool) {
            do { let c = try Config.parse(argv); out.append(SelfTestCase("config.\(name)", check(c))) }
            catch { out.append(SelfTestCase("config.\(name)", false, "\(error)")) }
        }
        func reject(_ name: String, _ argv: [String]) {
            do { _ = try Config.parse(argv); out.append(SelfTestCase("config.reject.\(name)", false, "accepted \(argv)")) }
            catch { out.append(SelfTestCase("config.reject.\(name)", true)) }
        }
        expect("defaults", []) { c in
            c.logDir == "logs" && c.runDir == "run" && c.memHz == 4 && c.auditHz == 0.2 && c.spPeriod == 20
                && c.spPath == "/usr/sbin/system_profiler" && c.breakMIBs.isEmpty && c.displayID == nil && c.focusRestore
                && !c.hidTrustNotify && c.offlineGrace == 600 && c.nearbyFreshSeconds == 300 && c.pageSeconds == 8 && c.logLevel == .summary
                && c.summarySeconds == 10 && c.mode == .app && c.autoRecover && c.autoRecoverStableSeconds == 3
        }
        expect("all", ["--log-dir", "L", "--run-dir", "R", "--mem-hz", "2", "--audit-hz", "1", "--sp-period", "30",
                       "--sp-path", "/nonexistent/system_profiler", "--break-mib", "vm.swapusage", "--break-mib", "hw.memsize",
                       "--display-id", "2", "--no-focus-restore", "--hid-trust-notify", "yes", "--offline-grace", "120",
                       "--page-seconds", "5", "--log-level", "sample", "--summary-seconds", "1", "--headless", "--duration", "300",
                       "--nearby-fresh-seconds", "0", "--auto-recover", "no", "--auto-recover-stable-seconds", "7.5"]) { c in
            c.logDir == "L" && c.runDir == "R" && c.memHz == 2 && c.auditHz == 1 && c.spPeriod == 30
                && c.spPath == "/nonexistent/system_profiler" && c.breakMIBs == ["vm.swapusage", "hw.memsize"] && c.displayID == 2
                && !c.focusRestore && c.hidTrustNotify && c.offlineGrace == 120 && c.nearbyFreshSeconds == 0 && c.pageSeconds == 5 && c.logLevel == .sample
                && c.summarySeconds == 1 && c.headless && c.duration == 300 && c.mode == .headless
                && !c.autoRecover && c.autoRecoverStableSeconds == 7.5
        }
        expect("snapshot", ["--snapshot", "/tmp/x.png", "--dump-rects"]) { $0.mode == .snapshot && $0.dumpRects && $0.snapshotOut == "/tmp/x.png" }
        expect("selftest", ["--selftest"]) { $0.mode == .selftest }
        expect("psn", ["-psn_0_12345"]) { $0.mode == .app }
        reject("memhz", ["--mem-hz", "11"])
        reject("audit>mem", ["--mem-hz", "1", "--audit-hz", "2"])
        reject("level", ["--log-level", "verbose"])
        reject("trust", ["--hid-trust-notify", "maybe"])
        reject("nearby-negative", ["--nearby-fresh-seconds", "-1"])
        expect("auto-recover", ["--auto-recover", "yes", "--auto-recover-stable-seconds", "0.5"]) { $0.autoRecover && $0.autoRecoverStableSeconds == 0.5 }
        reject("auto-recover-value", ["--auto-recover", "maybe"])
        reject("auto-recover-stable-low", ["--auto-recover-stable-seconds", "0.4"])
        reject("auto-recover-stable-high", ["--auto-recover-stable-seconds", "61"])
        reject("auto-recover-stable-missing", ["--auto-recover-stable-seconds"])
        expect("nearby", ["--nearby-fresh-seconds", "120"]) { $0.nearbyFreshSeconds == 120 }
        reject("unknown", ["--frobnicate"])
        reject("missing", ["--log-dir"])
        reject("duration-no-headless", ["--duration", "5"])
        reject("dumprects-alone", ["--dump-rects"])
        // v2 (spec §7, §10.1)
        expect("v2_defaults", []) { c in c.view == nil && c.battery == nil && c.lang == nil && c.hotkeys && c.memDisplayHz == 2 && c.cliLayer == SettingsLayer() }
        expect("view", ["--view", "cpu"]) { $0.view == .cpu && $0.cliLayer.view == .cpu }
        expect("view_network", ["--view", "network"]) { $0.view == .network }
        expect("lang", ["--lang", "en"]) { $0.lang == .en && $0.cliLayer.language == .en }
        expect("lang_system", ["--lang", "system"]) { $0.lang == .system }
        expect("battery", ["--battery", "no"]) { $0.battery == false && $0.cliLayer.batteryVisible == false }
        expect("hotkeys", ["--hotkeys", "no"]) { !$0.hotkeys }
        expect("mem_display_hz", ["--mem-display-hz", "4"]) { $0.memDisplayHz == 4 }
        expect("snapshot_view", ["--snapshot", "/tmp/x.png", "--view", "network", "--lang", "en", "--battery", "no"]) {
            $0.mode == .snapshot && $0.view == .network && $0.lang == .en && $0.battery == false
        }
        reject("view", ["--view", "gpu"])
        reject("view_missing", ["--view"])
        reject("lang", ["--lang", "fr"])
        reject("lang_missing", ["--lang"])
        reject("battery", ["--battery", "maybe"])
        reject("battery_missing", ["--battery"])
        reject("hotkeys", ["--hotkeys", "1"])
        reject("mem_display_hz", ["--mem-display-hz", "3"])
        return out
    }
}
