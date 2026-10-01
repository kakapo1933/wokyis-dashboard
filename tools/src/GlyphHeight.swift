// glyphheight — measure the ink (glyph) bounding box of text inside rectangles of a PNG.
//
// usage: glyphheight IMAGE.png --rect x,y,w,h[:label[@min]] [--rect ...]
//                    [--lines] [--gap N] [--threshold N] [--min N] [--out annotated.png]
//
//  * coordinates are image PIXELS, origin top-left (a Wokyis `screencapture -D 2` PNG is 1280x720 = 1:1 screen px)
//  * background colour is auto-detected per rect from its 1-px border (most frequent colour),
//    so each rect must be drawn with a little padding around the text and must not cut through glyphs
//  * a pixel is ink when max(|dR|,|dG|,|dB|) vs background >= threshold; default threshold is adaptive
//    (50 % of the max contrast in the rect → edge at ~50 % anti-alias coverage)
//  * --lines splits each rect into text lines (rows of ink separated by >= --gap empty rows, default 3)
//  * @min / --min: pass/fail threshold on ink HEIGHT in px; exit status 1 when any measurement fails
//  * --out: writes a copy of the image with the rect (yellow), ink bbox (magenta/green) and "h=NNpx" drawn
import Foundation
import CoreGraphics

@main
struct GlyphHeight {
    static func main() {
        let a = Args(Array(CommandLine.arguments.dropFirst()), flagNames: ["lines", "help", "json"])
        if a.has("help") || a.positional.isEmpty || (a.opts["rect"] ?? []).isEmpty {
            print("usage: glyphheight IMAGE.png --rect x,y,w,h[:label[@minpx]] [--rect ...] [--lines] [--gap N] [--threshold N] [--min N] [--out annotated.png] [--json]")
            exit(a.has("help") ? 0 : 2)
        }
        let path = a.positional[0]
        let img = loadCGImage(path)
        let bm = Bitmap(image: img)
        let thr = a.int("threshold")
        let gap = a.int("gap") ?? 3
        let globalMin = a.int("min")

        struct Row { var rect: PixRect; var line: Int; var ink: InkResult; var min: Int? }
        var rows: [Row] = []
        for spec in a.opts["rect"]! {
            var r = parseRect(spec)
            var minH = globalMin
            if let at = r.label.lastIndex(of: "@") {
                minH = Int(r.label[r.label.index(after: at)...]) ?? minH
                r.label = String(r.label[..<at])
            }
            if a.has("lines") {
                let ls = measureLines(bm, r, threshold: thr, gap: gap)
                if ls.isEmpty { rows.append(Row(rect: r, line: 0, ink: InkResult(found: false), min: minH)) }
                for (i, l) in ls.enumerated() { rows.append(Row(rect: r, line: i + 1, ink: l, min: minH)) }
            } else {
                rows.append(Row(rect: r, line: 0, ink: measureInk(bm, r, threshold: thr), min: minH))
            }
        }

        var failed = false
        print("# image=\(path) size=\(img.width)x\(img.height)")
        print("label\tline\trect\tink_x\tink_y\tink_w\tink_h\tbg_rgb\tthreshold\tmax_contrast\tmin_h\tresult")
        for r in rows {
            let res: String
            if !r.ink.found { res = "NO_INK"; if r.min != nil { failed = true } }
            else if let m = r.min { res = r.ink.height >= m ? "PASS" : "FAIL"; if r.ink.height < m { failed = true } }
            else { res = "-" }
            let bg = "\(r.ink.bg.0),\(r.ink.bg.1),\(r.ink.bg.2)"
            print("\(r.rect.label.isEmpty ? "-" : r.rect.label)\t\(r.line)\t\(r.rect)\t\(r.ink.minX)\t\(r.ink.minY)\t\(r.ink.width)\t\(r.ink.height)\t\(bg)\t\(r.ink.threshold)\t\(r.ink.maxDist)\t\(r.min.map(String.init) ?? "-")\t\(res)")
        }

        if let out = a.one("out") {
            let ctx = bm.ctx
            let H = img.height
            // redraw the pristine image (measurements were done already)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: H))
            let yellow = rgba(1, 0.85, 0), mag = rgba(1, 0.1, 0.9), green = rgba(0.1, 1, 0.3), red = rgba(1, 0.2, 0.2)
            var drawnRects = Set<String>()
            for r in rows {
                let key = r.rect.description
                if !drawnRects.contains(key) {
                    strokeRectTop(ctx, CGFloat(r.rect.x), CGFloat(r.rect.y), CGFloat(r.rect.w), CGFloat(r.rect.h),
                                  imageHeight: H, color: yellow, width: 1)
                    drawnRects.insert(key)
                }
                guard r.ink.found else { continue }
                let ok = r.min.map { r.ink.height >= $0 }
                let c = ok == nil ? mag : (ok! ? green : red)
                strokeRectTop(ctx, CGFloat(r.ink.minX) - 1, CGFloat(r.ink.minY) - 1,
                              CGFloat(r.ink.width) + 2, CGFloat(r.ink.height) + 2, imageHeight: H, color: c, width: 1)
                // tick marks at the ink top and bottom rows (extend to the right of the rect)
                ctx.setStrokeColor(c); ctx.setLineWidth(1)
                let xr = CGFloat(r.ink.maxX) + 2
                for yy in [r.ink.minY, r.ink.maxY] {
                    let yc = CGFloat(H - yy) - 0.5
                    ctx.move(to: CGPoint(x: xr, y: yc)); ctx.addLine(to: CGPoint(x: xr + 10, y: yc))
                }
                ctx.move(to: CGPoint(x: xr + 5, y: CGFloat(H - r.ink.minY) - 0.5))
                ctx.addLine(to: CGPoint(x: xr + 5, y: CGFloat(H - r.ink.maxY) - 0.5))
                ctx.strokePath()
                var txt = "h=\(r.ink.height)px"
                if let m = r.min { txt += (ok! ? " ≥\(m) OK" : " <\(m) FAIL") }
                if !r.rect.label.isEmpty { txt = "\(r.rect.label): " + txt }
                var tx = xr + 14
                let ty = CGFloat(r.ink.minY)
                if tx > CGFloat(img.width) - 150 { tx = max(0, CGFloat(r.ink.minX)) }
                drawText(ctx, txt, x: tx, yTop: ty, imageHeight: H, size: 13, color: c, bgColor: rgba(0, 0, 0, 0.75))
            }
            drawText(ctx, "glyphheight: ink = max-channel diff vs rect-border bg >= threshold (adaptive 50%); h = ink rows incl. top & bottom",
                     x: 4, yTop: CGFloat(H) - 18, imageHeight: H, size: 11, color: rgba(1, 1, 1), bgColor: rgba(0, 0, 0, 0.75), bold: false)
            writePNG(bm.makeImage(), out)
            print("# annotated -> \(out)")
        }
        exit(failed ? 1 : 0)
    }
}
