// AMCompare+DryRun.swift — `amcompare dry-run`: runs the complete criterion-#4 harness (preflight, protocol.md,
// scheduling, AX 50 Hz refresh detection, OCR, colour classification, DSP join, judgement, attempts.tsv, report.png,
// summary.md) with synthetic inputs instead of Activity Monitor / screencapture / the live panel log:
//   * AM: a scripted AX source (values change 0.3 s after polling starts) and a synthetic 3840×2160 "LG" image with an
//     AM-like footer drawn by CoreText at the AX frames, plus a pressure graph filled with AM's gradient colours.
//   * panel: a real offscreen render of the panel (`WokyisPanel --snapshot … --dump-rects`) = wokyis.png + rects +
//     state.json, and a synthetic sample-level log (START, MEM, DSP) whose strings come from state.json.
// Each scenario has a known expected outcome; `--scenario all` checks them all (exit 0 only if every one matches).
import Foundation
import CoreGraphics

let dryMain = CGRect(x: 0, y: 0, width: 1920, height: 1080)

final class SyntheticAM: AMSource {
    var v0: [String], v1: [String]
    var refreshAt = Date.distantFuture
    var failReads = false
    let valueFrames: [CGRect]
    let labelFrames: [CGRect]
    let graphFrame: CGRect?
    let windowFrame: CGRect? = CGRect(x: 300, y: 200, width: 1100, height: 700)
    let windowID: CGWindowID? = 4242
    init(v0: [String], v1: [String]) {
        self.v0 = v0; self.v1 = v1
        var vf: [CGRect] = [], lf: [CGRect] = []
        let rows: [(CGFloat, CGFloat)] = [(560, 745), (560, 765), (560, 785), (560, 805), (820, 745), (820, 765), (820, 785)]
        for (x, y) in rows { lf.append(CGRect(x: x, y: y, width: 118, height: 16)); vf.append(CGRect(x: x + 125, y: y, width: 80, height: 16)) }
        valueFrames = vf; labelFrames = lf
        graphFrame = CGRect(x: 330, y: 765, width: 190, height: 80)
    }
    func read() -> [String]? {
        if failReads { return nil }
        return Date() < refreshAt ? v0 : v1
    }
    func visibility() -> (ok: Bool, detail: String) { (true, "synthetic window, always visible") }
    var describe: String { "synthetic AM (dry run)" }
}

/// Draws the synthetic LG frame; copies the panel snapshot as the Wokyis frame.
struct SyntheticCapturer: Capturer {
    let am: SyntheticAM
    let lgValues: () -> [String]
    let graphRGB: (CGFloat, CGFloat, CGFloat)
    let panelPNG: String
    let duration: () -> Double
    func capture(lg: String, wk: String) -> CaptureResult {
        let t0 = Date()
        let s: CGFloat = 2
        let bm = Bitmap(width: Int(dryMain.width * s), height: Int(dryMain.height * s))
        let H = bm.height
        let ctx = bm.ctx
        ctx.setFillColor(rgba(0.12, 0.12, 0.13)); ctx.fill(CGRect(x: 0, y: 0, width: bm.width, height: H))
        if let w = am.windowFrame {
            ctx.setFillColor(rgba(0.17, 0.17, 0.18))
            ctx.fill(CGRect(x: w.minX * s, y: CGFloat(H) - w.maxY * s, width: w.width * s, height: w.height * s))
        }
        let vals = lgValues()
        let labels = MemField.allCases.map { $0.amLabels[0] }
        for (i, f) in am.labelFrames.enumerated() {
            drawText(ctx, labels[i], x: f.minX * s, yTop: f.minY * s, imageHeight: H, size: 11 * s, color: rgba(0.7, 0.7, 0.72), bold: false)
            let v = am.valueFrames[i]
            drawText(ctx, vals[i], x: v.minX * s + 4, yTop: v.minY * s, imageHeight: H, size: 11 * s, color: rgba(0.95, 0.95, 0.95), bold: false)
        }
        if let g = am.graphFrame {
            drawText(ctx, "MEMORY PRESSURE", x: g.minX * s, yTop: (g.minY - 20) * s, imageHeight: H, size: 10 * s, color: rgba(0.7, 0.7, 0.72), bold: true)
            // 3-pt columns, AM gradient alpha 0.5 → 0.333 over the window background (approximated with a flat 0.45)
            let bg = (0.17, 0.17, 0.18), a = 0.45
            let c = rgba(graphRGB.0 * a + CGFloat(bg.0) * (1 - a), graphRGB.1 * a + CGFloat(bg.1) * (1 - a), graphRGB.2 * a + CGFloat(bg.2) * (1 - a))
            ctx.setFillColor(c)
            var x = g.maxX
            var k = 0
            while x - 3 >= g.minX {
                let pct = 0.45 + 0.1 * sin(Double(k) / 5)
                let hh = g.height * CGFloat(pct)
                ctx.fill(CGRect(x: (x - 3) * s, y: CGFloat(H) - g.maxY * s, width: 3 * s, height: hh * s))
                x -= 3; k += 1
            }
        }
        writePNG(bm.makeImage(), lg)
        try? FileManager.default.removeItem(atPath: wk)
        try? FileManager.default.copyItem(atPath: panelPNG, toPath: wk)
        // the synthetic capture "takes" `duration()` seconds: t1 = t0 + duration (sleep the rest, so later timestamps stay ordered)
        let d = duration()
        let t1 = t0.addingTimeInterval(d)
        if t1 > Date() { Thread.sleep(until: t1) }
        return CaptureResult(t0: t0, t1: t1, rc: 0, error: nil)
    }
}

final class SyntheticLog {
    let path: String
    var memSeq: UInt64 = 1000, dspSeq: UInt64 = 5000
    init(path: String, start: Date) {
        self.path = path
        writeText("\(isoNow(start)) START build=dryrun pid=\(getpid()) mode=app args=\"--log-level sample\" mem_hz=4 audit_hz=0.2 sp_period=20 log_level=sample summary_s=10 selftest=ok mibs=20/20 locale=en_TW sim=0\n", path)
    }
    func mem(_ t: Date, _ s: [String], pct: String, lvl: String) -> UInt64 {
        memSeq += 1
        let keys = MemField.allCases.map { $0.memKey }
        let body = zip(keys, s).map { "\($0.0)=\(ByteString.parse($0.1).map { String(Int64($0.bytes)) } ?? "-") \"\($0.1)\"" }.joined(separator: " ")
        appendText("\(isoNow(t)) MEM seq=\(memSeq) dur_us=9 mode=mte sim=0 \(body) pct=\(pct) lvl=\(lvl) fail=-\n", path)
        return memSeq
    }
    func dsp(_ t: Date, mem: UInt64, regions: String) {
        dspSeq += 1
        appendText("\(isoNow(t)) DSP seq=\(dspSeq) mem_seq=\(mem) clock=00:00:00 regions=\(regions) bat=\"kb:100\" page=1/1 stale=0 sim=0\n", path)
    }
    func aud(_ t: Date) { appendText("\(isoNow(t)) AUD fresh=1 same=0 age_ms=- d_used=3 d_cached=0 d_app=-1 d_wired=0 d_comp=0 free_err=2 mode=mte\n", path) }
}

enum DryRun {
    struct Scenario { let name: String; let expect: Harness.Outcome; let expectAttempts: Int; let expectReason: InvalidReason?; let about: String }
    static let scenarios: [Scenario] = [
        Scenario(name: "pass", expect: .pass, expectAttempts: 3, expectReason: nil, about: "all fields within thresholds at 3 time points"),
        Scenario(name: "retry", expect: .pass, expectAttempts: 4, expectReason: .iii, about: "first attempt of point 1 has a 700 ms capture (iii), the retry is valid"),
        Scenario(name: "fail-used", expect: .fail, expectAttempts: 1, expectReason: nil, about: "Memory Used differs by 0.28 GB → FAIL, stop after point 1"),
        Scenario(name: "fail-pressure", expect: .fail, expectAttempts: 1, expectReason: nil, about: "AM graph yellow vs panel green → FAIL"),
        Scenario(name: "invalid-am-ocr", expect: .incomplete, expectAttempts: 3, expectReason: .i, about: "LG image shows values ≠ ax_before/ax_after → (i) ×3"),
        Scenario(name: "invalid-panel", expect: .incomplete, expectAttempts: 3, expectReason: .ii, about: "log MEM strings ≠ panel image → (ii) ×3"),
        Scenario(name: "slow", expect: .incomplete, expectAttempts: 3, expectReason: .iii, about: "capture 700 ms → (iii) ×3"),
        Scenario(name: "ax-fail", expect: .incomplete, expectAttempts: 3, expectReason: .iv, about: "AX reads fail after preflight → (iv) ×3"),
        Scenario(name: "control", expect: .incomplete, expectAttempts: 3, expectReason: .v, about: "control.json gets an injection after preflight → (v) ×3"),
        Scenario(name: "am-colour-unknown", expect: .fail, expectAttempts: 1, expectReason: nil, about: "AM graph blue (unclassifiable) → valid attempt, pressure colour FAIL, stop"),
        Scenario(name: "no-refresh", expect: .aborted, expectAttempts: 1, expectReason: nil, about: "AX works but AM never refreshes → precondition not met → ABORTED (not an invalid reason)"),
    ]

    /// Offscreen panel render via the app binary → png, rects, state strings.
    static func panelSnapshot(bin: String, dir: String) -> (png: String, rects: String, strings: [String], pct: String, lvl: String)? {
        let png = dir + "/panel_snapshot.png"
        let r = runProcess(bin, ["--snapshot", png, "--dump-rects"])
        guard r.rc == 0, let rects = try? String(contentsOfFile: dir + "/panel_snapshot.rects.tsv", encoding: .utf8),
              let sd = FileManager.default.contents(atPath: dir + "/panel_snapshot.state.json"),
              let st = try? JSONSerialization.jsonObject(with: sd) as? [String: Any], let mem = st["memory"] as? [String: Any] else {
            print("dry-run: panel snapshot failed (rc \(r.rc)): \(r.out.prefix(300))"); return nil
        }
        let strings = MemField.allCases.map { (mem[$0.rawValue] as? String) ?? "—" }
        let lvl = (mem["pressure_level"] as? Int).map(String.init) ?? "-"
        return (png, rects, strings, (mem["pressure_percent"] as? String) ?? "—", lvl)
    }

    /// AM strings = panel strings shifted by `deltaGiB` (per field; physical never shifted).
    static func shifted(_ s: [String], _ d: [MemField: Double]) -> [String] {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .memory; fmt.allowedUnits = .useAll; fmt.zeroPadsFractionDigits = true; fmt.allowsNonnumericFormatting = false
        fmt.formattingContext = .listItem
        return zip(MemField.allCases, s).map { f, v in
            guard let delta = d[f], let b = ByteString.parse(v) else { return v }
            return fmt.string(fromByteCount: Int64(b.bytes + delta * Double(1 << 30)))
        }
    }

    static func run(scenario sc: Scenario, root: String, panelBin: String, toolHash: String) -> (Harness.Outcome, [String]) {
        let dir = root + "/" + sc.name
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let snap = panelSnapshot(bin: panelBin, dir: dir) else { return (.aborted, ["no panel snapshot"]) }
        let MiB = 1.0 / 1024
        var deltas: [MemField: Double] = [.used: 0.08, .cached: -0.05, .swap: 0.3 * MiB, .app: 0.1, .compressed: -0.19]
        if sc.name == "fail-used" { deltas[.used] = 0.28 }
        let v1 = shifted(snap.strings, deltas)
        var d0 = deltas; d0[.used] = (deltas[.used] ?? 0) - 0.01
        let v0 = shifted(snap.strings, d0)
        let am = SyntheticAM(v0: v0, v1: v1)
        let logPath = dir + "/panel.log", ctlPath = dir + "/control.json"
        try? FileManager.default.removeItem(atPath: ctlPath)
        let log = SyntheticLog(path: logPath, start: Date().addingTimeInterval(-120))
        var logStrings = snap.strings
        if sc.name == "invalid-panel" { logStrings = shifted(snap.strings, [.used: 0.05]) }   // log ≠ what the image shows
        // recent lines so that preflight sees a live sample-level log
        let now = Date()
        let m0 = log.mem(now.addingTimeInterval(-0.5), snap.strings, pct: snap.pct, lvl: snap.lvl)
        log.dsp(now.addingTimeInterval(-0.47), mem: m0, regions: "used,pressure")
        var attemptNo = 0
        let graph: (CGFloat, CGFloat, CGFloat) = sc.name == "fail-pressure" ? (0.941, 0.745, 0.141) : sc.name == "am-colour-unknown" ? (0.2, 0.35, 1.0) : (snap.lvl == "4" ? (1, 0, 0) : (snap.lvl == "2" ? (0.941, 0.745, 0.141) : (0, 0.8, 0)))
        let cap = SyntheticCapturer(am: am, lgValues: {
            if sc.name == "invalid-am-ocr" { return shifted(v1, [.cached: 0.5]) }
            return v1
        }, graphRGB: graph, panelPNG: snap.png, duration: {
            if sc.name == "slow" || (sc.name == "retry" && attemptNo == 1) { return 0.7 }
            return 0.3
        })
        let h = Harness(am: am, capturer: cap, controlPath: ctlPath, logPath: logPath, rectsTSV: snap.rects, mainBounds: dryMain,
                        compositeBin: nil, hostCallers: { [] }, panelPid: getpid())
        h.dry = true
        h.spacing = 2
        h.logWait = 0.4
        h.refreshTimeout = 2
        h.toolHash = toolHash
        h.beforePoll = {
            attemptNo += 1
            am.refreshAt = sc.name == "no-refresh" ? .distantFuture : Date().addingTimeInterval(0.3)
            if sc.name == "ax-fail" { am.failReads = true }
            if sc.name == "control" { writeText(#"{"version":1,"expires":"2099-01-01T00:00:00+08:00","fail":["mem.swap"]}"#, ctlPath) }
        }
        h.afterCapture = { c in
            let s1 = log.mem(c.t0.addingTimeInterval(-0.35), logStrings, pct: snap.pct, lvl: snap.lvl)
            log.dsp(c.t0.addingTimeInterval(-0.32), mem: s1, regions: "used,sec1")
            log.aud(c.t0.addingTimeInterval(-0.2))
            let s2 = log.mem(c.t0.addingTimeInterval(0.15), logStrings, pct: snap.pct, lvl: snap.lvl)
            log.dsp(c.t0.addingTimeInterval(0.18), mem: s2, regions: "used")
            log.dsp(c.t1.addingTimeInterval(0.2), mem: s2, regions: "clock")
        }
        let stamp = compactStamp(Date())
        let outcome = h.run(root: dir, stamp: stamp)
        // collect first reasons from attempts.tsv
        var reasons: [String] = []
        if let t = try? String(contentsOfFile: h.runDir + "/attempts.tsv", encoding: .utf8) {
            for line in t.split(separator: "\n").dropFirst() { let c = line.split(separator: "\t", omittingEmptySubsequences: false); if c.count > 4 { reasons.append(String(c[4])) } }
        }
        return (outcome, reasons)
    }

    static func main(_ a: Args, toolHash: String, root: String) -> Int32 {
        let out = a.one("out") ?? NSTemporaryDirectory() + "amcompare-dryrun-\(compactStamp(Date()))"
        let panelBin = a.one("panel-bin") ?? root + "/build/WokyisPanel.app/Contents/MacOS/WokyisPanel"
        guard FileManager.default.isExecutableFile(atPath: panelBin) else { print("dry-run needs the panel binary for the offscreen render: \(panelBin)"); return 2 }
        let which = a.one("scenario") ?? "all"
        let list = which == "all" ? scenarios : scenarios.filter { $0.name == which }
        guard !list.isEmpty else { print("unknown scenario \(which); known: \(scenarios.map { $0.name }.joined(separator: " "))"); return 2 }
        var allOK = true
        var table = "scenario\texpected\tgot\tattempts\treasons\tresult\tabout\n"
        for sc in list {
            print("=== dry-run scenario \(sc.name): \(sc.about)")
            let (o, reasons) = run(scenario: sc, root: out, panelBin: panelBin, toolHash: toolHash)
            var ok = o == sc.expect && reasons.count == sc.expectAttempts
            if let r = sc.expectReason { ok = ok && reasons.contains { $0.split(separator: ",").contains(Substring(r.rawValue)) } }
            else if sc.expect == .aborted { ok = ok && reasons.allSatisfy { $0 == "aborted" } }
            else { ok = ok && reasons.allSatisfy { $0 == "-" } }
            if !ok { allOK = false }
            table += "\(sc.name)\t\(sc.expect.rawValue)\t\(o.rawValue)\t\(reasons.count)\t\(reasons.joined(separator: " "))\t\(ok ? "OK" : "MISMATCH")\t\(sc.about)\n"
        }
        writeText(table, out + "/dryrun_results.tsv")
        print(table, terminator: "")
        print("dry-run: \(allOK ? "all scenarios behaved as expected" : "SOME SCENARIOS DID NOT BEHAVE AS EXPECTED") → \(out)")
        return allOK ? 0 : 1
    }
}

func compactStamp(_ d: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: d)
}
