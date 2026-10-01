// fontcal — offscreen font-size calibration at 1x (CoreText into a CGBitmapContext, no windows).
//
// usage:
//   fontcal report [--digits 64] [--labels 32] [--sheet out.png]      full calibration tables (markdown)
//   fontcal measure --font KEY --size PT --text "…"                  one measurement (worst case over 4 sub-pixel baselines)
//   fontcal minsize --font KEY --text "…" --target PX                 smallest integer pt whose ink height >= PX
//   fontcal render  --font KEY --size PT --text "…" --out f.png [--fg FFFFFF --bg 000000] [--yoff 0.25]
//   fontcal fonts                                                    list font keys
//   fontcal selftest                                                 glyphheight ground truth (solid bars of known height)
//
// Font keys mirror what a SwiftUI/AppKit panel would use:
//   sf-<weight>        NSFont.systemFont(ofSize:weight:)                     ≈ SwiftUI .system(size:weight:)
//   sfmono-<weight>    NSFont.monospacedDigitSystemFont(ofSize:weight:)      ≈ .system(size:).monospacedDigit()
//   sfround-<weight>   systemFont + .rounded design                         ≈ .system(size:weight:design:.rounded)
//   pingfang-<weight>  PingFangTC-{Regular,Medium,Semibold}
//   weights: regular medium semibold bold heavy (pingfang: regular medium semibold)
import Foundation
import AppKit
import CoreText

func weightOf(_ s: String) -> NSFont.Weight {
    switch s {
    case "light": return .light
    case "regular": return .regular
    case "medium": return .medium
    case "semibold": return .semibold
    case "bold": return .bold
    case "heavy": return .heavy
    case "black": return .black
    default: die("unknown weight \(s)")
    }
}

func makeFont(_ key: String, _ size: CGFloat) -> CTFont {
    let parts = key.split(separator: "-", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { die("bad font key \(key)") }
    let (fam, w) = (parts[0], parts[1])
    switch fam {
    case "sf": return NSFont.systemFont(ofSize: size, weight: weightOf(w)) as CTFont
    case "sfmono": return NSFont.monospacedDigitSystemFont(ofSize: size, weight: weightOf(w)) as CTFont
    case "sfround":
        let base = NSFont.systemFont(ofSize: size, weight: weightOf(w))
        guard let d = base.fontDescriptor.withDesign(.rounded) else { die("rounded design unavailable") }
        return (NSFont(descriptor: d, size: size) ?? base) as CTFont
    case "pingfang":
        let name = ["regular": "PingFangTC-Regular", "medium": "PingFangTC-Medium", "semibold": "PingFangTC-Semibold"][w]
        guard let n = name, let f = NSFont(name: n, size: size) else { die("PingFang TC \(w) not available") }
        return f as CTFont
    default: die("unknown font family \(fam)")
    }
}

struct Rendered {
    let bitmap: Bitmap
    let advance: CGFloat       // typographic width (layout budget)
    let ascent: CGFloat
    let descent: CGFloat
    let fontName: String
}

/// Renders one line; `yoff` shifts the baseline by a sub-pixel amount to expose anti-alias variance.
func render(_ key: String, _ size: CGFloat, _ text: String, fg: CGColor = rgba(0, 0, 0), bg: CGColor = rgba(1, 1, 1),
            yoff: CGFloat = 0, xoff: CGFloat = 0) -> Rendered {
    let font = makeFont(key, size)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): fg,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
    let adv = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
    let pad = max(8, size * 0.5)
    let W = Int(ceil(adv + 2 * pad)), H = Int(ceil(asc + desc + 2 * pad))
    let bm = Bitmap(width: W, height: H)
    bm.ctx.setFillColor(bg)
    bm.ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    bm.ctx.setAllowsFontSmoothing(true)
    bm.ctx.setShouldAntialias(true)
    bm.ctx.textPosition = CGPoint(x: pad + xoff, y: pad + desc + yoff)
    CTLineDraw(line, bm.ctx)
    // actual fonts used per glyph run (reveals CoreText fallback, e.g. CJK under the system font)
    var names: [String] = []
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let at = CTRunGetAttributes(run) as NSDictionary
        if let f = at[kCTFontAttributeName as String] {
            let n = CTFontCopyPostScriptName(f as! CTFont) as String
            if !names.contains(n) { names.append(n) }
        }
    }
    return Rendered(bitmap: bm, advance: adv, ascent: asc, descent: desc, fontName: names.joined(separator: "+"))
}

struct Measure { var inkH: Int; var inkHmax: Int; var inkW: Int; var advance: CGFloat; var font: String }

/// Worst case (minimum) ink height over baselines offset by 0, .25, .5, .75 px and both polarities.
func measure(_ key: String, _ size: CGFloat, _ text: String) -> Measure {
    var hMin = Int.max, hMax = 0, wMax = 0
    var adv: CGFloat = 0, name = ""
    for yoff in [0.0, 0.25, 0.5, 0.75] as [CGFloat] {
        for dark in [false, true] {
            let r = render(key, size, text, fg: dark ? rgba(1, 1, 1) : rgba(0, 0, 0), bg: dark ? rgba(0, 0, 0) : rgba(1, 1, 1), yoff: yoff)
            let ink = measureInk(r.bitmap, PixRect(x: 0, y: 0, w: r.bitmap.width, h: r.bitmap.height))
            hMin = min(hMin, ink.height); hMax = max(hMax, ink.height); wMax = max(wMax, ink.width)
            adv = r.advance; name = r.fontName
        }
    }
    return Measure(inkH: hMin, inkHmax: hMax, inkW: wMax, advance: adv, font: name)
}

func minSize(_ key: String, _ text: String, _ target: Int) -> (Int, Measure) {
    var lo = 1, hi = 1000
    while lo < hi {
        let mid = (lo + hi) / 2
        if measure(key, CGFloat(mid), text).inkH >= target { hi = mid } else { lo = mid + 1 }
    }
    // guard against non-monotonic hinting: walk up until satisfied
    var s = lo
    var m = measure(key, CGFloat(s), text)
    while m.inkH < target { s += 1; m = measure(key, CGFloat(s), text) }
    return (s, m)
}

func hex(_ s: String) -> CGColor {
    let v = Int(s, radix: 16) ?? 0
    return rgba(CGFloat((v >> 16) & 255) / 255, CGFloat((v >> 8) & 255) / 255, CGFloat(v & 255) / 255)
}

func f1(_ x: Double) -> String { String(format: "%.1f", x) }
func f3(_ x: Double) -> String { String(format: "%.3f", x) }

@main
struct FontCal {
    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        guard let cmd = argv.first else { die("usage: fontcal report|measure|minsize|render|fonts|selftest …  (see header of FontCal.swift / README)") }
        let a = Args(Array(argv.dropFirst()), flagNames: [])
        switch cmd {
        case "fonts":
            for k in ["sf", "sfmono", "sfround"] { for w in ["regular", "medium", "semibold", "bold", "heavy"] {
                print("\(k)-\(w)\t\(CTFontCopyPostScriptName(makeFont("\(k)-\(w)", 20)) as String)") } }
            for w in ["regular", "medium", "semibold"] { print("pingfang-\(w)\t\(CTFontCopyPostScriptName(makeFont("pingfang-\(w)", 20)) as String)") }
        case "measure":
            guard let k = a.one("font"), let s = a.double("size"), let t = a.one("text") else { die("measure --font K --size PT --text T") }
            let m = measure(k, CGFloat(s), t)
            print("font=\(k) (\(m.font)) size=\(s)pt text=\"\(t)\" ink_h_min=\(m.inkH) ink_h_max=\(m.inkHmax) ink_w=\(m.inkW) advance=\(f1(Double(m.advance)))")
        case "minsize":
            guard let k = a.one("font"), let t = a.one("text"), let tg = a.int("target") else { die("minsize --font K --text T --target PX") }
            let (s, m) = minSize(k, t, tg)
            print("font=\(k) (\(m.font)) text=\"\(t)\" target=\(tg)px -> min_size=\(s)pt ink_h=\(m.inkH)..\(m.inkHmax) ink_w=\(m.inkW) advance=\(f1(Double(m.advance)))")
        case "render":
            guard let k = a.one("font"), let s = a.double("size"), let t = a.one("text"), let out = a.one("out") else { die("render --font K --size PT --text T --out F") }
            let r = render(k, CGFloat(s), t, fg: hex(a.one("fg") ?? "000000"), bg: hex(a.one("bg") ?? "FFFFFF"),
                           yoff: CGFloat(a.double("yoff") ?? 0))
            writePNG(r.bitmap.makeImage(), out)
            print("rendered \(r.bitmap.width)x\(r.bitmap.height) font=\(r.fontName) advance=\(f1(Double(r.advance))) -> \(out)")
        case "selftest":
            selfTest(a.one("out"))
        case "report":
            report(digits: a.int("digits") ?? 64, labels: a.int("labels") ?? 32, sheet: a.one("sheet"))
        default: die("unknown command \(cmd)")
        }
    }

    /// Ground truth for measureInk: anti-aliased bars with known fractional heights / positions.
    static func selfTest(_ out: String?) {
        print("case\ttrue_top\ttrue_h\tmeasured_h\tmeasured_top\terr_px")
        let W = 900, H = 300
        let bm = Bitmap(width: W, height: H)
        bm.ctx.setFillColor(rgba(0.05, 0.05, 0.08)); bm.ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        var worst = 0.0
        var cases: [(Double, Double, Double)] = []   // x, topY (from top), height
        var x = 20.0
        for h in [32.0, 32.5, 63.6, 64.0, 64.4, 100.25] {
            for top in [40.0, 40.3, 40.5] { cases.append((x, top, h)); x += 42 }
        }
        bm.ctx.setShouldAntialias(true)
        for (cx, top, h) in cases {
            bm.ctx.setFillColor(rgba(0.95, 0.95, 0.95))
            bm.ctx.fill(CGRect(x: cx, y: Double(H) - top - h, width: 30, height: h))
        }
        for (cx, top, h) in cases {
            let ink = measureInk(bm, PixRect(x: Int(cx) - 5, y: 20, w: 40, h: 200))
            // at 50 % coverage threshold a bar of true height h spanning [top, top+h) yields ~round(h) rows
            let err = Double(ink.height) - h
            worst = max(worst, abs(err))
            print("bar x=\(Int(cx))\t\(top)\t\(h)\t\(ink.height)\t\(ink.minY)\t\(String(format: "%+.2f", err))")
        }
        print("# worst |error| = \(String(format: "%.2f", worst)) px (expected <= 1.0: 50%-coverage edges round to nearest pixel)")
        if let o = out { writePNG(bm.makeImage(), o); print("# bars image -> \(o)") }
        exit(worst <= 1.0 ? 0 : 1)
    }

    static func report(digits: Int, labels: Int, sheet: String?) {
        let numFonts = ["sf-regular", "sf-semibold", "sf-bold", "sfmono-regular", "sfmono-semibold", "sfmono-bold",
                        "sfround-medium", "sfround-semibold", "sfround-bold"]
        let labelFonts = ["sf-regular", "sf-medium", "sf-semibold", "sfround-medium", "pingfang-regular", "pingfang-medium", "pingfang-semibold"]

        print("## 1. Ratios at 100 pt (ink height / point size, worst of 4 sub-pixel baselines x 2 polarities)\n")
        print("| font key | PostScript | digits \"0123456789\" | cap \"H\" | \"x\" | \"Memory Used\" (full ink) | CJK \"已使用記憶體\" |")
        print("|---|---|---|---|---|---|---|")
        for k in Array(Set(numFonts + labelFonts)).sorted() {
            let d = measure(k, 100, "0123456789"), c = measure(k, 100, "H"), xh = measure(k, 100, "x")
            let mu = measure(k, 100, "Memory Used"), cj = measure(k, 100, "已使用記憶體")
            print("| \(k) | \(d.font) | \(f3(Double(d.inkH) / 100)) | \(f3(Double(c.inkH) / 100)) | \(f3(Double(xh.inkH) / 100)) | \(f3(Double(mu.inkH) / 100)) | \(f3(Double(cj.inkH) / 100)) (\(cj.font)) |")
        }

        print("\n## 2. Minimum integer point size for main numbers (digit ink height >= \(digits) px)\n")
        print("| font key | min pt (\"0123456789\") | ink h | \"18.52 GB\" min pt | \"100%\" min pt | adv \"18.52 GB\" @min | adv \"100%\" @min | adv \"24.00 GB\" @min | adv \"1023.9 MB\" @min |")
        print("|---|---|---|---|---|---|---|---|---|")
        for k in numFonts {
            let (s, m) = minSize(k, "0123456789", digits)
            let (s2, _) = minSize(k, "18.52 GB", digits)
            let (s3, _) = minSize(k, "100%", digits)
            let a1 = measure(k, CGFloat(s), "18.52 GB"), a2 = measure(k, CGFloat(s), "100%")
            let a3 = measure(k, CGFloat(s), "24.00 GB"), a4 = measure(k, CGFloat(s), "1023.9 MB")
            print("| \(k) | **\(s)** | \(m.inkH)..\(m.inkHmax) | \(s2) | \(s3) | \(f1(Double(a1.advance))) | \(f1(Double(a2.advance))) | \(f1(Double(a3.advance))) | \(f1(Double(a4.advance))) |")
        }

        print("\n## 3. Minimum integer point size for labels (>= \(labels) px)\n")
        print("Latin: conservative = cap height of \"H\" (letters without descenders); full-ink of \"Memory Used\" includes the 'y' descender.\n")
        print("| font key | cap \"H\" min pt | \"Memory Used\" full-ink min pt | CJK \"已使用記憶體\" min pt (font used) | CJK \"實體記憶體\" min pt | adv \"Memory Used\" @capmin | adv \"已使用記憶體\" @cjkmin | adv \"Compressed\" @capmin |")
        print("|---|---|---|---|---|---|---|---|")
        for k in labelFonts {
            let (sc, _) = minSize(k, "H", labels)
            let (sm, _) = minSize(k, "Memory Used", labels)
            let (sj, mj) = minSize(k, "已使用記憶體", labels)
            let (sj2, _) = minSize(k, "實體記憶體", labels)
            let a1 = measure(k, CGFloat(sc), "Memory Used"), a2 = measure(k, CGFloat(sj), "已使用記憶體"), a3 = measure(k, CGFloat(sc), "Compressed")
            print("| \(k) | **\(sc)** | \(sm) | **\(sj)** (\(mj.font)) | \(sj2) | \(f1(Double(a1.advance))) | \(f1(Double(a2.advance))) | \(f1(Double(a3.advance))) |")
        }

        print("\n## 4. Width budget of typical strings (typographic advance in px @1x)\n")
        let samples: [(String, String, Int)] = [
            ("sfmono-semibold", "18.52 GB", 0), ("sfmono-semibold", "100%", 0), ("sfmono-semibold", "0 bytes", 0),
            ("sfround-semibold", "18.52 GB", 0), ("sf-medium", "Physical Memory", 1), ("sf-medium", "Memory Used", 1),
            ("sf-medium", "Cached Files", 1), ("sf-medium", "Swap Used", 1), ("sf-medium", "App Memory", 1),
            ("sf-medium", "Wired Memory", 1), ("sf-medium", "Compressed", 1), ("sf-medium", "Magic Keyboard", 1),
            ("sf-medium", "Alex's AirPods Pro", 1), ("pingfang-medium", "實體記憶體", 1), ("pingfang-medium", "已使用記憶體", 1),
            ("pingfang-medium", "觸控式軌跡板", 1), ("pingfang-medium", "左耳 右耳 充電盒", 1),
        ]
        print("| font key | text | size pt | ink h | ink w | advance |")
        print("|---|---|---|---|---|---|")
        var sheetItems: [(String, String, Int)] = []
        for (k, t, kind) in samples {
            let s: Int
            if kind == 0 { s = minSize(k, "0123456789", digits).0 }
            else if k.hasPrefix("pingfang") { s = minSize(k, "已使用記憶體", labels).0 }
            else { s = minSize(k, "H", labels).0 }
            let m = measure(k, CGFloat(s), t)
            print("| \(k) | \(t) | \(s) | \(m.inkH) | \(m.inkW) | \(f1(Double(m.advance))) |")
            sheetItems.append((k, t, s))
        }

        if let out = sheet {
            // 1280x720 1x sheet with a few of the recommended sizes — to be verified with glyphheight
            let W = 1280, H = 720
            let bm = Bitmap(width: W, height: H)
            bm.ctx.setFillColor(rgba(0.07, 0.07, 0.09)); bm.ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            let picks: [(String, String, Int, CGFloat, CGFloat)] = [
                ("sfmono-semibold", "18.52 GB", sheetItems[0].2, 20, 20),
                ("sfmono-semibold", "100%", sheetItems[1].2, 700, 20),
                ("sf-medium", "Memory Used", sheetItems[5].2, 20, 200),
                ("pingfang-medium", "已使用記憶體", sheetItems[14].2, 20, 300),
                ("sf-medium", "Compressed", sheetItems[11].2, 700, 200),
                ("pingfang-medium", "左耳 右耳 充電盒", sheetItems[16].2, 700, 300),
            ]
            for (k, t, s, x, yTop) in picks {
                let font = makeFont(k, CGFloat(s))
                let attrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgba(0.95, 0.95, 0.95),
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: t, attributes: attrs))
                bm.ctx.textPosition = CGPoint(x: x, y: CGFloat(H) - yTop - CTFontGetAscent(font))
                CTLineDraw(line, bm.ctx)
                print("sheet: \(k) \(s)pt \"\(t)\" at x=\(Int(x)) top=\(Int(yTop))")
            }
            writePNG(bm.makeImage(), out)
            print("# sheet -> \(out)")
        }
    }
}
