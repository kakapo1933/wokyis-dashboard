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
    static func startBody(config: Config, mode: Config.Mode, selftest: String, mibs: String) -> String {
        "build=\(buildHash) pid=\(getpid()) mode=\(mode.rawValue) args=\(EventLog.q(config.argsQuoted)) mem_hz=\(fmt(config.memHz)) "
            + "audit_hz=\(fmt(config.auditHz)) sp_period=\(fmt(config.spPeriod)) log_level=\(config.logLevel.rawValue) "
            + "summary_s=\(fmt(config.summarySeconds)) selftest=\(selftest) mibs=\(mibs) locale=\(Locale.current.identifier) sim=0"
    }
    static func fmt(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }
}

/// stdout SUM body (EventLog.summary adds "HH:MM:SS SUM "):
/// used="18.52 GB" press=48%/1 swap="39.8 MB" kb=100 tp=85 airpods=- mode=mte sim=0
enum SummaryFormat {
    static func body(sample: MemSample?, groups: [DeviceGroup], sim: Bool) -> String {
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
            + "mouse=\(first(.mouse)) airpods=\(pods) mode=\(sample?.mode.rawValue ?? "-") sim=\(sim ? 1 : 0)"
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
