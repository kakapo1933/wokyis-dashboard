// composite — put the main-display (LG) screenshot and the Wokyis screenshot from ONE `screencapture -x lg.png wk.png`
// invocation side by side in a single PNG with a caption, as "same screenshot" evidence.
//
// usage: composite LG.png WOKYIS.png --out OUT.png [--lg-crop x,y,w,h] [--lg-scale S] [--caption "text"]
//                  [--time "2026-10-01T04:05:06.123+08:00"]
//
//  * LG.png must be the FIRST file of the screencapture call (main display, 3840x2160 px on this Mac),
//    WOKYIS.png the SECOND (1280x720). The tool checks sizes and exits 3 if the Wokyis image is not 1280x720.
//  * the Wokyis image is pasted 1:1 (never resampled) so pixel measurements stay valid on the composite.
//  * the LG image (or --lg-crop region, in LG image pixels) is scaled by --lg-scale; default: full frame → 0.5
//    (3840x2160 → 1920x1080 = its point size); crop → 1.0 unless its height exceeds 1080 (then fit to 1080).
//  * caption line 1: --time (default: modification time of LG.png) + source file names; line 2: --caption text.
import Foundation
import CoreGraphics

@main
struct Composite {
    static func main() {
        let a = Args(Array(CommandLine.arguments.dropFirst()), flagNames: ["help"])
        guard a.positional.count == 2, let out = a.one("out"), !a.has("help") else {
            print("usage: composite LG.png WOKYIS.png --out OUT.png [--lg-crop x,y,w,h] [--lg-scale S] [--caption text] [--time text]")
            exit(2)
        }
        let lgPath = a.positional[0], wkPath = a.positional[1]
        var lg = loadCGImage(lgPath)
        let wk = loadCGImage(wkPath)
        if wk.width != 1280 || wk.height != 720 {
            FileHandle.standardError.write("composite: WOKYIS image is \(wk.width)x\(wk.height), expected 1280x720 — wrong file order?\n".data(using: .utf8)!)
            exit(3)
        }
        var cropDesc = "full"
        var defScale = lg.height > 1080 ? 1080.0 / Double(lg.height) : 1.0
        if let c = a.one("lg-crop") {
            let r = clamp(parseRect(c), lg.width, lg.height)
            guard let cr = lg.cropping(to: CGRect(x: r.x, y: r.y, width: r.w, height: r.h)) else { die("crop failed") }
            lg = cr; cropDesc = "crop \(r)"
            defScale = r.h > 1080 ? 1080.0 / Double(r.h) : 1.0
        }
        let s = a.double("lg-scale") ?? defScale
        let lgW = Int((Double(lg.width) * s).rounded()), lgH = Int((Double(lg.height) * s).rounded())
        let gap = 24, capH = 64, labH = 26, margin = 16
        let W = margin + lgW + gap + wk.width + margin
        let H = capH + labH + max(lgH, wk.height) + margin
        let bm = Bitmap(width: W, height: H)
        let ctx = bm.ctx
        ctx.setFillColor(rgba(0.12, 0.12, 0.14)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        let top = capH + labH
        ctx.interpolationQuality = .high
        ctx.draw(lg, in: CGRect(x: margin, y: H - top - lgH, width: lgW, height: lgH))
        ctx.interpolationQuality = .none
        let wkX = margin + lgW + gap
        ctx.draw(wk, in: CGRect(x: wkX, y: H - top - wk.height, width: wk.width, height: wk.height))
        // 1-px frames just outside each image
        strokeRectTop(ctx, CGFloat(margin - 1), CGFloat(top - 1), CGFloat(lgW + 2), CGFloat(lgH + 2), imageHeight: H, color: rgba(0.5, 0.5, 0.55))
        strokeRectTop(ctx, CGFloat(wkX - 1), CGFloat(top - 1), CGFloat(wk.width + 2), CGFloat(wk.height + 2), imageHeight: H, color: rgba(1, 0.8, 0))

        var t = a.one("time")
        if t == nil, let attrs = try? FileManager.default.attributesOfItem(atPath: lgPath), let m = attrs[.modificationDate] as? Date {
            t = isoNow(m) + " (LG.png mtime)"
        }
        let lgName = (lgPath as NSString).lastPathComponent, wkName = (wkPath as NSString).lastPathComponent
        drawText(ctx, "\(t ?? "?")   ·   one `screencapture -x \(lgName) \(wkName)` call", x: CGFloat(margin), yTop: 8,
                 imageHeight: H, size: 20, color: rgba(1, 1, 1))
        if let c = a.one("caption") {
            drawText(ctx, c, x: CGFloat(margin), yTop: 36, imageHeight: H, size: 16, color: rgba(0.85, 0.85, 0.9), bold: false)
        }
        drawText(ctx, "Main display (LG) — \(cropDesc), scaled ×\(String(format: "%.3g", s)) → \(lgW)×\(lgH)", x: CGFloat(margin),
                 yTop: CGFloat(capH + 2), imageHeight: H, size: 15, color: rgba(0.75, 0.75, 0.8), bold: false)
        drawText(ctx, "Wokyis — 1280×720 at 1:1 pixels (unscaled)", x: CGFloat(wkX), yTop: CGFloat(capH + 2),
                 imageHeight: H, size: 15, color: rgba(1, 0.85, 0.3), bold: false)
        writePNG(bm.makeImage(), out)
        print("composite \(W)x\(H) -> \(out)  (lg \(lg.width)x\(lg.height) \(cropDesc) ×\(s); wokyis at x=\(wkX) y=\(top) 1:1)")
    }
}
