// AMCompare+Run.swift — criterion-#4 harness: preflight, protocol.md, time points / attempts, capture, OCR, join,
// judgement and all per-attempt / per-run outputs (spec §15 #4).
import Foundation
import AppKit
import CoreGraphics

// MARK: - process helpers

@discardableResult
func runProcess(_ path: String, _ args: [String]) -> (rc: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

let hostCallerNames = ["vm_stat", "top", "amcal", "hsprobe", "memprobe", "procstat"]
func runningHostCallers() -> [String] {
    hostCallerNames.compactMap { n in
        let r = runProcess("/usr/bin/pgrep", ["-x", n])
        return r.rc == 0 ? "\(n)(pid \(r.out.split(separator: "\n").joined(separator: ",")))" : nil
    }
}

func procName(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 1024)
    return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
}

func imageSize(_ path: String) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}

func sha256File(_ path: String) -> String {
    let r = runProcess("/usr/bin/shasum", ["-a", "256", path])
    return r.rc == 0 ? String(r.out.prefix(64)) : "?"
}

func nn(_ x: Any?) -> Any { x ?? NSNull() }
func writeText(_ s: String, _ path: String) { FileManager.default.createFile(atPath: path, contents: s.data(using: .utf8)) }
func appendText(_ s: String, _ path: String) {
    if !FileManager.default.fileExists(atPath: path) { writeText(s, path); return }
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(s.data(using: .utf8)!); h.closeFile() }
}
func jsonString(_ o: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
    return String(data: d, encoding: .utf8)!
}

// MARK: - capture

struct CaptureResult { let t0: Date; let t1: Date; let rc: Int32; let error: String? }
protocol Capturer { func capture(lg: String, wk: String) -> CaptureResult }

/// ONE `screencapture -x lg.png wokyis.png` call (first file = main display, second = Wokyis), bracketed by t0/t1.
struct ScreenCapturer: Capturer {
    func capture(lg: String, wk: String) -> CaptureResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", lg, wk]
        let t0 = Date()
        do { try p.run() } catch { return CaptureResult(t0: t0, t1: Date(), rc: -1, error: "\(error)") }
        p.waitUntilExit()
        let t1 = Date()
        return CaptureResult(t0: t0, t1: t1, rc: p.terminationStatus, error: p.terminationStatus == 0 ? nil : "screencapture rc=\(p.terminationStatus)")
    }
}

// MARK: - environment

final class Harness {
    var am: AMSource
    var capturer: Capturer
    var controlPath: String
    var logPath: String
    var rectsTSV: String?
    var mainBounds: CGRect
    var compositeBin: String?
    var hostCallers: () -> [String]
    var panelPid: pid_t?
    var points = 3, attemptsPerPoint = 3
    var spacing: Double = 60
    var logWait: Double = 1.3
    var refreshTimeout: Double = 12     // > 2 × AM's slowest update period (5 s): no refresh = precondition not met
    var dry = false
    var beforePoll: (() -> Void)? = nil        // dry-run hook (scripted AM refresh)
    var afterCapture: ((CaptureResult) -> Void)? = nil   // dry-run hook (synthetic log lines)
    var runDir = ""
    var protocolHash = ""
    var toolHash = ""

    init(am: AMSource, capturer: Capturer, controlPath: String, logPath: String, rectsTSV: String?, mainBounds: CGRect,
         compositeBin: String?, hostCallers: @escaping () -> [String], panelPid: pid_t?) {
        self.am = am; self.capturer = capturer; self.controlPath = controlPath; self.logPath = logPath; self.rectsTSV = rectsTSV
        self.mainBounds = mainBounds; self.compositeBin = compositeBin; self.hostCallers = hostCallers; self.panelPid = panelPid
    }

    func controlEmpty() -> (empty: Bool, detail: String) { ControlState.isEmpty(FileManager.default.contents(atPath: controlPath)) }

    // MARK: log tail
    func readLog(from: Double, to: Double) -> PanelLog {
        guard let h = FileHandle(forReadingAtPath: (logPath as NSString).resolvingSymlinksInPath) else { return PanelLog() }
        defer { h.closeFile() }
        let size = h.seekToEndOfFile()
        let chunk: UInt64 = 8 << 20
        h.seek(toFileOffset: size > chunk ? size - chunk : 0)
        let data = h.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        var pl = LogParse.parse(text, from: from, to: to)
        // START is the first line of the process's first file: panel-YYYYMMDD-HHMMSS.log (rotations are …-001.log, …)
        var first = (logPath as NSString).resolvingSymlinksInPath
        if let r = first.range(of: #"-[0-9]{3}\.log$"#, options: .regularExpression) { first.replaceSubrange(r, with: ".log") }
        if pl.startLevel == nil, let h2 = FileHandle(forReadingAtPath: first) {
            let head = LogParse.parse(String(decoding: h2.readData(ofLength: 4096), as: UTF8.self))
            pl.startLevel = head.startLevel; pl.startT = head.startT
            h2.closeFile()
        }
        return pl
    }

    // MARK: preflight
    struct Check { let name: String; let ok: Bool; let detail: String }

    func preflight() -> [Check] {
        var cs: [Check] = []
        if let p = panelPid {
            let alive = kill(p, 0) == 0
            let name = procName(p) ?? "?"
            cs.append(Check(name: "panel process", ok: alive && (dry || name == "WokyisPanel"), detail: "pid \(p) alive=\(alive) comm=\(name)"))
        } else { cs.append(Check(name: "panel process", ok: false, detail: "no pid (run/panel.pid empty?)")) }
        let c = controlEmpty()
        cs.append(Check(name: "control.json empty", ok: c.empty, detail: "\(controlPath): \(c.detail)"))
        let hc = hostCallers()
        cs.append(Check(name: "no other host_statistics64 callers", ok: hc.isEmpty, detail: hc.isEmpty ? "pgrep -x \(hostCallerNames.joined(separator: " ")): none" : hc.joined(separator: " ")))
        let vals = am.read()
        cs.append(Check(name: "AX footer 7 values", ok: vals != nil && am.valueFrames.count == 7,
                        detail: vals.map { zip(MemField.allCases, $0).map { "\($0.0.title)=\($0.1)" }.joined(separator: " | ") } ?? "AX read failed: \(am.describe)"))
        cs.append(Check(name: "AX pressure graph element", ok: am.graphFrame != nil, detail: am.graphFrame.map { "frame \(fmtR($0)) (CG points)" } ?? "not found"))
        let v = am.visibility()
        cs.append(Check(name: "AM window visible, inside LG", ok: v.ok, detail: "\(am.describe): \(v.detail)"))
        let now = Date().timeIntervalSince1970
        let pl = readLog(from: now - 90, to: now + 5)
        let lastMem = pl.mem.values.map { $0.t }.max()
        let lastDsp = pl.dsp.last?.t
        cs.append(Check(name: "panel log at sample level", ok: pl.startLevel == "sample" && lastMem != nil && lastDsp != nil && now - lastMem! < 3 && now - lastDsp! < 5,
                        detail: "\(logPath): log_level=\(pl.startLevel ?? "?") last MEM \(lastMem.map { String(format: "%.1f s ago", now - $0) } ?? "none") last DSP \(lastDsp.map { String(format: "%.1f s ago", now - $0) } ?? "none")"))
        cs.append(Check(name: "panel running ≥ 60 s", ok: pl.startT.map { now - $0 >= 60 } ?? false,
                        detail: pl.startT.map { String(format: "START %.0f s ago", now - $0) } ?? "no START line found"))
        cs.append(Check(name: "panel value rects", ok: rectsTSV != nil && PanelRegions.crops(rectsTSV: rectsTSV).count == 8,
                        detail: rectsTSV == nil ? "no rects.tsv" : "\(rectsTSV!.split(separator: "\n").count - 1) rows"))
        if !dry, let p = panelPid {
            let wins = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).filter { ($0[kCGWindowOwnerPID as String] as? Int32) == p }
            let rects = wins.compactMap { w -> CGRect? in (w[kCGWindowBounds as String]).flatMap { CGRect(dictionaryRepresentation: $0 as! CFDictionary) } }
            let onWokyis = rects.filter { $0.width == 1280 && $0.height == 720 && !mainBounds.intersects($0) }
            cs.append(Check(name: "panel full-screen on the Wokyis", ok: !onWokyis.isEmpty, detail: rects.map(fmtR).joined(separator: " ; ")))
        }
        return cs
    }

    // MARK: attempt
    struct Attempt {
        var k = 0, point = 0, n = 0
        var reasons: [InvalidReason] = []
        var notes: [String] = []
        var tDet: Date?, cap: CaptureResult?
        var axBefore: [String]?, axAfter: [String]?
        var amOCR: [OCRResult] = [], amMatched = "-"
        var panelOCR: [OCRResult] = [], panelPctOCR: OCRResult?
        var dsp: PanelDSP?, mem: PanelMEM?
        var eligible: [UInt64] = []
        var amGraph: ColourSample.GraphSample?
        var panelPill: (cls: HueClass, hue: Double?, n: Int, rgb: (Int, Int, Int))?
        var fields: [Threshold.FieldResult] = []
        var pressurePass: Bool?
        var valid: Bool { reasons.isEmpty }
        var verdict: String { !valid ? "INVALID" : ((fields.allSatisfy { $0.pass } && pressurePass == true) ? "PASS" : "FAIL") }
        var aborted: String?
    }

    func attempt(k: Int, point: Int, n: Int, trace: String) -> Attempt {
        var a = Attempt(k: k, point: point, n: n)
        let dir = runDir + String(format: "/attempt-%02d", k)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let hc = hostCallers()
        if !hc.isEmpty { a.aborted = "host_statistics64 caller running: \(hc.joined(separator: " "))"; return a }
        let ctl0 = controlEmpty()
        if !ctl0.empty { a.reasons.append(.v); a.notes.append("control before: \(ctl0.detail)") }
        let vis0 = am.visibility()
        if !vis0.ok { a.reasons.append(.iv); a.notes.append("AM before: \(vis0.detail)") }
        // --- AX 50 Hz until AM refreshes
        beforePoll?()
        let tStart = Date()
        func traceRow(_ ev: String, _ v: [String]?) {
            let t = Date()
            appendText("\(k),\(isoNow(t)),\(Int(t.timeIntervalSince(tStart) * 1000)),\(v == nil ? 0 : 1),\(ev)," + (v ?? Array(repeating: "", count: 7)).map { "\"\($0)\"" }.joined(separator: ",") + "\n", trace)
        }
        guard let base = am.read() else {
            traceRow("baseline_fail", nil)
            if !a.reasons.contains(.iv) { a.reasons.append(.iv) }
            a.notes.append("AX baseline read failed")
            writeAttemptFiles(&a, dir: dir); return a
        }
        traceRow("baseline", base)
        var changed: [String]? = nil
        var next = Date()
        var pollOK = 0, pollFail = 0
        while Date().timeIntervalSince(tStart) < refreshTimeout {
            next = next.addingTimeInterval(0.02)
            let s = next.timeIntervalSinceNow
            if s > 0 { Thread.sleep(forTimeInterval: s) }
            guard let v = am.read() else { traceRow("poll_fail", nil); pollFail += 1; continue }
            pollOK += 1
            if v != base { changed = v; break }
            traceRow("poll", v)
        }
        guard let before = changed else {
            if pollOK == 0 {   // every AX poll failed → (iv) AX read failed
                if !a.reasons.contains(.iv) { a.reasons.append(.iv) }
                a.notes.append(String(format: "AX polls failed (%d) for %.0f s", pollFail, refreshTimeout))
                writeAttemptFiles(&a, dir: dir); return a
            }
            // AX reads work but AM never refreshed: the capture's precondition is not met. Not one of the five invalid
            // reasons (spec §15 #4) → no attempt is judged; the run stops and the user decides.
            a.aborted = String(format: "precondition not met: no AM refresh within %.0f s (AX values unchanged, %d reads ok, %d failed) — check AM's update frequency", refreshTimeout, pollOK, pollFail)
            writeAttemptFiles(&a, dir: dir); return a
        }
        a.tDet = Date()
        a.axBefore = before
        // --- capture immediately
        let lgPath = dir + "/lg.png", wkPath = dir + "/wokyis.png"
        let cap = capturer.capture(lg: lgPath, wk: wkPath)
        a.cap = cap
        a.axAfter = am.read()
        traceRow("ax_before", before); traceRow("ax_after", a.axAfter)
        afterCapture?(cap)
        if let e = cap.error { a.aborted = "capture failed: \(e)"; writeAttemptFiles(&a, dir: dir); return a }
        guard let wkSize = imageSize(wkPath), wkSize == (1280, 720), let lgSize = imageSize(lgPath) else {
            a.aborted = "capture files missing or Wokyis image not 1280x720 (display order changed?)"; writeAttemptFiles(&a, dir: dir); return a
        }
        if a.axAfter == nil { if !a.reasons.contains(.iv) { a.reasons.append(.iv) }; a.notes.append("AX read after capture failed") }
        let vis1 = am.visibility()
        if !vis1.ok { if !a.reasons.contains(.iv) { a.reasons.append(.iv) }; a.notes.append("AM after: \(vis1.detail)") }
        let ctl1 = controlEmpty()
        if !ctl1.empty { if !a.reasons.contains(.v) { a.reasons.append(.v) }; a.notes.append("control after: \(ctl1.detail)") }
        let capMs = cap.t1.timeIntervalSince(cap.t0) * 1000
        if capMs > 600 { a.reasons.append(.iii); a.notes.append(String(format: "capture %.0f ms", capMs)) }
        // --- AM OCR
        let lgImg = loadCGImage(lgPath), wkImg = loadCGImage(wkPath)
        for (i, _) in MemField.allCases.enumerated() where i < am.valueFrames.count {
            let r = Geo.toLG(am.valueFrames[i].insetBy(dx: -6, dy: -3), main: mainBounds, imageWidth: lgSize.0)
            a.amOCR.append(VisionOCR.read(lgImg, crop: r, scale: 2))
        }
        let amTexts = a.amOCR.map { $0.text }
        if OCRNorm.tupleEqual(amTexts, before) { a.amMatched = "ax_before" }
        else if let aft = a.axAfter, OCRNorm.tupleEqual(amTexts, aft) { a.amMatched = "ax_after" }
        else { a.reasons.append(.i); a.notes.append("AM OCR [\(amTexts.joined(separator: " | "))] ≠ ax_before / ax_after") }
        // --- AM pressure colour
        let lgBM = Bitmap(image: lgImg)
        if let g = am.graphFrame {
            let gs = ColourSample.amGraph(lgBM, framePx: Geo.toLG(g, main: mainBounds, imageWidth: lgSize.0))
            a.amGraph = gs
            // not an invalid reason (spec §15 #4): the attempt stays valid and its colour comparison FAILS (stop, ask the user)
            if gs.cls == .unknown { a.notes.append("AM graph colour not determinable (\(gs.note)) → pressure colour judged FAIL") }
        } else { if !a.reasons.contains(.iv) { a.reasons.append(.iv) }; a.notes.append("AX read failed: no graph frame") }
        // --- panel OCR + colour
        let crops = PanelRegions.crops(rectsTSV: rectsTSV)
        for f in MemField.allCases { a.panelOCR.append(VisionOCR.read(wkImg, crop: crops[f.rawValue]!, scale: 1)) }
        a.panelPctOCR = VisionOCR.read(wkImg, crop: crops["pressure"]!, scale: 1, expectBytes: false)
        let wkBM = Bitmap(image: wkImg)
        a.panelPill = ColourSample.panelPill(wkBM)
        // --- join with the panel log (wait for the next DSP commit to be written)
        let waitUntil = cap.t1.addingTimeInterval(logWait)
        if waitUntil > Date() { Thread.sleep(until: waitUntil) }
        let c0 = cap.t0.timeIntervalSince1970, c1 = cap.t1.timeIntervalSince1970
        let pl = readLog(from: c0 - 30, to: c1 + 10)
        let elig = Join.eligible(pl.dsp, cap0: c0, cap1: c1)
        a.eligible = elig.map { $0.seq }
        let pctDigits = String((a.panelPctOCR?.text ?? "").filter { $0.isNumber })
        if let m = Join.match(ocr: a.panelOCR.map { $0.text }, ocrPct: pctDigits.isEmpty ? "—" : pctDigits, eligible: elig, mem: pl.mem) {
            a.dsp = m.0; a.mem = m.1
            if m.0.sim || m.1.sim { if !a.reasons.contains(.v) { a.reasons.append(.v) }; a.notes.append("joined DSP/MEM carry sim=1") }
        } else {
            a.reasons.append(.ii)
            a.notes.append("panel OCR [\(a.panelOCR.map { $0.text }.joined(separator: " | ")) | \(pctDigits)%] vs eligible DSP \(a.eligible) (log_level=\(pl.startLevel ?? "?"))")
        }
        // log slice
        var slice = pl.lines.filter { $0.0 >= c0 - 3 && $0.0 <= c1 + 3 }.map { $0.1 }
        if let m = a.mem, !slice.contains(m.raw) { slice.insert(m.raw, at: 0) }
        writeText(slice.joined(separator: "\n") + "\n", dir + "/log_slice.log")
        // --- judgement (only meaningful when valid; computed for the record anyway)
        let amStrings = a.amMatched == "ax_after" ? (a.axAfter ?? before) : before
        let panelStrings = a.mem.map { m in MemField.allCases.map { m.strings[$0] ?? "—" } } ?? a.panelOCR.map { $0.text }
        a.fields = zip(MemField.allCases, zip(amStrings, panelStrings)).map { Threshold.judge($0.0, am: $0.1.0, panel: $0.1.1) }
        if let g = a.amGraph { a.pressurePass = a.panelPill.map { g.cls != .unknown && g.cls == $0.cls } ?? false }
        // composite
        if let comp = compositeBin, FileManager.default.isExecutableFile(atPath: comp) {
            var args = [lgPath, wkPath, "--out", dir + "/composite.png",
                        "--time", "\(isoNow(cap.t0)) … \(isoNow(cap.t1)) (\(Int(capMs)) ms)",
                        "--caption", "criterion #4 attempt \(k) (time point \(point), try \(n)) — Activity Monitor (left) vs Wokyis panel (right)"]
            if let wf = am.windowFrame {
                let r = Geo.toLG(wf.insetBy(dx: -8, dy: -8), main: mainBounds, imageWidth: lgSize.0).intersection(CGRect(x: 0, y: 0, width: lgSize.0, height: lgSize.1)).integral
                args += ["--lg-crop", "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"]
            }
            let r = runProcess(comp, args)
            if r.rc != 0 { a.notes.append("composite rc=\(r.rc): \(r.out.prefix(200))") }
        }
        writeAttemptFiles(&a, dir: dir)
        Report.draw(a, lg: lgImg, wk: wkImg, h: self, out: dir + "/report.png")
        return a
    }

    func writeAttemptFiles(_ a: inout Attempt, dir: String) {
        func vals(_ v: [String]?) -> Any {
            guard let v = v else { return NSNull() }
            var d: [String: String] = [:]
            for (f, x) in zip(MemField.allCases, v) { d[f.rawValue] = x }
            return d
        }
        var b: [String: Any] = [:]
        b["values"] = vals(a.axBefore); b["t_det"] = nn(a.tDet.map(isoNow))
        writeText(jsonString(b), dir + "/ax_before.json")
        var c: [String: Any] = [:]
        c["values"] = vals(a.axAfter); c["t_cap1"] = nn(a.cap.map { isoNow($0.t1) })
        writeText(jsonString(c), dir + "/ax_after.json")
        var am = "field\tocr\tconf\tpass\tcrop_px\tax_before\tax_after\n"
        for (i, f) in MemField.allCases.enumerated() where i < a.amOCR.count {
            let o = a.amOCR[i]
            am += "\(f.rawValue)\t\(o.text)\t\(String(format: "%.2f", o.conf))\t\(o.pass)\t\(fmtR(o.crop))\t\(a.axBefore?[i] ?? "")\t\(a.axAfter?[i] ?? "")\n"
        }
        writeText(am, dir + "/am_ocr.tsv")
        var pn = "field\tocr\tconf\tcrop_px\tdsp_mem_string\n"
        for (i, f) in MemField.allCases.enumerated() where i < a.panelOCR.count {
            let o = a.panelOCR[i]
            pn += "\(f.rawValue)\t\(o.text)\t\(String(format: "%.2f", o.conf))\t\(fmtR(o.crop))\t\(a.mem?.strings[f] ?? "")\n"
        }
        if let p = a.panelPctOCR { pn += "pressure_pct\t\(p.text)\t\(String(format: "%.2f", p.conf))\t\(fmtR(p.crop))\t\(a.mem?.pct ?? "")\n" }
        writeText(pn, dir + "/panel_ocr.tsv")
        writeText(jsonString(resultDict(a)), dir + "/result.json")
    }

    func resultDict(_ a: Attempt) -> [String: Any] {
        var d: [String: Any] = [:]
        d["k"] = a.k; d["time_point"] = a.point; d["try"] = a.n
        d["valid"] = a.valid && a.aborted == nil
        d["reasons"] = a.reasons.map { "\($0.rawValue): \($0.text)" }
        d["notes"] = a.notes
        d["verdict"] = a.aborted != nil ? "ABORTED" : a.verdict
        d["t_det"] = nn(a.tDet.map(isoNow))
        d["t_cap0"] = nn(a.cap.map { isoNow($0.t0) })
        d["t_cap1"] = nn(a.cap.map { isoNow($0.t1) })
        d["capture_ms"] = nn(a.cap.map { Int($0.t1.timeIntervalSince($0.t0) * 1000) })
        d["am_ocr_matched"] = a.amMatched
        d["dsp_seq"] = nn(a.dsp.map { Int($0.seq) })
        d["mem_seq"] = nn(a.mem.map { Int($0.seq) })
        d["eligible_dsp"] = a.eligible.map { Int($0) }
        if let e = a.aborted { d["aborted"] = e }
        d["fields"] = a.fields.map { f -> [String: Any] in
            var x: [String: Any] = [:]
            x["field"] = f.field.rawValue; x["am"] = f.am; x["panel"] = f.panel
            x["diff_bytes"] = nn(f.diffBytes); x["diff_gib"] = nn(f.diffBytes.map { $0 / Double(1 << 30) })
            x["rule"] = f.rule; x["pass"] = f.pass
            return x
        }
        var p: [String: Any] = [:]
        p["am_class"] = a.amGraph?.cls.rawValue ?? "-"; p["am_hue"] = nn(a.amGraph?.hue); p["am_note"] = a.amGraph?.note ?? "-"
        p["panel_class"] = a.panelPill?.cls.rawValue ?? "-"; p["panel_hue"] = nn(a.panelPill?.hue)
        p["panel_pct"] = a.mem?.pct ?? "-"; p["panel_lvl"] = a.mem?.lvl ?? "-"; p["pass"] = nn(a.pressurePass)
        d["pressure"] = p
        return d
    }

    static let tsvHeader = (["k", "time_point", "try", "valid", "reason", "t_det", "t_cap0", "t_cap1", "capture_ms", "dsp_seq", "mem_seq", "am_ocr_matched"]
        + MemField.allCases.flatMap { ["am_\($0.rawValue)", "panel_\($0.rawValue)", "diff_\($0.rawValue)_bytes"] }
        + ["am_pressure_class", "panel_pressure_class", "panel_pressure_pct", "verdict", "notes"]).joined(separator: "\t") + "\n"

    func tsvRow(_ a: Attempt) -> String {
        var c: [String] = [String(a.k), String(a.point), String(a.n), (a.valid && a.aborted == nil) ? "1" : "0",
                           a.aborted != nil ? "aborted" : (a.reasons.isEmpty ? "-" : a.reasons.map { $0.rawValue }.joined(separator: ",")),
                           a.tDet.map(isoNow) ?? "-", a.cap.map { isoNow($0.t0) } ?? "-", a.cap.map { isoNow($0.t1) } ?? "-",
                           a.cap.map { String(Int($0.t1.timeIntervalSince($0.t0) * 1000)) } ?? "-",
                           a.dsp.map { String($0.seq) } ?? "-", a.mem.map { String($0.seq) } ?? "-", a.amMatched]
        for (i, _) in MemField.allCases.enumerated() {
            if i < a.fields.count { let f = a.fields[i]; c += [f.am, f.panel, f.diffBytes.map { String(format: "%.0f", $0) } ?? "-"] }
            else { c += ["-", "-", "-"] }
        }
        c += [a.amGraph?.cls.rawValue ?? "-", a.panelPill?.cls.rawValue ?? "-", a.mem?.pct ?? "-", a.aborted != nil ? "ABORTED" : a.verdict,
              (a.notes + (a.aborted.map { [$0] } ?? [])).joined(separator: " ; ").replacingOccurrences(of: "\t", with: " ")]
        return c.joined(separator: "\t") + "\n"
    }

    // MARK: run
    enum Outcome: String { case pass = "PASS", fail = "FAIL", incomplete = "INCOMPLETE", aborted = "ABORTED", preflightFailed = "PREFLIGHT FAILED" }

    func run(root: String, stamp: String) -> Outcome {
        runDir = root + "/run-" + stamp
        try? FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
        if let r = rectsTSV { writeText(r, runDir + "/panel_rects.tsv") }
        // preflight
        let pf = preflight()
        var pft = "# amcompare preflight \(isoNow())\(dry ? "  (DRY RUN — synthetic inputs)" : "")\n"
        for c in pf { pft += "\(c.ok ? "OK  " : "FAIL")\t\(c.name)\t\(c.detail)\n" }
        let pfOK = pf.allSatisfy { $0.ok }
        pft += "preflight\t\(pfOK ? "PASS" : "FAIL")\n"
        writeText(pft, runDir + "/preflight.txt")
        print(pft, terminator: "")
        guard pfOK else {
            writeText("# criterion #4 — preflight failed, no attempt made\n\nSee preflight.txt.\n", runDir + "/summary.md")
            return .preflightFailed
        }
        print(String(format: "Vision warm-up: %.1f s", VisionOCR.warmUp()))
        // protocol.md: written once, before the first attempt, read-only afterwards
        let proto = runDir + "/protocol.md"
        let fd = open(proto, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { print("protocol.md already exists — refusing to overwrite"); return .aborted }
        let ptext = protocolText()
        _ = ptext.withCString { write(fd, $0, strlen($0)) }
        close(fd)
        chmod(proto, 0o444)
        protocolHash = sha256File(proto)
        let trace = runDir + "/am_ax_trace.csv"
        writeText("attempt,t_wall,t_rel_ms,ok,event," + MemField.allCases.map { "\"\($0.title)\"" }.joined(separator: ",") + "\n", trace)
        writeText(Harness.tsvHeader, runDir + "/attempts.tsv")
        var all: [Attempt] = []
        var pointResults: [(Int, Attempt?)] = []
        var outcome: Outcome = .pass
        var k = 0
        var nextStart = Date()
        outer: for point in 1...points {
            if nextStart > Date() {
                print(String(format: "time point %d: waiting %.0f s (spacing ≥ %.0f s)", point, nextStart.timeIntervalSinceNow, spacing))
                Thread.sleep(until: nextStart)
            }
            var chosen: Attempt? = nil
            for n in 1...attemptsPerPoint {
                k += 1
                let a = attempt(k: k, point: point, n: n, trace: trace)
                all.append(a)
                appendText(tsvRow(a), runDir + "/attempts.tsv")
                print("attempt \(k) (point \(point) try \(n)): \(a.aborted != nil ? "ABORTED \(a.aborted!)" : a.verdict)\(a.reasons.isEmpty ? "" : " reasons=" + a.reasons.map { $0.rawValue }.joined(separator: ","))")
                if a.aborted != nil { outcome = .aborted; pointResults.append((point, nil)); break outer }
                if a.valid { chosen = a; break }
                Thread.sleep(forTimeInterval: dry ? 0.1 : 1.0)
            }
            pointResults.append((point, chosen))
            guard let c = chosen else { outcome = .incomplete; break }
            if c.verdict == "FAIL" { outcome = .fail; break }
            nextStart = (c.cap?.t0 ?? Date()).addingTimeInterval(spacing)
        }
        let protoStill = sha256File(proto)
        writeText(summaryText(outcome: outcome, attempts: all, points: pointResults, protoUnchanged: protoStill == protocolHash), runDir + "/summary.md")
        print("outcome: \(outcome.rawValue) → \(runDir)/summary.md")
        return outcome
    }

    // MARK: texts
    func protocolText() -> String {
        """
        # Criterion #4 — pre-registered protocol (written \(isoNow()) before the first attempt; never modified)

        Tool: `tools/bin/amcompare` sha256 \(toolHash)\(dry ? "  \n**DRY RUN** — synthetic AM / capture / log; not evidence for criterion #4." : "")

        ## Thresholds (all computed from the DISPLAYED strings; KB/MB/GB/TB = 2^10/2^20/2^30/2^40 bytes)
        | field | pass when |
        |---|---|
        | Physical Memory | panel string identical to AM string (after the normalisation below) |
        | Swap Used | \\|panel − AM\\| ≤ 1 MiB (1,048,576 bytes) |
        | Memory Used, Cached Files, App Memory, Wired Memory, Compressed | each \\|panel − AM\\| ≤ 0.2 × 2^30 bytes |
        | pressure colour | AM graph colour class == panel pill colour class (green / yellow / red) |
        Arithmetic is exact (integers in 1/100 byte). A value that is not of the form `<number> <bytes|KB|MB|GB|TB>` fails.

        ## Time points and attempts
        - Exactly \(points) time points. The first starts right after this file is written; each next one starts ≥ \(Int(spacing)) s after the previous time point's valid capture (t_cap0).
        - ≤ \(attemptsPerPoint) attempts per time point; the FIRST valid attempt counts; later attempts are not made.
        - A time point with \(attemptsPerPoint) invalid attempts → overall INCOMPLETE → stop and ask the user.
        - Any valid attempt with a field over its threshold → overall FAIL → stop immediately and ask the user (no re-runs, thresholds unchanged).

        ## One attempt
        1. Checks: control.json empty, AM window visible; `pgrep -x vm_stat top amcal hsprobe memprobe procstat` must be empty (else the run is ABORTED, not an attempt).
        2. AX reads the 7 AM footer values at 50 Hz; the first read whose strings differ from the baseline = AM refresh → `ax_before` (= the new values), t_det.
        3. Immediately ONE `screencapture -x lg.png wokyis.png`, t_cap0 before / t_cap1 after the call; then AX again → `ax_after`.
        4. AM value = OCR (Apple Vision, en-US, per-value crop from the AX frame, ×2, digitfix) of lg.png; must equal ax_before or ax_after (whole 7-tuple).
        5. AM pressure colour = rightmost 4 px columns of the AX graph frame (extended inwards ≤ 16 px only if uncoloured), middle of the coloured run ±2 rows, median hue (coloured = HSV S ≥ 0.25, V ≥ 40): green 75–165°, yellow 25–75°, red < 25° or ≥ 330°.
        6. Panel value = OCR of wokyis.png (value crops: y from the panel snapshot rects ±8 px, x = the field's column); must equal the strings of some DSP commit (its mem_seq → MEM strings, + pressure %) whose on-screen interval [t_commit_k, t_commit_k+1) intersects [t_cap0 − 0.1 s, t_cap1]. The panel values judged are those MEM strings.
        7. Panel pressure colour = pill left padding (x 719–727, y 106–134), same hue classes.
        8. Normalisation for every string comparison: NBSP/narrow NBSP → space, digitfix (O/o→0, I/l/|→1 in mostly-numeric tokens), all whitespace removed, upper-case; dash-like / empty → "—".

        ## Invalid attempt — ONLY these five reasons
        - (i) AM OCR ≠ ax_before and ≠ ax_after
        - (ii) panel OCR matches no eligible DSP
        - (iii) capture took > 600 ms (t_cap1 − t_cap0)
        - (iv) AX read failed (baseline / every poll / after capture / graph frame) or AM window not visible (covered, minimised or off the main display)
        - (v) control.json not empty during the attempt (empty = missing file, or a JSON object without any fail / hang / garbage entry and without pressure; invalid JSON = not empty); a joined DSP/MEM line carrying sim=1 is recorded evidence of a non-empty control file
        Not invalid: an AM graph colour that cannot be classified → the attempt is valid and its pressure colour is judged FAIL (stop, ask the user).
        Precondition, not an attempt outcome: AM must refresh (AX values change) within \(Int(refreshTimeout)) s of polling; otherwise the run is ABORTED before any capture and the user decides.
        Tool errors that fit none of these (screencapture failure, wrong image size) ABORT the run; the user decides.

        ## Side evidence (not part of the verdict)
        `AUD` lines of the same period are copied into each attempt's log_slice.log.

        ## Panel formulas (spec §5.2, for the record)
        P = hw.pagesize; Used = (memsize/P − F − E)·P, F = free + free_cpu + MTE free terms (mte) or + R (calibrated); Cached = (E + U)·P;
        App = (I − U)·P; Wired = (wired + throttled)·P; Compressed = (compress_ts + compress_non_ts)·P; Swap = xsu_used; Physical = hw.memsize.
        """
    }

    func summaryText(outcome: Outcome, attempts: [Attempt], points: [(Int, Attempt?)], protoUnchanged: Bool) -> String {
        var s = "# Criterion #4 — Activity Monitor vs panel: **\(outcome.rawValue)**\(dry ? " (DRY RUN — synthetic inputs, not evidence)" : "")\n\n"
        s += "- run: `\(runDir)`\n- protocol.md sha256 \(protocolHash) — \(protoUnchanged ? "unchanged at the end of the run" : "**CHANGED during the run**")\n"
        s += "- attempts: \(attempts.count) (see attempts.tsv, attempt-NN/)\n- Δ = panel − AM, computed from the displayed strings (KB/MB/GB = 2^10/2^20/2^30)\n\n"
        s += "## Time points (first valid attempt)\n\n| point | attempt | t_cap0 | capture ms | DSP / MEM seq | "
        s += MemField.allCases.map { $0.title }.joined(separator: " | ") + " | pressure | verdict |\n|---|---|---|---|---|" + String(repeating: "---|", count: 9) + "\n"
        let GiB = Double(1 << 30), MiB = Double(1 << 20)
        for (p, a) in points {
            guard let a = a else { s += "| \(p) | — | — | — | — | " + String(repeating: "— | ", count: 8) + "no valid attempt |\n"; continue }
            var cells: [String] = []
            for f in a.fields {
                let d: String
                if f.field == .physical { d = f.pass ? "identical" : "differs" }
                else if f.field == .swap { d = f.diffBytes.map { String(format: "Δ %+.2f MB", $0 / MiB) } ?? "?" }
                else { d = f.diffBytes.map { String(format: "Δ %+.3f GB", $0 / GiB) } ?? "?" }
                cells.append("AM \(f.am) / panel \(f.panel) (\(d)) \(f.pass ? "✓" : "✗")")
            }
            let pr = "AM \(a.amGraph?.cls.rawValue ?? "-") / panel \(a.panelPill?.cls.rawValue ?? "-") (\(a.mem?.pct ?? "-")%) \(a.pressurePass == true ? "✓" : "✗")"
            s += "| \(p) | \(a.k) | \(a.cap.map { isoNow($0.t0) } ?? "-") | \(a.cap.map { String(Int($0.t1.timeIntervalSince($0.t0) * 1000)) } ?? "-") | \(a.dsp.map { String($0.seq) } ?? "-") / \(a.mem.map { String($0.seq) } ?? "-") | "
            s += cells.joined(separator: " | ") + " | \(pr) | \(a.verdict) |\n"
        }
        s += "\n## All attempts\n\n| k | point | try | valid | reasons / notes |\n|---|---|---|---|---|\n"
        for a in attempts {
            s += "| \(a.k) | \(a.point) | \(a.n) | \(a.valid && a.aborted == nil ? "yes" : "no") | \((a.reasons.map { "(\($0.rawValue)) \($0.text)" } + a.notes + (a.aborted.map { ["ABORTED: \($0)"] } ?? [])).joined(separator: "; ").replacingOccurrences(of: "|", with: "/")) |\n"
        }
        s += "\n## Next step\n\n"
        switch outcome {
        case .pass: s += "All \(points.count) time points valid and within thresholds.\n"
        case .fail: s += "**Stop — a valid attempt exceeded a threshold.** Formulas are in protocol.md; the measured differences are above. Thresholds are NOT relaxed and the run is NOT repeated to look for a pass; the user decides.\n"
        case .incomplete: s += "**Stop — a time point had \(attemptsPerPoint) invalid attempts.** The user decides how to proceed.\n"
        case .aborted: s += "**Stop — the run was aborted by a tool / environment error** (see notes). The user decides.\n"
        case .preflightFailed: s += "Preflight failed.\n"
        }
        return s
    }
}

// MARK: - report.png

enum Report {
    static func draw(_ a: Harness.Attempt, lg: CGImage, wk: CGImage, h: Harness, out: String) {
        // AM footer crop (LG px): union of value frames + graph frame, padded
        var foot = CGRect.null
        for r in h.am.valueFrames { foot = foot.union(r) }
        if let g = h.am.graphFrame { foot = foot.union(g) }
        if foot.isNull, let w = h.am.windowFrame { foot = w }
        let footPx = foot.isNull ? CGRect(x: 0, y: 0, width: min(1280, lg.width), height: min(300, lg.height))
            : Geo.toLG(foot.insetBy(dx: -150, dy: -20), main: h.mainBounds, imageWidth: lg.width).intersection(CGRect(x: 0, y: 0, width: lg.width, height: lg.height)).integral
        guard let amCrop = lg.cropping(to: footPx) else { return }
        let rows = 14
        let W = max(1280, amCrop.width) + 40
        let tableH = 30 * rows + 40
        let H = 50 + amCrop.height + 20 + 720 + 20 + tableH
        let bm = Bitmap(width: W, height: H)
        let ctx = bm.ctx
        ctx.setFillColor(rgba(0.1, 0.1, 0.12)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let amY = 50, wkY = 50 + amCrop.height + 20, tY = wkY + 720 + 20
        ctx.draw(amCrop, in: CGRect(x: 20, y: H - amY - amCrop.height, width: amCrop.width, height: amCrop.height))
        ctx.draw(wk, in: CGRect(x: 20, y: H - wkY - 720, width: 1280, height: 720))
        let cyan = rgba(0, 0.9, 1), mag = rgba(1, 0.2, 0.9)
        for o in a.amOCR {
            strokeRectTop(ctx, o.crop.minX - footPx.minX + 20, o.crop.minY - footPx.minY + CGFloat(amY), o.crop.width, o.crop.height, imageHeight: H, color: cyan, width: 2)
        }
        if let g = a.amGraph {
            let r = g.rows ?? g.columns
            strokeRectTop(ctx, r.minX - footPx.minX + 20 - 2, r.minY - footPx.minY + CGFloat(amY) - 2, r.width + 4, r.height + 4, imageHeight: H, color: mag, width: 2)
        }
        for o in a.panelOCR + (a.panelPctOCR.map { [$0] } ?? []) {
            strokeRectTop(ctx, o.crop.minX + 20, o.crop.minY + CGFloat(wkY), o.crop.width, o.crop.height, imageHeight: H, color: cyan, width: 1)
        }
        let ps = PanelRegions.pillSample
        strokeRectTop(ctx, ps.minX + 20 - 2, ps.minY + CGFloat(wkY) - 2, ps.width + 4, ps.height + 4, imageHeight: H, color: mag, width: 2)
        let white = rgba(1, 1, 1), green = rgba(0.3, 1, 0.4), red = rgba(1, 0.35, 0.35), grey = rgba(0.75, 0.75, 0.8)
        let head = "attempt \(a.k) · time point \(a.point) try \(a.n) · \(a.aborted != nil ? "ABORTED" : a.verdict)\(a.reasons.isEmpty ? "" : " · invalid (" + a.reasons.map { $0.rawValue }.joined(separator: ",") + ")")"
            + " · capture \(a.cap.map { "\(isoNow($0.t0)) … \(Int($0.t1.timeIntervalSince($0.t0) * 1000)) ms" } ?? "-") · DSP \(a.dsp.map { String($0.seq) } ?? "-") / MEM \(a.mem.map { String($0.seq) } ?? "-")\(h.dry ? " · DRY RUN" : "")"
        drawText(ctx, head, x: 20, yTop: 12, imageHeight: H, size: 20, color: a.verdict == "PASS" ? green : (a.verdict == "FAIL" ? red : white))
        var y = CGFloat(tY)
        func row(_ cols: [String], _ c: CGColor) {
            let xs: [CGFloat] = [20, 220, 420, 620, 820, 1020, 1220]
            for (i, t) in cols.enumerated() where i < xs.count { drawText(ctx, t, x: xs[i], yTop: y, imageHeight: H, size: 17, color: c, bold: i == 0) }
            y += 30
        }
        row(["field", "AM (AX)", "AM OCR", "panel (MEM)", "panel OCR", "Δ panel − AM", "rule / result"], grey)
        let GiB = Double(1 << 30), MiB = Double(1 << 20)
        for (i, f) in MemField.allCases.enumerated() {
            let fr = i < a.fields.count ? a.fields[i] : nil
            let d: String = fr?.diffBytes.map { f == .swap ? String(format: "%+.2f MB", $0 / MiB) : String(format: "%+.3f GB", $0 / GiB) } ?? "-"
            row([f.title, fr?.am ?? "-", i < a.amOCR.count ? a.amOCR[i].text : "-", fr?.panel ?? "-", i < a.panelOCR.count ? a.panelOCR[i].text : "-", d,
                 fr.map { "\($0.rule) \($0.pass ? "PASS" : "FAIL")" } ?? "-"], fr?.pass == true ? green : (fr == nil ? white : red))
        }
        let pc = "AM \(a.amGraph?.cls.rawValue ?? "-") \(a.amGraph?.hue.map { String(format: "%.0f°", $0) } ?? "") vs panel \(a.panelPill?.cls.rawValue ?? "-") \(a.panelPill?.hue.map { String(format: "%.0f°", $0) } ?? "") (\(a.mem?.pct ?? "-")%, lvl \(a.mem?.lvl ?? "-"))"
        row(["Pressure colour", pc, "", "", "", "", a.pressurePass == true ? "same class PASS" : "FAIL"], a.pressurePass == true ? green : red)
        row(["AM OCR matched", a.amMatched, "eligible DSP", a.eligible.map(String.init).joined(separator: ","), "", "", ""], grey)
        for n in (a.notes + (a.aborted.map { [$0] } ?? [])).prefix(3) { drawText(ctx, "note: " + String(n.prefix(150)), x: 20, yTop: y, imageHeight: H, size: 15, color: grey, bold: false); y += 24 }
        drawText(ctx, "cyan = OCR crops · magenta = colour samples (AM graph rightmost columns / panel pill padding)", x: 20, yTop: CGFloat(H - 26), imageHeight: H, size: 14, color: grey, bold: false)
        writePNG(bm.makeImage(), out)
    }
}
