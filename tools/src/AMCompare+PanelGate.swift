// AMCompare+PanelGate.swift — c2measure's acceptance gate (`amcompare panelocr`): does a Wokyis capture show the same
// LAYOUT as the panel's SIGUSR1 snapshot, so that the snapshot's rects describe the glyphs in the captured frame?
//   memory   OCR of the 7 values + pressure % (per-field crops, PanelRegions) vs the snapshot's state.json strings
//   clock    OCR of the clock (x 1040–1272 of the clock row) vs state.json "clock"
//   battery  the battery value column (x 1040–1272, y 12–648; labels / bolt / chip mostly left of it) read as a list of
//            lines that contain a digit or "%", in the capture AND in the snapshot's own PNG with the same reader →
//            same number of lines, pairwise layout-equal, centre y within ±30 px (a row that appears, disappears or
//            moves — also a "—" row turning into a number or back — changes the list). Labels are not OCR-gated: the
//            en-US reader cannot read CJK and the zh-Hant reading of the same label differs between capture and render.
// Layout key = OCRNorm.key (the pre-registered normalisation, unchanged) with every ASCII digit → "9". The renderer
// draws numbers in SF Pro Condensed with kMonospacedNumbersSelector, so equal layout keys ⇒ identical glyph positions.
// Exact equality (OCRNorm.key) is recorded as well (`match` column, summary "ALL MATCH" vs "LAYOUT MATCH").
import Foundation
import CoreGraphics
import Vision

extension OCRNorm {
    /// key(s) with every ASCII digit → "9": "18.48 GB" ≡ "18.63 GB", but "9.99 GB" ≢ "10.00 GB", "—" ≢ "4.38 GB".
    static func layoutKey(_ s: String) -> String { String(key(s).map { "0123456789".contains($0) ? "9" : $0 }) }
}

struct GateLine { let text: String; let conf: Float; let box: CGRect }   // box: image px, top-left origin

enum PanelGate {
    static let batteryCrop = CGRect(x: 1040, y: 12, width: 232, height: 636)
    static let clockCrop = CGRect(x: 1040, y: 648, width: 232, height: 68)
    static let yTolerance: CGFloat = 30

    /// en-US lines in `crop` that contain a digit or "%" (digitfix applied), top → bottom. Same pass order as
    /// VisionOCR.read: without language correction first, with correction only when the first pass kept nothing.
    static func lines(_ img: CGImage, crop: CGRect) -> [GateLine] {
        let r = crop.integral.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard !r.isNull, r.width >= 4, r.height >= 4, let sub = img.cropping(to: r) else { return [] }
        for correct in [false, true] {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = correct
            req.recognitionLanguages = ["en-US"]
            req.minimumTextHeight = 0
            try? VNImageRequestHandler(cgImage: sub, options: [:]).perform([req])
            let out = (req.results ?? []).compactMap { o -> GateLine? in
                guard let c = o.topCandidates(1).first else { return nil }
                let t = OCRNorm.digitfix(OCRNorm.spaces(c.string))
                guard t.contains(where: { "0123456789%".contains($0) }) else { return nil }
                let b = o.boundingBox
                return GateLine(text: t, conf: c.confidence,
                                box: CGRect(x: r.minX + b.minX * r.width, y: r.minY + (1 - b.maxY) * r.height, width: b.width * r.width, height: b.height * r.height))
            }.sorted { ($0.box.midY, $0.box.minX) < ($1.box.midY, $1.box.minX) }
            if !out.isEmpty { return out }
        }
        return []
    }

    struct Pair { let cap: GateLine?; let ref: GateLine?; let exact: Bool; let layout: Bool; let note: String }

    /// Pairwise comparison of two line lists (capture vs reference) in top → bottom order.
    static func compare(cap: [GateLine], ref: [GateLine], yTol: CGFloat = yTolerance) -> [Pair] {
        (0..<max(cap.count, ref.count)).map { i in
            let c = i < cap.count ? cap[i] : nil, e = i < ref.count ? ref[i] : nil
            guard let c = c, let e = e else { return Pair(cap: c, ref: e, exact: false, layout: false, note: c == nil ? "line missing in capture" : "extra line in capture") }
            let dy = c.box.midY - e.box.midY
            let exact = OCRNorm.key(c.text) == OCRNorm.key(e.text)
            let lk = OCRNorm.layoutKey(c.text) == OCRNorm.layoutKey(e.text)
            let note = String(format: "y %.0f vs ref %.0f", c.box.midY, e.box.midY) + (abs(dy) > yTol ? " (moved > \(Int(yTol)) px)" : "")
            return Pair(cap: c, ref: e, exact: exact, layout: lk && abs(dy) <= yTol, note: note)
        }
    }

    /// `amcompare panelocr WOKYIS.png --rects R.tsv [--state S.json] [--ref SNAPSHOT.png]`. Exit 0 = accepted (every
    /// element layout-equivalent; summary says whether also exactly equal), 1 = rejected, 2 = bad input.
    static func run(png: String, rects: String, state: String?, ref refPath: String?) -> Int32 {
        let img = loadCGImage(png)
        guard img.width == 1280, img.height == 720 else { print("panelocr: \(png) is \(img.width)x\(img.height), expected 1280x720"); return 2 }
        let crops = PanelRegions.crops(rectsTSV: rects)
        var expected: [String: String] = [:]
        var clock: String? = nil
        if let s = state, let d = FileManager.default.contents(atPath: s), let st = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let mem = st["memory"] as? [String: Any] {
            for f in MemField.allCases { expected[f.rawValue] = mem[f.rawValue] as? String }
            expected["pressure"] = mem["pressure_percent"] as? String
            clock = st["clock"] as? String
        }
        let haveState = !expected.isEmpty
        var allLayout = true, allExact = true
        func yn(_ b: Bool?) -> String { b.map { $0 ? "yes" : "NO" } ?? "-" }
        print("field\tocr\tconf\tcrop\texpected\tmatch\tlayout\tnote")
        func row(_ name: String, _ text: String, _ conf: Float, _ crop: CGRect, _ e: String?, note: String = "") {
            let exact = e.map { OCRNorm.key($0) == OCRNorm.key(text) }
            let layout = e.map { OCRNorm.layoutKey($0) == OCRNorm.layoutKey(text) }
            if exact == false { allExact = false }
            if layout == false { allLayout = false }
            print("\(name)\t\(text)\t\(String(format: "%.2f", conf))\t\(fmtR(crop))\t\(e ?? "-")\t\(yn(exact))\t\(yn(layout))\t\(note)")
        }
        for name in MemField.allCases.map({ $0.rawValue }) + ["pressure"] {
            var r = VisionOCR.read(img, crop: crops[name]!, scale: 1, expectBytes: name != "pressure")
            if name == "pressure" { r = OCRResult(text: String(r.text.filter { $0.isNumber }), conf: r.conf, crop: r.crop, pass: r.pass) }
            row(name, r.text, r.conf, r.crop, expected[name])
        }
        let c = VisionOCR.read(img, crop: clockCrop, scale: 1, expectBytes: false)
        row("clock", c.text, c.conf, c.crop, haveState ? (clock ?? "—") : nil)
        // battery: capture vs the snapshot's own PNG (same reader, same crop)
        if haveState {
            var refImg: CGImage? = nil
            if let p = refPath, FileManager.default.fileExists(atPath: p) {
                let i = loadCGImage(p)
                guard i.width == 1280, i.height == 720 else { print("panelocr: --ref \(p) is \(i.width)x\(i.height), expected 1280x720"); return 2 }
                refImg = i
            }
            if let ri = refImg {
                let pairs = compare(cap: lines(img, crop: batteryCrop), ref: lines(ri, crop: batteryCrop))
                for (i, p) in pairs.enumerated() {
                    if !p.exact { allExact = false }
                    if !p.layout { allLayout = false }
                    let box = p.cap?.box ?? p.ref?.box ?? batteryCrop
                    print("battery.\(i + 1)\t\(p.cap?.text ?? "(none)")\t\(String(format: "%.2f", p.cap?.conf ?? 0))\t\(fmtR(box))\t\(p.ref?.text ?? "(none)")\t\(yn(p.exact))\t\(yn(p.layout))\t\(p.note)")
                }
                if pairs.isEmpty { print("battery\t(none)\t0.00\t\(fmtR(batteryCrop))\t(none)\tyes\tyes\tno digit line in capture or snapshot") }
            } else {
                allLayout = false; allExact = false
                print("battery\t-\t0.00\t\(fmtR(batteryCrop))\t-\tNO\tNO\tno reference image (--ref SNAPSHOT.png) → battery area not comparable")
            }
        }
        print("panelocr\t\(!haveState ? "no --state given" : (allLayout ? (allExact ? "ALL MATCH" : "LAYOUT MATCH") : "MISMATCH"))")
        return allLayout ? 0 : 1
    }

    /// Part of `amcompare unittest`.
    static func selfTest() -> Bool {
        var ok = true, n = 0
        func expect(_ name: String, _ c: Bool, _ d: String = "") { n += 1; if !c { ok = false }; print("\(c ? "PASS" : "FAIL")\t\(name)\t\(d)") }
        let same: [(String, String)] = [("18.48 GB", "18.63 GB"), ("47", "51"), ("12:18:26", "12:19:03"), ("24.00\u{00A0}GB", "13.37 GB"),
                                        ("O bytes", "7 bytes"), ("1,023.9 MB", "4,567.0 MB"), ("99%", "98%"), ("", "—"), ("-", "—")]
        for (a, b) in same { expect("layout ≡ '\(a)' '\(b)'", OCRNorm.layoutKey(a) == OCRNorm.layoutKey(b), OCRNorm.layoutKey(a)) }
        let diff: [(String, String)] = [("9.99 GB", "10.00 GB"), ("—", "4.38 GB"), ("", "47"), ("1,023.9 MB", "999.9 MB"), ("0 bytes", "1 byte"),
                                        ("100%", "99%"), ("3.07 GB", "3.07 MB"), ("39.8 MB", "3.98 MB"), ("9", "10")]
        for (a, b) in diff { expect("layout ≢ '\(a)' '\(b)'", OCRNorm.layoutKey(a) != OCRNorm.layoutKey(b), "\(OCRNorm.layoutKey(a)) vs \(OCRNorm.layoutKey(b))") }
        expect("exact key unchanged", OCRNorm.key("18.48 GB") != OCRNorm.key("18.63 GB") && OCRNorm.key("—") == "—")
        func L(_ t: String, _ y: CGFloat) -> GateLine { GateLine(text: t, conf: 1, box: CGRect(x: 1080, y: y - 35, width: 170, height: 70)) }
        let ref = [L("100%", 60), L("99%", 158)]
        let p1 = compare(cap: [L("100%", 66), L("98%", 160)], ref: ref)
        expect("battery digit change accepted", p1.count == 2 && p1.allSatisfy { $0.layout } && !p1[1].exact)
        expect("battery 99% → 100% rejected", !compare(cap: [L("100%", 60), L("100%", 158)], ref: ref).allSatisfy { $0.layout })
        expect("battery row appears", !compare(cap: ref + [L("85%", 256)], ref: ref).allSatisfy { $0.layout })
        expect("battery row disappears", !compare(cap: [L("100%", 60)], ref: ref).allSatisfy { $0.layout })
        expect("battery row moved", !compare(cap: [L("100%", 60), L("99%", 256)], ref: ref).allSatisfy { $0.layout })
        expect("battery — row becomes a number", !compare(cap: [L("100%", 60), L("85%", 158), L("99%", 256)], ref: [L("100%", 60), L("99%", 256)]).allSatisfy { $0.layout })
        print("panelgate selftest: \(ok ? "all \(n) passed" : "FAILED")")
        return ok
    }
}
