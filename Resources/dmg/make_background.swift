// make_background.swift — background of the installer disk image window (scripts/package.sh), styled after the classic
// Macintosh file-copy window: 1-bit pixel art on a 50 % gray dither desktop, a pinstriped title bar with a close box,
// a "items remaining to be copied" line with a progress bar, Geneva / Silom type (Chicago is no longer shipped).
// Usage: swift make_background.swift OUT_DIR → OUT_DIR/background.png (600x420) and background@2x.png (1200x840, 144 dpi).
// Drawn on the 1x pixel grid without anti-aliasing; the 2x image is the same pixels scaled ×2 (nearest neighbour), so
// it stays crisp on Retina. Layout in window points (origin top-left; Finder positions set by layout.applescript): the
// window shows 600x400 pt (the extra 20 pt cover a shorter title bar on older macOS); app icon centre (160, 190),
// Applications centre (440, 190), icon size 128, item names around y 275 on white. Over a light picture Finder draws the
// item names in black even in Dark Mode (measured 2026-10-02). Finder's path bar, when the user has it on, covers the
// bottom ~30 pt: nothing essential sits below y 360.
import AppKit
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let W = 600, H = 420
let appX = 160, appsX = 440, iconY = 190
let black = CGColor(gray: 0, alpha: 1), white = CGColor(gray: 1, alpha: 1)

let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)          // top-left origin, 1 unit = 1 pixel
ctx.setShouldAntialias(false); ctx.setAllowsFontSmoothing(false); ctx.interpolationQuality = .none
ctx.setAllowsFontSubpixelPositioning(false); ctx.setShouldSubpixelPositionFonts(false)   // glyphs on whole pixels
func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: CGColor = black) { ctx.setFillColor(c); ctx.fill(CGRect(x: x, y: y, width: w, height: h)) }
func frame(_ x: Int, _ y: Int, _ w: Int, _ h: Int) { fill(x, y, w, 1); fill(x, y + h - 1, w, 1); fill(x, y, 1, h); fill(x + w - 1, y, 1, h) }
func text(_ s: String, _ font: NSFont, x: Int? = nil, centerX: Int? = nil, top: Int) -> Int {
  let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.black])
  let w = Int(a.size().width.rounded(.up))
  let g = NSGraphicsContext(cgContext: ctx, flipped: true)
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g; g.shouldAntialias = false
  a.draw(at: CGPoint(x: x ?? (centerX! - w / 2), y: top))
  NSGraphicsContext.restoreGraphicsState()
  return w
}
// whole-pixel advances like the old bitmap fonts (fractional advances rounded glyph by glyph give uneven gaps)
func px(_ f: NSFont) -> NSFont { f.screenFont(with: .antialiasedIntegerAdvancementsRenderingMode) }
let geneva = px(NSFont(name: "Geneva", size: 12)!)
let silom = px(NSFont(name: "Silom", size: 12) ?? NSFont.boldSystemFont(ofSize: 12))
/// Chinese has no bitmap font here, and outline CJK drawn without anti-aliasing comes out heavy and smudged (compared
/// 2026-10-02), so it is drawn anti-aliased into a gray buffer and thresholded at 50 % coverage: thin, pure 1-bit strokes.
/// The text sits on the white window, so the 1-bit image is laid over it with a multiply blend.
@discardableResult func cjkText(_ s: String, size: CGFloat = 14, x: Int? = nil, centerX: Int? = nil, top: Int) -> Int {
  let f = NSFont(name: "PingFangTC-Regular", size: size) ?? NSFont.systemFont(ofSize: size)
  let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: NSColor.black])
  let w = Int(a.size().width.rounded(.up)) + 4, h = Int(a.size().height.rounded(.up)) + 2
  let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)!
  g.setFillColor(gray: 1, alpha: 1); g.fill(CGRect(x: 0, y: 0, width: w, height: h))
  g.translateBy(x: 0, y: CGFloat(h)); g.scaleBy(x: 1, y: -1)
  g.setShouldAntialias(true); g.setAllowsFontSmoothing(false); g.setShouldSubpixelPositionFonts(false)
  let n = NSGraphicsContext(cgContext: g, flipped: true)
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = n; a.draw(at: CGPoint(x: 2, y: 1)); NSGraphicsContext.restoreGraphicsState()
  let p = g.data!.bindMemory(to: UInt8.self, capacity: w * h)
  for i in 0..<(w * h) { p[i] = p[i] < 128 ? 0 : 255 }
  let x0 = x ?? (centerX! - w / 2)
  ctx.saveGState(); ctx.setBlendMode(.multiply)
  ctx.translateBy(x: CGFloat(x0), y: CGFloat(top + h)); ctx.scaleBy(x: 1, y: -1)        // images draw upright
  ctx.draw(g.makeImage()!, in: CGRect(x: 0, y: 0, width: w, height: h))
  ctx.restoreGState()
  return x0 + w
}

// desktop: classic 50 % gray dither
fill(0, 0, W, H, white)
for y in 0..<H { for x in stride(from: y % 2, to: W, by: 2) { fill(x, y, 1, 1) } }

// the copy window: white, 1-px frame, 1-px drop shadow (right and bottom)
let wx = 20, wy = 12, ww = 560, wh = 340
fill(wx + 2, wy + 2, ww, wh)                          // shadow
fill(wx, wy, ww, wh, white); frame(wx, wy, ww, wh)
// title bar: pinstripes, close box, title in a white plate with the six-stripe badge
let tbH = 19
for y in stride(from: wy + 3, to: wy + tbH - 2, by: 2) { fill(wx + 2, y, ww - 4, 1) }
fill(wx, wy + tbH, ww, 1)
fill(wx + 8, wy + 3, 13, 13, white); frame(wx + 9, wy + 4, 11, 11)       // close box
let title = "Wokyis Panel"
let tw = Int(NSAttributedString(string: title, attributes: [.font: silom]).size().width.rounded(.up))
let plateW = tw + 16 + 14 + 6, plateX = W / 2 - plateW / 2
fill(plateX, wy + 2, plateW, tbH - 3, white)
let stripes: [UInt32] = [0x61BB46, 0xFDB827, 0xF5821F, 0xE03A3E, 0x963D97, 0x009DDC]   // top -> bottom
for (i, h) in stripes.enumerated() {
  fill(plateX + 8, wy + 4 + i * 2, 14, 2, CGColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1))
}
_ = text(title, silom, x: plateX + 8 + 14 + 6, top: wy + 2)

// instructions
cjkText("把 WokyisPanel 拖到「應用程式」完成安裝", centerX: W / 2, top: wy + 28)
_ = text("Drag WokyisPanel to Applications to install.", geneva, centerX: W / 2, top: wy + 52)

// pixel arrow between the two icons
let ax0 = appX + 80, ax1 = appsX - 80
fill(ax0, iconY - 2, ax1 - ax0 - 10, 5)
for i in 0..<12 { fill(ax1 - 12 + i, iconY - 11 + i, 1, 23 - 2 * i) }     // stepped head

// "items remaining to be copied" + progress bar (the classic copy dialog)
let py = wy + 288
let after = cjkText("要拷貝的項目", x: wx + 22, top: py - 3)       // a thresholded full-width colon loses its upper dot
_ = text(": 1", geneva, x: after - 2, top: py)
_ = text("Items remaining to be copied: 1", geneva, x: wx + 156, top: py)
let bx = wx + 24, bw = ww - 48, by = py + 20
frame(bx, by, bw, 12)
fill(bx + 2, by + 2, (bw - 4) * 5 / 8, 8)

let one = ctx.makeImage()!
func save(_ img: CGImage, _ name: String) {
  let rep = NSBitmapImageRep(cgImage: img); rep.size = NSSize(width: W, height: H)   // 72 dpi at 1x, 144 dpi at 2x
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
save(one, "background.png")
let two = CGContext(data: nil, width: W * 2, height: H * 2, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
two.interpolationQuality = .none
two.draw(one, in: CGRect(x: 0, y: 0, width: W * 2, height: H * 2))
save(two.makeImage()!, "background@2x.png")
print("ok")
