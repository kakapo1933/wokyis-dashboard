// Mockup.swift (v2 design) — offscreen 1280×720 @1x renders of every view × language × battery-column combination.
//   mockup render OUT_DIR [FILTER]  → OUT_DIR/mockup_<view>_<lang>_<bat|full>_<state>.png + data/*.rects.tsv / *.boxes.tsv
//                                     + data/layout_report.txt; exit 1 when any layout problem
//   mockup bench                    → CPU per full frame / per region set, every view (criterion 7 budget)
//   mockup fmt                      → CPU / network formatter boundary strings
// Every state is deterministic (seeded synthetic histories, fixed strings), no live reads.
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

// MARK: formatters (the app's StateBuilder uses the same rules)

let memFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .memory; f.allowedUnits = .useAll; f.zeroPadsFractionDigits = true
    f.allowsNonnumericFormatting = false; f.formattingContext = .listItem
    return f
}()
let fileFormatter: ByteCountFormatter = {   // AM fileSizeFormatter (Network: Data received / sent)
    let f = ByteCountFormatter()
    f.countStyle = .file; f.allowedUnits = .useAll; f.zeroPadsFractionDigits = true
    f.allowsNonnumericFormatting = false; f.formattingContext = .listItem
    return f
}()
let intFormatter: NumberFormatter = {        // AM integerFormatter
    let f = NumberFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.numberStyle = .decimal; f.usesGroupingSeparator = true; f.groupingSeparator = ","
    f.maximumFractionDigits = 0; f.roundingMode = .halfUp
    return f
}()
func am(_ bytes: UInt64) -> Shown { .text(memFormatter.string(fromByteCount: Int64(bytes))) }
func pct(_ v: Double) -> Shown { .text(L10n.fmt2(v) + "%") }
func int(_ v: UInt64) -> Shown { .text(L10n.int(Double(v))) }
func file(_ b: UInt64) -> Shown { .text(fileFormatter.string(fromByteCount: Int64(b))) }
func speed(_ bps: Double, _ l: Lang) -> Shown { .text(L10n.speed(bytesPerSecond: bps, l)) }
let GB: UInt64 = 1 << 30, MB: UInt64 = 1 << 20

struct SeededRNG: RandomNumberGenerator {
    var s: UInt64
    init(seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
}

// MARK: synthetic histories

let now = 100_000.0

func pressureHistory(span: Double, base: Double, segments: [(from: Double, level: PressureLevel, target: Double, sim: Bool)], seed: UInt64) -> [PressureSample] {
    var out: [PressureSample] = []
    var v = base
    var rng = SeededRNG(seed: seed)
    var t = now - span
    while t <= now {
        let age = now - t
        var seg = (level: PressureLevel.normal, target: base, sim: false)
        for s in segments where age <= s.from { seg = (s.level, s.target, s.sim) }
        v += (seg.target - v) * 0.06 + Double.random(in: -1.6...1.6, using: &rng)
        v = min(99, max(3, v))
        out.append(PressureSample(t: t, percent: v.rounded(), level: seg.level, simulated: seg.sim))
        t += 1
    }
    return out
}

/// CPU: system ≈ sysBase, user ≈ userBase with bursts; `peak` → bursts to 100 % total; gapLast = last N s failed (nil);
/// simLast = last N s simulated.
func cpuRing(span: Int, sysBase: Double, userBase: Double, peak: Bool, gapLast: Int = 0, simLast: Int = 0, seed: UInt64) -> SecondRing<CPUPoint> {
    let ring = SecondRing<CPUPoint>()
    var rng = SeededRNG(seed: seed)
    var s = sysBase, u = userBase
    for k in stride(from: span - 1, through: 0, by: -1) {
        let t = now - Double(k)
        let burst = peak && (k % 97 < 14)
        s += ((burst ? sysBase * 3 : sysBase) - s) * 0.2 + Double.random(in: -1.2...1.2, using: &rng)
        u += ((burst ? 100 - s : userBase) - u) * (burst ? 0.6 : 0.15) + Double.random(in: -3...3, using: &rng)
        s = min(100, max(0, s)); u = min(100 - s, max(0, u))
        let failed = k < gapLast
        ring.append(CPUPoint(t: t, system: failed ? nil : Float(s), user: failed ? nil : Float(u), simulated: k < simLast))
    }
    return ring
}

/// Network bytes/s: background rx/tx + download bursts; gapLast = last N s without rate.
func netRing(span: Int, rx: Double, tx: Double, burst: Double, gapLast: Int = 0, simLast: Int = 0, seed: UInt64) -> SecondRing<NetPoint> {
    let ring = SecondRing<NetPoint>()
    var rng = SeededRNG(seed: seed)
    for k in stride(from: span - 1, through: 0, by: -1) {
        let t = now - Double(k)
        let b = (k % 180) < 40 ? burst * (0.6 + 0.4 * sin(Double(k) / 7)) : 0
        let r = max(0, rx * Double.random(in: 0.5...1.5, using: &rng) + b)
        let w = max(0, tx * Double.random(in: 0.5...1.5, using: &rng) + b * 0.08)
        let failed = k < gapLast
        ring.append(NetPoint(t: t, rx: failed ? nil : r, tx: failed ? nil : w, simulated: k < simLast))
    }
    return ring
}

// MARK: devices

func ok(_ p: Int, _ c: Bool = false) -> CellState { .ok(p, charging: c) }
func hid(_ k: DeviceKind, _ s: CellState, tag: String? = nil, connected: Bool = true) -> DeviceGroup {
    DeviceGroup(kind: k, name: "x", ownerTag: tag, connected: connected, cells: [BatteryCell(label: k.label, state: s)])
}
func pods(_ l: CellState, _ r: CellState, _ c: CellState, owner: String? = nil, presence: Presence = .connected) -> DeviceGroup {
    DeviceGroup(kind: .airpods, name: "AirPods Pro", ownerTag: owner, presence: presence,
                cells: [BatteryCell(label: "左耳", state: l), BatteryCell(label: "右耳", state: r), BatteryCell(label: "充電盒", state: c)])
}
let devTypical = [hid(.keyboard, ok(100)), hid(.trackpad, ok(85)), pods(ok(100), ok(97), ok(48, true))]
/// 3 HID (two tagged keyboards, 100 % charging and 20 % low charging) + one tagged NEARBY AirPods group (worst header)
let devWorst = [hid(.keyboard, ok(100, true), tag: "ALEX"), hid(.keyboard, ok(20, true), tag: "小明"), hid(.trackpad, ok(100, true)),
                pods(ok(100, true), ok(20, true), .unavailable, owner: "ALEX", presence: .nearby)]
/// offline / failed / stale rows + offline tagged AirPods (single page: 3 + 1 rows)
let devFailed = [hid(.keyboard, ok(100), connected: false), hid(.trackpad, .failed), hid(.mouse, .stale),
                 pods(ok(80), ok(80), .unavailable, owner: "ABCDEFGHIJ", presence: .offline)]
/// nearby, low + charging, plus a generic HID device
let devNearby = [hid(.mouse, ok(9, true)), hid(.other, ok(64)), pods(ok(9, true), ok(100, true), ok(15), presence: .nearby)]

// MARK: state matrix

struct Combo { let view: ViewKind; let lang: Lang; let battery: Bool
    var name: String { "\(view.token)_\(lang.rawValue)_\(battery ? "bat" : "full")" }
}

func states() -> [(String, PanelState)] {
    var out: [(String, PanelState)] = []
    let typicalMem = MemoryDisplay(physical: am(24 * GB), used: am(18 * GB + 530 * MB), cached: am(3 * GB + 420 * MB), swap: am(39 * MB + 768 * 1024),
                                   app: am(7 * GB + 880 * MB), wired: am(3 * GB + 70 * MB), compressed: am(7 * GB + 600 * MB), pressurePercent: 48, pressureLevel: .normal)
    let wideS = am(1_023 * MB + 900 * 1024)
    let worstMem = MemoryDisplay(physical: am(24 * GB), used: am(24 * GB), cached: wideS, swap: wideS, app: wideS, wired: wideS, compressed: wideS,
                                 pressurePercent: 100, pressureLevel: .critical)
    let failedMem = MemoryDisplay(physical: am(24 * GB), used: .failed, cached: .failed, swap: am(39 * MB + 768 * 1024), app: .failed, wired: .failed,
                                  compressed: .failed, pressurePercent: nil, pressureLevel: nil)
    let hTyp = pressureHistory(span: 900, base: 48, segments: [(900, .normal, 48, false)], seed: 1)
    let hWorst = pressureHistory(span: 900, base: 60, segments: [(900, .warning, 80, false), (120, .critical, 99, false)], seed: 2)
    var hGap = hTyp; for k in (hGap.count - 40)..<hGap.count { hGap[k].percent = nil; hGap[k].level = nil }
    for k in (hGap.count - 120)..<hGap.count { hGap[k].simulated = true }
    let hShort = hTyp.filter { now - $0.t <= 190 }

    let cpuTyp = CPUDisplay(system: pct(4.99), user: pct(16.65), idle: pct(78.36), threads: int(4_783), processes: int(795))
    let cpuWorst = CPUDisplay(system: pct(100), user: pct(100), idle: pct(100), threads: int(99_999), processes: int(99_999))
    let cpuSmall = CPUDisplay(system: pct(0.25), user: pct(1.5), idle: pct(98.25), threads: int(812), processes: int(97))
    let rTyp = cpuRing(span: 900, sysBase: 5, userBase: 17, peak: false, seed: 3)
    let rWorst = cpuRing(span: 900, sysBase: 12, userBase: 40, peak: true, seed: 4)
    // failed_sim: the last 120 s are simulated, the last 40 s of them failed → 80 s of magenta stripe under valid data,
    // no stripe under the gap (v1 pressure rule, now shared by the three graphs)
    let rFail = cpuRing(span: 900, sysBase: 5, userBase: 17, peak: false, gapLast: 40, simLast: 120, seed: 5)
    let rShort = cpuRing(span: 190, sysBase: 5, userBase: 17, peak: false, seed: 6)

    func netD(_ l: Lang, worst: Bool, huge: Bool = false) -> NetDisplay {
        if worst {
            let pk: Shown = huge ? int(12_345_678_901) : int(1_234_567_890)
            return NetDisplay(download: .text("999.99 Mb" + (l == .zh ? "/秒" : "/s")), upload: .text("999.99 Mb" + (l == .zh ? "/秒" : "/s")),
                              packetsIn: pk, packetsOut: pk, packetsInRate: int(999_999), packetsOutRate: int(999_999),
                              received: .text("999.99 GB"), sent: .text("999.99 GB"))
        }
        return NetDisplay(download: speed(739_000, l), upload: speed(19_574, l), packetsIn: int(27_833_717), packetsOut: int(68_441_461),
                          packetsInRate: int(612), packetsOutRate: int(148), received: file(22_758_680_252), sent: file(93_632_064_060))
    }
    let nTyp = netRing(span: 900, rx: 40_000, tx: 12_000, burst: 1_200_000, seed: 7)
    let nWorst = netRing(span: 900, rx: 9_000_000, tx: 4_000_000, burst: 120_000_000, seed: 8)
    let nFail = netRing(span: 900, rx: 40_000, tx: 12_000, burst: 1_200_000, gapLast: 40, simLast: 120, seed: 9)
    let nShort = netRing(span: 190, rx: 40_000, tx: 12_000, burst: 1_200_000, seed: 10)

    // r2: the badge is composed with the view's own sources first and collapsed by whole items when it does not fit
    // the main column (same width rule the renderer's last-resort truncation uses)
    let measurer = PanelRenderer()
    func badge(_ v: ViewKind, _ l: Lang, _ bat: Bool) -> String {
        let maxW = (bat ? Layout.LR : 1252) - Layout.L
        let fits: (String) -> Bool = { measurer.width(measurer.labelPieces($0, color: Theme.sim)) <= maxW }
        switch v {
        case .memory: return L10n.badge(fail: ["mem.vm", "mem.pressure", "bat.hid"], hang: ["bat.sp"], garbage: [], pressure: nil, l, view: v, fits: fits)!
        case .cpu: return L10n.badge(fail: ["bat.hid", "cpu.load", "cpu.tasks"], hang: [], garbage: ["bat.iops"], pressure: nil, l, view: v, fits: fits)!
        case .network: return L10n.badge(fail: ["mem.swap", "bat.hid", "net.if"], hang: ["bat.sp"], garbage: [], pressure: (.critical, 92), l, view: v, fits: fits)!
        }
    }

    for v in ViewKind.allCases { for l in Lang.allCases { for bat in [true, false] {
        let c = Combo(view: v, lang: l, battery: bat)
        func make(mem: MemoryDisplay, hist: [PressureSample], cov: Double, devices: [DeviceGroup], page: Int = 0, clock: String,
                  stale: Bool = false, badge: String? = nil, cpu: CPUDisplay, cpuH: SecondRing<CPUPoint>, net: NetDisplay, netH: SecondRing<NetPoint>) -> PanelState {
            PanelState(memory: mem, history: hist, now: now, historyCoverage: cov, devices: devices, batteryPage: page, clock: clock,
                       sampleStale: stale, simulationBadge: badge, view: v, lang: l, batteryVisible: bat,
                       cpu: cpu, cpuHistory: cpuH.view(), net: net, netHistory: netH.view(), sysCoverage: cov)
        }
        out.append(("\(c.name)_typ", make(mem: typicalMem, hist: hTyp, cov: 900, devices: devTypical, clock: "04:12:33",
                                          cpu: cpuTyp, cpuH: rTyp, net: netD(l, worst: false), netH: nTyp)))
        out.append(("\(c.name)_worst_p1", make(mem: worstMem, hist: hWorst, cov: 900, devices: devWorst, page: 0, clock: "23:59:59",
                                               cpu: cpuWorst, cpuH: rWorst, net: netD(l, worst: true), netH: nWorst)))
        if bat {
            out.append(("\(c.name)_worst_p2", make(mem: worstMem, hist: hWorst, cov: 900, devices: devWorst, page: 1, clock: "23:59:59",
                                                   cpu: cpuWorst, cpuH: rWorst, net: netD(l, worst: true), netH: nWorst)))
        }
        out.append(("\(c.name)_failed_sim", make(mem: failedMem, hist: hGap, cov: 900, devices: devFailed, clock: "23:59:59", badge: badge(v, l, bat),
                                                 cpu: .blank, cpuH: rFail, net: .blank, netH: nFail)))
        out.append(("\(c.name)_collect_stale_nodev", make(mem: typicalMem, hist: hShort, cov: 190, devices: [], clock: "23:59:59", stale: true,
                                                          cpu: cpuSmall, cpuH: rShort, net: netD(l, worst: false), netH: nShort)))
        out.append(("\(c.name)_nearby_huge", make(mem: worstMem, hist: hTyp, cov: 900, devices: devNearby, clock: "08:08:08",
                                                  cpu: cpuWorst, cpuH: rWorst, net: netD(l, worst: true, huge: true), netH: nWorst)))
    } } }
    return out
}

func makeContext() -> CGContext {
    let ctx = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 1280 * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: 720); ctx.scaleBy(x: 1, y: -1)
    return ctx
}
func writePNG(_ img: CGImage, _ path: String) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}
func cpuNow() -> Double { var ts = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts); return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9 }

@main
struct Mockup {
    static func main() {
        let argv = CommandLine.arguments
        let cmd = argv.count > 1 ? argv[1] : "render"
        switch cmd {
        case "render":
            let dir = argv.count > 2 ? argv[2] : "."
            let filter = argv.count > 3 ? argv[3] : ""
            try? FileManager.default.createDirectory(atPath: "\(dir)/data", withIntermediateDirectories: true)
            var bad = 0
            var report = ""
            for (name, st) in states() where filter.isEmpty || name.contains(filter) {
                let r = PanelRenderer()
                let ctx = makeContext()
                r.draw(ctx, st)
                writePNG(ctx.makeImage()!, "\(dir)/mockup_\(name).png")
                var tsv = "label\tx,y,w,h\tmin_px\tclass\n"
                for s in r.specs {
                    let q = s.rect
                    tsv += "\(s.label)\t\(Int(q.minX)),\(Int(q.minY)),\(Int(q.width)),\(Int(q.height))\t\(s.minPx)\t\(s.cls)\n"
                }
                try! tsv.write(toFile: "\(dir)/data/mockup_\(name).rects.tsv", atomically: true, encoding: .utf8)
                var boxes = "id\tx,y,w,h\n"
                for b in r.boxes where !b.r.isNull { boxes += "\(b.id)\t\(Int(b.r.minX)),\(Int(b.r.minY)),\(Int(b.r.width)),\(Int(b.r.height))\n" }
                try! boxes.write(toFile: "\(dir)/data/mockup_\(name).boxes.tsv", atomically: true, encoding: .utf8)
                // partial-redraw equivalence: repainting every region of the view onto a full frame must not change a pixel
                let full = ctx.makeImage()!
                r.draw(ctx, st, only: Set(Layout.regions(view: st.view, battery: st.batteryVisible, lang: st.lang).keys))
                if st.simulationBadge != nil { r.drawSimFrame(ctx) }
                let partial = ctx.makeImage()!
                let same = (full.dataProvider!.data! as Data) == (partial.dataProvider!.data! as Data)
                // live path (renderer.measure = false) must paint the identical frame
                let live = PanelRenderer(); live.measure = false
                let lctx = makeContext(); live.draw(lctx, st)
                let liveSame = (full.dataProvider!.data! as Data) == (lctx.makeImage()!.dataProvider!.data! as Data)
                r.draw(makeContext(), st)   // restore specs/boxes of the full frame for the checks below
                var probs = r.layoutProblems()
                if !same { probs.append("partial region redraw differs from the full frame") }
                if !liveSame { probs.append("measure=false frame differs from the measured frame") }
                bad += probs.count
                let line = "\(name): \(r.specs.filter { !$0.label.hasPrefix("glyph:") }.count) class rects + \(r.specs.filter { $0.label.hasPrefix("glyph:") }.count) glyph rects, layout problems: \(probs.count)"
                print(line); report += line + "\n"
                for p in probs { print("   ! \(p)"); report += "   ! \(p)\n" }
                for g in r.gapReport() { report += "   · \(g)\n" }
            }
            try! report.write(toFile: "\(dir)/data/layout_report.txt", atomically: true, encoding: .utf8)
            exit(bad == 0 ? 0 : 1)
        case "bench":
            let all = states()
            let r = PanelRenderer(); let ctx = makeContext()
            let n = 200
            func run(_ st: PanelState, _ only: Set<Region>?) -> Double {
                for _ in 0..<5 { r.draw(ctx, st, only: only) }
                let c0 = cpuNow(); for _ in 0..<n { r.draw(ctx, st, only: only) }; return (cpuNow() - c0) / Double(n) * 1000
            }
            r.measure = CommandLine.arguments.contains("--measure")   // live path: no measurement records
            print("# renderer.measure=\(r.measure) (live PanelView: false); CPU ms per draw call, offscreen CG only")
            print("state\tfull_ms\tvalues_ms\tgraph_ms\tclock_ms\tbattery_ms\tbudget_%(values@Hz+graph@1Hz+clock@1Hz)")
            for (name, st) in all where name.hasSuffix("_typ") {
                let regs = Layout.regions(view: st.view, battery: st.batteryVisible, lang: st.lang)
                let values = Set(regs.keys.filter { $0.view == st.view })
                let full = run(st, nil), vals = run(st, values), graph = run(st, [.graph]), clock = run(st, [.clock])
                let bat = st.batteryVisible ? run(st, [.battery]) : 0
                let hz: Double = st.view == .memory ? 4 : 1
                print(String(format: "%@\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f", name, full, vals, graph, clock, bat, (vals * hz + graph + clock) / 10))
            }
        case "fmt":
            for b in [0.0, 124.9, 125, 999.99, 124_999.4, 124_999.9, 739_000, 19_574, 1_234_567, 124_999_999, 125_000_000, 3e12] {
                print("speed \(b) B/s\t\(L10n.speed(bytesPerSecond: b, .en))\t\(L10n.speed(bytesPerSecond: b, .zh))")
            }
            for b: UInt64 in [999, 1000, 999_500, 12_345_678, 999_950_000, 22_756_185_858, 1_000_000_000_000] {
                print("file \(b)\t\(fileFormatter.string(fromByteCount: Int64(b)))")
            }
            for v in [4.994, 4.995, 16.649, 99.995, 100] { print("pct \(v)\t\(L10n.fmt2(v))%") }
            for v in [999_999_999.0, 1_234_567_890, 12_345_678_901] { print("compact \(Int(v))\t\(PanelRenderer.compactCount(v))") }
            let c0 = cpuNow(); for k in 0..<100_000 { _ = L10n.fmt2(Double(k) / 7) }
            print(String(format: "fmt2 cached: %.2f us/call", (cpuNow() - c0) / 100_000 * 1e6))
        case "check":
            exit(checks() ? 0 : 1)
        default:
            print("usage: mockup render DIR [FILTER] | bench | fmt | check")
        }
    }
}

// MARK: model / string checks run by `mockup check` (they become selftest cases in the app: ring.put, l10n.badge_fit,
// render.digit_guard)
func checks() -> Bool {
    var ok = true
    func expect(_ c: Bool, _ name: String) { print("\(c ? "PASS" : "FAIL") \(name)"); ok = ok && c }
    // SecondRing.put: same second → replace; jitter ≤ 2 s → replace; step back > 2 s → truncate + append; order kept
    let r = SecondRing<CPUPoint>(visible: 10, slack: 4)
    for t in 0..<20 { r.put(CPUPoint(t: Double(t), system: 1, user: 1)) }
    expect(r.count == 10 && r.last?.t == 19, "ring.append_wrap count=10 last=19")
    expect(r.put(CPUPoint(t: 19, system: 2, user: 2)) == .replaced && r.last?.system == 2, "ring.same_second_replaces")
    expect(r.put(CPUPoint(t: 18, system: 3, user: 3)) == .replaced && r.last?.t == 19 && r.last?.system == 3, "ring.jitter_folds_into_newest_second")
    let res = r.put(CPUPoint(t: 12, system: 4, user: 4))
    var ts: [Double] = []; r.view().forEach { ts.append($0.t) }
    expect(res == .steppedBack(dropped: 8) && ts == ts.sorted() && ts.last == 12, "ring.step_back_truncates \(res) \(ts)")
    var n = 0; let v = r.view(); for t in 13..<40 { r.put(CPUPoint(t: Double(t), system: 1, user: 1)) }; v.forEach { _ in n += 1 }
    expect(n < v.count, "ring.view_skips_overwritten (\(n) of \(v.count) still readable)")
    // badge collapse: whole items, view's own sources first, pressure kept, no mid-word cut
    let m = PanelRenderer()
    for l in Lang.allCases { for bat in [true, false] {
        let maxW = (bat ? Layout.LR : 1252) - Layout.L
        let b = L10n.badge(fail: ["mem.physical", "mem.vm", "mem.swap", "bat.hid", "cpu.load", "cpu.tasks", "net.if"], hang: ["bat.sp"],
                           garbage: ["bat.iops"], pressure: (.critical, 92), l, view: .network,
                           fits: { m.width(m.labelPieces($0, color: Theme.sim)) <= maxW })!
        let w = m.width(m.labelPieces(b, color: Theme.sim))
        let own = b.contains(L10n.sourceName("net.if", l))
        let more = b.contains(l == .zh ? "另 " : " MORE")
        expect(w <= maxW && own && more && !b.hasSuffix("…"), "l10n.badge_fit \(l.rawValue) \(bat ? "bat" : "full") w=\(Int(w))≤\(Int(maxW)): \(b)")
    } }
    // digit guard: a 56 pt grid number (flattest digit 1/4/7 = 40 px) is flagged at minPx 41, a 60 pt one passes 43
    // vector ink rounded DOWN (stricter than the rasterised PNG by ≤ 1 px): 56 pt (raster 40 px, zero margin) is flagged
    for (size, minPx, want) in [(CGFloat(56), 40, false), (60, 40, true)] {
        let rr = PanelRenderer(); let ctx = makeContext()
        rr.draw(ctx, PanelState(memory: MemoryDisplay(physical: .failed, used: .failed, cached: .failed, swap: .failed, app: .failed, wired: .failed,
                                                       compressed: .failed, pressurePercent: nil, pressureLevel: nil), history: [], now: now,
                                historyCoverage: 0, devices: [], clock: "12:34:56"))
        rr.text(ctx, rr.valuePieces(.text("1,234,567,890"), size: size, minPx: minPx), x: 28, baseline: 300, id: "value.probe")
        let s = rr.specs.first { $0.label.hasPrefix("value.probe[") }!
        let flagged = rr.layoutProblems().contains { $0.hasPrefix("glyph value.probe") }
        expect(flagged != want, String(format: "render.digit_guard %.0fpt minPx %d: smallest digit %.1f px, rect %@ (no comma inside)", size, minPx, s.inkH, "\(s.rect)"))
    }
    return ok
}
