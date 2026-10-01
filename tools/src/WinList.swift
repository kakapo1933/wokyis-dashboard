// winlist — criterion #1 / gate G5: where are a process's windows, and does anything of the system (menu bar, Dock)
// cover the Wokyis?  Read-only: CGWindowListCopyWindowInfo + CGGetActiveDisplayList, no AX, no events.
//
// usage: winlist --owner NAME | --pid PID  [--wokyis x,y,w,h] [--all-layers] [--check] [--json]
//        winlist --overlays [--wokyis x,y,w,h] [--watch SEC --interval MS]     (G5: menu bar / Dock over the Wokyis)
//        winlist --displays
//        winlist --selftest
//
//  * all coordinates are CG GLOBAL points (origin top-left of the main display, y down), as in kCGWindowBounds.
//  * displays: CGGetActiveDisplayList + CGDisplayBounds; the Wokyis is the display whose bounds equal --wokyis or,
//    by default, the first non-main 1280x720 display (name from NSScreen.localizedName when available).
//  * owner windows: EVERY window of the owner (kCGWindowListOptionAll: on- and off-screen), with id, layer, onscreen,
//    alpha, bounds, the displays it intersects (with the intersection area) and whether it lies fully inside the Wokyis.
//  * --check: exit 1 when any ON-SCREEN owner window with alpha > 0 intersects a display other than the Wokyis, or when
//    the owner has no on-screen window inside the Wokyis. Off-screen windows are listed but do not fail.
//  * --overlays: on-screen windows above the normal layer (layer > 0) owned by Window Server / Dock / SystemUIServer / Control Center / Notification Center
//    (menu bar, Dock, status items) that intersect the Wokyis, with layer and intersection. --watch samples repeatedly.
import Foundation
import CoreGraphics
import AppKit

struct Disp { var id: CGDirectDisplayID; var bounds: CGRect; var name: String; var main: Bool; var wokyis = false }

struct Win {
    var id: Int; var owner: String; var pid: Int; var name: String; var layer: Int; var onscreen: Bool; var alpha: Double; var bounds: CGRect
    init(_ d: [String: Any], onscreenIDs: Set<Int>) {
        id = d[kCGWindowNumber as String] as? Int ?? 0
        owner = d[kCGWindowOwnerName as String] as? String ?? ""
        pid = d[kCGWindowOwnerPID as String] as? Int ?? 0
        name = d[kCGWindowName as String] as? String ?? ""
        layer = d[kCGWindowLayer as String] as? Int ?? 0
        alpha = d[kCGWindowAlpha as String] as? Double ?? 1
        onscreen = (d[kCGWindowIsOnscreen as String] as? Bool ?? false) || onscreenIDs.contains(id)
        var r = CGRect.zero
        if let b = d[kCGWindowBounds as String] { r = CGRect(dictionaryRepresentation: b as! CFDictionary) ?? .zero }
        bounds = r
    }
}

func fmtRect(_ r: CGRect) -> String {
    func f(_ v: CGFloat) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
    return "\(f(r.minX)),\(f(r.minY)),\(f(r.width)),\(f(r.height))"
}

func displays(wokyis override: CGRect?) -> [Disp] {
    var n: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetActiveDisplayList(n, &ids, &n)
    var names: [CGDirectDisplayID: String] = [:]
    for s in NSScreen.screens {
        if let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber { names[num.uint32Value] = s.localizedName }
    }
    var out = ids.map { Disp(id: $0, bounds: CGDisplayBounds($0), name: names[$0] ?? "?", main: CGDisplayIsMain($0) != 0) }
    if let o = override {
        for i in out.indices where out[i].bounds == o { out[i].wokyis = true }
        if !out.contains(where: { $0.wokyis }) { out.append(Disp(id: 0, bounds: o, name: "--wokyis", main: false, wokyis: true)) }
    } else if let i = out.firstIndex(where: { $0.name.localizedCaseInsensitiveContains("wokyis") })
                ?? out.firstIndex(where: { !$0.main && $0.bounds.width == 1280 && $0.bounds.height == 720 }) {
        out[i].wokyis = true
    }
    return out
}

func windows() -> [Win] {
    let on = Set(((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []).compactMap { $0[kCGWindowNumber as String] as? Int })
    return ((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []).map { Win($0, onscreenIDs: on) }
}

/// Classification of one owner window against the displays.
struct Placement { var hits: [(Disp, CGFloat)]; var insideWokyis: Bool; var offWokyisArea: CGFloat }
func place(_ w: Win, _ ds: [Disp]) -> Placement {
    var hits: [(Disp, CGFloat)] = []
    for d in ds {
        let i = w.bounds.intersection(d.bounds)
        if !i.isNull && i.width > 0 && i.height > 0 { hits.append((d, i.width * i.height)) }
    }
    let wk = ds.first { $0.wokyis }
    let inside = wk.map { $0.bounds.contains(w.bounds) && w.bounds.width > 0 } ?? false
    let off = hits.filter { !$0.0.wokyis }.map { $0.1 }.reduce(0, +)
    return Placement(hits: hits, insideWokyis: inside, offWokyisArea: off)
}

let systemOverlayOwners: Set<String> = ["Window Server", "Dock", "SystemUIServer", "Control Center", "Notification Center", "Spotlight"]

@main
struct WinList {
    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        if argv.first == "--selftest" { exit(selftest() ? 0 : 1) }
        let a = Args(argv, flagNames: ["help", "check", "json", "overlays", "displays", "all-layers"])
        let wkOverride = a.one("wokyis").map { s -> CGRect in let r = parseRect(s); return CGRect(x: r.x, y: r.y, width: r.w, height: r.h) }
        if a.has("help") || (a.one("owner") == nil && a.int("pid") == nil && !a.has("overlays") && !a.has("displays")) {
            print("usage: winlist --owner NAME | --pid PID [--wokyis x,y,w,h] [--check] [--json] | --overlays [--watch SEC --interval MS] | --displays | --selftest")
            exit(a.has("help") ? 0 : 2)
        }
        let ds = displays(wokyis: wkOverride)
        print("# winlist \(isoNow())  (CG global points, origin = top-left of main display)")
        for d in ds {
            print("display\tid=\(d.id)\tname=\"\(d.name)\"\tbounds=\(fmtRect(d.bounds))\tmain=\(d.main ? 1 : 0)\twokyis=\(d.wokyis ? 1 : 0)")
        }
        if a.has("displays") { exit(0) }
        if a.has("overlays") {
            let watch = a.double("watch") ?? 0
            let interval = Double(a.int("interval") ?? 250) / 1000
            let end = Date().addingTimeInterval(watch)
            var maxCover = 0
            repeat {
                let n = printOverlays(ds)
                maxCover = max(maxCover, n)
                if watch > 0 { Thread.sleep(forTimeInterval: interval) }
            } while watch > 0 && Date() < end
            print("overlay_summary\tmax_windows_over_wokyis=\(maxCover)")
            exit(0)
        }
        let all = windows()
        let mine = all.filter { w in
            if let p = a.int("pid") { return w.pid == p }
            return w.owner == a.one("owner")!
        }
        let wk = ds.first { $0.wokyis }
        print("# owner=\(a.one("owner") ?? "pid \(a.int("pid")!)") windows=\(mine.count) wokyis=\(wk.map { fmtRect($0.bounds) } ?? "NOT FOUND")")
        print("win\tid\tlayer\tonscreen\talpha\tbounds\tinside_wokyis\tdisplays(intersection px²)\tname")
        var onWokyis = 0, onscreenElsewhere = 0, offscreenElsewhere = 0
        var json: [[String: Any]] = []
        for w in mine {
            let p = place(w, ds)
            let disp = p.hits.map { "\($0.0.wokyis ? "Wokyis" : ($0.0.main ? "main" : "id\($0.0.id)")):\(Int($0.1))" }.joined(separator: ",")
            print("win\t\(w.id)\t\(w.layer)\t\(w.onscreen ? 1 : 0)\t\(String(format: "%.2f", w.alpha))\t\(fmtRect(w.bounds))\t\(p.insideWokyis ? 1 : 0)\t\(disp.isEmpty ? "-" : disp)\t\"\(w.name)\"")
            if w.onscreen && w.alpha > 0 && p.insideWokyis { onWokyis += 1 }
            if p.offWokyisArea > 0 { if w.onscreen && w.alpha > 0 { onscreenElsewhere += 1 } else { offscreenElsewhere += 1 } }
            json.append(["id": w.id, "layer": w.layer, "onscreen": w.onscreen, "alpha": w.alpha, "bounds": fmtRect(w.bounds),
                         "inside_wokyis": p.insideWokyis, "displays": disp, "name": w.name])
        }
        let ok = onWokyis >= 1 && onscreenElsewhere == 0
        print("summary\ton_wokyis_onscreen=\(onWokyis)\tonscreen_off_wokyis=\(onscreenElsewhere)\toffscreen_off_wokyis=\(offscreenElsewhere)\ttotal=\(mine.count)")
        print("verdict\t\(ok ? "PASS" : "FAIL")\t(PASS = ≥1 on-screen window fully inside the Wokyis and 0 on-screen windows touching any other display)")
        _ = printOverlays(ds)
        if a.has("json"), let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: d, encoding: .utf8)!)
        }
        exit(a.has("check") && !ok ? 1 : 0)
    }

    /// Prints on-screen system overlay windows intersecting the Wokyis; returns their count.
    @discardableResult
    static func printOverlays(_ ds: [Disp]) -> Int {
        guard let wk = ds.first(where: { $0.wokyis }) else { print("overlay\tno Wokyis display found"); return 0 }
        let hits = windows().filter { w in
            guard w.onscreen, w.alpha > 0, w.layer > 0, systemOverlayOwners.contains(w.owner) else { return false }
            let i = w.bounds.intersection(wk.bounds)
            return !i.isNull && i.width > 0 && i.height > 0
        }
        let t = isoNow()
        if hits.isEmpty { print("overlay\t\(t)\tnone") }
        for w in hits {
            let i = w.bounds.intersection(wk.bounds)
            print("overlay\t\(t)\towner=\"\(w.owner)\"\tname=\"\(w.name)\"\tid=\(w.id)\tlayer=\(w.layer)\tbounds=\(fmtRect(w.bounds))\tover_wokyis=\(fmtRect(i))")
        }
        return hits.count
    }

    static func selftest() -> Bool {
        var ok = true
        func expect(_ n: String, _ c: Bool, _ d: String = "") { print("\(c ? "PASS" : "FAIL")\t\(n)\t\(d)"); if !c { ok = false } }
        let lg = Disp(id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), name: "LG", main: true)
        var wk = Disp(id: 2, bounds: CGRect(x: -1280, y: 745, width: 1280, height: 720), name: "Wokyis", main: false); wk.wokyis = true
        let ds = [lg, wk]
        func w(_ r: CGRect) -> Win {
            Win([kCGWindowNumber as String: 1, kCGWindowOwnerName as String: "X", kCGWindowLayer as String: 0,
                 kCGWindowIsOnscreen as String: true, kCGWindowBounds as String: r.dictionaryRepresentation], onscreenIDs: [])
        }
        let full = place(w(wk.bounds), ds)
        expect("fullscreen-inside", full.insideWokyis && full.offWokyisArea == 0 && full.hits.count == 1)
        let straddle = place(w(CGRect(x: -100, y: 800, width: 400, height: 300)), ds)
        expect("straddle", !straddle.insideWokyis && straddle.offWokyisArea == 300 * 280 && straddle.hits.count == 2, "\(straddle.offWokyisArea)")
        let onLG = place(w(CGRect(x: 100, y: 100, width: 800, height: 450)), ds)
        expect("on-lg", !onLG.insideWokyis && onLG.offWokyisArea == 800 * 450)
        let bounds = w(CGRect(x: -1280, y: 745, width: 1280, height: 720)).bounds
        expect("bounds-parse", bounds == wk.bounds, fmtRect(bounds))
        // Informational only: the live display list is empty while the displays sleep or the session is locked,
        // which says nothing about winlist's logic, so it must not fail the build.
        let live = displays(wokyis: nil)
        print("INFO\tlive-displays\t\(live.isEmpty ? "none online (asleep/locked?)" : live.map { "\($0.name) \(fmtRect($0.bounds)) wokyis=\($0.wokyis)" }.joined(separator: "; "))")
        print(ok ? "winlist selftest: all passed" : "winlist selftest: FAILED")
        return ok
    }
}
