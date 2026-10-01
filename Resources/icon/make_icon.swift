// make_icon.swift — WokyisPanel app icon (CoreGraphics). Usage: swift make_icon.swift OUT_DIR
// The Wokyis retro dock (classic all-in-one Macintosh-style body with a 5" 16:9 screen, floppy-style slot, front ports),
// whose screen is filled edge to edge with the first panel icon: green memory-pressure area graph and a battery.
import AppKit
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func c(_ h: UInt32, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: CGFloat(h >> 16 & 255)/255, green: CGFloat(h >> 8 & 255)/255, blue: CGFloat(h & 255)/255, alpha: a) }
func rr(_ r: CGRect, _ k: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil) }

/// The first icon (v1) laid out to FILL `r` (any aspect): dark gradient background, inner graph panel with green
/// memory-pressure area graph, and a stand + battery row below. `simple` = graph only (small sizes).
func drawV1(_ ctx: CGContext, _ r: CGRect, simple: Bool) {
  ctx.saveGState()
  let g = CGGradient(colorsSpace: nil, colors: [c(0x1B2129), c(0x07090C)] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
  let m = r.height * 0.07
  let rowH = simple ? 0 : r.height * 0.16
  let scr = CGRect(x: r.minX + m, y: r.minY + m + rowH, width: r.width - 2 * m, height: r.height - 2 * m - rowH)
  let k = r.height / 400   // stroke scale
  ctx.addPath(rr(scr, 22 * k)); ctx.setFillColor(c(0x07090C)); ctx.fillPath()
  ctx.addPath(rr(scr, 22 * k)); ctx.setStrokeColor(c(0x3A4048)); ctx.setLineWidth(5 * k); ctx.strokePath()
  if !simple {
    ctx.setStrokeColor(c(0x323B47)); ctx.setLineWidth(2 * k)
    for i in 1..<4 { let x = scr.minX + scr.width * CGFloat(i) / 4; ctx.move(to: CGPoint(x: x, y: scr.minY + 12 * k)); ctx.addLine(to: CGPoint(x: x, y: scr.maxY - 12 * k)) }
    ctx.move(to: CGPoint(x: scr.minX + 12 * k, y: scr.midY)); ctx.addLine(to: CGPoint(x: scr.maxX - 12 * k, y: scr.midY)); ctx.strokePath()
  }
  let ys: [CGFloat] = [0.30, 0.34, 0.31, 0.42, 0.40, 0.55, 0.50, 0.47, 0.62, 0.58, 0.66, 0.60]
  let inner = scr.insetBy(dx: 14 * k, dy: 14 * k)
  let pts = ys.enumerated().map { CGPoint(x: inner.minX + inner.width * CGFloat($0.offset) / CGFloat(ys.count - 1), y: inner.minY + inner.height * $0.element) }
  let line = CGMutablePath(); line.move(to: pts[0]); for p in pts.dropFirst() { line.addLine(to: p) }
  let area = CGMutablePath(); area.addPath(line); area.addLine(to: CGPoint(x: inner.maxX, y: inner.minY)); area.addLine(to: CGPoint(x: inner.minX, y: inner.minY)); area.closeSubpath()
  ctx.saveGState(); ctx.addPath(area); ctx.clip()
  let fg = CGGradient(colorsSpace: nil, colors: [c(0x30D158, 0.85), c(0x30D158, 0.18)] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(fg, start: CGPoint(x: 0, y: inner.maxY), end: CGPoint(x: 0, y: inner.minY), options: []); ctx.restoreGState()
  ctx.addPath(line); ctx.setStrokeColor(c(0x30D158)); ctx.setLineWidth((simple ? 22 : 9) * k); ctx.setLineJoin(.round); ctx.setLineCap(.round); ctx.strokePath()
  if !simple {
    let bh = rowH * 0.62, bw = bh * 2.1
    let b = CGRect(x: scr.maxX - bw - 12 * k, y: r.minY + m * 0.6 + (rowH - bh) / 2, width: bw, height: bh)
    ctx.addPath(rr(b, bh * 0.25)); ctx.setStrokeColor(c(0xF2F4F7)); ctx.setLineWidth(5 * k); ctx.strokePath()
    ctx.addPath(rr(CGRect(x: b.maxX + 5 * k, y: b.midY - bh * 0.22, width: 8 * k, height: bh * 0.44), 3 * k)); ctx.setFillColor(c(0xF2F4F7)); ctx.fillPath()
    ctx.addPath(rr(CGRect(x: b.minX + 9 * k, y: b.minY + 9 * k, width: (b.width - 18 * k) * 0.72, height: b.height - 18 * k), 5 * k)); ctx.fillPath()
    ctx.addPath(rr(CGRect(x: scr.minX + 12 * k, y: b.midY - bh * 0.22, width: scr.width * 0.4, height: bh * 0.44), bh * 0.22)); ctx.setFillColor(c(0x3A4048)); ctx.fillPath()
  }
  ctx.restoreGState()
}

func render(_ px: Int) -> Data {
  let s = CGFloat(px)
  let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.scaleBy(x: s/1024, y: s/1024)
  let small = px <= 64
  // retro body: tall rounded box (front face) with a slightly darker foot
  let bodyR = CGRect(x: 100, y: 100, width: 824, height: 824)   // full macOS icon grid tile (no system backdrop)
  ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: c(0x000000, 0.40))
  ctx.addPath(rr(bodyR, 185)); ctx.setFillColor(c(0xE4DECF)); ctx.fillPath(); ctx.restoreGState()
  ctx.saveGState(); ctx.addPath(rr(bodyR, 185)); ctx.clip()
  let bg = CGGradient(colorsSpace: nil, colors: [c(0xF3EFE4), c(0xDDD6C4)] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: bodyR.maxY), end: CGPoint(x: 512, y: bodyR.minY), options: [])
  // foot band
  ctx.setFillColor(c(0xCFC7B2)); ctx.fill(CGRect(x: bodyR.minX, y: bodyR.minY, width: bodyR.width, height: 70))
  ctx.restoreGState()
  ctx.addPath(rr(bodyR, 185)); ctx.setStrokeColor(c(0xB9B19C)); ctx.setLineWidth(small ? 14 : 6); ctx.strokePath()
  // recessed screen bezel (16:9 panel inside a deeper, taller bezel like the original)
  let bezel = CGRect(x: 196, y: 404, width: 632, height: 440)
  ctx.addPath(rr(bezel, 44)); ctx.setFillColor(c(0xC9C1AC)); ctx.fillPath()
  let glass = CGRect(x: 228, y: 436, width: 568, height: 376)
  ctx.addPath(rr(glass, 30)); ctx.setFillColor(c(0x07090C)); ctx.fillPath()
  // the screen shows the first icon, centered
  ctx.saveGState(); ctx.addPath(rr(glass, 30)); ctx.clip()
  drawV1(ctx, glass, simple: small)   // fills the whole screen
  ctx.restoreGState()
  // glass highlight
  if !small {
    ctx.saveGState(); ctx.addPath(rr(glass, 30)); ctx.clip()
    let hl = CGGradient(colorsSpace: nil, colors: [c(0xFFFFFF, 0.10), c(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: glass.minX, y: glass.maxY), end: CGPoint(x: glass.midX, y: glass.midY), options: []); ctx.restoreGState()
    // floppy-style slot + front ports
    ctx.addPath(rr(CGRect(x: 520, y: 290, width: 270, height: 28), 13)); ctx.setFillColor(c(0x3E3A33)); ctx.fillPath()
    for i in 0..<2 { ctx.addPath(rr(CGRect(x: 240 + CGFloat(i) * 76, y: 290, width: 54, height: 28), 6)); ctx.setFillColor(c(0x5A554B)); ctx.fillPath() }
    ctx.addPath(rr(CGRect(x: 240, y: 232, width: 38, height: 24), 10)); ctx.fillPath()   // USB-C
    ctx.addPath(rr(CGRect(x: 520, y: 244, width: 140, height: 10), 5)); ctx.setFillColor(c(0xB9B19C)); ctx.fillPath() // card slot
  }
  return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}
let set = "\(out)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (n, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
  try! render(px).write(to: URL(fileURLWithPath: "\(set)/icon_\(n).png"))
}
try! render(1024).write(to: URL(fileURLWithPath: "\(out)/AppIcon-1024.png"))
print("ok")
