// golden OUTDIR → renders goldenStates() (21 v1 memory / zh / battery states) + "app_golden" (= the app's
// Sources/Evidence/GoldenFixture.swift, the state `--selftest render.memory.golden` pins) with the renderer it is
// compiled with (tools/golden/v1 = frozen v1, or Sources/Render = current; see tools/golden_pin.sh);
// writes OUTDIR/<state>.png + OUTDIR/<state>.specs.txt and prints
// "<state>\t<sha256 RGBA>\tboxes=<sha256 of element ink boxes>\tspecs=<sha256 of measurement rects>\tproblems=N".
// r2: pixels and boxes are the golden; measurement rects are reported separately (r2 changed the digit rects on purpose).
import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
@main struct Golden { static func main() {
    let dir = CommandLine.arguments[1]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, st) in goldenStates() + [("app_golden", GoldenFixture.state())] {
        var buf = [UInt8](repeating: 0, count: 1280 * 720 * 4)
        let ctx = CGContext(data: &buf, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 1280 * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: 720); ctx.scaleBy(x: 1, y: -1)
        let r = PanelRenderer()
        r.draw(ctx, st)
        let img = ctx.makeImage()!
        let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(dir)/\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
        let px = SHA256.hash(data: Data(buf)).map { String(format: "%02x", $0) }.joined()
        let specs = r.specs.map { "\($0.label) \($0.rect) \($0.minPx) \($0.cls)" }.joined(separator: "\n")
        let boxes = r.boxes.map { "\($0.id) \($0.r)" }.joined(separator: "\n")
        try? specs.write(toFile: "\(dir)/\(name).specs.txt", atomically: true, encoding: .utf8)
        func h(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        print("\(name)\t\(px)\tboxes=\(h(boxes))\tspecs=\(h(specs))\tproblems=\(r.layoutProblems().count)")
    }
    if ProcessInfo.processInfo.environment["GOLDEN_DUMP_AM"] != nil {
        for (b, s) in amUsed.sorted(by: { $0.key < $1.key }) { FileHandle.standardError.write(Data("    \(b): \"\(s)\",\n".utf8)) }
    }
}}
