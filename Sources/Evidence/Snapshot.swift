// Snapshot.swift — offscreen render of a PanelState (no window) + measurement manifests (spec §10, §15 #1/#2).
//   OUT.png                     1280×720 @1x, sRGB, top-left origin (same PanelRenderer as the live view)
//   OUT.rects.tsv               binding class rects   (label, x,y,w,h, min_px, class)  — glyphheight input
//   OUT.perglyph.tsv            per-glyph label rects (informational, same columns)
//   OUT.boxes.tsv               element ink boxes     (id, x,y,w,h)
//   OUT.state.json              the displayed strings of that state
// `--snapshot OUT.png [--dump-rects] [--view memory|cpu|network] [--lang zh|en|system] [--battery yes|no]` renders
// `offscreenState()` once and exits (default memory / zh / battery column = the v1 output); `--lang system` resolves with
// Locale.preferredLanguages like the app. Never reads or writes UserDefaults. The live app's SIGUSR1 path calls
// `render(_:to:dumpRects:)` with the state it last drew (measured rendering, any view).
// Owner: app agent (initial version by the skeleton step).
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum Snapshot {
    struct Output {
        let png: URL
        let files: [URL]
        let layoutProblems: [String]
        let classRects: Int
        let glyphRects: Int
    }

    static func makeContext() -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 1280 * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: 720); ctx.scaleBy(x: 1, y: -1)
        return ctx
    }

    /// Render `state` into a fresh 1280×720 bitmap; returns the renderer (specs / boxes / layoutProblems) and the image.
    static func renderImage(_ state: PanelState) -> (PanelRenderer, CGImage)? {
        guard let ctx = makeContext() else { return nil }
        let r = PanelRenderer()
        r.draw(ctx, state)
        guard let img = ctx.makeImage() else { return nil }
        return (r, img)
    }

    static func render(_ state: PanelState, to png: URL, dumpRects: Bool) throws -> Output {
        guard let (r, img) = renderImage(state) else { throw SourceError.parse("bitmap context") }
        try FileManager.default.createDirectory(at: png.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SourceError.errno(EIO, "png destination \(png.path)")
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw SourceError.errno(EIO, "png write \(png.path)") }
        var files = [png]
        let cls = r.specs.filter { !$0.label.hasPrefix("glyph:") }, gl = r.specs.filter { $0.label.hasPrefix("glyph:") }
        if dumpRects {
            let base = png.deletingPathExtension()
            func row(_ s: MeasureSpec) -> String {
                let q = s.rect
                return "\(s.label)\t\(Int(q.minX)),\(Int(q.minY)),\(Int(q.width)),\(Int(q.height))\t\(s.minPx)\t\(s.cls)\n"
            }
            let header = "label\tx,y,w,h\tmin_px\tclass\n"
            let rects = base.appendingPathExtension("rects.tsv"), per = base.appendingPathExtension("perglyph.tsv")
            let boxes = base.appendingPathExtension("boxes.tsv"), js = base.appendingPathExtension("state.json")
            try (header + cls.map(row).joined()).write(to: rects, atomically: true, encoding: .utf8)
            try (header + gl.map(row).joined()).write(to: per, atomically: true, encoding: .utf8)
            var b = "id\tx,y,w,h\n"
            for x in r.boxes where !x.r.isNull { b += "\(x.id)\t\(Int(x.r.minX)),\(Int(x.r.minY)),\(Int(x.r.width)),\(Int(x.r.height))\n" }
            try b.write(to: boxes, atomically: true, encoding: .utf8)
            let data = try JSONSerialization.data(withJSONObject: stateJSON(state), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: js)
            files += [rects, per, boxes, js]
        }
        return Output(png: png, files: files, layoutProblems: r.layoutProblems(), classRects: cls.count, glyphRects: gl.count)
    }

    /// The displayed strings (what OCR must read back) of a state.
    static func stateJSON(_ s: PanelState) -> [String: Any] {
        func shown(_ v: Shown) -> String { if case .text(let t) = v { return t }; return "—" }
        let m = s.memory
        var mem: [String: Any] = ["physical": shown(m.physical), "used": shown(m.used), "cached": shown(m.cached), "swap": shown(m.swap),
                                  "app": shown(m.app), "wired": shown(m.wired), "compressed": shown(m.compressed),
                                  "pressure_level_word": m.pressureLevel?.word ?? "未知", "pressure_simulated": m.pressureSimulated]
        mem["pressure_percent"] = m.pressurePercent.map { "\($0)" } ?? "—"
        mem["pressure_level"] = m.pressureLevel?.rawValue ?? NSNull()
        let pages = PanelRenderer.pages(s.devices)
        let devs: [[String: Any]] = s.devices.map { g in
            ["kind": g.kind.rawValue, "name": g.name, "owner_tag": g.ownerTag ?? NSNull(), "connected": g.connected,
             "presence": g.presence.rawValue, "presence_word": g.presence == .nearby ? "附近" : (g.presence == .offline ? "離線" : ""),
             "cells": g.cells.map { c -> [String: Any] in
                 var d: [String: Any] = ["label": c.label]
                 switch c.state {
                 case .ok(let p, let ch): d["state"] = "ok"; d["text"] = "\(p)%"; d["charging"] = ch
                 case .failed: d["state"] = "failed"; d["text"] = "—"
                 case .unavailable: d["state"] = "unavailable"; d["text"] = "—"
                 case .stale: d["state"] = "stale"; d["text"] = "—"
                 }
                 if !g.showsCells { d["text"] = "離線" }
                 return d
             }]
        }
        let hist = s.history
        let c = s.cpu, n = s.net
        let cpu: [String: Any] = ["system": shown(c.system), "user": shown(c.user), "idle": shown(c.idle), "threads": shown(c.threads),
                                  "processes": shown(c.processes)]
        let net: [String: Any] = ["download": shown(n.download), "upload": shown(n.upload), "packets_in": shown(n.packetsIn),
                                  "packets_out": shown(n.packetsOut), "packets_in_per_s": shown(n.packetsInRate),
                                  "packets_out_per_s": shown(n.packetsOutRate), "received": shown(n.received), "sent": shown(n.sent)]
        return ["memory": mem, "devices": devs, "battery_page": s.batteryPage, "battery_pages": pages.count,
                "clock": s.clock, "sample_stale": s.sampleStale, "simulation_badge": s.simulationBadge ?? NSNull(),
                "history_points": hist.count, "history_coverage_s": s.historyCoverage, "now": s.now,
                "view": s.view.rawValue, "lang": s.lang.rawValue, "battery_visible": s.batteryVisible, "cpu": cpu, "net": net,
                "cpu_history_points": s.cpuHistory.count, "net_history_points": s.netHistory.count, "sys_coverage_s": s.sysCoverage]
    }

    /// Deterministic fixture used by `--snapshot` until the live Store can provide a one-shot state:
    /// typical memory strings, 15 min smooth history, keyboard + trackpad + one AirPods group (case charging).
    static func fixtureState(now: Date) -> PanelState {
        let GB: Int64 = 1 << 30, MB: Int64 = 1 << 20
        let mem = MemoryDisplay(physical: .text(AMFormat.string(24 * GB)), used: .text(AMFormat.string(18 * GB + 530 * MB)),
                                cached: .text(AMFormat.string(3 * GB + 420 * MB)), swap: .text(AMFormat.string(39 * MB + 768 * 1024)),
                                app: .text(AMFormat.string(7 * GB + 880 * MB)), wired: .text(AMFormat.string(3 * GB + 70 * MB)),
                                compressed: .text(AMFormat.string(7 * GB + 600 * MB)), pressurePercent: 48, pressureLevel: .normal)
        let t = floor(now.timeIntervalSince1970)
        var hist: [PressureSample] = []
        for k in stride(from: 899, through: 0, by: -1) {
            let x = Double(k)
            let pct = (48 + 6 * sin(x / 47) + 3 * sin(x / 11)).rounded()
            hist.append(PressureSample(t: t - x, percent: pct, level: .normal, simulated: false))
        }
        let devices = [
            DeviceGroup(kind: .keyboard, name: "Magic Keyboard", ownerTag: nil, connected: true, cells: [BatteryCell(label: "鍵盤", state: .ok(100, charging: false))]),
            DeviceGroup(kind: .trackpad, name: "Magic Trackpad", ownerTag: nil, connected: true, cells: [BatteryCell(label: "軌跡板", state: .ok(85, charging: false))]),
            DeviceGroup(kind: .airpods, name: "AirPods Pro", ownerTag: nil, connected: true,
                        cells: [BatteryCell(label: "左耳", state: .ok(100, charging: false)), BatteryCell(label: "右耳", state: .ok(97, charging: false)),
                                BatteryCell(label: "充電盒", state: .ok(48, charging: true))]),
        ]
        return PanelState(memory: mem, history: hist, now: t, historyCoverage: 900, devices: devices, clock: EventLog.hms(now))
    }

    /// v2: the v1 fixture + fixed CPU values (4.99 / 16.65 / 78.36 %, 4,783 threads, 795 processes), network values
    /// (5.91 Mb/s down, 156.59 kb/s up, …) and 900 s synthetic CPU / network histories, shown in `view` / `lang` /
    /// with or without the battery column. Main thread (SecondRing).
    static func fixtureState(now: Date, view: ViewKind, lang: Lang, battery: Bool) -> PanelState {
        var s = fixtureState(now: now)
        let t = s.now
        let cpuR = RenderSelfTest.cpuRing(span: 900, now: t), netR = RenderSelfTest.netRing(span: 900, now: t)
        s.view = view; s.lang = lang; s.batteryVisible = battery
        s.cpu = StateBuilder.cpu(CPUReading(system: 4.99, user: 16.65, idle: 78.36, nice: 0, cores: 12), tasks: TaskCounts(threads: 4_783, processes: 795))
        s.net = StateBuilder.net(NetReading(pktIn: 27_833_717, pktOut: 68_441_461, bytesIn: 22_758_680_252, bytesOut: 93_632_064_060,
                                           pktInRate: 612, pktOutRate: 148, rxRate: 739_000, txRate: 19_574, ifaces: 14), lang: lang)
        s.cpuHistory = cpuR.view(); s.netHistory = netR.view(); s.sysCoverage = 900   // a view holds its ring
        s.netTop = StateBuilder.netTop(netTopFixture)
        return s
    }

    /// Five apps (bytes/s): a long name that is cut, a CJK name, and rates from Mb down to bits.
    static let netTopFixture = [ProcTraffic(name: "Safari", rx: 652_000, tx: 14_800), ProcTraffic(name: "Microsoft Teams", rx: 71_300, tx: 4_640),
                                ProcTraffic(name: "微信", rx: 9_870, tx: 5_210), ProcTraffic(name: "Claude", rx: 1_550, tx: 1_225),
                                ProcTraffic(name: "mDNSResponder", rx: 80, tx: 45)]

    /// The state rendered by `--snapshot` (no window, no sampling threads, no UserDefaults).
    static func offscreenState(config: Config, now: Date = Date()) -> PanelState {
        fixtureState(now: now, view: config.view ?? .memory, lang: Settings.resolve(config.lang ?? .zh), battery: config.battery ?? true)
    }

    /// `--snapshot OUT.png [--dump-rects]` entry point. Exit: 0 ok, 1 layout problems, 2 write error.
    static func runOffscreen(config: Config) -> Int32 {
        guard let out = config.snapshotOut else { return 2 }
        let url = URL(fileURLWithPath: out).standardizedFileURL
        do {
            let st = offscreenState(config: config)
            let o = try render(st, to: url, dumpRects: config.dumpRects)
            for f in o.files { print(f.path) }
            print("view=\(st.view.rawValue) lang=\(st.lang.rawValue) battery=\(st.batteryVisible ? "yes" : "no") class_rects=\(o.classRects) glyph_rects=\(o.glyphRects) layout_problems=\(o.layoutProblems.count)")
            for p in o.layoutProblems { print("  ! \(p)") }
            return o.layoutProblems.isEmpty ? 0 : 1
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            return 2
        }
    }
}
