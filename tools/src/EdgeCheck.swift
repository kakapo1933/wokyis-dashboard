// edgecheck — criterion #1: is the panel's 1-px outer ring (spec §7.2 token `edge` #3A4048) intact on all four edges
// of a real Wokyis capture (i.e. nothing cropped, no scroll bar, no title bar, no offset)?
//
// usage: edgecheck IMAGE.png [--color 3A4048] [--tol 6] [--exclude x,y,w,h[:label]]... [--ring N] [--inner]
//                  [--expect-size 1280x720] [--max-list 20] [--out annotated.png]
//        edgecheck --selftest
//
//  * ring pixel matches when max(|dR|,|dG|,|dB|) vs --color <= --tol.
//  * edges: top = row 0 (x 0…W-1), bottom = row H-1, left = column 0 (y 0…H-1), right = column W-1;
//    corners belong to both of their edges (top 1280 + left 720 …, as in spec §15 #1).
//  * --exclude rects (image px, top-left origin) are removed from the denominators and reported separately
//    (e.g. the macOS privacy indicator dot in the top-right corner: --exclude 1256,0,24,24:privacy).
//  * --ring N checks rings 0…N-1 (default 1 = only the outermost pixels). --inner additionally reports the ring just
//    inside (must NOT be the edge colour: proves the ring is 1 px, i.e. the frame is not offset by one pixel).
//  * exit 0 = every non-excluded ring pixel matches (and size == --expect-size when given); 1 = mismatch; 2 = usage.
import Foundation
import CoreGraphics

@main
struct EdgeCheck {
    struct EdgeResult { var name: String; var ok = 0; var total = 0; var excluded = 0; var excludedOK = 0; var bad: [(Int, Int, (Int, Int, Int))] = [] }

    static func parseHex(_ s: String) -> (Int, Int, Int)? {
        var h = s.hasPrefix("#") ? String(s.dropFirst()) : s
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return ((v >> 16) & 255, (v >> 8) & 255, v & 255)
    }

    /// Checks ring `k` (0 = outermost). Returns results for top, bottom, left, right.
    static func check(_ bm: Bitmap, color: (Int, Int, Int), tol: Int, exclude: [PixRect], ring k: Int, maxList: Int) -> [EdgeResult] {
        let W = bm.width, H = bm.height
        func excluded(_ x: Int, _ y: Int) -> Bool { exclude.contains { x >= $0.x && x < $0.x + $0.w && y >= $0.y && y < $0.y + $0.h } }
        func run(_ name: String, _ pts: [(Int, Int)]) -> EdgeResult {
            var r = EdgeResult(name: name)
            for (x, y) in pts {
                let c = bm.rgb(x, y)
                let match = colorDist(c, color) <= tol
                if excluded(x, y) { r.excluded += 1; if match { r.excludedOK += 1 }; continue }
                r.total += 1
                if match { r.ok += 1 } else if r.bad.count < maxList { r.bad.append((x, y, c)) }
            }
            return r
        }
        return [run("top", (k..<(W - k)).map { ($0, k) }),
                run("bottom", (k..<(W - k)).map { ($0, H - 1 - k) }),
                run("left", (k..<(H - k)).map { (k, $0) }),
                run("right", (k..<(H - k)).map { (W - 1 - k, $0) })]
    }

    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        if argv.first == "--selftest" { exit(selftest() ? 0 : 1) }
        let a = Args(argv, flagNames: ["help", "inner"])
        guard let path = a.positional.first, !a.has("help") else {
            print("usage: edgecheck IMAGE.png [--color 3A4048] [--tol 6] [--exclude x,y,w,h[:label]]... [--ring N] [--inner] [--expect-size WxH] [--max-list N] [--out annotated.png] | edgecheck --selftest")
            exit(a.has("help") ? 0 : 2)
        }
        guard let color = parseHex(a.one("color") ?? "3A4048") else { die("bad --color") }
        let tol = a.int("tol") ?? 6
        let rings = max(1, a.int("ring") ?? 1)
        let maxList = a.int("max-list") ?? 20
        let exclude = (a.opts["exclude"] ?? []).map(parseRect)
        let img = loadCGImage(path)
        let bm = Bitmap(image: img)
        var failed = false
        print("# edgecheck \(path) size=\(img.width)x\(img.height) color=#\(String(format: "%02X%02X%02X", color.0, color.1, color.2)) tol=\(tol) (max-channel)")
        if let es = a.one("expect-size") {
            let ok = es == "\(img.width)x\(img.height)"
            print("size\t\(img.width)x\(img.height)\texpected \(es)\t\(ok ? "PASS" : "FAIL")")
            if !ok { failed = true }
        }
        for e in exclude { print("# exclude \(e)\(e.label.isEmpty ? "" : " (\(e.label))")") }
        print("ring\tedge\tmatch\ttotal\tresult\texcluded\texcluded_match")
        var all: [Int: [EdgeResult]] = [:]
        for k in 0..<rings {
            let rs = check(bm, color: color, tol: tol, exclude: exclude, ring: k, maxList: maxList)
            all[k] = rs
            for r in rs {
                let pass = r.ok == r.total && r.total > 0
                if !pass { failed = true }
                print("\(k)\t\(r.name)\t\(r.ok)\t\(r.total)\t\(pass ? "PASS" : "FAIL")\t\(r.excluded)\t\(r.excludedOK)")
            }
        }
        if a.has("inner") {
            let rs = check(bm, color: color, tol: tol, exclude: exclude, ring: rings, maxList: 0)
            for r in rs {
                print("inner\(rings)\t\(r.name)\t\(r.ok)\t\(r.total)\t\(r.ok == 0 ? "not-edge-colour (expected)" : "edge-colour pixels inside the ring")\t\(r.excluded)\t\(r.excludedOK)")
            }
        }
        for (k, rs) in all.sorted(by: { $0.key < $1.key }) {
            for r in rs where !r.bad.isEmpty {
                print("# ring \(k) \(r.name): first \(r.bad.count) mismatching px: " + r.bad.map { "(\($0.0),\($0.1))=\($0.2.0),\($0.2.1),\($0.2.2)" }.joined(separator: " "))
            }
        }
        if let out = a.one("out") {
            // 8x magnified corners + mismatch markers are hard to see on a 1280x720 image; draw red dots at mismatches
            // and cyan boxes at excludes on a copy of the image.
            let ctx = bm.ctx, H = img.height
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: H))
            for e in exclude { strokeRectTop(ctx, CGFloat(e.x), CGFloat(e.y), CGFloat(e.w), CGFloat(e.h), imageHeight: H, color: rgba(0, 0.9, 1)) }
            ctx.setFillColor(rgba(1, 0.1, 0.1))
            for (_, rs) in all { for r in rs { for b in r.bad { ctx.fill(CGRect(x: b.0 - 2, y: H - 1 - b.1 - 2, width: 5, height: 5)) } } }
            let summary = (all[0] ?? []).map { "\($0.name) \($0.ok)/\($0.total)" }.joined(separator: "  ")
            drawText(ctx, "edgecheck ring0: \(summary)  (tol \(tol))", x: 40, yTop: 330, imageHeight: H, size: 22, color: rgba(1, 1, 1), bgColor: rgba(0, 0, 0, 0.8))
            writePNG(bm.makeImage(), out)
            print("# annotated -> \(out)")
        }
        print("verdict\t\(failed ? "FAIL" : "PASS")")
        exit(failed ? 1 : 0)
    }

    // MARK: - selftest: synthetic 1280x720 images with a known ring

    static func selftest() -> Bool {
        let edge = (0x3A, 0x40, 0x48)
        func make(_ mutate: (Bitmap) -> Void) -> Bitmap {
            let bm = Bitmap(width: 1280, height: 720)
            bm.ctx.setFillColor(rgba(7 / 255, 9 / 255, 12 / 255)); bm.ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
            bm.ctx.setFillColor(rgba(CGFloat(edge.0) / 255, CGFloat(edge.1) / 255, CGFloat(edge.2) / 255))
            bm.ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
            bm.ctx.setFillColor(rgba(7 / 255, 9 / 255, 12 / 255)); bm.ctx.fill(CGRect(x: 1, y: 1, width: 1278, height: 718))
            mutate(bm)
            return bm
        }
        func set(_ bm: Bitmap, _ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
            let o = y * bm.bytesPerRow + x * 4; bm.data[o] = c.0; bm.data[o + 1] = c.1; bm.data[o + 2] = c.2; bm.data[o + 3] = 255
        }
        var ok = true
        func expect(_ name: String, _ cond: Bool, _ detail: String) { print("\(cond ? "PASS" : "FAIL")\t\(name)\t\(detail)"); if !cond { ok = false } }
        // 1. intact ring
        let a = make { _ in }
        let ra = check(a, color: edge, tol: 6, exclude: [], ring: 0, maxList: 5)
        expect("intact", ra.map { "\($0.ok)/\($0.total)" } == ["1280/1280", "1280/1280", "720/720", "720/720"], ra.map { "\($0.name) \($0.ok)/\($0.total)" }.joined(separator: " "))
        // inside ring is background
        let inner = check(a, color: edge, tol: 6, exclude: [], ring: 1, maxList: 0)
        expect("inner-not-edge", inner.allSatisfy { $0.ok == 0 }, inner.map { "\($0.name) \($0.ok)" }.joined(separator: " "))
        // 2. privacy dot in the top-right + exclude
        let b = make { bm in for y in 0..<10 { for x in 1265..<1275 { set(bm, x, y, (255, 150, 0)) } } }
        let rb = check(b, color: edge, tol: 6, exclude: [], ring: 0, maxList: 5)
        expect("dot-detected", rb[0].ok == 1270 && rb[3].ok == 720, "top \(rb[0].ok)/\(rb[0].total) right \(rb[3].ok)/\(rb[3].total)")
        let rbx = check(b, color: edge, tol: 6, exclude: [PixRect(x: 1256, y: 0, w: 24, h: 24)], ring: 0, maxList: 5)
        expect("dot-excluded", rbx[0].ok == rbx[0].total && rbx[0].total == 1256 && rbx[0].excluded == 24 && rbx[3].total == 696,
               "top \(rbx[0].ok)/\(rbx[0].total) excl \(rbx[0].excluded); right \(rbx[3].ok)/\(rbx[3].total) excl \(rbx[3].excluded)")
        // 3. tolerance: +5 passes, +7 fails
        let c = make { bm in set(bm, 100, 0, (0x3A + 5, 0x40, 0x48)); set(bm, 200, 0, (0x3A + 7, 0x40, 0x48)) }
        let rc = check(c, color: edge, tol: 6, exclude: [], ring: 0, maxList: 5)
        expect("tolerance", rc[0].ok == 1279 && rc[0].bad.first?.0 == 200, "top \(rc[0].ok)/\(rc[0].total) bad \(rc[0].bad.map { "\($0.0)" })")
        // 4. content shifted by one pixel down (title-bar-like offset): top row is background
        let d = make { bm in bm.ctx.setFillColor(rgba(7 / 255, 9 / 255, 12 / 255)); bm.ctx.fill(CGRect(x: 0, y: 719, width: 1280, height: 1)) }
        let rd = check(d, color: edge, tol: 6, exclude: [], ring: 0, maxList: 5)
        expect("missing-top-row", rd[0].ok == 0 && rd[1].ok == 1280, "top \(rd[0].ok) bottom \(rd[1].ok) left \(rd[2].ok) right \(rd[3].ok)")
        // 5. hex parsing
        expect("hex", parseHex("#3a4048")! == (0x3A, 0x40, 0x48) && parseHex("fff")! == (255, 255, 255) && parseHex("xyz") == nil, "")
        print(ok ? "edgecheck selftest: all passed" : "edgecheck selftest: FAILED")
        return ok
    }
}
