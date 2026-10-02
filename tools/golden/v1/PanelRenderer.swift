// PanelRenderer.swift — FINAL layout for the 1280×720 @1x Wokyis panel (Phase 2 synthesis).
//
// Base: design A ("glance first") renderer; grafts: C (condensed numerals, AirPods group box, region redraw),
// B (1 px edge ring for criterion 1, text page indicator), judges' must-fixes (no lowercase in labels,
// ≥30 px between adjacent values, label↔value proximity, distinct failed/unavailable/offline, low-battery cue
// that never reuses pressure colours, charging bolt ≥32 px next to the number, startup "收集中" hint).
//
// The SAME code draws the offscreen mockups (CGBitmapContext, flipped) and the live panel
// (NSView.draw, isFlipped = true → NSGraphicsContext.current!.cgContext). Context must be top-left origin.
// Besides drawing, the renderer returns
//   * specs  — glyph-height measurement rects (one per text piece / glyph class; plus per-glyph informational rects)
//   * boxes  — element ink boxes for layoutProblems()
import AppKit
import CoreText

// MARK: - theme (sRGB)

enum Theme {
    static func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
    }
    static let bg        = c(0x07090C)   // near-black
    static let edge      = c(0x3A4048)   // 1 px ring on the outermost pixels (criterion 1 edgecheck)
    static let well      = c(0x0E1217)   // graph well + AirPods group box
    static let grid      = c(0x323B47)   // minute lines (visible: 1.9:1 on well)
    static let gridMajor = c(0x465160)   // 5-minute line and 50 % line
    static let divider   = c(0x1B2129)
    static let label     = c(0x8B95A1)   // static labels (6.6:1)
    static let value     = c(0xF2F4F7)   // live values + failed "—" (18:1)
    static let unit      = c(0xA7B0BB)
    static let offline   = c(0x7A838E)   // "離線" rows (5.2:1 ≥ 3.5:1)
    static let dim       = c(0x6B7480)   // unavailable "—" (4.2:1)
    static let nearby    = c(0xA0A9B4)   // 「附近」 word + nearby AirPods numbers / bolt (8.4:1 on bg, 7.9:1 on well; 2.2:1 below value white)
    static let nearbyBar = c(0x4B525B)   // nearby AirPods bar fill (grey, never the white/low bar)
    static let pillUnknown = c(0x4B525B) // pressure source failed → grey "未知" pill
    static let trackBar  = c(0x1B2129)
    static let barNormal = c(0x7D8894)
    static let attention = c(0xF2F4F7)   // inverted chips: low battery "低", stall "停滯" (never a pressure hue)
    static let sim       = c(0xFF2FB9)   // simulation / injection marker only
    static func pressureFill(_ l: PressureLevel) -> (r: CGFloat, g: CGFloat, b: CGFloat) {   // AM fill hues
        switch l { case .normal: (0, 0.8, 0); case .warning: (0.941, 0.745, 0.141); case .critical: (1, 0, 0) }
    }
    static func pressureText(_ l: PressureLevel) -> CGColor {   // number, pill, graph top line
        switch l { case .normal: c(0x30D158); case .warning: c(0xF0BE24); case .critical: c(0xFF453A) }
    }
}

// MARK: - fonts

enum Fonts {
    /// SF Pro Condensed (width trait −0.2 → .SFNS-Condensed*) with monospaced digits: all numbers, units, Latin labels.
    nonisolated(unsafe) private static var cache: [String: CTFont] = [:]   // main-thread only
    static func num(_ size: CGFloat, _ w: NSFont.Weight = .semibold) -> CTFont {
        let key = "n\(size)/\(w.rawValue)"
        if let f = cache[key] { return f }
        let f = makeNum(size, w); cache[key] = f; return f
    }
    private static func makeNum(_ size: CGFloat, _ w: NSFont.Weight) -> CTFont {
        let base = NSFont.systemFont(ofSize: size, weight: w)
        var d = base.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.width: -0.2, NSFontDescriptor.TraitKey.weight: w.rawValue]])
        d = d.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return (NSFont(descriptor: d, size: size) ?? base) as CTFont
    }
    /// PingFang TC (explicit; system fallback is shorter: 0.88×pt vs 0.93×pt).
    static func cjk(_ size: CGFloat, _ face: String = "Medium") -> CTFont {
        let key = "c\(size)/\(face)"
        if let f = cache[key] { return f }
        let f = (NSFont(name: "PingFangTC-\(face)", size: size) ?? NSFont.systemFont(ofSize: size)) as CTFont
        cache[key] = f; return f
    }
}

enum Size {
    static let hero: CGFloat = 110      // Memory Used digits  (≈80 px ink)
    static let heroMin: CGFloat = 96    // auto-fit floor (≈69 px)
    static let main: CGFloat = 96       // pressure %, battery % digits (≈69 px)
    static let secondary: CGFloat = 60  // six other memory values + clock (≈44 px, ≥40)
    static let unit: CGFloat = 48       // GB / MB / bytes and "%" (cap ≈34 px)
    static let cjk: CGFloat = 38        // CJK labels, PingFang TC Medium (≈35–36 px)
    static let caps: CGFloat = 48       // Latin label runs, upper-case only, SF Condensed Semibold (≈35 px)
}

// MARK: - layout table (top-left px). Every region rect is also a dirty rect for partial redraw.

enum Region: String, CaseIterable {
    case chrome, used, pressure, graph, axis, sec0, sec1, sec2, sec3, sec4, sec5, battery, clock, sim
}

enum Layout {
    static let W: CGFloat = 1280, H: CGFloat = 720
    static let L: CGFloat = 28, LR: CGFloat = 828            // memory column
    static let divider = CGRect(x: 846, y: 28, width: 2, height: 664)
    static let RL: CGFloat = 866, RR: CGFloat = 1252         // battery column
    static let heroLabelBase: CGFloat = 56
    static let heroBase: CGFloat = 154
    static let pressureX: CGFloat = 440
    static let pill = CGRect(x: 716, y: 93, width: 112, height: 54)
    static let graph = CGRect(x: 28, y: 176, width: 800, height: 180)
    static let axisBase: CGFloat = 400
    static let secColX: [CGFloat] = [28, 294, 592]
    static let secLabelBase: [CGFloat] = [456, 586]
    static let secValueBase: [CGFloat] = [516, 642]
    static let badgeBase: CGFloat = 704
    static let clockBase: CGFloat = 700
    static let batFirstTop: CGFloat = 25                      // ink top of the first battery row
    static let batPitch: CGFloat = 98
    static let mainInk: CGFloat = 69                          // ink height of 96 pt condensed digits
    static let pageBase: CGFloat = 636                         // "n/N" page indicator slot (right-aligned)
    static let region: [Region: CGRect] = [
        .used: CGRect(x: 20, y: 12, width: 404, height: 154),
        .pressure: CGRect(x: 430, y: 12, width: 406, height: 154),
        .graph: CGRect(x: 20, y: 170, width: 816, height: 192),
        .axis: CGRect(x: 20, y: 362, width: 816, height: 48),
        .sec0: CGRect(x: 20, y: 412, width: 268, height: 116), .sec1: CGRect(x: 288, y: 412, width: 302, height: 116),
        .sec2: CGRect(x: 590, y: 412, width: 250, height: 116), .sec3: CGRect(x: 20, y: 538, width: 268, height: 116),
        .sec4: CGRect(x: 288, y: 538, width: 302, height: 116), .sec5: CGRect(x: 590, y: 538, width: 250, height: 116),
        .battery: CGRect(x: 858, y: 12, width: 406, height: 636),
        .clock: CGRect(x: 858, y: 650, width: 406, height: 62),
        .sim: CGRect(x: 20, y: 660, width: 816, height: 52),
    ]
}

// MARK: - measurement records

struct MeasureSpec {
    var label: String
    var rect: CGRect      // integer image px, top-left origin
    var minPx: Int        // 0 = informational
    var cls: String       // digit | cjk | latin-cap | unit | glyph-cjk | glyph-cap
}

struct Piece {
    var text: String
    var font: CTFont
    var color: CGColor
    var cls: String               // digit | cjk | latin-cap | unit | symbol
    var minPx: Int = 0
    var gapBefore: CGFloat = 0
    var isLabel = false           // labels get per-glyph informational rects + the no-lowercase check
}

enum Align { case left, right, center }

final class PanelRenderer {
    private(set) var specs: [MeasureSpec] = []
    private(set) var boxes: [(id: String, r: CGRect)] = []
    private(set) var labelTexts: [(id: String, text: String)] = []   // rendered label strings (lowercase audit)
    var graphSpan: Double = 600                                          // criterion 3: ≥ 10 min

    // MARK: text primitive

    private func attr(_ p: Piece) -> NSAttributedString {
        NSAttributedString(string: p.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): p.font,
                                                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): p.color])
    }

    @discardableResult
    func text(_ ctx: CGContext, _ pieces: [Piece], x: CGFloat, baseline: CGFloat, align: Align = .left, id: String) -> CGRect {
        let lines = pieces.map { CTLineCreateWithAttributedString(attr($0)) }
        let adv = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        let total = zip(pieces, adv).reduce(0) { $0 + $1.0.gapBefore + $1.1 }
        var cx = align == .left ? x : (align == .right ? x - total : x - total / 2)
        cx = cx.rounded()
        var union = CGRect.null
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (i, p) in pieces.enumerated() {
            cx += p.gapBefore
            ctx.textPosition = CGPoint(x: cx, y: baseline)
            CTLineDraw(lines[i], ctx)
            let ink = inkRect(lines[i], cx, baseline)
            if !ink.isNull { union = union.union(ink) }
            if p.isLabel { labelTexts.append((id, p.text)) }
            if p.cls != "symbol" && !ink.isNull {
                var mr = ink
                var what = p.text
                if p.cls == "digit", let seg = digitSegment(p.text), seg.count < p.text.count {
                    // measure only a pure digit run: commas descend below the baseline and would inflate the height
                    let r = rangeOf(seg, in: p.text)
                    let off = CTLineGetOffsetForStringIndex(lines[i], r.location, nil)
                    let sub = CTLineCreateWithAttributedString(NSAttributedString(string: seg, attributes:
                        [NSAttributedString.Key(kCTFontAttributeName as String): p.font]))
                    mr = inkRect(sub, cx + off, baseline)
                    what = seg
                }
                specs.append(MeasureSpec(label: "\(id)[\(what)]", rect: mr.insetBy(dx: -5, dy: -5).integral, minPx: p.minPx, cls: p.cls))
                if p.isLabel && (p.cls == "cjk" || p.cls == "latin-cap") {
                    // informational per-glyph rects (x = the glyph's own advance box, no x padding)
                    let ns = p.text as NSString
                    for k in 0..<ns.length {
                        let ch = ns.substring(with: NSRange(location: k, length: 1))
                        if ch == " " || "、：，。…·（）".contains(ch) { continue }   // punctuation is not a glyph class
                        let x0 = cx + CTLineGetOffsetForStringIndex(lines[i], k, nil)
                        let x1 = cx + CTLineGetOffsetForStringIndex(lines[i], k + 1, nil)
                        let r = CGRect(x: x0, y: ink.minY - 5, width: x1 - x0, height: ink.height + 10).integral
                        specs.append(MeasureSpec(label: "glyph:\(id)[\(ch)]", rect: r, minPx: 0, cls: p.cls == "cjk" ? "glyph-cjk" : "glyph-cap"))
                    }
                }
            }
            cx += adv[i]
        }
        ctx.restoreGState()
        boxes.append((id, union))
        return union
    }

    func width(_ pieces: [Piece]) -> CGFloat {
        pieces.reduce(0) { $0 + $1.gapBefore + CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr($1)), nil, nil, nil)) }
    }
    private func inkRect(_ line: CTLine, _ x: CGFloat, _ baseline: CGFloat) -> CGRect {
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        if b.isNull || b.isEmpty { return .null }
        return CGRect(x: x + b.minX, y: baseline - b.maxY, width: b.width, height: b.height)
    }
    private func digitSegment(_ s: String) -> String? {
        var best = "", cur = ""
        for ch in s { if ch.isNumber || ch == "." { cur.append(ch) } else { if cur.count > best.count { best = cur }; cur = "" } }
        if cur.count > best.count { best = cur }
        return best.isEmpty ? nil : best
    }
    private func rangeOf(_ seg: String, in s: String) -> CFRange {
        let ns = s as NSString
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: seg, options: [], range: search)
            if r.location == NSNotFound { return CFRange(location: 0, length: 0) }
            let before = r.location == 0 ? " " : ns.substring(with: NSRange(location: r.location - 1, length: 1))
            if !(before.first!.isNumber || before == ".") { return CFRange(location: r.location, length: r.length) }
            search = NSRange(location: r.location + 1, length: ns.length - r.location - 1)
        }
    }

    // MARK: label / value helpers

    /// CJK runs → PingFang TC 38; Latin runs → UPPER-CASE SF Condensed Semibold 48; digit runs → same font, class digit.
    func labelPieces(_ s: String, color: CGColor = Theme.label, cjkFace: String = "Medium") -> [Piece] {
        var out: [Piece] = []
        var cur = "", curIsCJK: Bool? = nil
        func flush() {
            guard !cur.isEmpty, let isC = curIsCJK else { return }
            let gap: CGFloat = out.isEmpty ? 0 : 8
            if isC {
                out.append(Piece(text: cur, font: Fonts.cjk(Size.cjk, cjkFace), color: color, cls: "cjk", minPx: 32, gapBefore: gap, isLabel: true))
            } else {
                let t = cur.uppercased().trimmingCharacters(in: .whitespaces)
                let hasLetter = t.contains { $0.isLetter }
                out.append(Piece(text: t, font: Fonts.num(Size.caps, .semibold), color: color, cls: hasLetter ? "latin-cap" : "digit",
                                 minPx: 32, gapBefore: gap, isLabel: true))
            }
            cur = ""
        }
        for ch in s {
            let isC = ch.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
            if ch == " " { if !cur.isEmpty { flush(); curIsCJK = nil }; continue }
            if ch == "·" {
                flush(); curIsCJK = nil
                out.append(Piece(text: "·", font: Fonts.num(Size.caps), color: Theme.offline, cls: "symbol", gapBefore: 8))
                continue
            }
            if curIsCJK != nil && curIsCJK != isC { flush() }
            curIsCJK = isC; cur.append(ch)
        }
        flush()
        return out
    }

    func valuePieces(_ v: Shown, size: CGFloat, minPx: Int) -> [Piece] {
        guard let p = v.parts else {   // failed source → bright "—" (same token in memory and battery)
            return [Piece(text: "—", font: Fonts.num(size, .semibold), color: Theme.value, cls: "symbol")]
        }
        var out = [Piece(text: p.number, font: Fonts.num(size), color: Theme.value, cls: "digit", minPx: minPx)]
        if !p.unit.isEmpty {
            out.append(Piece(text: p.unit, font: Fonts.num(Size.unit, .medium), color: Theme.unit, cls: "unit", minPx: 0, gapBefore: (size * 0.12).rounded()))
        }
        return out
    }

    // MARK: frame

    /// Full frame when `only == nil`; otherwise repaint just those regions (bg-filled + clipped), as NSView.draw(dirtyRect) would.
    func draw(_ ctx: CGContext, _ s: PanelState, only: Set<Region>? = nil) {
        specs = []; boxes = []; labelTexts = []
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        let regions = only ?? Set(Region.allCases)
        if only == nil || regions.contains(.chrome) { drawChrome(ctx) }
        for r in Region.allCases where r != .chrome && regions.contains(r) {
            if only != nil, let rr = Layout.region[r] {
                ctx.saveGState(); ctx.clip(to: rr); ctx.setFillColor(Theme.bg); ctx.fill(rr)
                drawRegion(ctx, r, s)
                ctx.restoreGState()
            } else { drawRegion(ctx, r, s) }
        }
        if s.simulationBadge != nil && only == nil { drawSimFrame(ctx) }
    }

    func drawRegion(_ ctx: CGContext, _ r: Region, _ s: PanelState) {
        switch r {
        case .chrome: drawChrome(ctx)
        case .used: drawUsed(ctx, s)
        case .pressure: drawPressure(ctx, s)
        case .graph: drawGraph(ctx, s)
        case .axis: drawAxis(ctx, s)
        case .sec0, .sec1, .sec2, .sec3, .sec4, .sec5:
            drawSecondary(ctx, s, Int(String(r.rawValue.last!))!)
        case .battery: drawBatteries(ctx, s)
        case .clock: drawClock(ctx, s)
        case .sim: if let b = s.simulationBadge { drawBadge(ctx, b) }
        }
    }

    func drawChrome(_ ctx: CGContext) {
        ctx.setFillColor(Theme.bg)
        ctx.fill(CGRect(x: 0, y: 0, width: Layout.W, height: Layout.H))
        ctx.setFillColor(Theme.edge)   // 1 px ring on the outermost pixels
        ctx.fill(CGRect(x: 0, y: 0, width: Layout.W, height: 1)); ctx.fill(CGRect(x: 0, y: Layout.H - 1, width: Layout.W, height: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: Layout.H)); ctx.fill(CGRect(x: Layout.W - 1, y: 0, width: 1, height: Layout.H))
        ctx.setFillColor(Theme.divider); ctx.fill(Layout.divider)
    }

    func drawUsed(_ ctx: CGContext, _ s: PanelState) {
        text(ctx, labelPieces("記憶體用量"), x: Layout.L, baseline: Layout.heroLabelBase, id: "label.used")
        var size = Size.hero
        while size > Size.heroMin && width(valuePieces(s.memory.used, size: size, minPx: 64)) > Layout.pressureX - Layout.L - 24 { size -= 2 }
        text(ctx, valuePieces(s.memory.used, size: size, minPx: 64), x: Layout.L, baseline: Layout.heroBase, id: "value.used")
    }

    func drawPressure(_ ctx: CGContext, _ s: PanelState) {
        let m = s.memory
        text(ctx, labelPieces("記憶體壓力"), x: Layout.pressureX, baseline: Layout.heroLabelBase, id: "label.pressure")
        let lvl = m.pressurePercent == nil ? nil : m.pressureLevel
        let col = lvl.map(Theme.pressureText) ?? Theme.value
        let pv: [Piece] = m.pressurePercent.map {
            [Piece(text: "\($0)", font: Fonts.num(Size.main), color: col, cls: "digit", minPx: 64),
             Piece(text: "%", font: Fonts.num(Size.unit), color: col, cls: "symbol", gapBefore: 4)]
        } ?? [Piece(text: "—", font: Fonts.num(Size.main), color: Theme.value, cls: "symbol")]
        text(ctx, pv, x: Layout.pressureX, baseline: Layout.heroBase, id: "value.pressure")
        // level pill: fixed slot (never moves), pressure hue with dark text; grey "未知" when the source failed
        let pill = Layout.pill
        ctx.setFillColor(lvl == nil ? Theme.pillUnknown : col)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.fillPath()
        boxes.append(("pill", pill))
        let word = lvl?.word ?? "未知"
        text(ctx, labelPieces(word, color: lvl == nil ? Theme.value : Theme.bg, cjkFace: "Semibold"), x: pill.midX, baseline: pill.midY + 13, align: .center, id: "pill.word")
        boxes.removeLast()   // pill text lies inside the pill box by design
    }

    func drawGraph(_ ctx: CGContext, _ s: PanelState) {
        let g = Layout.graph
        ctx.setFillColor(Theme.well)
        ctx.addPath(CGPath(roundedRect: g, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.fillPath()
        boxes.append(("graph", g))
        let plot = g.insetBy(dx: 0, dy: 4)
        // minute grid (every 60 s, 5-min mark brighter) + 50 % line
        for k in 1..<10 {
            let x = (g.maxX - CGFloat(k) / 10 * g.width).rounded()
            ctx.setFillColor(k == 5 ? Theme.gridMajor : Theme.grid)
            ctx.fill(CGRect(x: x, y: g.minY + 6, width: k == 5 ? 2 : 1, height: g.height - 12))
        }
        ctx.setFillColor(Theme.gridMajor)
        ctx.fill(CGRect(x: g.minX + 6, y: (plot.minY + plot.height / 2).rounded(), width: g.width - 12, height: 1))
        ctx.setFillColor(Theme.grid)
        ctx.fill(CGRect(x: g.minX + 6, y: plot.minY, width: g.width - 12, height: 1))   // 100 %

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: g, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.clip()
        let pxPerSec = g.width / CGFloat(graphSpan)
        func xOf(_ t: Double) -> CGFloat { g.maxX - CGFloat(s.now - t) * pxPerSec }
        func yOf(_ p: Double) -> CGFloat { plot.maxY - CGFloat(min(100, max(0, p)) / 100) * plot.height }
        let vis = s.history.filter { s.now - $0.t <= graphSpan + 2 }
        var i = 0
        while i < vis.count {
            guard let lvl = vis[i].level, vis[i].percent != nil else { i += 1; continue }
            var j = i
            while j + 1 < vis.count, vis[j + 1].level == lvl, vis[j + 1].percent != nil, vis[j + 1].t - vis[j].t < 2.5 { j += 1 }
            let x0 = xOf(vis[i].t)
            let x1 = j + 1 < vis.count && vis[j + 1].percent != nil && vis[j + 1].t - vis[j].t < 2.5 ? xOf(vis[j + 1].t) : xOf(vis[j].t) + max(1, pxPerSec)
            let area = CGMutablePath(), top = CGMutablePath()
            area.move(to: CGPoint(x: x0, y: plot.maxY))
            for k in i...j {
                let xa = xOf(vis[k].t), xb = k < j ? xOf(vis[k + 1].t) : x1
                let y = yOf(vis[k].percent!)
                area.addLine(to: CGPoint(x: xa, y: y)); area.addLine(to: CGPoint(x: xb, y: y))
                if k == i { top.move(to: CGPoint(x: xa, y: y)) } else { top.addLine(to: CGPoint(x: xa, y: y)) }
                top.addLine(to: CGPoint(x: xb, y: y))
            }
            area.addLine(to: CGPoint(x: x1, y: plot.maxY)); area.closeSubpath()
            let f = Theme.pressureFill(lvl)
            ctx.saveGState()
            ctx.addPath(area); ctx.clip()
            let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [CGColor(srgbRed: f.r, green: f.g, blue: f.b, alpha: 0.80),
                                           CGColor(srgbRed: f.r, green: f.g, blue: f.b, alpha: 0.30)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: plot.minY), end: CGPoint(x: 0, y: plot.maxY), options: [])
            ctx.restoreGState()
            ctx.setStrokeColor(Theme.pressureText(lvl)); ctx.setLineWidth(2.5); ctx.setLineJoin(.round)
            ctx.addPath(top); ctx.strokePath()
            for k in i...j where vis[k].simulated {   // simulated seconds: magenta stripe until they scroll out
                let xa = xOf(vis[k].t), xb = k < j ? xOf(vis[k + 1].t) : x1
                ctx.setFillColor(Theme.sim); ctx.fill(CGRect(x: xa, y: g.maxY - 7, width: xb - xa, height: 7))
            }
            i = j + 1
        }
        ctx.restoreGState()
    }

    func drawAxis(_ ctx: CGContext, _ s: PanelState) {
        let left = s.historyCoverage >= graphSpan ? "十分鐘前" : "收集中 \(Int(s.historyCoverage / 60))/10 分鐘"
        text(ctx, labelPieces(left), x: Layout.graph.minX, baseline: Layout.axisBase, id: "label.axisLeft")
        text(ctx, labelPieces("現在"), x: Layout.graph.maxX, baseline: Layout.axisBase, align: .right, id: "label.axisNow")
    }

    /// Grid order = AM footer blocks: row 1 = AM left block (Physical, Cached, Swap), row 2 = AM right block (App, Wired, Compressed).
    static let secCells: [(label: String, key: String)] = [
        ("實體記憶體", "physical"), ("快取的檔案", "cached"), ("使用的交換檔", "swap"),
        ("APP 記憶體", "app"), ("系統核心記憶體", "wired"), ("已壓縮", "compressed"),
    ]
    func drawSecondary(_ ctx: CGContext, _ s: PanelState, _ i: Int) {
        let m = s.memory
        let v: Shown = [m.physical, m.cached, m.swap, m.app, m.wired, m.compressed][i]
        let c = Self.secCells[i]
        let row = i / 3, col = i % 3
        text(ctx, labelPieces(c.label), x: Layout.secColX[col], baseline: Layout.secLabelBase[row], id: "label.\(c.key)")
        text(ctx, valuePieces(v, size: Size.secondary, minPx: 40), x: Layout.secColX[col], baseline: Layout.secValueBase[row], id: "value.\(c.key)")
    }

    // MARK: batteries

    enum Block { case hid(DeviceGroup), pods(DeviceGroup) }

    static let maxRowsPerPage = 5
    /// Paging (spec §6.6): HID devices are pinned on every page while AirPods groups rotate (one per page when ≥ 2)
    /// only when HID rows + 3 ≤ 5 value rows; no AirPods and ≤ 5 HID rows → one page; otherwise generic packing of
    /// whole groups into pages of ≤ 5 value rows (AirPods connected 3 rows, offline 1).
    static func pages(_ devices: [DeviceGroup]) -> [[Block]] {
        let hid = devices.filter { $0.kind.isHID }, pods = devices.filter { !$0.kind.isHID }
        if pods.isEmpty && hid.count <= maxRowsPerPage { return [hid.map { .hid($0) }] }
        if !pods.isEmpty && hid.count + 3 <= maxRowsPerPage {
            if pods.count == 1 { return [hid.map { .hid($0) } + [.pods(pods[0])]] }
            return pods.map { p in hid.map { .hid($0) } + [.pods(p)] }
        }
        var pages: [[Block]] = [[]]; var rows = 0
        for d in devices {
            let need = d.kind.isHID ? 1 : (d.showsCells ? 3 : 1)
            if rows + need > maxRowsPerPage && !pages[pages.count - 1].isEmpty { pages.append([]); rows = 0 }
            pages[pages.count - 1].append(d.kind.isHID ? .hid(d) : .pods(d)); rows += need
        }
        return pages
    }

    func drawBatteries(_ ctx: CGContext, _ s: PanelState) {
        if s.devices.isEmpty {
            text(ctx, labelPieces("沒有已連線的"), x: Layout.RL, baseline: 92, id: "label.nodev1")
            text(ctx, labelPieces("藍牙周邊"), x: Layout.RL, baseline: 146, id: "label.nodev2")
            return
        }
        let pages = Self.pages(s.devices)
        let pi = min(s.batteryPage, pages.count - 1)
        var top = Layout.batFirstTop
        for (bi, b) in pages[pi].enumerated() {
            switch b {
            case .hid(let d):
                let base = top + Layout.mainInk
                drawCellRow(ctx, label: d.kind.label, tag: d.ownerTag, state: d.cells.first?.state, connected: d.connected,
                            xl: Layout.RL, xr: Layout.RR, base: base, id: "dev\(bi)")
                top = base + Layout.batPitch - Layout.mainInk
            case .pods(let d):
                let boxTop = top + 3
                let hb = boxTop + 48
                var rowsBottom = hb + 16
                let box0 = CGRect(x: Layout.RL, y: boxTop, width: Layout.RR - Layout.RL, height: 0)
                // box height is known up front → draw it first (connected and nearby: three rows; offline: title only)
                let h: CGFloat = d.showsCells ? (hb + 16 + Layout.mainInk + 2 * Layout.batPitch + 30) - boxTop : (hb + 16) - boxTop
                let box = CGRect(x: box0.minX, y: boxTop, width: box0.width, height: h)
                ctx.setFillColor(Theme.well)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.fillPath()
                // header: "AIRPODS" or, when two groups share the kind, "AIRPODS · TAG" → "耳機 · TAG" (truncated to fit)
                let inner = (Layout.RL + 16, Layout.RR - 16)
                var head = d.kind.label
                if let o = d.ownerTag {
                    var tag = o
                    head = "\(d.kind.label) · \(tag)"
                    let room = inner.1 - inner.0 - (d.connected ? 0 : 90)   // offline / nearby: room for 「離線」/「附近」
                    if width(labelPieces(head)) > room { head = "耳機 · \(tag)" }
                    while width(labelPieces(head)) > room && tag.count > 1 { tag.removeLast(); head = "耳機 · \(tag)" }
                }
                let allStale = !d.cells.isEmpty && d.cells.allSatisfy { $0.state == .stale }
                let hc = (d.showsCells && !allStale) ? Theme.label : Theme.offline
                text(ctx, labelPieces(head, color: hc), x: inner.0, baseline: hb, id: "label.dev\(bi).head")
                if !d.showsCells {
                    text(ctx, labelPieces("離線", color: Theme.offline), x: inner.1, baseline: hb, align: .right, id: "value.dev\(bi).offline")
                } else {
                    let nearby = d.presence == .nearby
                    if nearby {   // not connected to this Mac, fresh IOPS / BLE values: 「附近」 where 「離線」 would be, grey numbers
                        text(ctx, labelPieces("附近", color: Theme.nearby), x: inner.1, baseline: hb, align: .right, id: "value.dev\(bi).nearby")
                    }
                    var base = hb + 16 + Layout.mainInk
                    for (ci, c) in d.cells.enumerated() {
                        drawCellRow(ctx, label: c.label, state: c.state, connected: true, nearby: nearby,
                                    xl: inner.0, xr: inner.1, base: base, id: "dev\(bi).\(ci)")
                        rowsBottom = base + 30
                        base += Layout.batPitch
                    }
                }
                boxes.append(("box\(bi)", box))
                _ = rowsBottom
                top = box.maxY + 12
            }
        }
        if pages.count > 1 {
            text(ctx, labelPieces("\(pi + 1)/\(pages.count)"), x: Layout.RR, baseline: Layout.pageBase, align: .right, id: "label.page")
        }
    }

    /// One battery row: label left (+ " · TAG" when two devices share the kind, truncated to fit); right-aligned number;
    /// to its left an optional charging bolt (≥32 px) and an optional inverted "低" chip (≤20 %); bar under the digits
    /// (white + thicker when low). Never a stale number. `.stale` (connection unknown: sp stale) → whole row grey "—".
    /// `nearby` (AirPods not connected to this Mac, fresh IOPS/BLE value): same sizes, number + bolt in Theme.nearby grey,
    /// grey bar; the white 「低」 chip still marks ≤ 20 %.
    func drawCellRow(_ ctx: CGContext, label: String, tag: String? = nil, state: CellState?, connected: Bool, nearby: Bool = false,
                     xl: CGFloat, xr: CGFloat, base: CGFloat, id: String) {
        let grey = !connected || state == .stale
        let lc = grey ? Theme.offline : Theme.label
        var leftEdge: CGFloat   // left end of the right-hand content (value, bolt, chip, "離線")
        if !connected {
            leftEdge = text(ctx, labelPieces("離線", color: Theme.offline), x: xr, baseline: base - 16, align: .right, id: "value.\(id).offline").minX
        } else {
            switch state {
            case .ok(let p, let charging)?:
                let low = p <= 20
                let vc = nearby ? Theme.nearby : Theme.value
                let num = text(ctx, [Piece(text: "\(p)", font: Fonts.num(Size.main), color: vc, cls: "digit", minPx: 64),
                                     Piece(text: "%", font: Fonts.num(Size.unit), color: vc, cls: "symbol", gapBefore: 4)],
                               x: xr, baseline: base, align: .right, id: "value.\(id)")
                leftEdge = num.minX
                let midY = base - Layout.mainInk / 2
                if charging {
                    let r = CGRect(x: leftEdge - 12 - 24, y: (midY - 20).rounded(), width: 24, height: 40)
                    drawBolt(ctx, r, vc); boxes.append(("bolt.\(id)", r)); leftEdge = r.minX
                }
                if low {
                    let chip = CGRect(x: leftEdge - 12 - 58, y: (midY - 25).rounded(), width: 58, height: 50)
                    ctx.setFillColor(Theme.attention)
                    ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 12, cornerHeight: 12, transform: nil)); ctx.fillPath()
                    boxes.append(("chip.\(id)", chip))
                    text(ctx, labelPieces("低", color: Theme.bg, cjkFace: "Semibold"), x: chip.midX, baseline: chip.midY + 13, align: .center, id: "chip.\(id).word")
                    boxes.removeLast()
                    leftEdge = chip.minX
                }
                let bar = CGRect(x: xl, y: base + 12, width: xr - xl, height: low ? 8 : 6)
                ctx.setFillColor(Theme.trackBar); ctx.fill(bar)
                ctx.setFillColor(nearby ? Theme.nearbyBar : (low ? Theme.attention : Theme.barNormal))
                ctx.fill(CGRect(x: bar.minX, y: bar.minY, width: (bar.width * CGFloat(p) / 100).rounded(), height: bar.height))
                boxes.append(("bar.\(id)", bar))
            case .unavailable?:
                leftEdge = text(ctx, [Piece(text: "—", font: Fonts.num(Size.main), color: Theme.dim, cls: "symbol")], x: xr, baseline: base, align: .right, id: "value.\(id).na").minX
            case .stale?:
                leftEdge = text(ctx, [Piece(text: "—", font: Fonts.num(Size.main), color: Theme.offline, cls: "symbol")], x: xr, baseline: base, align: .right, id: "value.\(id).stale").minX
            case .failed?, nil:
                leftEdge = text(ctx, [Piece(text: "—", font: Fonts.num(Size.main), color: Theme.value, cls: "symbol")], x: xr, baseline: base, align: .right, id: "value.\(id).failed").minX
            }
        }
        text(ctx, labelPieces(fitLabel(label, tag: tag, maxWidth: leftEdge - 20 - xl), color: lc), x: xl, baseline: base - 16, id: "label.\(id)")
    }

    /// "鍵盤 · ALEX" → "鍵盤 · ALE" → … → "鍵盤 · K" until it fits `maxWidth`; when even a one-character tag does
    /// not fit (3-character label + charging bolt + "低" chip), the separator goes ("軌跡板K"), then the tag
    /// ("軌跡板") — a label never runs into the bolt / chip. No tag → the label itself.
    func fitLabel(_ label: String, tag: String?, maxWidth: CGFloat) -> String {
        guard var t = tag, !t.isEmpty else { return label }
        func fits(_ s: String) -> Bool { width(labelPieces(s)) <= maxWidth }
        var head = "\(label) · \(t)"
        while !fits(head) && t.count > 1 { t.removeLast(); head = "\(label) · \(t)" }
        if !fits(head) { head = "\(label)\(t)" }
        if !fits(head) { head = label }
        return head
    }

    private func drawBolt(_ ctx: CGContext, _ r: CGRect, _ c: CGColor) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + r.width * 0.62, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.56))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.45, y: r.minY + r.height * 0.56))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.42))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.55, y: r.minY + r.height * 0.42))
        p.closeSubpath()
        ctx.setFillColor(c); ctx.addPath(p); ctx.fillPath()
    }

    func drawClock(_ ctx: CGContext, _ s: PanelState) {
        if s.sampleStale {
            let chip = CGRect(x: Layout.RL, y: 652, width: 100, height: 52)
            ctx.setFillColor(Theme.attention)
            ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 12, cornerHeight: 12, transform: nil)); ctx.fillPath()
            boxes.append(("chip.stale", chip))
            text(ctx, labelPieces("停滯", color: Theme.bg, cjkFace: "Semibold"), x: chip.midX, baseline: chip.midY + 13, align: .center, id: "chip.stale.word")
            boxes.removeLast()
        } else {
            text(ctx, labelPieces("更新"), x: Layout.RL, baseline: Layout.clockBase - 4, id: "label.clock")
        }
        text(ctx, [Piece(text: s.clock, font: Fonts.num(Size.secondary, .medium), color: Theme.unit, cls: "digit", minPx: 40)],
             x: Layout.RR, baseline: Layout.clockBase, align: .right, id: "value.clock")
    }

    func drawSimFrame(_ ctx: CGContext) {
        ctx.setStrokeColor(Theme.sim); ctx.setLineWidth(6)
        ctx.stroke(CGRect(x: 3, y: 3, width: Layout.W - 6, height: Layout.H - 6))
    }
    func drawBadge(_ ctx: CGContext, _ badge: String) {
        var b = badge
        while width(labelPieces(b, color: Theme.sim)) > Layout.LR - Layout.L && b.count > 4 { b = String(b.dropLast(2)) + "…" }
        text(ctx, labelPieces(b, color: Theme.sim), x: Layout.L, baseline: Layout.badgeBase, id: "label.sim")
    }

    // MARK: layout self-check

    func layoutProblems() -> [String] {
        var out: [String] = []
        let safe = CGRect(x: 8, y: 8, width: Layout.W - 16, height: Layout.H - 16)
        for b in boxes where !b.r.isNull && !safe.contains(b.r) { out.append("off-canvas \(b.id) \(b.r.integral)") }
        for b in boxes where !b.r.isNull && b.id != "graph" {
            let inLeft = b.r.minX >= Layout.L - 1 && b.r.maxX <= Layout.LR + 1
            let inRight = b.r.minX >= Layout.RL - 1 && b.r.maxX <= Layout.RR + 1
            if !(inLeft || inRight) { out.append("outside column grid \(b.id) \(b.r.integral)") }
        }
        func contained(_ a: String, _ b: String) -> Bool {   // text inside the AirPods box is by design
            (a.hasPrefix("box") && !b.hasPrefix("box")) || (b.hasPrefix("box") && !a.hasPrefix("box"))
        }
        for i in 0..<boxes.count { for j in (i + 1)..<boxes.count {
            let a = boxes[i], b = boxes[j]
            if a.r.isNull || b.r.isNull { continue }
            if contained(a.id, b.id) {
                let (box, other) = a.id.hasPrefix("box") ? (a.r, b.r) : (b.r, a.r)
                if box.intersects(other) && !box.insetBy(dx: 4, dy: 4).contains(other) { out.append("box edge crosses \(a.id) × \(b.id)") }
                continue
            }
            if a.r.insetBy(dx: -3, dy: -3).intersects(b.r) { out.append("overlap \(a.id) \(a.r.integral) × \(b.id) \(b.r.integral)") }
        } }
        // measurement rects must not contain other elements' ink (per-glyph informational rects excluded)
        for s in specs where !s.label.hasPrefix("glyph:") { for b in boxes where !b.r.isNull {
            let owner = s.label.components(separatedBy: "[").first!
            if b.id == owner || b.id.hasPrefix("box") { continue }
            if (b.id == "pill" && owner == "pill.word") || (b.id.hasPrefix("chip") && owner.hasPrefix(b.id)) { continue }
            if s.rect.intersects(b.r) { out.append("measure-rect \(s.label) \(s.rect) touches \(b.id)") }
        } }
        // judges' must-fixes
        for l in labelTexts where l.text.contains(where: { $0.isLowercase }) { out.append("lowercase in label \(l.id): \(l.text)") }
        let box = Dictionary(boxes.map { ($0.id, $0.r) }, uniquingKeysWith: { a, _ in a })
        let keys = Self.secCells.map { $0.key }
        for row in 0..<2 {
            for col in 0..<2 {
                for kind in ["value", "label"] {
                    if let a = box["\(kind).\(keys[row * 3 + col])"], let b = box["\(kind).\(keys[row * 3 + col + 1])"], !a.isNull, !b.isNull {
                        let gap = b.minX - a.maxX
                        if gap < 30 { out.append("adjacent \(kind) gap \(Int(gap)) px < 30 (\(keys[row * 3 + col]) → \(keys[row * 3 + col + 1]))") }
                    }
                }
            }
        }
        for col in 0..<3 {   // proximity: label→own value gap × 1.5 ≤ value→next label gap
            if let l = box["label.\(keys[col])"], let v = box["value.\(keys[col])"], let n = box["label.\(keys[col + 3])"], !v.isNull, v.height > 20 {
                let g1 = v.minY - l.maxY, g2 = n.minY - v.maxY
                if g2 < 1.5 * g1 { out.append("proximity \(keys[col]): label→value \(Int(g1)) vs value→next label \(Int(g2))") }
            }
        }
        return out
    }

    /// Gap metrics for the report (secondary grid).
    func gapReport() -> [String] {
        let box = Dictionary(boxes.map { ($0.id, $0.r) }, uniquingKeysWith: { a, _ in a })
        let keys = Self.secCells.map { $0.key }
        var out: [String] = []
        for row in 0..<2 { for col in 0..<2 {
            if let a = box["value.\(keys[row * 3 + col])"], let b = box["value.\(keys[row * 3 + col + 1])"], !a.isNull, !b.isNull {
                out.append("value gap \(keys[row * 3 + col])→\(keys[row * 3 + col + 1]) = \(Int(b.minX - a.maxX)) px")
            }
        } }
        for col in 0..<3 {
            if let l = box["label.\(keys[col])"], let v = box["value.\(keys[col])"], let n = box["label.\(keys[col + 3])"], !v.isNull, v.height > 20 {   // "—" excluded
                out.append("proximity \(keys[col]): label→value \(Int(v.minY - l.maxY)) px, value→next label \(Int(n.minY - v.maxY)) px")
            }
        }
        return out
    }
}
