// AMCompare+Logic.swift — pure logic of the criterion-#4 harness (no I/O, no AX, no capture):
//   displayed string → exact bytes, thresholds / judgement, OCR normalisation, pressure hue classification,
//   control.json emptiness, panel log parsing (MEM / DSP) and the DSP ↔ capture-window join.
// Everything here is covered by `amcompare unittest`.
import Foundation

// MARK: - fields

enum MemField: String, CaseIterable {
    case physical, used, cached, swap, app, wired, compressed
    /// Activity Monitor footer label (English Base nib) and zh_TW label (AM follows the system language).
    var amLabels: [String] {
        switch self {
        case .physical: return ["Physical Memory:", "實體記憶體："]
        case .used: return ["Memory Used:", "記憶體用量："]
        case .cached: return ["Cached Files:", "快取的檔案："]
        case .swap: return ["Swap Used:", "使用的交換檔："]
        case .app: return ["App Memory:", "App記憶體："]
        case .wired: return ["Wired Memory:", "系統核心記憶體："]
        case .compressed: return ["Compressed:", "已壓縮："]
        }
    }
    /// key used in the panel's MEM log line (spec §12)
    var memKey: String { self == .physical ? "phys" : (self == .compressed ? "comp" : rawValue) }
    var title: String {
        switch self {
        case .physical: return "Physical Memory"; case .used: return "Memory Used"; case .cached: return "Cached Files"
        case .swap: return "Swap Used"; case .app: return "App Memory"; case .wired: return "Wired Memory"; case .compressed: return "Compressed"
        }
    }
}

// MARK: - displayed string → bytes (exact, in 1/100 byte units)

/// Parsed displayed value. `centi` = bytes × 100, exact (AM shows ≤ 2 fraction digits, units are powers of 2).
struct DisplayedBytes: Equatable {
    let centi: Int64
    var bytes: Double { Double(centi) / 100 }
}

enum ByteString {
    static let units: [String: Int64] = ["BYTES": 1, "BYTE": 1, "KB": 1 << 10, "MB": 1 << 20, "GB": 1 << 30, "TB": 1 << 40]

    /// "18.52 GB" → 18.52 × 2^30 bytes; "1,023.9 MB"; "0 bytes"; "1 byte". nil when not of that form.
    /// KB/MB/GB/TB are 2^10/2^20/2^30/2^40 (ByteCountFormatter .memory, spec §5.3).
    static func parse(_ raw: String) -> DisplayedBytes? {
        let s = OCRNorm.spaces(raw).trimmingCharacters(in: .whitespaces)
        guard let sp = s.lastIndex(where: { $0 == " " }) ?? s.firstIndex(where: { $0.isLetter }) else { return nil }
        let numPart = s[..<sp].trimmingCharacters(in: .whitespaces)
        let unitPart = s[sp...].trimmingCharacters(in: .whitespaces).uppercased()
        guard let unit = units[unitPart] else { return nil }
        let n = numPart.replacingOccurrences(of: ",", with: "")
        guard !n.isEmpty, n.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), n.filter({ $0 == "." }).count <= 1,
              n.first != ".", n.last != "." else { return nil }
        // grouping commas must be at thousands positions
        if numPart.contains(",") {
            let intPart = numPart.split(separator: ".", maxSplits: 1)[0]
            let groups = intPart.split(separator: ",", omittingEmptySubsequences: false)
            guard groups.count >= 2, (1...3).contains(groups[0].count), groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        }
        let parts = n.split(separator: ".", omittingEmptySubsequences: false)
        let frac = parts.count == 2 ? String(parts[1]) : ""
        guard frac.count <= 2, let digits = Int64(parts[0] + frac) else { return nil }
        let scale: Int64 = frac.count == 0 ? 100 : (frac.count == 1 ? 10 : 1)     // → ×100 total
        let (m1, o1) = digits.multipliedReportingOverflow(by: unit)
        let (m2, o2) = m1.multipliedReportingOverflow(by: scale)
        guard !o1, !o2 else { return nil }
        return DisplayedBytes(centi: m2)
    }
}

// MARK: - thresholds (pre-registered, spec §15 #4)

enum Threshold {
    static let swapCenti: Int64 = (1 << 20) * 100                  // |Δ| ≤ 1 MiB
    static let gbCenti: Int64 = 20 * (1 << 30)                     // |Δ| ≤ 0.2 × 2^30 bytes  (0.2 × 100 = 20)
    struct FieldResult { let field: MemField; let am: String; let panel: String; let diffBytes: Double?; let pass: Bool; let rule: String }

    static func judge(_ f: MemField, am: String, panel: String) -> FieldResult {
        switch f {
        case .physical:
            let eq = OCRNorm.key(am) == OCRNorm.key(panel)
            let d: Double? = { if let a = ByteString.parse(am), let b = ByteString.parse(panel) { return b.bytes - a.bytes }; return nil }()
            return FieldResult(field: f, am: am, panel: panel, diffBytes: d, pass: eq && ByteString.parse(am) != nil, rule: "string identical")
        case .swap:
            guard let a = ByteString.parse(am), let b = ByteString.parse(panel) else {
                return FieldResult(field: f, am: am, panel: panel, diffBytes: nil, pass: false, rule: "|Δ| ≤ 1 MiB (unparseable)")
            }
            return FieldResult(field: f, am: am, panel: panel, diffBytes: b.bytes - a.bytes, pass: abs(b.centi - a.centi) <= swapCenti, rule: "|Δ| ≤ 1 MiB")
        default:
            guard let a = ByteString.parse(am), let b = ByteString.parse(panel) else {
                return FieldResult(field: f, am: am, panel: panel, diffBytes: nil, pass: false, rule: "|Δ| ≤ 0.2 GiB (unparseable)")
            }
            return FieldResult(field: f, am: am, panel: panel, diffBytes: b.bytes - a.bytes, pass: abs(b.centi - a.centi) <= gbCenti, rule: "|Δ| ≤ 0.2 GiB")
        }
    }
}

// MARK: - OCR normalisation

enum OCRNorm {
    /// NBSP / narrow NBSP / figure space → space
    static func spaces(_ s: String) -> String {
        String(s.map { ["\u{00A0}", "\u{202F}", "\u{2007}", "\u{2009}"].contains($0) ? " " : $0 })
    }
    /// digitfix: in tokens that are mostly digits (or only digits / separators / look-alikes), O/o → 0 and I/l/| → 1
    /// (tools/bin/ocr --digitfix rule, extended to digit-less tokens such as the "O" OCR reads in "0 bytes").
    static func digitfix(_ t: String) -> String {
        t.split(separator: " ", omittingEmptySubsequences: false).map { tok -> String in
            let d = tok.filter { $0.isNumber }.count
            let l = tok.filter { "OoIl|".contains($0) }.count
            // a token made only of digits / separators / look-alikes ("O" in "O bytes", "l,O23") is numeric too
            let onlyNumeric = !tok.isEmpty && tok.allSatisfy { $0.isNumber || ",.OoIl|".contains($0) } && tok.contains { !",.".contains($0) }
            guard onlyNumeric || (d > 0 && d * 2 >= tok.count - l) else { return String(tok) }
            return String(tok.map { "Oo".contains($0) ? "0" : ("Il|".contains($0) ? "1" : $0) })
        }.joined(separator: " ")
    }
    /// Comparison key (pre-registered): spaces unified, digitfix, all whitespace removed, upper-cased;
    /// every dash-like string ("—", "–", "-", "--", "") → "—".
    static func key(_ s: String) -> String {
        let t = digitfix(spaces(s)).filter { !$0.isWhitespace }.uppercased()
        if t.isEmpty || t.allSatisfy({ "—–-−".contains($0) }) { return "—" }
        return t
    }
    static func tupleEqual(_ a: [String], _ b: [String]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { key($0) == key($1) } }
}

// MARK: - pressure colour

enum HueClass: String { case green, yellow, red, unknown }

enum PressureColor {
    /// hue in degrees 0…360, saturation 0…1 (HSV), value 0…255
    static func hsv(_ r: Int, _ g: Int, _ b: Int) -> (h: Double, s: Double, v: Int) {
        let mx = max(r, g, b), mn = min(r, g, b), d = Double(mx - mn)
        guard mx > 0, d > 0 else { return (0, 0, mx) }
        var h: Double
        if mx == r { h = 60 * (Double(g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == g { h = 60 * (Double(b - r) / d + 2) }
        else { h = 60 * (Double(r - g) / d + 4) }
        if h < 0 { h += 360 }
        return (h, d / Double(mx), mx)
    }
    /// A pixel counts as coloured when S ≥ 0.25 and V ≥ 40.
    static func isColoured(_ c: (Int, Int, Int)) -> Bool { let x = hsv(c.0, c.1, c.2); return x.s >= 0.25 && x.v >= 40 }
    /// green 75–165°, yellow 25–75°, red <25° or ≥330°, anything else unknown.
    static func classify(hue h: Double) -> HueClass {
        if h >= 75 && h < 165 { return .green }
        if h >= 25 && h < 75 { return .yellow }
        if h < 25 || h >= 330 { return .red }
        return .unknown
    }
    /// Median hue of the coloured pixels (red wrap: hues ≥ 330 are taken as h − 360) → class.
    static func classify(pixels: [(Int, Int, Int)]) -> (cls: HueClass, hue: Double?, n: Int) {
        let hs = pixels.filter(isColoured).map { p -> Double in let h = hsv(p.0, p.1, p.2).h; return h >= 330 ? h - 360 : h }.sorted()
        guard !hs.isEmpty else { return (.unknown, nil, 0) }
        var med = hs[hs.count / 2]
        if med < 0 { med += 360 }
        return (classify(hue: med), med, hs.count)
    }
}

// MARK: - control.json

enum ControlState {
    /// Pre-registered: "empty" = file missing, or a JSON object without any fail / hang / garbage entry and without
    /// `pressure`. Anything else (including unreadable / invalid JSON) = NOT empty.
    static func isEmpty(_ data: Data?) -> (empty: Bool, detail: String) {
        guard let d = data else { return (true, "missing") }
        let txt = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "<binary>"
        guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (false, "not a JSON object: \(txt.prefix(80))") }
        for k in ["fail", "hang", "garbage"] {
            if let a = obj[k] as? [Any], !a.isEmpty { return (false, "\(k)=\(a)") }
            if obj[k] != nil && !(obj[k] is [Any]) { return (false, "\(k) not an array") }
        }
        if obj["pressure"] != nil && !(obj["pressure"] is NSNull) { return (false, "pressure=\(obj["pressure"]!)") }
        return (true, txt.isEmpty ? "empty file" : txt)
    }
}

// MARK: - panel log (MEM / DSP)

struct PanelMEM { let t: Double; let seq: UInt64; let strings: [MemField: String]; let pct: String; let lvl: String; let sim: Bool; let raw: String }
/// v2: `view` = the DSP `view=` token ("mem" when absent, v1 logs). A CPU / network commit (mem_seq=-) stays in the
/// timeline — it ends the on-screen interval of the memory commit before it — but never matches (memSeq 0).
struct PanelDSP { let t: Double; let seq: UInt64; let memSeq: UInt64; let clock: String; let sim: Bool; let raw: String; var view: String = "mem"
    var lang = "zh", batv = "1"     // v1 lines carry no view / lang / batv → the v1 layout (mem / zh / 1)
    var isMemory: Bool { view == "mem" }
    /// The layout PanelRegions.columns and the clock / battery crops were measured on (v1: memory, zh, battery shown).
    var isOCRLayout: Bool { view == "mem" && lang == "zh" && batv == "1" }
    var layoutTokens: String { "view=\(view) lang=\(lang) batv=\(batv)" }
}
struct PanelLog { var mem: [UInt64: PanelMEM] = [:]; var dsp: [PanelDSP] = []; var lines: [(Double, String)] = []; var startLevel: String?; var startT: Double? }

enum LogParse {
    /// 2026-10-01T05:07:13.250+08:00 → epoch seconds
    static func ts<S: StringProtocol>(_ s: S) -> Double? {
        let u = Array(s.utf8)
        guard u.count >= 19, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58 else { return nil }
        func num(_ a: Int, _ b: Int) -> Int? {
            guard b <= u.count else { return nil }
            var v = 0; for i in a..<b { let c = Int(u[i]) - 48; if c < 0 || c > 9 { return nil }; v = v * 10 + c }; return v
        }
        guard let Y = num(0, 4), let M = num(5, 7), let D = num(8, 10), let h = num(11, 13), let m = num(14, 16), let sec = num(17, 19) else { return nil }
        var i = 19, frac = 0.0
        if i < u.count && u[i] == 46 { i += 1; var sc = 0.1; while i < u.count, u[i] >= 48, u[i] <= 57 { frac += Double(Int(u[i]) - 48) * sc; sc /= 10; i += 1 } }
        var off = 0
        if i < u.count {
            if u[i] == 90 { off = 0 }
            else if (u[i] == 43 || u[i] == 45), let oh = num(i + 1, i + 3) {
                let om = (i + 3 < u.count && u[i + 3] == 58) ? (num(i + 4, i + 6) ?? 0) : (num(i + 3, i + 5) ?? 0)
                off = (oh * 3600 + om * 60) * (u[i] == 45 ? -1 : 1)
            } else { return nil }
        }
        var t = tm(); t.tm_year = Int32(Y - 1900); t.tm_mon = Int32(M - 1); t.tm_mday = Int32(D); t.tm_hour = Int32(h); t.tm_min = Int32(m); t.tm_sec = Int32(sec)
        return Double(timegm(&t) - off) + frac
    }
    /// key=value tokens (value may be "quoted"), and bare "…" strings attached to the preceding key.
    static func body(_ b: String) -> (kv: [String: String], quoted: [String: String]) {
        var kv: [String: String] = [:], qs: [String: String] = [:]
        var lastKey: String? = nil
        let c = Array(b)
        var i = 0
        while i < c.count {
            while i < c.count && c[i] == " " { i += 1 }
            if i >= c.count { break }
            if c[i] == "\"" {
                var j = i + 1; while j < c.count && c[j] != "\"" { j += 1 }
                if let k = lastKey { qs[k] = String(c[(i + 1)..<min(j, c.count)]) }
                i = j + 1; lastKey = nil; continue
            }
            var j = i; var eq = -1
            while j < c.count && c[j] != " " {
                if c[j] == "=" && eq < 0 {
                    eq = j
                    if j + 1 < c.count && c[j + 1] == "\"" {
                        var e = j + 2; while e < c.count && c[e] != "\"" { e += 1 }
                        kv[String(c[i..<j])] = String(c[(j + 2)..<min(e, c.count)])
                        j = e + 1; eq = -2; break
                    }
                }
                j += 1
            }
            if eq >= 0 { let k = String(c[i..<eq]); kv[k] = String(c[(eq + 1)..<j]); lastKey = k } else { lastKey = nil }
            i = max(j, i + 1)
        }
        return (kv, qs)
    }

    static func parse(_ text: String, from: Double = -.infinity, to: Double = .infinity) -> PanelLog {
        var out = PanelLog()
        for raw in text.split(separator: "\n") {
            guard let sp = raw.firstIndex(of: " "), let t = ts(raw[..<sp]) else { continue }
            let rest = raw[raw.index(after: sp)...]
            let sp2 = rest.firstIndex(of: " ") ?? rest.endIndex
            let kind = String(rest[..<sp2])
            let bodyStr = sp2 < rest.endIndex ? String(rest[rest.index(after: sp2)...]) : ""
            if kind == "START" { out.startLevel = body(bodyStr).kv["log_level"]; out.startT = t }
            guard t >= from && t <= to else { continue }
            out.lines.append((t, String(raw)))
            if kind == "MEM" {
                let (kv, qs) = body(bodyStr)
                guard let seq = kv["seq"].flatMap({ UInt64($0) }) else { continue }
                var st: [MemField: String] = [:]
                for f in MemField.allCases { st[f] = qs[f.memKey] ?? "—" }
                out.mem[seq] = PanelMEM(t: t, seq: seq, strings: st, pct: kv["pct"] ?? "—", lvl: kv["lvl"] ?? "-", sim: kv["sim"] == "1", raw: String(raw))
            } else if kind == "DSP" {
                let (kv, _) = body(bodyStr)
                guard let seq = kv["seq"].flatMap({ UInt64($0) }) else { continue }
                let view = kv["view"] ?? "mem", lang = kv["lang"] ?? "zh", batv = kv["batv"] ?? "1"
                if view == "mem" {
                    guard let ms = kv["mem_seq"].flatMap({ UInt64($0) }) else { continue }
                    out.dsp.append(PanelDSP(t: t, seq: seq, memSeq: ms, clock: kv["clock"] ?? "", sim: kv["sim"] == "1", raw: String(raw),
                                            lang: lang, batv: batv))
                } else {
                    out.dsp.append(PanelDSP(t: t, seq: seq, memSeq: 0, clock: kv["clock"] ?? "", sim: kv["sim"] == "1", raw: String(raw), view: view,
                                            lang: lang, batv: batv))
                }
            }
        }
        out.dsp.sort { $0.t < $1.t }
        return out
    }
}

// MARK: - join: which DSP commits could be on screen during the capture?

enum Join {
    /// DSP k is on screen during [t_k, t_{k+1}); eligible when that interval intersects [cap0 − 0.1 s, cap1].
    static func eligible(_ dsp: [PanelDSP], cap0: Double, cap1: Double) -> [PanelDSP] {
        var out: [PanelDSP] = []
        for (i, d) in dsp.enumerated() {
            let end = i + 1 < dsp.count ? dsp[i + 1].t : Double.infinity
            if d.t <= cap1 && end > cap0 - 0.1 { out.append(d) }
        }
        return out
    }
    /// Panel strings in field order + pressure percent.
    static func expected(_ d: PanelDSP, _ mem: [UInt64: PanelMEM]) -> (strings: [String], pct: String, mem: PanelMEM)? {
        guard d.isMemory, let m = mem[d.memSeq] else { return nil }   // CPU / network commits never match
        return (MemField.allCases.map { m.strings[$0] ?? "—" }, m.pct, m)
    }
    /// First eligible DSP whose strings equal the OCR'd panel strings (7 fields + pressure %).
    static func match(ocr: [String], ocrPct: String, eligible: [PanelDSP], mem: [UInt64: PanelMEM]) -> (PanelDSP, PanelMEM)? {
        for d in eligible {
            guard let e = expected(d, mem) else { continue }
            if OCRNorm.tupleEqual(ocr, e.strings) && OCRNorm.key(ocrPct) == OCRNorm.key(e.pct) { return (d, e.mem) }
        }
        return nil
    }
}

// MARK: - invalid reasons (the ONLY five, spec §15 #4)

enum InvalidReason: String, CaseIterable {
    case i = "i", ii = "ii", iii = "iii", iv = "iv", v = "v"
    var text: String {
        switch self {
        case .i: return "AM OCR ≠ ax_before and ≠ ax_after"
        case .ii: return "panel OCR matches no eligible DSP"
        case .iii: return "capture took > 600 ms"
        case .iv: return "AX read failed or AM window not visible"
        case .v: return "control.json not empty during the attempt"
        }
    }
}

// MARK: - unit tests

enum LogicTests {
    static func run() -> Bool {
        var ok = true, n = 0
        func expect(_ name: String, _ c: Bool, _ d: String = "") { n += 1; if !c { ok = false }; print("\(c ? "PASS" : "FAIL")\t\(name)\t\(d)") }
        let GiB = Double(1 << 30), MiB = Double(1 << 20)
        // spec §5.3 AMFormat cases (bytes → string); parsing the string back must give the displayed value
        let cases: [(String, Double)] = [("0 bytes", 0), ("1,023 bytes", 1023), ("1 KB", 1024), ("1,023 KB", 1023 * 1024), ("1.0 MB", MiB),
                                         ("39.3 MB", 39.3 * MiB), ("39.8 MB", 39.8 * MiB), ("1,023.5 MB", 1023.5 * MiB), ("1,023.9 MB", 1023.9 * MiB),
                                         ("1.00 GB", GiB), ("3.07 GB", 3.07 * GiB), ("18.52 GB", 18.52 * GiB), ("24.00 GB", 24 * GiB),
                                         ("1 byte", 1), ("1.00 TB", Double(1 << 40)), ("24.00\u{00A0}GB", 24 * GiB), ("24.00GB", 24 * GiB)]
        for (s, v) in cases {
            let p = ByteString.parse(s)
            expect("parse \(s)", p != nil && abs(p!.bytes - v) < 0.01, p.map { String($0.bytes) } ?? "nil")
        }
        for bad in ["—", "", "GB", "18.5.2 GB", "18.523 GB", "1,02 GB", "18,52 GB", "n/a", "12 XB", "-1 GB", ".5 GB"] {
            expect("reject '\(bad)'", ByteString.parse(bad) == nil)
        }
        // exact thresholds from displayed strings
        expect("gb Δ=0.20 pass", Threshold.judge(.used, am: "18.52 GB", panel: "18.72 GB").pass)
        expect("gb Δ=0.21 fail", !Threshold.judge(.used, am: "18.52 GB", panel: "18.73 GB").pass)
        expect("gb Δ=-0.20 pass", Threshold.judge(.app, am: "7.86 GB", panel: "7.66 GB").pass)
        expect("gb across units", Threshold.judge(.compressed, am: "1,023.9 MB", panel: "1.19 GB").pass
               && !Threshold.judge(.compressed, am: "1,023.9 MB", panel: "1.21 GB").pass, "1.19 GB − 1023.9 MB = \((1.19 * GiB - 1023.9 * MiB) / GiB) GiB")
        expect("swap Δ=1.0 MB pass (exact)", Threshold.judge(.swap, am: "39.8 MB", panel: "40.8 MB").pass)
        expect("swap Δ=1.1 MB fail", !Threshold.judge(.swap, am: "39.8 MB", panel: "40.9 MB").pass)
        expect("swap 1,023.9 MB vs 1.00 GB", Threshold.judge(.swap, am: "1,023.9 MB", panel: "1.00 GB").pass, "Δ = 0.1 MiB")
        expect("swap KB", Threshold.judge(.swap, am: "0 bytes", panel: "1,023 KB").pass && !Threshold.judge(.swap, am: "0 bytes", panel: "1.1 MB").pass)
        expect("physical identical", Threshold.judge(.physical, am: "24.00 GB", panel: "24.00\u{00A0}GB").pass)
        expect("physical differs", !Threshold.judge(.physical, am: "24.00 GB", panel: "24.01 GB").pass)
        expect("dash fails", !Threshold.judge(.used, am: "18.52 GB", panel: "—").pass && !Threshold.judge(.physical, am: "—", panel: "—").pass)
        expect("diff sign", abs((Threshold.judge(.used, am: "18.52 GB", panel: "18.72 GB").diffBytes ?? 0) - 0.2 * GiB) < 1)
        // normalisation
        expect("norm spaces", OCRNorm.key("24.00 GB") == OCRNorm.key("24.00\u{00A0}GB") && OCRNorm.key("24.00 GB") == OCRNorm.key("24.00GB"))
        expect("norm digitfix", OCRNorm.key("1O.5O GB") == OCRNorm.key("10.50 GB") && OCRNorm.key("l8.52 GB") == OCRNorm.key("18.52 GB"))
        expect("norm keeps GB letters", OCRNorm.key("3.07 GB") != OCRNorm.key("3.07 MB"))
        expect("norm O bytes", OCRNorm.key("O bytes") == OCRNorm.key("0 bytes") && OCRNorm.key("l,O23 KB") == OCRNorm.key("1,023 KB"), OCRNorm.key("O bytes"))
        expect("norm keeps words", OCRNorm.digitfix("Physical Memory: bytes GB MB") == "Physical Memory: bytes GB MB")
        expect("norm dashes", OCRNorm.key("—") == OCRNorm.key("-") && OCRNorm.key("") == "—" && OCRNorm.key("–") == "—")
        // hue
        let hueCases: [((Int, Int, Int), HueClass)] = [((140, 119, 62), .yellow), ((151, 122, 30), .yellow), ((185, 5, 7), .red), ((7, 107, 12), .green),
                                                       ((0x30, 0xD1, 0x58), .green), ((0xF0, 0xBE, 0x24), .yellow), ((0xFF, 0x45, 0x3A), .red),
                                                       ((255, 0, 0), .red), ((0, 204, 0), .green), ((255, 149, 0), .yellow)]
        for (c, want) in hueCases {
            let r = PressureColor.classify(pixels: [c])
            expect("hue \(c) → \(want.rawValue)", r.cls == want, String(format: "%.1f°", r.hue ?? -1))
        }
        expect("grey pill → unknown", PressureColor.classify(pixels: [(0x4B, 0x52, 0x5B), (7, 9, 12)]).cls == .unknown)
        expect("red wrap median", PressureColor.classify(pixels: [(255, 0, 20), (255, 0, 10), (255, 10, 0)]).cls == .red)
        // control
        expect("control missing", ControlState.isEmpty(nil).empty)
        expect("control {}", ControlState.isEmpty("{}".data(using: .utf8)).empty)
        expect("control empty lists", ControlState.isEmpty(#"{"version":1,"expires":"2026-10-01T05:30:00+08:00","fail":[]}"#.data(using: .utf8)).empty)
        expect("control fail", !ControlState.isEmpty(#"{"version":1,"fail":["mem.swap"]}"#.data(using: .utf8)).empty)
        expect("control pressure", !ControlState.isEmpty(#"{"version":1,"pressure":{"level":2,"percent":71}}"#.data(using: .utf8)).empty)
        expect("control garbage json", !ControlState.isEmpty("{not json".data(using: .utf8)).empty && !ControlState.isEmpty(Data()).empty)
        // log parsing + join
        let log = """
        2026-10-01T05:07:10.000+08:00 START build=x pid=1 mode=app log_level=sample sim=0
        2026-10-01T05:07:13.000+08:00 MEM seq=100 dur_us=9 mode=mte sim=0 phys=25769803776 "24.00 GB" used=19883098112 "18.52 GB" cached=1 "3.41 GB" swap=41680896 "39.8 MB" app=1 "7.86 GB" wired=1 "3.07 GB" comp=1 "7.59 GB" pct=48 lvl=1 fail=-
        2026-10-01T05:07:13.030+08:00 DSP seq=10 mem_seq=100 clock=05:07:13 regions=used bat="kb:100" page=1/1 stale=0 sim=0
        2026-10-01T05:07:13.250+08:00 MEM seq=101 dur_us=9 mode=mte sim=0 phys=25769803776 "24.00 GB" used=19893098112 "18.53 GB" cached=1 "3.41 GB" swap=41680896 "39.8 MB" app=1 "7.86 GB" wired=1 "3.07 GB" comp=1 "7.59 GB" pct=48 lvl=1 fail=-
        2026-10-01T05:07:13.280+08:00 DSP seq=11 mem_seq=101 clock=05:07:13 regions=used page=1/1 stale=0 sim=0
        2026-10-01T05:07:14.030+08:00 DSP seq=12 mem_seq=101 clock=05:07:14 regions=clock page=1/1 stale=0 sim=0
        garbage line
        """
        let pl = LogParse.parse(log)
        expect("log parse", pl.mem.count == 2 && pl.dsp.count == 3 && pl.startLevel == "sample" && pl.mem[100]?.strings[.used] == "18.52 GB" && pl.mem[101]?.strings[.compressed] == "7.59 GB")
        let t = { (s: String) in LogParse.ts(s)! }
        let e1 = Join.eligible(pl.dsp, cap0: t("2026-10-01T05:07:13.100+08:00"), cap1: t("2026-10-01T05:07:13.400+08:00"))
        expect("eligible spans commit", e1.map { $0.seq } == [10, 11], "\(e1.map { $0.seq })")
        let e2 = Join.eligible(pl.dsp, cap0: t("2026-10-01T05:07:13.400+08:00"), cap1: t("2026-10-01T05:07:13.600+08:00"))
        expect("eligible -0.1 s slack excludes", e2.map { $0.seq } == [11], "\(e2.map { $0.seq })")
        let e2b = Join.eligible(pl.dsp, cap0: t("2026-10-01T05:07:13.350+08:00"), cap1: t("2026-10-01T05:07:13.600+08:00"))
        expect("eligible -0.1 s slack includes", e2b.map { $0.seq } == [10, 11], "DSP 10 ends .280 > cap0−0.1 = .250: \(e2b.map { $0.seq })")
        let e3 = Join.eligible(pl.dsp, cap0: t("2026-10-01T05:07:15.000+08:00"), cap1: t("2026-10-01T05:07:15.300+08:00"))
        expect("last DSP open-ended", e3.map { $0.seq } == [12])
        let ocrA = ["24.00 GB", "18.53 GB", "3.41 GB", "39.8 MB", "7.86 GB", "3.07 GB", "7.59 GB"]
        let m1 = Join.match(ocr: ocrA, ocrPct: "48", eligible: e1, mem: pl.mem)
        expect("join matches 2nd", m1?.0.seq == 11 && m1?.1.seq == 101)
        expect("join no match", Join.match(ocr: ocrA, ocrPct: "49", eligible: e1, mem: pl.mem) == nil
               && Join.match(ocr: ocrA, ocrPct: "48", eligible: [pl.dsp[0]], mem: pl.mem) == nil)
        expect("ts offset", abs(t("2026-10-01T05:07:13.250+08:00") - t("2026-09-30T21:07:13.250Z")) < 1e-9)
        // v2: only view=mem DSP lines join; a CPU commit ends the memory commit's on-screen interval and never matches
        let log2 = log.replacingOccurrences(of: "garbage line", with: """
        2026-10-01T05:07:13.400+08:00 DSP seq=13 mem_seq=- sys_seq=5 clock=05:07:13 regions=all bat="hidden" page=1/1 stale=0 draw_us=1 view=cpu lang=en batv=0 sim=0
        """).replacingOccurrences(of: "regions=used page=1/1 stale=0 sim=0", with: "regions=used page=1/1 stale=0 view=mem lang=zh batv=1 sim=0")
        let pl2 = LogParse.parse(log2)
        let e4 = Join.eligible(pl2.dsp, cap0: t("2026-10-01T05:07:13.550+08:00"), cap1: t("2026-10-01T05:07:13.700+08:00"))
        expect("v2 view filter", pl2.dsp.count == 4 && pl2.dsp.filter(\.isMemory).count == 3 && e4.map { $0.seq } == [13]
               && Join.match(ocr: ocrA, ocrPct: "48", eligible: e4, mem: pl2.mem) == nil
               && Join.match(ocr: ocrA, ocrPct: "48", eligible: Join.eligible(pl2.dsp, cap0: t("2026-10-01T05:07:13.300+08:00"), cap1: t("2026-10-01T05:07:13.350+08:00")), mem: pl2.mem)?.0.seq == 11,
               "\(pl2.dsp.map { "\($0.seq):\($0.view)" }) e4=\(e4.map { $0.seq })")
        // OPS-1: the OCR crops are the v1 memory / zh / battery layout; v1 lines (no tokens) count as that layout
        expect("dsp layout tokens", pl2.dsp.map(\.isOCRLayout) == [true, true, false, true] && pl2.dsp[2].layoutTokens == "view=cpu lang=en batv=0"
               && pl.dsp.allSatisfy(\.isOCRLayout), "\(pl2.dsp.map(\.layoutTokens))")
        print("amcompare unittest: \(ok ? "all \(n) passed" : "FAILED")")
        return ok
    }
}
