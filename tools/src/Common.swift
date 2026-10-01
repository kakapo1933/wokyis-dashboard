// Common.swift — shared helpers for the Wokyis evidence tools.
// Pure CoreGraphics / ImageIO / CoreText. No third-party code.
import Foundation
import CoreGraphics
import ImageIO
import CoreText
import UniformTypeIdentifiers

// MARK: - errors / output

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

func die(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func isoNow(_ d: Date = Date()) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone.current
    return f.string(from: d)
}

// MARK: - RGBA bitmap (8-bit, premultiplied last, row 0 = TOP of image)

final class Bitmap {
    let width: Int
    let height: Int
    let ctx: CGContext
    let data: UnsafeMutablePointer<UInt8>
    let bytesPerRow: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            die("cannot create \(width)x\(height) bitmap context")
        }
        ctx = c
        data = c.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
    }

    convenience init(image: CGImage) {
        self.init(width: image.width, height: image.height)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    /// r,g,b of pixel at (x, y) with y measured from the TOP.
    @inline(__always) func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let o = y * bytesPerRow + x * 4
        return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]))
    }

    func makeImage() -> CGImage { ctx.makeImage()! }
}

func loadCGImage(_ path: String) -> CGImage {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        die("cannot read image: \(path)")
    }
    return img
}

func writePNG(_ img: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        die("cannot create png: \(path)")
    }
    CGImageDestinationAddImage(dst, img, nil)
    if !CGImageDestinationFinalize(dst) { die("cannot write png: \(path)") }
}

// MARK: - rect parsing

struct PixRect: CustomStringConvertible {
    var x: Int, y: Int, w: Int, h: Int
    var label: String = ""
    var description: String { "\(x),\(y),\(w),\(h)" }
}

/// Parses "x,y,w,h" or "x,y,w,h:label".
func parseRect(_ s: String) -> PixRect {
    var spec = s
    var label = ""
    if let i = s.firstIndex(of: ":") {
        spec = String(s[..<i])
        label = String(s[s.index(after: i)...])
    }
    let p = spec.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard p.count == 4, p[2] > 0, p[3] > 0 else { die("bad rect '\(s)', expected x,y,w,h[:label]") }
    return PixRect(x: p[0], y: p[1], w: p[2], h: p[3], label: label)
}

func clamp(_ r: PixRect, _ W: Int, _ H: Int) -> PixRect {
    let x0 = max(0, min(W, r.x)), y0 = max(0, min(H, r.y))
    let x1 = max(0, min(W, r.x + r.w)), y1 = max(0, min(H, r.y + r.h))
    return PixRect(x: x0, y: y0, w: max(0, x1 - x0), h: max(0, y1 - y0), label: r.label)
}

// MARK: - ink measurement

struct InkResult {
    var found: Bool
    var minX = 0, minY = 0, maxX = 0, maxY = 0       // inclusive, image pixel coords (top-left origin)
    var bg: (Int, Int, Int) = (0, 0, 0)
    var threshold = 0
    var maxDist = 0
    var inkPixels = 0
    var width: Int { found ? maxX - minX + 1 : 0 }
    var height: Int { found ? maxY - minY + 1 : 0 }
}

/// Background = most frequent colour (quantised to 4 bits/channel, then averaged) on the rect border.
func borderBackground(_ bm: Bitmap, _ r: PixRect) -> (Int, Int, Int) {
    var hist: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
    func add(_ x: Int, _ y: Int) {
        let c = bm.rgb(x, y)
        let k = (c.0 >> 4) << 8 | (c.1 >> 4) << 4 | (c.2 >> 4)
        var e = hist[k] ?? (0, 0, 0, 0)
        e.n += 1; e.r += c.0; e.g += c.1; e.b += c.2
        hist[k] = e
    }
    for x in r.x..<(r.x + r.w) { add(x, r.y); add(x, r.y + r.h - 1) }
    for y in r.y..<(r.y + r.h) { add(r.x, y); add(r.x + r.w - 1, y) }
    let best = hist.values.max { $0.n < $1.n }!
    return (best.r / best.n, best.g / best.n, best.b / best.n)
}

@inline(__always) func colorDist(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
    max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
}

/// Measures the ink bounding box inside `r`.
/// A pixel is "ink" when its max-channel distance from the background colour is >= threshold.
/// threshold == nil → adaptive: 50 % of the strongest contrast found in the rect (min 24),
/// i.e. the edge is taken where anti-aliased coverage crosses ~50 %.
func measureInk(_ bm: Bitmap, _ r0: PixRect, threshold: Int? = nil, bg bgOverride: (Int, Int, Int)? = nil) -> InkResult {
    let r = clamp(r0, bm.width, bm.height)
    var res = InkResult(found: false)
    guard r.w > 2, r.h > 2 else { return res }
    let bg = bgOverride ?? borderBackground(bm, r)
    res.bg = bg
    var maxD = 0
    for y in r.y..<(r.y + r.h) { for x in r.x..<(r.x + r.w) { maxD = max(maxD, colorDist(bm.rgb(x, y), bg)) } }
    res.maxDist = maxD
    let thr = threshold ?? max(24, maxD / 2)
    res.threshold = thr
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, n = 0
    for y in r.y..<(r.y + r.h) {
        for x in r.x..<(r.x + r.w) where colorDist(bm.rgb(x, y), bg) >= thr {
            n += 1
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
    if maxX >= 0 && maxD >= 24 {
        res.found = true
        res.minX = minX; res.minY = minY; res.maxX = maxX; res.maxY = maxY; res.inkPixels = n
    }
    return res
}

/// Splits the rect into horizontal ink bands (text lines) separated by >= `gap` empty rows,
/// then returns one InkResult per band (same bg / threshold as the whole rect).
func measureLines(_ bm: Bitmap, _ r0: PixRect, threshold: Int? = nil, gap: Int = 3) -> [InkResult] {
    let r = clamp(r0, bm.width, bm.height)
    let whole = measureInk(bm, r, threshold: threshold)
    guard whole.found else { return [] }
    var rowHas = [Bool](repeating: false, count: r.h)
    for y in r.y..<(r.y + r.h) {
        for x in r.x..<(r.x + r.w) where colorDist(bm.rgb(x, y), whole.bg) >= whole.threshold {
            rowHas[y - r.y] = true; break
        }
    }
    var bands: [(Int, Int)] = []
    var start: Int? = nil, lastInk = -1
    for i in 0..<r.h {
        if rowHas[i] {
            if start == nil { start = i }
            lastInk = i
        } else if let s = start, i - lastInk >= gap {
            bands.append((s, lastInk)); start = nil
        }
    }
    if let s = start { bands.append((s, lastInk)) }
    return bands.map { b in
        var sub = PixRect(x: r.x, y: r.y + b.0, w: r.w, h: b.1 - b.0 + 1)
        sub.label = r.label
        return measureInk(bm, sub, threshold: whole.threshold, bg: whole.bg)
    }
}

// MARK: - drawing helpers (annotations); y is TOP-origin image coordinates

func drawText(_ ctx: CGContext, _ s: String, x: CGFloat, yTop: CGFloat, imageHeight: Int,
              size: CGFloat, color: CGColor, bgColor: CGColor? = nil, bold: Bool = true) {
    let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
    let w = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
    let baselineY = CGFloat(imageHeight) - yTop - asc
    if let bgc = bgColor {
        ctx.setFillColor(bgc)
        ctx.fill(CGRect(x: x - 3, y: baselineY - desc - 2, width: w + 6, height: asc + desc + 4))
    }
    ctx.textPosition = CGPoint(x: x, y: baselineY)
    CTLineDraw(line, ctx)
}

func strokeRectTop(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                   imageHeight: Int, color: CGColor, width: CGFloat = 1) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.stroke(CGRect(x: x + 0.5, y: CGFloat(imageHeight) - y - h + 0.5, width: w - 1, height: h - 1))
}

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// MARK: - simple arg parsing

struct Args {
    var positional: [String] = []
    var opts: [String: [String]] = [:]
    var flags: Set<String> = []
    init(_ argv: [String], flagNames: Set<String>) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let k = String(a.dropFirst(2))
                if flagNames.contains(k) { flags.insert(k) }
                else if i + 1 < argv.count { opts[k, default: []].append(argv[i + 1]); i += 1 }
                else { die("option \(a) needs a value") }
            } else { positional.append(a) }
            i += 1
        }
    }
    func one(_ k: String) -> String? { opts[k]?.last }
    func int(_ k: String) -> Int? { one(k).flatMap { Int($0) } }
    func double(_ k: String) -> Double? { one(k).flatMap { Double($0) } }
    func has(_ k: String) -> Bool { flags.contains(k) }
}
