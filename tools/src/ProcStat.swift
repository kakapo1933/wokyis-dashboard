// procstat — sample CPU and memory of a process TREE (root pid + all descendants) from cumulative counters.
//
// usage: procstat (--pid PID | --name COMM) [--duration SEC] [--interval SEC] [--csv out.csv] [--quiet]
//
//  CPU:   proc_pid_rusage(RUSAGE_INFO_V4) ri_user_time + ri_system_time (mach ticks → ns via mach_timebase_info).
//         Interval CPU% (of ONE core) = Δcpu / Δwall × 100, summed over the tree. This is exact accumulated CPU,
//         unlike the decaying `ps %cpu`.
//         * pids new since the last sample contribute their whole cumulative CPU (they started inside the interval,
//           checked via start time; pid reuse is detected by (pid, start time) identity)
//         * CPU of descendants that exited between samples is recovered from the parents' ri_child_user/system_time
//           delta minus what was already counted for tracked children that vanished (clamped at 0)
//  Memory: per sample, Σ ri_phys_footprint (what Activity Monitor's "Memory" column shows) and Σ ri_resident_size (RSS).
//  Output: CSV rows (one per interval) + summary (wall, total CPU s, avg CPU%, max/avg footprint & RSS, per-process table).
//  Exit status 0; 4 when the root process disappears (the partial summary is still printed).
import Foundation
import Darwin

struct PInfo { var pid: Int32; var ppid: Int32; var start: UInt64; var comm: String }

func allPids() -> [Int32] {
    let n = proc_listallpids(nil, 0)
    var buf = [Int32](repeating: 0, count: Int(n) + 256)
    let got = buf.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<Int32>.size)) }
    return Array(buf.prefix(Int(max(0, got)))).filter { $0 > 0 }
}

func bsdInfo(_ pid: Int32) -> PInfo? {
    var bi = proc_bsdinfo()
    let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sz) == sz else { return nil }
    let comm = withUnsafeBytes(of: bi.pbi_comm) { raw -> String in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
    var name = comm
    var nb = [CChar](repeating: 0, count: 4 * Int(MAXCOMLEN))
    if proc_name(pid, &nb, UInt32(nb.count)) > 0 { name = String(cString: nb) }
    return PInfo(pid: pid, ppid: Int32(bi.pbi_ppid), start: bi.pbi_start_tvsec * 1_000_000 + bi.pbi_start_tvusec, comm: name)
}

struct Usage { var cpuNs: UInt64; var childNs: UInt64; var footprint: UInt64; var rss: UInt64 }

let timebase: (UInt64, UInt64) = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return (UInt64(t.numer), UInt64(t.denom)) }()
@inline(__always) func ticksToNs(_ t: UInt64) -> UInt64 { t * timebase.0 / timebase.1 }

func usage(_ pid: Int32) -> Usage? {
    var ri = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &ri) { p -> Int32 in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard rc == 0 else { return nil }
    return Usage(cpuNs: ticksToNs(ri.ri_user_time + ri.ri_system_time),
                 childNs: ticksToNs(ri.ri_child_user_time + ri.ri_child_system_time),
                 footprint: ri.ri_phys_footprint, rss: ri.ri_resident_size)
}

struct Key: Hashable { var pid: Int32; var start: UInt64 }

func tree(root: Key) -> [Key: PInfo] {
    var infos: [Int32: PInfo] = [:]
    for p in allPids() { if let i = bsdInfo(p) { infos[p] = i } }
    guard let r = infos[root.pid], r.start == root.start else { return [:] }
    var children: [Int32: [Int32]] = [:]
    for (p, i) in infos where p != i.ppid { children[i.ppid, default: []].append(p) }
    var out: [Key: PInfo] = [:]
    var stack = [root.pid]
    while let p = stack.popLast() {
        guard let i = infos[p] else { continue }
        out[Key(pid: p, start: i.start)] = i
        stack.append(contentsOf: children[p] ?? [])
    }
    return out
}

func mb(_ b: Double) -> String { String(format: "%.1f", b / 1_048_576) }

@main
struct ProcStat {
    static func main() {
        let a = Args(Array(CommandLine.arguments.dropFirst()), flagNames: ["quiet", "help"])
        if a.has("help") || (a.one("pid") == nil && a.one("name") == nil) {
            print("usage: procstat (--pid PID | --name COMM) [--duration SEC=60] [--interval SEC=1] [--csv out.csv] [--quiet]")
            exit(a.has("help") ? 0 : 2)
        }
        var rootPid: Int32
        if let p = a.int("pid") { rootPid = Int32(p) }
        else {
            let n = a.one("name")!
            let m = allPids().compactMap(bsdInfo).filter { $0.comm == n }
            guard m.count == 1 else { die("--name \(n): \(m.count) matches (\(m.map { String($0.pid) }.joined(separator: ","))); use --pid") }
            rootPid = m[0].pid
        }
        guard let ri = bsdInfo(rootPid) else { die("pid \(rootPid) not found / not inspectable") }
        let root = Key(pid: rootPid, start: ri.start)
        let duration = a.double("duration") ?? 60, interval = a.double("interval") ?? 1
        var csv = "timestamp,elapsed_s,n_procs,cpu_pct_1core,cpu_s_cum,footprint_mb,rss_mb,pids\n"
        let quiet = a.has("quiet")
        if !quiet { print("# procstat root=\(rootPid) (\(ri.comm)) duration=\(duration)s interval=\(interval)s  units: CPU% of one core, MB = 2^20 bytes") }

        struct Last { var cpu: UInt64; var child: UInt64 }
        var last: [Key: Last] = [:]
        var perProc: [Key: (comm: String, cpu: UInt64, maxFp: UInt64)] = [:]
        let t0 = DispatchTime.now().uptimeNanoseconds
        var tPrev = t0
        var totalCpu: UInt64 = 0
        var fpMax: UInt64 = 0, rssMax: UInt64 = 0, fpSum = 0.0, rssSum = 0.0, samples = 0
        var intervals: [Double] = []
        var rootGone = false

        // baseline sample
        for (k, i) in tree(root: root) { if let u = usage(k.pid) { last[k] = Last(cpu: u.cpuNs, child: u.childNs); perProc[k] = (i.comm, 0, u.footprint) } }
        let samplerStartUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        _ = samplerStartUs

        while true {
            let target = tPrev + UInt64(interval * 1e9)
            let now0 = DispatchTime.now().uptimeNanoseconds
            if target > now0 { usleep(UInt32((target - now0) / 1000)) }
            let tNow = DispatchTime.now().uptimeNanoseconds
            let t = tree(root: root)
            if t.isEmpty { rootGone = true; break }
            var dCpu: UInt64 = 0, dChild: UInt64 = 0, fp: UInt64 = 0, rss: UInt64 = 0
            var cur: [Key: Last] = [:]
            for (k, i) in t {
                guard let u = usage(k.pid) else { continue }
                cur[k] = Last(cpu: u.cpuNs, child: u.childNs)
                fp += u.footprint; rss += u.rss
                var d: UInt64
                if let l = last[k] {
                    d = u.cpuNs &- l.cpu; if u.cpuNs < l.cpu { d = 0 }
                    if u.childNs > l.child { dChild += u.childNs - l.child }
                } else { d = u.cpuNs }          // new process inside this interval
                dCpu += d
                var pp = perProc[k] ?? (i.comm, 0, 0)
                pp.cpu += d; pp.maxFp = max(pp.maxFp, u.footprint); perProc[k] = pp
            }
            // exited tracked processes: their last-known CPU is already counted; parents' child-time delta covers the rest
            var vanishedCounted: UInt64 = 0
            for (k, l) in last where cur[k] == nil { vanishedCounted += l.cpu + l.child }
            let reapedExtra = dChild > vanishedCounted ? dChild - vanishedCounted : 0
            dCpu += reapedExtra
            totalCpu += dCpu
            last = cur
            let wall = Double(tNow - tPrev) / 1e9
            let pct = Double(dCpu) / 1e9 / wall * 100
            intervals.append(pct)
            fpMax = max(fpMax, fp); rssMax = max(rssMax, rss); fpSum += Double(fp); rssSum += Double(rss); samples += 1
            let el = Double(tNow - t0) / 1e9
            let pids = t.keys.map { String($0.pid) }.sorted().joined(separator: " ")
            let row = "\(isoNow()),\(String(format: "%.3f", el)),\(t.count),\(String(format: "%.3f", pct)),\(String(format: "%.4f", Double(totalCpu) / 1e9)),\(mb(Double(fp))),\(mb(Double(rss))),\(pids)"
            csv += row + "\n"
            if !quiet { print(row) }
            tPrev = tNow
            if el >= duration - 1e-3 { break }
        }
        let wall = Double(tPrev - t0) / 1e9
        var sum = "# summary root=\(rootPid) (\(ri.comm))\(rootGone ? " ROOT EXITED EARLY" : "")\n"
        sum += "wall_s=\(String(format: "%.3f", wall)) samples=\(samples) total_cpu_s=\(String(format: "%.4f", Double(totalCpu) / 1e9))\n"
        sum += "avg_cpu_pct_1core=\(String(format: "%.3f", wall > 0 ? Double(totalCpu) / 1e9 / wall * 100 : 0)) max_interval_cpu_pct=\(String(format: "%.3f", intervals.max() ?? 0))\n"
        if samples > 0 {
            sum += "footprint_mb max=\(mb(Double(fpMax))) avg=\(mb(fpSum / Double(samples)))  rss_mb max=\(mb(Double(rssMax))) avg=\(mb(rssSum / Double(samples)))\n"
        }
        sum += "per-process (pid comm cpu_s max_footprint_mb):\n"
        for (k, v) in perProc.sorted(by: { $0.value.cpu > $1.value.cpu }) {
            sum += "  \(k.pid)\t\(v.comm)\t\(String(format: "%.4f", Double(v.cpu) / 1e9))\t\(mb(Double(v.maxFp)))\n"
        }
        print(sum, terminator: "")
        if let path = a.one("csv") {
            do { try (csv + sum.split(separator: "\n").map { "# " + $0 }.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
            catch { die("cannot write \(path): \(error)") }
            print("# csv -> \(path)")
        }
        exit(rootGone ? 4 : 0)
    }
}
