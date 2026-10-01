// AMCompare+AX.swift — read-only access to Activity Monitor: AX footer values (+ frames), the pressure graph element,
// the AM window (CGWindowList) and on-screen visibility. Never clicks, focuses, raises or sends events.
// AX approach from phase1/mem/amcal.swift (`axdump`): static texts of the AM main window, value = the nearest static
// text to the right of each footer label on the same row.
import Foundation
import AppKit
import ApplicationServices

let amBundleID = "com.apple.ActivityMonitor"
let pressureLabels = ["MEMORY PRESSURE", "記憶體壓力", "Memory Pressure"]

func axAttr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let pv = axAttr(e, kAXPositionAttribute), let sv = axAttr(e, kAXSizeAttribute) else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}

struct AXNode { let el: AXUIElement; let role: String; let value: String; let frame: CGRect; let depth: Int }

/// What the harness needs from AM (real or synthetic).
protocol AMSource: AnyObject {
    /// 7 footer strings in MemField order; nil = AX read failed
    func read() -> [String]?
    var valueFrames: [CGRect] { get }          // CG global points, MemField order
    var graphFrame: CGRect? { get }            // CG global points
    var windowFrame: CGRect? { get }           // AM main window bounds (CG global points)
    var windowID: CGWindowID? { get }
    /// visible = window on screen, fully inside the main display, footer + graph not covered by another window
    func visibility() -> (ok: Bool, detail: String)
    var describe: String { get }
}

final class RealAM: AMSource {
    let pid: pid_t
    let app: AXUIElement
    var valueEls: [AXUIElement] = []
    var valueFrames: [CGRect] = []
    var graphFrame: CGRect?
    var windowFrame: CGRect?
    var windowID: CGWindowID?
    var labelFrames: [CGRect] = []
    var nodes: [AXNode] = []
    var discoveryError: String?

    init?(graphOverride: CGRect? = nil) {
        guard let p = NSRunningApplication.runningApplications(withBundleIdentifier: amBundleID).first?.processIdentifier else { return nil }
        pid = p
        app = AXUIElementCreateApplication(p)
        AXUIElementSetMessagingTimeout(app, 1.0)
        discover(graphOverride: graphOverride)
    }

    func mainWindow() -> AXUIElement? {
        guard let wins = axAttr(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        var best: (AXUIElement, CGFloat)? = nil
        for w in wins {
            let role = axAttr(w, kAXRoleAttribute) as? String ?? ""
            guard role == "AXWindow" else { continue }
            let title = axAttr(w, kAXTitleAttribute) as? String ?? ""
            let f = axFrame(w) ?? .zero
            if title.hasPrefix("Activity Monitor") || title.hasPrefix("活動監視器") { return w }
            if best == nil || f.width * f.height > best!.1 { best = (w, f.width * f.height) }
        }
        return best?.0
    }

    func collect(_ e: AXUIElement, depth: Int, into out: inout [AXNode]) {
        if depth > 12 || out.count > 4000 { return }
        let role = axAttr(e, kAXRoleAttribute) as? String ?? ""
        if ["AXScrollArea", "AXOutline", "AXTable", "AXToolbar", "AXMenuBar", "AXApplication"].contains(role) { return }
        let v = role == "AXStaticText" ? (axAttr(e, kAXValueAttribute) as? String ?? "") : ""
        out.append(AXNode(el: e, role: role, value: v, frame: axFrame(e) ?? .null, depth: depth))
        if role == "AXStaticText" { return }
        if let kids = axAttr(e, kAXChildrenAttribute) as? [AXUIElement] { for k in kids { collect(k, depth: depth + 1, into: &out) } }
    }

    func discover(graphOverride: CGRect?) {
        guard let w = mainWindow() else { discoveryError = "no AX window (AM window closed / minimised / on another Space?)"; return }
        windowFrame = axFrame(w)
        var ns: [AXNode] = []
        if let kids = axAttr(w, kAXChildrenAttribute) as? [AXUIElement] { for k in kids { collect(k, depth: 1, into: &ns) } }
        nodes = ns
        let texts = ns.filter { $0.role == "AXStaticText" && !$0.frame.isNull }
        let allLabels = Set(MemField.allCases.flatMap { $0.amLabels })
        var els: [AXUIElement] = [], frames: [CGRect] = [], lframes: [CGRect] = []
        for f in MemField.allCases {
            guard let l = texts.first(where: { f.amLabels.contains($0.value) }) else { discoveryError = "footer label \(f.amLabels[0]) not found (Memory tab not selected?)"; return }
            let cands = texts.filter { !allLabels.contains($0.value) && abs($0.frame.midY - l.frame.midY) <= 4 && $0.frame.minX > l.frame.minX }
            guard let best = cands.min(by: { $0.frame.minX < $1.frame.minX }) else { discoveryError = "no value next to \(f.amLabels[0])"; return }
            els.append(best.el); frames.append(best.frame); lframes.append(l.frame)
        }
        valueEls = els; valueFrames = frames; labelFrames = lframes
        if let g = graphOverride { graphFrame = g }
        else if let pl = texts.first(where: { pressureLabels.contains($0.value) }) {
            // graph = smallest non-text element containing a point 20 pt below the pressure label, 60–600 × 30–200 pt
            let probe = CGPoint(x: pl.frame.midX, y: pl.frame.maxY + 20)
            let cands = ns.filter { $0.role != "AXStaticText" && !$0.frame.isNull && $0.frame.contains(probe)
                && (60...600).contains($0.frame.width) && (30...200).contains($0.frame.height) }
            graphFrame = cands.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.frame
            if graphFrame == nil { discoveryError = "pressure graph element not found below '\(pl.value)' (use --graph-frame x,y,w,h)" }
        } else { discoveryError = "pressure label not found (use --graph-frame x,y,w,h)" }
        windowID = cgWindowID()
    }

    func cgWindowID() -> CGWindowID? {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var best: (CGWindowID, CGFloat)? = nil
        for w in info {
            guard let p = w[kCGWindowOwnerPID as String] as? pid_t, p == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String], let r = CGRect(dictionaryRepresentation: b as! CFDictionary),
                  let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            if let wf = windowFrame, abs(r.minX - wf.minX) < 2, abs(r.minY - wf.minY) < 2, abs(r.width - wf.width) < 2 { return id }
            if best == nil || r.width * r.height > best!.1 { best = (id, r.width * r.height) }
        }
        return best?.0
    }

    func read() -> [String]? {
        guard valueEls.count == 7 else { return nil }
        var out: [String] = []
        for e in valueEls { guard let v = axAttr(e, kAXValueAttribute) as? String else { return nil }; out.append(v) }
        return out
    }

    func visibility() -> (ok: Bool, detail: String) {
        guard discoveryError == nil else { return (false, discoveryError!) }
        return WindowCheck.visible(pid: pid, windowID: windowID, frame: windowFrame, mustSee: valueFrames + labelFrames + (graphFrame.map { [$0] } ?? []))
    }

    var describe: String { "Activity Monitor pid \(pid) window \(windowID.map(String.init) ?? "?") frame \(windowFrame.map(fmtR) ?? "?")" }

    /// Human-readable dump (amcompare axdump).
    func dump() -> String {
        var s = "# AM pid \(pid) window \(windowFrame.map(fmtR) ?? "nil") cgWindowID \(windowID.map(String.init) ?? "nil")\n"
        s += "# discovery: \(discoveryError ?? "ok")\n"
        for (f, r) in zip(MemField.allCases, valueFrames) { s += "value\t\(f.rawValue)\t\(fmtR(r))\n" }
        s += "graph\t\(graphFrame.map(fmtR) ?? "nil")\n"
        if let v = read() { s += "read\t" + v.joined(separator: " | ") + "\n" }
        for n in nodes where n.role == "AXStaticText" || (n.frame.height >= 30 && n.frame.height <= 200 && n.frame.width >= 60) {
            s += "node\t\(String(repeating: " ", count: n.depth))\(n.role)\t\(fmtR(n.frame))\t'\(n.value)'\n"
        }
        return s
    }
}

func fmtR(_ r: CGRect) -> String { String(format: "%.1f,%.1f,%.1f,%.1f", r.minX, r.minY, r.width, r.height) }

enum WindowCheck {
    static func mainDisplayBounds() -> CGRect { CGDisplayBounds(CGMainDisplayID()) }

    /// window on screen, inside the main display, and none of `mustSee` covered by a window in front of it.
    static func visible(pid: pid_t, windowID: CGWindowID?, frame: CGRect?, mustSee: [CGRect]) -> (ok: Bool, detail: String) {
        guard let wid = windowID, let wf = frame else { return (false, "AM window not found") }
        let main = mainDisplayBounds()
        guard main.contains(wf) else { return (false, "AM window \(fmtR(wf)) not fully inside the main display \(fmtR(main))") }
        guard let on = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return (false, "CGWindowList failed") }
        var covering: [String] = []
        var found = false
        for w in on {   // front → back
            let id = w[kCGWindowNumber as String] as? CGWindowID ?? 0
            if id == wid { found = true; break }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.01, layer >= 0, layer < 1000, let b = w[kCGWindowBounds as String],
                  let r = CGRect(dictionaryRepresentation: b as! CFDictionary) else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
            if owner == "Window Server" && layer > 0 { continue }   // cursor / menu bar backdrop
            // The Dock keeps a transparent container window whose bounds are the whole display (seen 2026-10-02 with
            // Stage Manager on: Dock#963 layer 20 0,0,1920,1080) and only paints the Dock bar inside it. Treat that
            // full-display container as non-occluding; a real occlusion of the footer still fails attempt validity (i)
            // because the footer OCR must equal the AX strings.
            if owner == "Dock" && r.equalTo(main) { continue }
            if mustSee.contains(where: { $0.intersects(r) }) { covering.append("\(owner)#\(id) layer \(layer) \(fmtR(r))") }
        }
        if !found { return (false, "AM window #\(wid) not on screen (other Space / minimised / hidden)") }
        if !covering.isEmpty { return (false, "footer covered by: " + covering.joined(separator: "; ")) }
        return (true, "on screen, inside main display \(fmtR(main)), footer uncovered")
    }
}
