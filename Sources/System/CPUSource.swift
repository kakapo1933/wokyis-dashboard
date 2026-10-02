// CPUSource.swift — CPU load (AM -[SMStatisticsManager updateCPUStatistics]) and thread / process counts (spec §5.2).
//
// * Ticks: host_processor_info(PROCESSOR_CPU_LOAD_INFO) → per-core u32 counters [user, system, idle, nice]
//   (CPU_STATE_*); the returned array is vm_deallocate'd after copying. Not host_statistics(HOST_CPU_LOAD_INFO)
//   (flavor rate limited), not ps / per-pid sums.
// * Formula (CPUFormula.average): per core d = new &- old (u32 wrapping), tot = Σd; cores with tot == 0 are skipped
//   (not counted in n); each state % = arithmetic MEAN of the per-core percentages (not tick weighted); n == 0 → nil
//   (the caller reports `.skipped(no_ticks)`, never NaN). nice is logged only.
// * Baseline guards (CPUDelta.feed, measured CLOCK_UPTIME_RAW dt):
//     no baseline → store it, .skipped(baseline) · dt < 0.5 s → .skipped(dt_short), baseline UNCHANGED ·
//     core count changed → baseline = new, .skipped(cores_changed) + WARN cpu_cores_changed ·
//     dt > 5 s → baseline = new, .skipped(gap) + WARN cpu_delta_reset reason=gap ·
//     any core Σd > 1.5 × kern.clockrate.hz × dt (u32 wrap of a backwards counter lands here) → baseline CLEARED,
//     .skipped(garbage) + WARN cpu_delta_reset reason=garbage → the next real read rebuilds the baseline and the one
//     after that reports again (an injected `garbage cpu.load` drops exactly N+1 samples).
// * Threads / processes: processor_set_statistics(PROCESSOR_SET_LOAD_INFO) on the default pset (thread_count,
//   task_count). The host port and the pset NAME port are taken once in init and cached (no per-second port urefs);
//   the pset port is released in deinit. Plausibility (CPUFormula.tasksPlausible): task_count > 0,
//   thread_count ≥ task_count, both ≤ 10⁷. kr ≠ 0 → processes from proc_listallpids (threads "—").
// Owner: sampler agent.
import Darwin
import Foundation

/// One host_processor_info snapshot: `cores` × CPU_STATE_MAX (4) u32 tick counters, row-major [user, system, idle, nice].
struct CPUTicks: Equatable, Sendable {
    var ticks: [UInt32]
    var cores: Int { ticks.count / CPUTicks.states }
    static let states = Int(CPU_STATE_MAX)   // 4
    static let user = Int(CPU_STATE_USER), system = Int(CPU_STATE_SYSTEM), idle = Int(CPU_STATE_IDLE), nice = Int(CPU_STATE_NICE)

    init(ticks: [UInt32]) { self.ticks = ticks }
    /// Test helper: one row per core, [user, system, idle, nice].
    init(rows: [[UInt32]]) {
        var t: [UInt32] = []; t.reserveCapacity(rows.count * CPUTicks.states)
        for r in rows {
            var row = [UInt32](repeating: 0, count: CPUTicks.states)
            row[CPUTicks.user] = r[0]; row[CPUTicks.system] = r[1]; row[CPUTicks.idle] = r[2]; row[CPUTicks.nice] = r[3]
            t += row
        }
        ticks = t
    }
    /// Every counter moved back by `by` (u32 wrapping) — the injected `garbage cpu.load` reading.
    func steppedBack(_ by: UInt32) -> CPUTicks { CPUTicks(ticks: ticks.map { $0 &- by }) }
}

enum CPUFormula {
    /// AM: arithmetic mean of the per-core percentages over the cores whose ticks advanced; nil when none did.
    static func average(old: CPUTicks, new: CPUTicks) -> CPUReading? {
        guard old.cores == new.cores else { return nil }
        let S = CPUTicks.states
        var sys = 0.0, usr = 0.0, idl = 0.0, nic = 0.0, n = 0
        for c in 0..<new.cores {
            let b = c * S
            let du = new.ticks[b + CPUTicks.user] &- old.ticks[b + CPUTicks.user]
            let ds = new.ticks[b + CPUTicks.system] &- old.ticks[b + CPUTicks.system]
            let di = new.ticks[b + CPUTicks.idle] &- old.ticks[b + CPUTicks.idle]
            let dn = new.ticks[b + CPUTicks.nice] &- old.ticks[b + CPUTicks.nice]
            let tot = Double(UInt64(du) + UInt64(ds) + UInt64(di) + UInt64(dn))
            if tot == 0 { continue }
            usr += Double(du) / tot; sys += Double(ds) / tot; idl += Double(di) / tot; nic += Double(dn) / tot
            n += 1
        }
        guard n > 0 else { return nil }
        let k = 100 / Double(n)
        return CPUReading(system: sys * k, user: usr * k, idle: idl * k, nice: nic * k, cores: new.cores)
    }

    /// Largest per-core Σd between two snapshots (u32 wrapping deltas), for the garbage guard.
    static func maxCoreDelta(old: CPUTicks, new: CPUTicks) -> UInt64 {
        let S = CPUTicks.states
        var m: UInt64 = 0
        for c in 0..<min(old.cores, new.cores) {
            var t: UInt64 = 0
            for s in 0..<S { t += UInt64(new.ticks[c * S + s] &- old.ticks[c * S + s]) }
            m = max(m, t)
        }
        return m
    }

    /// processor_set_statistics sanity (spec §5.2 r2): every task has ≥ 1 thread; > 10⁷ is not a real count.
    static func tasksPlausible(threads: Int, processes: Int) -> Bool {
        processes > 0 && threads >= processes && threads <= 10_000_000 && processes <= 10_000_000
    }
}

/// Baseline + guards for the CPU tick deltas. sysQ only (a value type owned by the sampler engine).
struct CPUDelta {
    static let minDt = 0.5, maxDt = 5.0, garbageFactor = 1.5
    private(set) var base: (ticks: CPUTicks, ns: UInt64)?

    mutating func reset() { base = nil }

    /// `garbage` = injected `garbage cpu.load`: the reading is replaced by the baseline moved back 1000 ticks and goes
    /// through the normal validation (→ discarded, baseline cleared). `warn` = (throttle key, WARN body).
    mutating func feed(_ t: CPUTicks, ns: UInt64, hz: Int, garbage: Bool = false) -> (Reading<CPUReading>, warn: (String, String)?) {
        guard let b = base else {
            if garbage { return (.skipped(reason: "garbage"), ("cpu_delta_reset:garbage", "cpu_delta_reset reason=garbage")) }
            base = (t, ns); return (.skipped(reason: "baseline"), nil)
        }
        guard ns >= b.ns else { base = (t, ns); return (.skipped(reason: "gap"), ("cpu_delta_reset:gap", "cpu_delta_reset reason=gap dt_s=neg")) }
        let dt = Double(ns - b.ns) / 1e9
        if dt < CPUDelta.minDt { return (.skipped(reason: "dt_short"), nil) }
        let cur = garbage ? b.ticks.steppedBack(1000) : t
        if cur.cores != b.ticks.cores {
            let from = b.ticks.cores
            base = (t, ns)
            return (.skipped(reason: "cores_changed"), ("cpu_cores_changed", "cpu_cores_changed from=\(from) to=\(t.cores)"))
        }
        if dt > CPUDelta.maxDt {
            base = (t, ns)
            return (.skipped(reason: "gap"), ("cpu_delta_reset:gap", "cpu_delta_reset reason=gap dt_s=\(String(format: "%.1f", dt))"))
        }
        let limit = CPUDelta.garbageFactor * Double(max(1, hz)) * dt
        let worst = CPUFormula.maxCoreDelta(old: b.ticks, new: cur)
        if Double(worst) > limit {
            base = nil
            return (.skipped(reason: "garbage"),
                    ("cpu_delta_reset:garbage", "cpu_delta_reset reason=garbage max_core_ticks=\(worst) limit=\(Int(limit))"))
        }
        base = (cur, ns)
        guard let r = CPUFormula.average(old: b.ticks, new: cur) else { return (.skipped(reason: "no_ticks"), nil) }
        return (.value(r), nil)
    }
}

/// Live Mach reads. Thread-safe for one caller at a time (the sampler calls it on sysQ only).
final class CPUReader: @unchecked Sendable {
    private static let hostPort = mach_host_self()   // one uref for the process lifetime (as HostAudit)
    private var pset = processor_set_name_t()
    private let psetKr: kern_return_t
    /// kern.clockrate.hz (scheduler ticks per second per core; 100 on this Mac), for the garbage guard.
    let clockHz: Int

    init() {
        var p = processor_set_name_t()
        psetKr = processor_set_default(CPUReader.hostPort, &p)
        pset = p
        var ci = clockinfo(); var len = MemoryLayout<clockinfo>.size
        var mib: [Int32] = [CTL_KERN, KERN_CLOCKRATE]
        clockHz = (sysctl(&mib, 2, &ci, &len, nil, 0) == 0 && ci.hz > 0) ? Int(ci.hz) : 100
    }

    deinit { if psetKr == KERN_SUCCESS { mach_port_deallocate(mach_task_self_, pset) } }

    func ticks() -> Result<CPUTicks, SourceError> {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var cnt: mach_msg_type_number_t = 0
        let kr = host_processor_info(CPUReader.hostPort, PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt)
        guard kr == KERN_SUCCESS, let info else { return .failure(.kern(kr == KERN_SUCCESS ? -1 : kr)) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(cnt) * MemoryLayout<integer_t>.stride)) }
        let count = min(Int(cnt), Int(n) * CPUTicks.states)
        guard count > 0, count % CPUTicks.states == 0 else { return .failure(.parse("cpu_load_info count=\(cnt) n=\(n)")) }
        var t = [UInt32](repeating: 0, count: count)
        for i in 0..<count { t[i] = UInt32(bitPattern: info[i]) }
        return .success(CPUTicks(ticks: t))
    }

    /// (thread_count, task_count) of the default processor set; `.kern(kr)` when the pset port or the call failed.
    func tasks() -> Result<(threads: Int, processes: Int), SourceError> {
        guard psetKr == KERN_SUCCESS else { return .failure(.kern(psetKr)) }
        var li = processor_set_load_info()
        var c = mach_msg_type_number_t(MemoryLayout<processor_set_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &li) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { processor_set_statistics(pset, PROCESSOR_SET_LOAD_INFO, $0, &c) }
        }
        guard kr == KERN_SUCCESS else { return .failure(.kern(kr)) }
        return .success((Int(li.thread_count), Int(li.task_count)))
    }

    /// Fallback process count (proc_listallpids with a real buffer — the NULL-buffer call only returns an estimate).
    static func processCount() -> Int? {
        let est = proc_listallpids(nil, 0)
        guard est > 0 else { return nil }
        var buf = [Int32](repeating: 0, count: Int(est) + 64)
        let n = buf.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return n > 0 ? Int(n) : nil
    }
}
