// logstats — criterion #6 / gate G4: update-interval statistics from the panel's own log (spec §12 + D4).
//
// usage: logstats LOG [LOG…] [--since T] [--until T] [--last-min N] [--occluded T0,T1]… [--mem-max 2] [--bat-max 60]
//                 [--sp-max 60] [--gaps 10] [--check] [--json OUT.json]
//        logstats --selftest
//   T = ISO timestamp as written in the log (2026-10-01T05:07:13.250+08:00) or local HH:MM[:SS] of the log's first day.
//
// Line format: "<local ISO ts ms+offset> <KIND> key=value key="quoted" …". Values used:
//   MEM  ts = sample START time; seq=               → intervals between consecutive MEM lines (same process run)
//   DSP  seq= mem_seq= regions= stale= sim=         → counts, rate, intervals, regions histogram
//   BAT  dev=                                       → per-device interval between BAT lines
//   SP   rc= ms= trigger=                           → interval between system_profiler polls, failures
//   WIN  occluded=0|1  or event=occluded|visible    → occlusion timeline (authoritative when present)
//   HEALTH occluded=N                               → fallback occlusion state (N>0 = occluded until the next HEALTH)
//   START / STOP                                    → process-run boundaries (intervals never span a restart)
//   HIST n=  ERR src= err=  WARN  CTL  DEV          → counts / listings
//   v2: CPU sys= user= idle= fail= skip=            → averages, fail / skip counts
//       NET rx_bps= tx_bps= fail= skip=             → p50 / p99, fail / skip counts; WARN net_counter_reset count
//       UI event= from= to= via=                    → per event counts; DSP view= → regions histogram per view;
//       HEALTH passes= view= mem_hz=                → last values
// An interval is attributed to the occlusion state at its START. With `log_level=summary` (D4 default) MEM is
// decimated to one line per summary-seconds and DSP is absent → the MEM verdict is marked NOT APPLICABLE; criterion #6
// evidence must come from a `--log-level sample` run.
// Exit: 0 (with --check: overall PASS), 1 (--check and overall FAIL or INCOMPLETE), 2 usage / unreadable.
import Foundation

// MARK: - parsing

struct LogLine {
    var t: Double          // epoch seconds
    var ts: Substring
    var kind: Substring
    var kv: [Substring: Substring]
    var quoted: [Substring: String]   // key → the "…" string following key=value (MEM field strings)
    var fileIndex: Int
    var word: Substring = ""          // first body token (WARN net_counter_reset …)
}

enum TS {
    /// Parses 2026-10-01T05:07:13.250+08:00 (also …Z, no fraction) → epoch seconds.
    static func parse<S: StringProtocol>(_ s: S) -> Double? {
        let u = Array(s.utf8)
        guard u.count >= 19, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58 else { return nil }
        func num(_ a: Int, _ b: Int) -> Int? {
            var v = 0
            for i in a..<b { let c = Int(u[i]) - 48; if c < 0 || c > 9 { return nil }; v = v * 10 + c }
            return v
        }
        guard let Y = num(0, 4), let M = num(5, 7), let D = num(8, 10), let h = num(11, 13), let m = num(14, 16), let sec = num(17, 19) else { return nil }
        var i = 19
        var frac = 0.0
        if i < u.count && u[i] == 46 {
            i += 1; var scale = 0.1
            while i < u.count, u[i] >= 48, u[i] <= 57 { frac += Double(Int(u[i]) - 48) * scale; scale /= 10; i += 1 }
        }
        var off = 0
        if i < u.count {
            if u[i] == 90 { off = 0 }
            else if u[i] == 43 || u[i] == 45, i + 5 < u.count + 0, let oh = num(i + 1, i + 3) {
                let om = (i + 5 < u.count && u[i + 3] == 58) ? (num(i + 4, i + 6) ?? 0) : (num(i + 3, i + 5) ?? 0)
                off = (oh * 3600 + om * 60) * (u[i] == 45 ? -1 : 1)
            } else { return nil }
        }
        var t = tm(); t.tm_year = Int32(Y - 1900); t.tm_mon = Int32(M - 1); t.tm_mday = Int32(D)
        t.tm_hour = Int32(h); t.tm_min = Int32(m); t.tm_sec = Int32(sec)
        return Double(timegm(&t) - off) + frac
    }
}

/// Splits a body into tokens honouring "…" quotes; `key=value` pairs go to kv, a bare "…" right after a key=value is
/// that key's quoted string.
func parseBody(_ body: Substring) -> ([Substring: Substring], [Substring: String]) {
    var kv: [Substring: Substring] = [:], qs: [Substring: String] = [:]
    var lastKey: Substring? = nil
    var i = body.startIndex
    while i < body.endIndex {
        while i < body.endIndex && body[i] == " " { i = body.index(after: i) }
        if i >= body.endIndex { break }
        if body[i] == "\"" {
            let s = body.index(after: i)
            let e = body[s...].firstIndex(of: "\"") ?? body.endIndex
            if let k = lastKey { qs[k] = String(body[s..<e]) }
            i = e < body.endIndex ? body.index(after: e) : e
            lastKey = nil
            continue
        }
        var j = i
        var eq: Substring.Index? = nil
        while j < body.endIndex && body[j] != " " {
            if body[j] == "=" && eq == nil {
                eq = j
                // key="quoted value with spaces"
                let n = body.index(after: j)
                if n < body.endIndex && body[n] == "\"" {
                    let s = body.index(after: n)
                    let e = body[s...].firstIndex(of: "\"") ?? body.endIndex
                    kv[body[i..<j]] = body[s..<e]
                    lastKey = nil
                    j = e < body.endIndex ? body.index(after: e) : e
                    eq = nil
                    i = j
                    break
                }
            }
            j = body.index(after: j)
        }
        if i == j { continue }
        if let e = eq { kv[body[i..<e]] = body[body.index(after: e)..<j]; lastKey = body[i..<e] } else { lastKey = nil }
        i = j
    }
    return (kv, qs)
}

func parseLine(_ raw: Substring, fileIndex: Int) -> LogLine? {
    guard let sp1 = raw.firstIndex(of: " ") else { return nil }
    let ts = raw[raw.startIndex..<sp1]
    guard let t = TS.parse(ts) else { return nil }
    let rest = raw[raw.index(after: sp1)...]
    let sp2 = rest.firstIndex(of: " ") ?? rest.endIndex
    let kind = rest[rest.startIndex..<sp2]
    let body = sp2 < rest.endIndex ? rest[rest.index(after: sp2)...] : Substring("")
    let (kv, qs) = (kind == "MEM" || kind == "BAT" || kind == "SP" || kind == "DSP" || kind == "WIN" || kind == "HEALTH" || kind == "START"
                    || kind == "ERR" || kind == "HIST" || kind == "DEV" || kind == "STOP" || kind == "WARN" || kind == "CTL" || kind == "AUD"
                    || kind == "CPU" || kind == "NET" || kind == "UI")
        ? parseBody(body) : ([:], [:])
    return LogLine(t: t, ts: ts, kind: kind, kv: kv, quoted: qs, fileIndex: fileIndex, word: body.prefix { $0 != " " })
}

// MARK: - statistics

struct Dist {
    var xs: [Double] = []
    mutating func add(_ x: Double) { xs.append(x) }
    var n: Int { xs.count }
    func q(_ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let idx = Int((p * Double(s.count - 1)).rounded(.up))   // nearest-rank (upper) → conservative p99
        return s[Swift.min(s.count - 1, Swift.max(0, idx))]
    }
    var max: Double? { xs.max() }
    var min: Double? { xs.min() }
    var mean: Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
    func count(over x: Double) -> Int { xs.filter { $0 > x }.count }
    func row(_ unit: String = "s") -> String {
        guard n > 0 else { return "n=0" }
        return String(format: "n=%d min=%.3f p50=%.3f mean=%.3f p99=%.3f max=%.3f", n, min!, q(0.5)!, mean!, q(0.99)!, max!)
    }
    var dict: [String: Any] {
        guard n > 0 else { return ["n": 0] }
        return ["n": n, "min": min!, "p50": q(0.5)!, "mean": mean!, "p99": q(0.99)!, "max": max!]
    }
}

struct Occlusion {
    /// sorted (t, occluded) change points; state before the first point = visible
    var points: [(Double, Bool)] = []
    var source = "none"
    func state(at t: Double) -> Bool {
        var s = false
        for p in points { if p.0 <= t { s = p.1 } else { break } }
        return s
    }
}

struct Report {
    var files: [String] = []
    var lines = 0, unparsed = 0
    var first: Double = .nan, last: Double = .nan
    var runs = 0
    var logLevel: [String] = []
    var memAll = Dist(), memVis = Dist(), memOcc = Dist()
    var memSeqGaps = 0, memSeqGapMissing = 0
    var memTop: [(Double, Double, Bool)] = []    // (interval, start t, occluded)
    var memCount = 0, memSim = 0
    var restartGaps: [(Double, Double)] = []
    var dspCount = 0, dspStale = 0, dspSim = 0
    var dspInt = Dist()
    var dspRegions: [String: Int] = [:]
    var dspRegionsByView: [String: [String: Int]] = [:]   // v2: DSP view= (no token = mem)
    var cpuCount = 0, cpuFail = 0, cpuSkip = 0
    var cpuSys = Dist(), cpuUser = Dist(), cpuIdle = Dist()
    var netCount = 0, netFail = 0, netSkip = 0, netCounterReset = 0
    var netRx = Dist(), netTx = Dist()
    var ui: [String: Int] = [:]                            // UI event=… counts (dedup, view, battery, lang, mem_hz, …)
    var batPerDev: [String: Dist] = [:]
    var batLastSeen: [String: Double] = [:]
    var batFirstSeen: [String: Double] = [:]
    var batCount: [String: Int] = [:]
    var spInt = Dist(), spMs = Dist()
    var spFail: [String: Int] = [:]
    var spTrigger: [String: Int] = [:]
    var spCount = 0
    var hist: [Int] = []
    var health: [(Double, [Substring: Substring])] = []
    var errs: [String: Int] = [:]
    var warns: [String: Int] = [:]
    var ctl = 0
    var dev: [String] = []
    var win: [String] = []
    var occ = Occlusion()
    var occludedSeconds = 0.0
}

func fmtT(_ t: Double) -> String {
    guard t.isFinite else { return "-" }
    let d = Date(timeIntervalSince1970: t)
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSxxx"
    return f.string(from: d)
}

/// "HH:MM[:SS]" relative to the local day of `ref`, or a full ISO timestamp.
func parseUserTime(_ s: String, ref: Double) -> Double? {
    if let t = TS.parse(s) { return t }
    let p = s.split(separator: ":").compactMap { Int($0) }
    guard p.count >= 2, ref.isFinite else { return nil }
    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
    var c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ref))
    c.hour = p[0]; c.minute = p[1]; c.second = p.count > 2 ? p[2] : 0
    return cal.date(from: c)?.timeIntervalSince1970
}

func analyze(_ lines: [LogLine], manualOcc: [(Double, Double)], gapsTop: Int) -> Report {
    var r = Report()
    r.lines = lines.count
    guard !lines.isEmpty else { return r }
    r.first = lines.first!.t; r.last = lines.last!.t
    // occlusion timeline
    var winPts: [(Double, Bool)] = []
    var healthPts: [(Double, Bool)] = []
    for l in lines {
        if l.kind == "WIN" {
            if let o = l.kv["occluded"], o == "0" || o == "1" { winPts.append((l.t, o == "1")) }
            else if let e = l.kv["event"] {
                if e == "occluded" || e == "occlusion_hidden" || e == "occlusion_on" { winPts.append((l.t, true)) }
                if e == "visible" || e == "occlusion_visible" || e == "occlusion_off" { winPts.append((l.t, false)) }
            }
        } else if l.kind == "HEALTH", let o = l.kv["occluded"], let n = Double(o) {
            healthPts.append((l.t, n > 0))
        }
    }
    if !manualOcc.isEmpty {
        for (a, b) in manualOcc.sorted(by: { $0.0 < $1.0 }) { r.occ.points.append((a, true)); r.occ.points.append((b, false)) }
        r.occ.source = "manual --occluded"
    } else if !winPts.isEmpty { r.occ.points = winPts; r.occ.source = "WIN occluded=/event=" }
    else if !healthPts.isEmpty { r.occ.points = healthPts; r.occ.source = "HEALTH occluded= (coarse: state holds until the next HEALTH line)" }
    // occluded seconds over the log span
    if !r.occ.points.isEmpty {
        var s = false, t0 = r.first
        for p in r.occ.points where p.0 >= r.first && p.0 <= r.last {
            if s { r.occludedSeconds += p.0 - t0 }
            s = p.1; t0 = p.0
        }
        if s { r.occludedSeconds += r.last - t0 }
        r.occ.points.sort { $0.0 < $1.0 }
    }

    var run = 0
    var prevMem: LogLine? = nil
    var prevDsp: Double? = nil
    var prevSp: Double? = nil
    var prevBat: [String: Double] = [:]
    for l in lines {
        switch l.kind {
        case "START":
            run += 1
            if let lv = l.kv["log_level"] { r.logLevel.append(String(lv)) }
            if let p = prevMem { r.restartGaps.append((p.t, l.t)) }
            prevMem = nil; prevDsp = nil; prevSp = nil; prevBat = [:]
        case "STOP":
            prevMem = nil; prevDsp = nil; prevSp = nil; prevBat = [:]
        case "MEM":
            r.memCount += 1
            if l.kv["sim"] == "1" { r.memSim += 1 }
            if let p = prevMem {
                let dt = l.t - p.t
                let occ = r.occ.state(at: p.t)
                r.memAll.add(dt)
                if occ { r.memOcc.add(dt) } else { r.memVis.add(dt) }
                r.memTop.append((dt, p.t, occ))
                if let a = p.kv["seq"].flatMap({ UInt64($0) }), let b = l.kv["seq"].flatMap({ UInt64($0) }), b != a + 1 {
                    r.memSeqGaps += 1; if b > a { r.memSeqGapMissing += Int(b - a - 1) }
                }
            }
            prevMem = l
        case "DSP":
            r.dspCount += 1
            if l.kv["stale"] == "1" { r.dspStale += 1 }
            if l.kv["sim"] == "1" { r.dspSim += 1 }
            let view = String(l.kv["view"] ?? "mem")
            for reg in (l.kv["regions"] ?? "").split(separator: ",") {
                r.dspRegions[String(reg), default: 0] += 1
                r.dspRegionsByView[view, default: [:]][String(reg), default: 0] += 1
            }
            if let p = prevDsp { r.dspInt.add(l.t - p) }
            prevDsp = l.t
        case "BAT":
            let d = String(l.kv["dev"] ?? "?")
            r.batCount[d, default: 0] += 1
            if r.batFirstSeen[d] == nil { r.batFirstSeen[d] = l.t }
            r.batLastSeen[d] = l.t
            if let p = prevBat[d] { r.batPerDev[d, default: Dist()].add(l.t - p) }
            prevBat[d] = l.t
        case "SP":
            r.spCount += 1
            if let p = prevSp { r.spInt.add(l.t - p) }
            prevSp = l.t
            if let ms = l.kv["ms"].flatMap({ Double($0) }) { r.spMs.add(ms / 1000) }
            if let rc = l.kv["rc"], rc != "0" { r.spFail["rc=\(rc)", default: 0] += 1 }
            if let tr = l.kv["trigger"] { r.spTrigger[String(tr), default: 0] += 1 }
        case "CPU":
            r.cpuCount += 1
            if let f = l.kv["fail"], f != "-" { r.cpuFail += 1 }
            if let k = l.kv["skip"], k != "-" { r.cpuSkip += 1 }
            if let v = l.kv["sys"].flatMap({ Double($0) }) { r.cpuSys.add(v) }
            if let v = l.kv["user"].flatMap({ Double($0) }) { r.cpuUser.add(v) }
            if let v = l.kv["idle"].flatMap({ Double($0) }) { r.cpuIdle.add(v) }
        case "NET":
            r.netCount += 1
            if let f = l.kv["fail"], f != "-" { r.netFail += 1 }
            if let k = l.kv["skip"], k != "-" { r.netSkip += 1 }
            if let v = l.kv["rx_bps"].flatMap({ Double($0) }) { r.netRx.add(v) }
            if let v = l.kv["tx_bps"].flatMap({ Double($0) }) { r.netTx.add(v) }
        case "UI":
            r.ui[String(l.kv["event"] ?? "?"), default: 0] += 1
        case "HIST":
            if let n = l.kv["n"].flatMap({ Int($0) }) { r.hist.append(n) }
        case "HEALTH":
            r.health.append((l.t, l.kv))
        case "ERR":
            r.errs["src=\(l.kv["src"] ?? "?") err=\(l.kv["err"] ?? "?")\(l.kv["sim"] == "1" ? " sim=1" : "")", default: 0] += 1
        case "WARN":
            let first = l.kv.keys.sorted().first.map(String.init) ?? "?"
            r.warns[first, default: 0] += 1
            if l.word == "net_counter_reset" { r.netCounterReset += 1 }
        case "CTL": r.ctl += 1
        case "DEV": r.dev.append("\(l.ts) dev=\(l.kv["dev"] ?? "?") kind=\(l.kv["kind"] ?? "?") \(l.kv["from"] ?? "?")→\(l.kv["to"] ?? "?") why=\(l.kv["why"] ?? "?")")
        case "WIN": r.win.append("\(l.ts) event=\(l.kv["event"] ?? "?")\(l.kv["occluded"].map { " occluded=\($0)" } ?? "")")
        default: break
        }
    }
    r.runs = run
    r.memTop.sort { $0.0 > $1.0 }
    r.memTop = Array(r.memTop.prefix(gapsTop))
    return r
}

// MARK: - main

@main
struct LogStats {
    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        if argv.first == "--selftest" { exit(selftest() ? 0 : 1) }
        let a = Args(argv, flagNames: ["help", "check"])
        guard !a.positional.isEmpty, !a.has("help") else {
            print("usage: logstats LOG [LOG…] [--since T] [--until T] [--last-min N] [--occluded T0,T1]… [--mem-max 2] [--bat-max 60] [--sp-max 60] [--gaps 10] [--check] [--json OUT.json] | logstats --selftest")
            exit(a.has("help") ? 0 : 2)
        }
        var all: [LogLine] = []
        var unparsed = 0
        for (fi, p) in a.positional.enumerated() {
            guard let data = FileManager.default.contents(atPath: p), let text = String(data: data, encoding: .utf8) else { die("cannot read \(p)") }
            for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if let l = parseLine(raw, fileIndex: fi) { all.append(l) } else { unparsed += 1 }
            }
        }
        let ref = all.first?.t ?? .nan
        var since = a.one("since").flatMap { parseUserTime($0, ref: ref) }
        let until = a.one("until").flatMap { parseUserTime($0, ref: ref) }
        if let m = a.double("last-min"), let last = all.last?.t { since = last - m * 60 }
        if a.one("since") != nil && since == nil { die("bad --since") }
        if a.one("until") != nil && until == nil { die("bad --until") }
        let lines = all.filter { (since == nil || $0.t >= since!) && (until == nil || $0.t <= until!) }
        var manual: [(Double, Double)] = []
        for o in a.opts["occluded"] ?? [] {
            let p = o.split(separator: ",").map(String.init)
            guard p.count == 2, let t0 = parseUserTime(p[0], ref: ref), let t1 = parseUserTime(p[1], ref: ref) else { die("bad --occluded \(o)") }
            manual.append((t0, t1))
        }
        var r = analyze(lines, manualOcc: manual, gapsTop: a.int("gaps") ?? 10)
        r.files = a.positional; r.unparsed = unparsed
        let memMax = a.double("mem-max") ?? 2.0, batMax = a.double("bat-max") ?? 60, spMax = a.double("sp-max") ?? 60
        let (text, ok, json) = render(r, memMax: memMax, batMax: batMax, spMax: spMax, since: since, until: until)
        print(text, terminator: "")
        if let out = a.one("json"), let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: out, contents: d)
        }
        exit(a.has("check") && !ok ? 1 : 0)
    }

    static func render(_ r: Report, memMax: Double, batMax: Double, spMax: Double, since: Double?, until: Double?) -> (String, Bool, [String: Any]) {
        var o = ""
        func p(_ s: String) { o += s + "\n" }
        var ok = true
        var incomplete = false
        var verdicts: [[String: Any]] = []
        func verdict(_ name: String, _ pass: Bool?, _ detail: String) {
            let v = pass == nil ? "NOT APPLICABLE" : (pass! ? "PASS" : "FAIL")
            if pass == false { ok = false }
            if pass == nil && (name.hasPrefix("mem_") || name.hasPrefix("bat_")) { incomplete = true }
            p("verdict\t\(name)\t\(v)\t\(detail)")
            verdicts.append(["name": name, "result": v, "detail": detail])
        }
        p("# logstats \(r.files.joined(separator: " "))")
        p("span\t\(fmtT(r.first)) … \(fmtT(r.last))\t\(String(format: "%.1f", (r.last - r.first).isFinite ? r.last - r.first : 0)) s\tlines=\(r.lines) unparsed=\(r.unparsed) process_runs(START)=\(r.runs)")
        if since != nil || until != nil { p("window\tsince=\(since.map(fmtT) ?? "-") until=\(until.map(fmtT) ?? "-")") }
        let levels = Set(r.logLevel)
        p("log_level\t\(r.logLevel.isEmpty ? "unknown (no START line in range)" : levels.sorted().joined(separator: ","))")
        p("occlusion\tsource=\(r.occ.source)\toccluded_s=\(String(format: "%.1f", r.occludedSeconds))\tchange_points=\(r.occ.points.count)")
        p("")
        p("## MEM (interval between consecutive MEM lines, ts = sample start; never across START/STOP)")
        p("MEM\tall\t\(r.memAll.row())\tover_0.5s=\(r.memAll.count(over: 0.5))\tover_\(memMax)s=\(r.memAll.count(over: memMax))")
        p("MEM\tvisible\t\(r.memVis.row())\tover_0.5s=\(r.memVis.count(over: 0.5))\tover_\(memMax)s=\(r.memVis.count(over: memMax))")
        p("MEM\toccluded\t\(r.memOcc.row())\tover_0.5s=\(r.memOcc.count(over: 0.5))\tover_\(memMax)s=\(r.memOcc.count(over: memMax))")
        p("MEM\tlines=\(r.memCount) sim=1:\(r.memSim) seq_gaps=\(r.memSeqGaps) seq_missing=\(r.memSeqGapMissing) restart_gaps=\(r.restartGaps.count)")
        for g in r.memTop { p("MEM_gap\t\(String(format: "%.3f", g.0)) s\tfrom \(fmtT(g.1))\t\(g.2 ? "occluded" : "visible")") }
        p("")
        p("## DSP (one line per committed draw)")
        let span = r.last - r.first
        p("DSP\tcount=\(r.dspCount)\trate=\(span > 0 ? String(format: "%.2f", Double(r.dspCount) / span) : "-")/s\tstale=1:\(r.dspStale)\tsim=1:\(r.dspSim)\tinterval \(r.dspInt.row())")
        if !r.dspRegions.isEmpty { p("DSP_regions\t" + r.dspRegions.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
        p("")
        if !r.dspRegionsByView.isEmpty && Set(r.dspRegionsByView.keys) != ["mem"] {
            for (v, regs) in r.dspRegionsByView.sorted(by: { $0.key < $1.key }) {
                p("DSP_regions[view=\(v)]\t" + regs.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            }
        }
        p("")
        p("## CPU / NET (SystemSampler, 1 Hz; summary level decimates both like MEM)")
        p("CPU\tlines=\(r.cpuCount)\tfail=\(r.cpuFail)\tskip=\(r.cpuSkip)\tsys_mean=\(r.cpuSys.mean.map { String(format: "%.2f", $0) } ?? "-")"
          + "\tuser_mean=\(r.cpuUser.mean.map { String(format: "%.2f", $0) } ?? "-")\tidle_mean=\(r.cpuIdle.mean.map { String(format: "%.2f", $0) } ?? "-")")
        p("NET\tlines=\(r.netCount)\tfail=\(r.netFail)\tskip=\(r.netSkip)\tcounter_reset=\(r.netCounterReset)"
          + "\trx_bps p50=\(r.netRx.q(0.5).map { String(format: "%.0f", $0) } ?? "-") p99=\(r.netRx.q(0.99).map { String(format: "%.0f", $0) } ?? "-")"
          + "\ttx_bps p50=\(r.netTx.q(0.5).map { String(format: "%.0f", $0) } ?? "-") p99=\(r.netTx.q(0.99).map { String(format: "%.0f", $0) } ?? "-")")
        p("UI\t" + (r.ui.isEmpty ? "0" : r.ui.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")))
        p("")
        p("## BAT (per device, interval between BAT lines)")
        for d in r.batCount.keys.sorted() {
            let dist = r.batPerDev[d] ?? Dist()
            let tail = r.last - (r.batLastSeen[d] ?? r.last)
            p("BAT\tdev=\(d)\tlines=\(r.batCount[d]!)\t\(dist.row())\tlast_seen=\(fmtT(r.batLastSeen[d] ?? .nan))\ttail_s=\(String(format: "%.1f", tail))")
        }
        if r.batCount.isEmpty { p("BAT\tno BAT lines") }
        p("")
        p("## SP (system_profiler polls)")
        p("SP\tcount=\(r.spCount)\tinterval \(r.spInt.row())\tfailures=\(r.spFail.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",").isEmpty ? "0" : r.spFail.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ","))\ttriggers=\(r.spTrigger.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ","))")
        p("SP_duration\t\(r.spMs.row())")
        p("")
        p("## other")
        p("HIST\tcount=\(r.hist.count)\tn_min=\(r.hist.min().map(String.init) ?? "-")\tn_last=\(r.hist.last.map(String.init) ?? "-")")
        if let h = r.health.last {
            let fps = r.health.compactMap { $0.1["footprint_mb"].flatMap { Double($0) } }
            p("HEALTH\tcount=\(r.health.count)\tlast: cpu_s=\(h.1["cpu_s"] ?? "-") footprint_mb=\(h.1["footprint_mb"] ?? "-") rss_mb=\(h.1["rss_mb"] ?? "-")"
              + " passes=\(h.1["passes"] ?? "-") view=\(h.1["view"] ?? "-") mem_hz=\(h.1["mem_hz"] ?? "-")\tmax_footprint_mb=\(fps.max().map { String(format: "%.1f", $0) } ?? "-")")
        } else { p("HEALTH\tcount=0") }
        p("ERR\t" + (r.errs.isEmpty ? "0" : r.errs.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: "; ")))
        p("WARN\t" + (r.warns.isEmpty ? "0" : r.warns.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: "; ")))
        p("CTL\t\(r.ctl)")
        for d in r.dev.prefix(50) { p("DEV\t\(d)") }
        for w in r.win.prefix(50) { p("WIN\t\(w)") }
        p("")
        p("## verdicts (criterion #6: memory ≤ \(memMax) s, battery ≤ \(batMax) s)")
        let summaryOnly = !levels.isEmpty && !levels.contains("sample")
        if summaryOnly || r.memAll.n == 0 {
            verdict("mem_interval_max", nil, summaryOnly ? "log_level=summary decimates MEM (D4) — rerun with --log-level sample" : "no MEM intervals")
        } else {
            verdict("mem_interval_max", r.memAll.max! <= memMax, String(format: "max %.3f s (visible %@, occluded %@)", r.memAll.max!,
                    r.memVis.max.map { String(format: "%.3f", $0) } ?? "-", r.memOcc.max.map { String(format: "%.3f", $0) } ?? "-"))
            if r.memOcc.n > 0 { verdict("mem_interval_max_occluded", r.memOcc.max! <= memMax, String(format: "max %.3f s over %d intervals", r.memOcc.max!, r.memOcc.n)) }
        }
        if r.batCount.isEmpty { verdict("bat_interval_max", nil, "no BAT lines") }
        for d in r.batCount.keys.sorted() {
            let dist = r.batPerDev[d] ?? Dist()
            let tail = r.last - (r.batLastSeen[d] ?? r.last)
            if dist.n == 0 { verdict("bat_interval_max[\(d)]", nil, "only one BAT line"); continue }
            verdict("bat_interval_max[\(d)]", dist.max! <= batMax, String(format: "max %.1f s over %d intervals (tail since last line %.1f s)", dist.max!, dist.n, tail))
        }
        if r.spInt.n > 0 { verdict("sp_interval_max", r.spInt.max! <= spMax, String(format: "max %.1f s over %d intervals", r.spInt.max!, r.spInt.n)) }
        let overall = !ok ? "FAIL" : (incomplete ? "INCOMPLETE" : "PASS")
        p("overall\t\(overall)\t(INCOMPLETE = a required verdict is NOT APPLICABLE)")
        var json: [String: Any] = ["files": r.files, "first": fmtT(r.first), "last": fmtT(r.last), "lines": r.lines, "runs": r.runs,
                                   "log_level": r.logLevel, "occlusion_source": r.occ.source, "occluded_s": r.occludedSeconds,
                                   "mem": ["all": r.memAll.dict, "visible": r.memVis.dict, "occluded": r.memOcc.dict, "lines": r.memCount,
                                           "seq_gaps": r.memSeqGaps, "seq_missing": r.memSeqGapMissing],
                                   "dsp": ["count": r.dspCount, "stale": r.dspStale, "sim": r.dspSim, "interval": r.dspInt.dict, "regions": r.dspRegions,
                                           "regions_by_view": r.dspRegionsByView],
                                   "cpu": ["lines": r.cpuCount, "fail": r.cpuFail, "skip": r.cpuSkip, "sys": r.cpuSys.dict, "user": r.cpuUser.dict, "idle": r.cpuIdle.dict],
                                   "net": ["lines": r.netCount, "fail": r.netFail, "skip": r.netSkip, "counter_reset": r.netCounterReset,
                                           "rx_bps": r.netRx.dict, "tx_bps": r.netTx.dict],
                                   "ui": r.ui,
                                   "sp": ["count": r.spCount, "interval": r.spInt.dict, "failures": r.spFail],
                                   "hist_count": r.hist.count, "errors": r.errs, "verdicts": verdicts, "overall": overall]
        var bat: [String: Any] = [:]
        for (d, c) in r.batCount { bat[d] = ["lines": c, "interval": (r.batPerDev[d] ?? Dist()).dict] }
        json["bat"] = bat
        return (o, ok && !incomplete, json)
    }

    // MARK: - selftest (synthetic log, known answers)

    static func selftest() -> Bool {
        var ok = true
        func expect(_ n: String, _ c: Bool, _ d: String = "") { print("\(c ? "PASS" : "FAIL")\t\(n)\t\(d)"); if !c { ok = false } }
        // timestamp parser
        let t0 = TS.parse("2026-10-01T05:07:13.250+08:00")!
        expect("ts-parse", abs(t0 - (1790802433.25 - 0)) < 1e-6 || abs(t0 - TS.parse("2026-09-30T21:07:13.250Z")!) < 1e-6, String(t0))
        expect("ts-offset", abs(TS.parse("2026-10-01T05:07:13.250+08:00")! - TS.parse("2026-09-30T21:07:13.250Z")!) < 1e-6)
        expect("ts-bad", TS.parse("garbage") == nil && TS.parse("2026-10-01 05:07:13") == nil)
        // body parser
        let (kv, qs) = parseBody(#"seq=7 dur_us=9 mode=mte sim=0 phys=25769803776 "24.00 GB" used=19883098112 "18.52 GB" name="Alex’s Magic Keyboard" pct=48"#)
        expect("body-kv", kv["seq"] == "7" && kv["phys"] == "25769803776" && kv["pct"] == "48" && kv["name"] == "Alex’s Magic Keyboard", "\(kv)")
        expect("body-quoted", qs["phys"] == "24.00 GB" && qs["used"] == "18.52 GB" && qs["name"] == nil, "\(qs)")
        // synthetic log: 120 s, MEM 4 Hz with one 1.2 s hole at t=30 s and a 2.5 s hole at t=80 s (inside an occluded period
        // 70–90 s), BAT kb every 15 s, tp every 15 s with one 50 s gap, SP every 20 s, DSP 2 Hz.
        func ts(_ s: Double) -> String {
            let d = Date(timeIntervalSince1970: 1790802400 + s)
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSxxx"
            return f.string(from: d)
        }
        var L: [(Double, String)] = []
        L.append((0, "START build=x pid=1 mode=app args=\"\" mem_hz=4 audit_hz=0.2 sp_period=20 log_level=sample summary_s=10 selftest=ok mibs=20/20 locale=en_TW sim=0"))
        var seq = 0
        var t = 0.0
        while t < 120 {
            if (t >= 30 && t < 31.2) || (t >= 80 && t < 82.5) { t += 0.25; continue }
            L.append((t, "MEM seq=\(seq) dur_us=9 mode=mte sim=0 phys=25769803776 \"24.00 GB\" pct=48 lvl=1 fail=-"))
            seq += 1; t += 0.25
        }
        for k in 0..<240 { L.append((Double(k) * 0.5 + 0.01, "DSP seq=\(k) mem_seq=\(k * 2) clock=05:07:13 regions=used,clock bat=\"kb:100\" page=1/1 stale=0 sim=0")) }
        for k in 0...7 { L.append((Double(k) * 15 + 1, "BAT dev=aa:bb kind=keyboard name=\"KB\" pct=100 chg=0 conn=1 src=hid sim=0")) }
        for tt in [1.0, 16, 31, 81, 96, 111] { L.append((tt + 0.5, "BAT dev=cc:dd kind=trackpad name=\"TP\" pct=85 chg=0 conn=1 src=hid sim=0")) }
        for k in 0..<6 { L.append((Double(k) * 20 + 2, "SP rc=0 ms=74 connected=2 not_connected=2 trigger=timer sim=0")) }
        L.append((70, "WIN event=occlusion occluded=1"))
        L.append((90, "WIN event=occlusion occluded=0"))
        L.append((60, "HIST n=60 span_s=59 coverage_s=60 sim_points=0"))
        L.append((100, "ERR src=mem.swap err=injected sim=1"))
        L.sort { $0.0 < $1.0 }
        let lines = L.compactMap { parseLine(Substring(ts($0.0) + " " + $0.1), fileIndex: 0) }
        expect("parse-all", lines.count == L.count, "\(lines.count)/\(L.count)")
        let r = analyze(lines, manualOcc: [], gapsTop: 5)
        expect("mem-max", abs((r.memAll.max ?? 0) - 2.75) < 1e-6, r.memAll.row())
        expect("mem-occluded-max", abs((r.memOcc.max ?? 0) - 2.75) < 1e-6 && r.memOcc.n == 70, r.memOcc.row())
        expect("mem-visible-max", abs((r.memVis.max ?? 0) - 1.5) < 1e-6, r.memVis.row())
        expect("mem-gap-top", r.memTop.count == 5 && abs(r.memTop[0].0 - 2.75) < 1e-6 && r.memTop[0].2 && abs(r.memTop[1].0 - 1.5) < 1e-6 && !r.memTop[1].2)
        expect("occ-source", r.occ.source.hasPrefix("WIN") && abs(r.occludedSeconds - 20) < 1e-6, "\(r.occludedSeconds)")
        expect("bat-kb", abs((r.batPerDev["aa:bb"]?.max ?? 0) - 15) < 1e-6 && r.batPerDev["aa:bb"]?.n == 7)
        expect("bat-tp-gap", abs((r.batPerDev["cc:dd"]?.max ?? 0) - 50) < 1e-6)
        expect("sp", r.spCount == 6 && abs((r.spInt.max ?? 0) - 20) < 1e-6)
        expect("dsp", r.dspCount == 240 && r.dspRegions["used"] == 240 && abs((r.dspInt.max ?? 0) - 0.5) < 1e-6)
        expect("err", r.errs["src=mem.swap err=injected sim=1"] == 1)
        let (text, allOK, _) = render(r, memMax: 2.0, batMax: 60, spMax: 60, since: nil, until: nil)
        expect("verdict-fail-on-2.75s", !allOK && text.contains("verdict\tmem_interval_max\tFAIL"))
        let (text2, ok2, _) = render(r, memMax: 3.0, batMax: 60, spMax: 60, since: nil, until: nil)
        expect("verdict-pass-at-3s", ok2 && text2.contains("verdict\tbat_interval_max[cc:dd]\tPASS"))
        let r2 = analyze(lines, manualOcc: [(1790802400 + 10, 1790802400 + 20)], gapsTop: 3)
        expect("manual-occ", r2.occ.source.hasPrefix("manual") && abs(r2.occludedSeconds - 10) < 1e-6 && abs((r2.memOcc.max ?? 0) - 0.25) < 1e-6)
        // v2: CPU / NET / UI lines, DSP regions per view, WARN net_counter_reset
        var V: [(Double, String)] = [(0, "START log_level=sample sim=0")]
        for k in 0..<10 {
            V.append((Double(k) + 0.01, "CPU seq=\(k) dur_us=120 sys=\(k == 3 ? "-" : "4.00") user=\(k == 3 ? "-" : "16.00") idle=\(k == 3 ? "-" : "80.00") nice=0.00 cores=12 threads=4783 procs=795 sim=0 fail=\(k == 3 ? "cpu.load" : "-") skip=\(k == 0 ? "baseline" : "-")"))
            V.append((Double(k) + 0.02, "NET seq=\(k) dur_us=150 ifaces=14 pkt_in=1 pkt_out=1 pkt_in_s=- pkt_out_s=- rx=1 tx=1 rx_bps=\(k == 0 ? "-" : String(k * 1000)) tx_bps=\(k == 0 ? "-" : "500") sim=0 fail=- skip=-"))
            V.append((Double(k) + 0.03, "DSP seq=\(k) mem_seq=- sys_seq=\(k) clock=05:07:13 regions=cpuSys,graph bat=\"hidden\" page=1/1 stale=0 draw_us=99 view=cpu lang=en batv=0 sim=0"))
        }
        V.append((5.5, "DSP seq=99 mem_seq=7 clock=05:07:13 regions=used,graph bat=\"kb:100\" page=1/1 stale=0 sim=0"))
        V.append((6, "WARN net_counter_reset if=en0 field=ibytes"))
        V.append((7, "UI event=view from=mem to=cpu via=hotkey"))
        V.append((7.05, "UI event=dedup action=toggle_battery via=hotkey first_via=menu"))
        V.append((8, "HEALTH cpu_s=1.0 footprint_mb=11 rss_mb=29 draws=60 passes=60 view=cpu mem_hz=1 sim=0"))
        V.sort { $0.0 < $1.0 }
        let rv = analyze(V.compactMap { parseLine(Substring(ts($0.0) + " " + $0.1), fileIndex: 0) }, manualOcc: [], gapsTop: 3)
        expect("v2-cpu", rv.cpuCount == 10 && rv.cpuFail == 1 && rv.cpuSkip == 1 && abs((rv.cpuSys.mean ?? 0) - 4) < 1e-9 && rv.cpuSys.n == 9)
        expect("v2-net", rv.netCount == 10 && rv.netRx.n == 9 && rv.netRx.max == 9000 && rv.netCounterReset == 1)
        expect("v2-ui", rv.ui["view"] == 1 && rv.ui["dedup"] == 1)
        expect("v2-dsp-by-view", rv.dspRegionsByView["cpu"]?["cpuSys"] == 10 && rv.dspRegionsByView["mem"]?["used"] == 1 && rv.dspRegions["graph"] == 11)
        let (tv, _, _) = render(rv, memMax: 2, batMax: 60, spMax: 60, since: nil, until: nil)
        expect("v2-render", tv.contains("DSP_regions[view=cpu]\tcpuSys=10") && tv.contains("CPU\tlines=10\tfail=1\tskip=1\tsys_mean=4.00")
               && tv.contains("counter_reset=1") && tv.contains("UI\tdedup=1 view=1") && tv.contains("passes=60 view=cpu mem_hz=1"))
        // summary-level log → NOT APPLICABLE
        let sumLines = [parseLine(Substring(ts(0) + " START log_level=summary sim=0"), fileIndex: 0)!,
                        parseLine(Substring(ts(1) + " MEM seq=0 sim=0"), fileIndex: 0)!, parseLine(Substring(ts(11) + " MEM seq=40 sim=0"), fileIndex: 0)!]
        let (t3, _, _) = render(analyze(sumLines, manualOcc: [], gapsTop: 3), memMax: 2, batMax: 60, spMax: 60, since: nil, until: nil)
        expect("summary-level-na", t3.contains("mem_interval_max\tNOT APPLICABLE"))
        print(ok ? "logstats selftest: all passed" : "logstats selftest: FAILED")
        return ok
    }
}
