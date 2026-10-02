// Support.swift — small shared helpers: START line, stdout SUM formatting, process HEALTH sampling.
// Owner: core.
import Foundation
import CryptoKit

enum StartInfo {
    /// Touch at the very start of main so uptime is measured from launch.
    static let launchedAt = Date()

    /// First 12 hex digits of the SHA-256 of the running executable ("unknown" when unreadable).
    static let buildHash: String = {
        guard let path = Bundle.main.executablePath ?? CommandLine.arguments.first,
              let data = FileManager.default.contents(atPath: path) else { return "unknown" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }()

    /// Body of the `START` line (spec §12). `mibs` = "resolved/total" from SysctlTable.
    /// v2 (spec §7): `ui` = the settings model of this run → view= battery= lang= lang_resolved= hotkeys= settings_src=.
    static func startBody(config: Config, mode: Config.Mode, selftest: String, mibs: String, ui: SettingsModel? = nil) -> String {
        var b = "build=\(buildHash) pid=\(getpid()) mode=\(mode.rawValue) args=\(EventLog.q(config.argsQuoted)) mem_hz=\(fmt(config.memHz)) "
            + "audit_hz=\(fmt(config.auditHz)) sp_period=\(fmt(config.spPeriod)) log_level=\(config.logLevel.rawValue) "
            + "summary_s=\(fmt(config.summarySeconds)) selftest=\(selftest) mibs=\(mibs) locale=\(Locale.current.identifier)"
        if let ui { b += " " + uiTokens(ui, hotkeys: config.hotkeys && mode == .app) + " mem_display_hz=\(fmt(config.memDisplayHz))" }
        return b + " sim=0"
    }

    static func uiTokens(_ ui: SettingsModel, hotkeys: Bool) -> String {
        let e = ui.effective
        return "view=\(e.view.token) battery=\(e.batteryVisible ? 1 : 0) lang=\(e.language.rawValue) lang_resolved=\(ui.resolvedLang.rawValue) "
            + "hotkeys=\(hotkeys ? 1 : 0) settings_src=\(ui.sources)"
    }
    static func fmt(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }
}

/// stdout SUM body (EventLog.summary adds "HH:MM:SS SUM "):
/// used="18.52 GB" press=48%/1 swap="39.8 MB" kb=100 tp=85 airpods=- mode=mte cpu=4.99/16.65 net=5.91Mb/156.59kb view=mem sim=0
/// (v2 cpu= system/user %, net= download/upload in AM bit units without "/s", "-" while unknown; spec §9.1)
enum SummaryFormat {
    static func body(sample: MemSample?, groups: [DeviceGroup], sim: Bool, sys: SysSample? = nil, view: ViewKind = .memory) -> String {
        func str(_ f: Field) -> String {
            guard let s = sample, let v = s.strings[f], let t = v else { return "-" }
            return EventLog.q(t)
        }
        var press = "-"
        if let p = sample?.pressure { press = "\(p.pct)%/\(p.level.rawValue)" }
        func cell(_ c: CellState, connected: Bool) -> String {
            guard connected else { return "off" }
            switch c {
            case .ok(let p, let ch): return "\(p)" + (ch ? "c" : "")
            case .failed: return "fail"
            case .unavailable: return "na"
            case .stale: return "stale"
            }
        }
        func first(_ k: DeviceKind) -> String {
            guard let g = groups.first(where: { $0.kind == k }), let c = g.cells.first else { return "-" }
            return cell(c.state, connected: g.connected)
        }
        var pods = "-"   // first AirPods group: "100/97/48c" connected, "~97/99/na" nearby (grey + 「附近」), "off" offline
        if let g = groups.first(where: { $0.kind == .airpods }) {
            pods = g.showsCells ? (g.presence == .nearby ? "~" : "") + g.cells.map { cell($0.state, connected: true) }.joined(separator: "/") : "off"
        }
        return "used=\(str(.used)) press=\(press) swap=\(str(.swap)) kb=\(first(.keyboard)) tp=\(first(.trackpad)) "
            + "mouse=\(first(.mouse)) airpods=\(pods) mode=\(sample?.mode.rawValue ?? "-") \(sysTokens(sys)) view=\(view.token) sim=\(sim ? 1 : 0)"
    }

    /// "cpu=4.99/16.65 net=5.91Mb/156.59kb" ("-" for an unknown part).
    static func sysTokens(_ s: SysSample?) -> String {
        let cpu = s?.cpu.value.map { "\(L10n.fmt2($0.system))/\(L10n.fmt2($0.user))" } ?? "-"
        var net = "-"
        if let n = s?.net.value, let rx = n.rxRate, let tx = n.txRate {
            func sp(_ b: Double) -> String { L10n.speed(bytesPerSecond: b, .en).replacingOccurrences(of: "/s", with: "").replacingOccurrences(of: " ", with: "") }
            net = "\(sp(rx))/\(sp(tx))"
        }
        return "cpu=\(cpu) net=\(net)"
    }
}

/// Own-process CPU / memory (the `HEALTH` line). CPU includes reaped children (system_profiler).
enum ProcessHealth {
    struct Sample: Sendable { let cpuSeconds: Double; let footprintMB: Double; let rssMB: Double }
    private static let timebase: (Double) = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t)
        return Double(t.numer) / Double(t.denom)
    }()
    static func sample() -> Sample? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        let ticks = Double(info.ri_user_time + info.ri_system_time + info.ri_child_user_time + info.ri_child_system_time)
        return Sample(cpuSeconds: ticks * timebase / 1e9, footprintMB: Double(info.ri_phys_footprint) / 1_048_576,
                      rssMB: Double(info.ri_resident_size) / 1_048_576)
    }
}

/// One app-mode panel per user (any copy: the checkout's build/ or an installed app): an exclusive flock on a fixed
/// per-user file, taken before the log is opened and held until the process exits (the fd is never closed; the kernel
/// releases the lock on exit or crash). Unlike a LaunchServices lookup it has no window in which two copies started
/// together both see each other, and unlike run/panel.pid it does not depend on --run-dir. O_CLOEXEC: children such as
/// system_profiler never inherit it.
enum InstanceLock {
    static let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("io.github.kakapo1933.wokyis-panel.lock")
    enum Result: Equatable { case acquired(Int32), busy, unavailable(Int32) }   // unavailable: errno; the panel still starts
    static func acquire(at path: String = InstanceLock.path) -> Result {
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .unavailable(errno) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return .acquired(fd) }
        let e = errno
        Darwin.close(fd)
        return e == EWOULDBLOCK ? .busy : .unavailable(e)
    }
    static func selfTest() -> [SelfTestCase] {
        let p = (NSTemporaryDirectory() as NSString).appendingPathComponent("wokyis-lock-selftest-\(getpid())")
        let a = acquire(at: p), b = acquire(at: p)
        if case .acquired(let fd) = a { Darwin.close(fd) }        // releases the lock
        let c = acquire(at: p)
        if case .acquired(let fd) = c { Darwin.close(fd) }
        unlink(p)
        var firstOK = false, thirdOK = false
        if case .acquired = a { firstOK = true }
        if case .acquired = c { thirdOK = true }
        return [SelfTestCase("app.instance_lock", firstOK && b == .busy && thirdOK, "\(a) \(b) \(c)")]
    }
}
