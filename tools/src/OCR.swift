// ocr — Apple Vision text recognition (VNRecognizeTextRequest, .accurate, en-US + zh-Hant), offline.
//
// usage: ocr IMAGE.png [--crop x,y,w,h] [--scale N] [--langs "en-US;zh-Hant,en-US"] [--fast] [--no-correct]
//            [--minconf 0.0] [--json] [--words]
//
//  * --crop is in image pixels (top-left origin); reported boxes are always in ORIGINAL image pixels, top-left origin
//  * --scale N upsamples the (cropped) image N× before recognition (helps small 1x UI text); boxes are mapped back
//  * default output: TSV  conf  x  y  w  h  text   (one line per recognised text observation, sorted top→bottom, left→right)
//  * --langs: ';'-separated passes, each a ','-separated language list. Default "en-US;zh-Hant,en-US" — Vision
//    only reads CJK when zh-Hant is listed first, which lowers Latin/digit confidence, so both passes run and are
//    merged by box overlap (IoU > 0.3) keeping the higher-confidence candidate
//  * --digitfix: in tokens that are mostly digits, O/o → 0 and I/l/| → 1 (use when comparing numbers)
//  * --words additionally splits each observation into whitespace-separated tokens with their own boxes
import Foundation
import CoreGraphics
import Vision

struct Hit: Codable { var text: String; var conf: Float; var x: Int; var y: Int; var w: Int; var h: Int; var kind: String; var pass: String }

@main
struct OCR {
    static func main() {
        let a = Args(Array(CommandLine.arguments.dropFirst()), flagNames: ["json", "fast", "no-correct", "words", "help", "digitfix"])
        guard let path = a.positional.first, !a.has("help") else {
            print("usage: ocr IMAGE.png [--crop x,y,w,h] [--scale N] [--langs \"en-US;zh-Hant,en-US\"] [--fast] [--no-correct] [--minconf C] [--json] [--words] [--digitfix]")
            exit(2)
        }
        var img = loadCGImage(path)
        var ox = 0, oy = 0
        if let c = a.one("crop") {
            let r = clamp(parseRect(c), img.width, img.height)
            guard let cropped = img.cropping(to: CGRect(x: r.x, y: r.y, width: r.w, height: r.h)) else { die("crop failed") }
            img = cropped; ox = r.x; oy = r.y
        }
        let scale = max(1, a.int("scale") ?? 1)
        if scale > 1 {
            let bm = Bitmap(width: img.width * scale, height: img.height * scale)
            bm.ctx.interpolationQuality = .high
            bm.ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width * scale, height: img.height * scale))
            img = bm.makeImage()
        }
        let W = Double(img.width), H = Double(img.height)
        // Vision only recognises CJK when zh-Hant is the FIRST language, but then Latin/digits get lower confidence.
        // Default: two passes (en-US) and (zh-Hant,en-US), merged by box overlap keeping the higher confidence.
        let passes: [[String]] = a.one("langs").map { $0.split(separator: ";").map { $0.split(separator: ",").map(String.init) } }
            ?? [["en-US"], ["zh-Hant", "en-US"]]
        let minConf = Float(a.double("minconf") ?? 0)
        func toPix(_ bb: CGRect) -> (Int, Int, Int, Int) {
            // Vision: normalised, origin bottom-left → image px, origin top-left, undo scale, add crop offset
            let x = bb.minX * W / Double(scale), w = bb.width * W / Double(scale)
            let y = (1 - bb.maxY) * H / Double(scale), h = bb.height * H / Double(scale)
            return (Int(x.rounded()) + ox, Int(y.rounded()) + oy, Int(w.rounded()), Int(h.rounded()))
        }
        func iou(_ p: CGRect, _ q: CGRect) -> Double {
            let i = p.intersection(q); if i.isNull { return 0 }
            let ia = Double(i.width * i.height)
            return ia / (Double(p.width * p.height) + Double(q.width * q.height) - ia)
        }
        var chosen: [(VNRecognizedText, CGRect, Int)] = []
        for (pi, langs) in passes.enumerated() {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = a.has("fast") ? .fast : .accurate
            req.usesLanguageCorrection = !a.has("no-correct")
            req.recognitionLanguages = langs
            req.minimumTextHeight = 0
            do { try VNImageRequestHandler(cgImage: img, options: [:]).perform([req]) } catch { die("Vision failed: \(error)") }
            for obs in req.results ?? [] {
                guard let cand = obs.topCandidates(1).first, cand.confidence >= minConf else { continue }
                if let j = chosen.firstIndex(where: { iou($0.1, obs.boundingBox) > 0.3 }) {
                    if cand.confidence > chosen[j].0.confidence { chosen[j] = (cand, obs.boundingBox, pi) }
                } else { chosen.append((cand, obs.boundingBox, pi)) }
            }
        }
        var hits: [Hit] = []
        for (cand, bb, pi) in chosen {
            let (x, y, w, h) = toPix(bb)
            hits.append(Hit(text: cand.string, conf: cand.confidence, x: x, y: y, w: w, h: h, kind: "line", pass: passes[pi].joined(separator: ",")))
            if a.has("words") {
                let s = cand.string
                var idx = s.startIndex
                for tok in s.split(separator: " ") {
                    guard let rng = s.range(of: tok, range: idx..<s.endIndex) else { continue }
                    idx = rng.upperBound
                    if let box = try? cand.boundingBox(for: rng) {
                        let (wx, wy, ww, wh) = toPix(box.boundingBox)
                        hits.append(Hit(text: String(tok), conf: cand.confidence, x: wx, y: wy, w: ww, h: wh, kind: "word", pass: passes[pi].joined(separator: ",")))
                    }
                }
            }
        }
        if a.has("digitfix") {
            // in tokens that are mostly digits, map look-alike letters to digits (Vision sometimes reads 0 as O)
            func fix(_ t: String) -> String {
                t.split(separator: " ", omittingEmptySubsequences: false).map { tok -> String in
                    let d = tok.filter { $0.isNumber }.count
                    let l = tok.filter { "OoIl|".contains($0) }.count
                    guard d > 0, d * 2 >= tok.count - l else { return String(tok) }
                    return String(tok.map { "Oo".contains($0) ? "0" : ("Il|".contains($0) ? "1" : $0) })
                }.joined(separator: " ")
            }
            for i in hits.indices { hits[i].text = fix(hits[i].text) }
        }
        hits.sort { ($0.y / 8, $0.x) < ($1.y / 8, $1.x) }
        if a.has("json") {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            print(String(data: try! enc.encode(hits), encoding: .utf8)!)
        } else {
            print("# ocr \(path) crop_origin=\(ox),\(oy) scale=\(scale) level=\(a.has("fast") ? "fast" : "accurate") passes=\(passes.map { $0.joined(separator: ",") }.joined(separator: ";"))")
            print("kind\tconf\tx\ty\tw\th\tpass\ttext")
            for h in hits { print("\(h.kind)\t\(String(format: "%.2f", h.conf))\t\(h.x)\t\(h.y)\t\(h.w)\t\(h.h)\t\(h.pass)\t\(h.text)") }
        }
    }
}
