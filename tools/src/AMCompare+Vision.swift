// AMCompare+Vision.swift — OCR (Apple Vision, in-process, offline) and pixel sampling for the criterion-#4 harness.
//   * AM side: one crop per footer value, from the AX frame (CG points → LG pixels), padded, upscaled ×2.
//   * panel side: one crop per value; y-range from the snapshot rects (value.<field>[…] rows ± 8 px), x-range = the
//     field's column (pre-registered table below) so a string that is wider/narrower than in the snapshot still fits.
//   * AM pressure colour: rightmost 4 px of the graph frame (extended inwards up to 16 px only if those columns hold no
//     coloured pixel), the vertical middle of the coloured run, median hue → class.
//   * panel pressure colour: the level pill's left padding (x 719–727, y 106–134 inside Layout.pill 716,93,112,54) —
//     the pill centre is covered by the dark pill text; also the pressure number's ink colour, informational.
import Foundation
import CoreGraphics
import Vision

struct OCRResult { let text: String; let conf: Float; let crop: CGRect; let pass: String }

enum VisionOCR {
    /// The first Vision text request in a process loads the model (measured ~55 s wall in a cold dry run); do it once
    /// before the first attempt so attempt timings are not dominated by it. Returns the seconds it took.
    static func warmUp() -> Double {
        let t0 = Date()
        let bm = Bitmap(width: 240, height: 60)
        bm.ctx.setFillColor(rgba(0, 0, 0)); bm.ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 60))
        drawText(bm.ctx, "18.52 GB", x: 10, yTop: 10, imageHeight: 60, size: 30, color: rgba(1, 1, 1))
        _ = read(bm.makeImage(), crop: CGRect(x: 0, y: 0, width: 240, height: 60))
        return Date().timeIntervalSince(t0)
    }

    /// Recognise the text in `crop` (image px, top-left origin). Observations are joined left→right with one space.
    static func read(_ img: CGImage, crop: CGRect, scale: Int = 1, expectBytes: Bool = true) -> OCRResult {
        let r = crop.integral.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard !r.isNull, r.width >= 4, r.height >= 4, var sub = img.cropping(to: r) else { return OCRResult(text: "", conf: 0, crop: crop, pass: "crop-failed") }
        if scale > 1 {
            let bm = Bitmap(width: sub.width * scale, height: sub.height * scale)
            bm.ctx.interpolationQuality = .high
            bm.ctx.draw(sub, in: CGRect(x: 0, y: 0, width: sub.width * scale, height: sub.height * scale))
            sub = bm.makeImage()
        }
        var best: OCRResult? = nil
        for correct in [false, true] {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = correct
            req.recognitionLanguages = ["en-US"]
            req.minimumTextHeight = 0
            try? VNImageRequestHandler(cgImage: sub, options: [:]).perform([req])
            let obs = (req.results ?? []).compactMap { o -> (CGFloat, String, Float)? in
                guard let c = o.topCandidates(1).first else { return nil }
                return (o.boundingBox.minX, c.string, c.confidence)
            }.sorted { $0.0 < $1.0 }
            let text = obs.map { $0.1 }.joined(separator: " ")
            let conf = obs.map { $0.2 }.min() ?? 0
            let res = OCRResult(text: OCRNorm.digitfix(OCRNorm.spaces(text)), conf: conf, crop: r, pass: correct ? "en-US+correction" : "en-US")
            if !expectBytes { if !text.isEmpty { return res } else { best = best ?? res; continue } }
            if ByteString.parse(res.text) != nil { return res }
            if best == nil || (best!.text.isEmpty && !res.text.isEmpty) { best = res }
        }
        return best ?? OCRResult(text: "", conf: 0, crop: r, pass: "none")
    }
}

// MARK: - geometry

enum Geo {
    /// CG global points → LG image pixels (main display origin, image width / display width scale).
    static func toLG(_ r: CGRect, main: CGRect, imageWidth: Int) -> CGRect {
        let s = CGFloat(imageWidth) / main.width
        return CGRect(x: (r.minX - main.minX) * s, y: (r.minY - main.minY) * s, width: r.width * s, height: r.height * s)
    }
}

// MARK: - panel regions

enum PanelRegions {
    /// Pre-registered column x-ranges (Layout §7.3 columns, 1280×720 px).
    static let columns: [String: (CGFloat, CGFloat)] = [
        "used": (20, 424), "pressure": (430, 712),
        "physical": (20, 288), "cached": (288, 588), "swap": (588, 842),
        "app": (20, 288), "wired": (288, 588), "compressed": (588, 842)]
    /// Fallback y-ranges when the rects file has no row for a field (e.g. a failed "—" value is not measured).
    static let defaultY: [String: (CGFloat, CGFloat)] = [
        "used": (62, 169), "pressure": (72, 168), "physical": (460, 530), "cached": (460, 530), "swap": (460, 530),
        "app": (586, 656), "wired": (586, 656), "compressed": (586, 656)]
    static let pill = CGRect(x: 716, y: 93, width: 112, height: 54)
    static let pillSample = CGRect(x: 719, y: 106, width: 9, height: 29)

    /// rects.tsv (Snapshot `label\tx,y,w,h\tmin_px\tclass`) → field → OCR crop.
    static func crops(rectsTSV: String?) -> [String: CGRect] {
        var ys: [String: (CGFloat, CGFloat)] = [:]
        for line in (rectsTSV ?? "").split(separator: "\n").dropFirst() {
            let c = line.split(separator: "\t")
            guard c.count >= 2, c[0].hasPrefix("value.") else { continue }
            let name = c[0].dropFirst(6)
            guard let br = name.firstIndex(of: "[") else { continue }
            let field = String(name[..<br])
            guard columns[field] != nil else { continue }
            let p = c[1].split(separator: ",").compactMap { Double($0) }
            guard p.count == 4 else { continue }
            let y0 = CGFloat(p[1]), y1 = CGFloat(p[1] + p[3])
            if let e = ys[field] { ys[field] = (min(e.0, y0), max(e.1, y1)) } else { ys[field] = (y0, y1) }
        }
        var out: [String: CGRect] = [:]
        for (f, col) in columns {
            let y = ys[f].map { ($0.0 - 8, $0.1 + 8) } ?? defaultY[f]!
            out[f] = CGRect(x: col.0, y: max(0, y.0), width: col.1 - col.0, height: min(720, y.1) - max(0, y.0))
        }
        return out
    }
}

// MARK: - colour sampling

enum ColourSample {
    static func pixels(_ bm: Bitmap, _ r: CGRect) -> [(Int, Int, Int)] {
        var out: [(Int, Int, Int)] = []
        let x0 = max(0, Int(r.minX)), x1 = min(bm.width, Int(r.maxX)), y0 = max(0, Int(r.minY)), y1 = min(bm.height, Int(r.maxY))
        guard x1 > x0, y1 > y0 else { return [] }
        for y in y0..<y1 { for x in x0..<x1 { out.append(bm.rgb(x, y)) } }
        return out
    }

    struct GraphSample { let cls: HueClass; let hue: Double?; let n: Int; let columns: CGRect; let rows: CGRect?; let note: String }

    /// AM graph: rightmost 4 px columns of `framePx`; coloured run → middle ±2 rows → median hue.
    static func amGraph(_ bm: Bitmap, framePx: CGRect) -> GraphSample {
        let f = framePx.integral
        var note = "rightmost 4 px"
        for inset in stride(from: 0, through: 12, by: 4) {
            let cols = CGRect(x: f.maxX - 4 - CGFloat(inset), y: f.minY, width: 4, height: f.height)
            // coloured rows in these columns
            var rows: [Int] = []
            for y in max(0, Int(cols.minY))..<min(bm.height, Int(cols.maxY)) {
                let px = (Int(cols.minX)..<Int(cols.maxX)).filter { $0 >= 0 && $0 < bm.width }.map { bm.rgb($0, y) }
                if px.filter(PressureColor.isColoured).count >= 2 { rows.append(y) }
            }
            if rows.isEmpty { note = "no coloured px in the rightmost \(inset + 4) px"; continue }
            if inset > 0 { note = "extended \(inset) px inwards (rightmost columns uncoloured)" }
            let mid = rows[rows.count / 2]
            let rr = CGRect(x: cols.minX, y: CGFloat(mid - 2), width: 4, height: 5)
            let c = PressureColor.classify(pixels: pixels(bm, rr))
            return GraphSample(cls: c.cls, hue: c.hue, n: c.n, columns: cols, rows: rr, note: note + ", coloured rows \(rows.first!)…\(rows.last!) (\(rows.count))")
        }
        return GraphSample(cls: .unknown, hue: nil, n: 0, columns: CGRect(x: f.maxX - 16, y: f.minY, width: 16, height: f.height), rows: nil, note: note)
    }

    /// Panel pill background (left padding of the pill).
    static func panelPill(_ bm: Bitmap) -> (cls: HueClass, hue: Double?, n: Int, rgb: (Int, Int, Int)) {
        let px = pixels(bm, PanelRegions.pillSample)
        let c = PressureColor.classify(pixels: px)
        let sorted = px.sorted { ($0.0 + $0.1 + $0.2) < ($1.0 + $1.1 + $1.2) }
        let med = sorted.isEmpty ? (0, 0, 0) : sorted[sorted.count / 2]
        return (c.cls, c.hue, c.n, med)
    }
}
