// RenderSelfTest.swift — `--selftest` cases for the v2 renderer, L10n and the history ring (spec §10.1):
//   render.<view>.<lang>.<bat|full>.<state>.layout   12 combos × {fixture, placeholder, failed, stale, sim}: layoutProblems()
//                                                    empty (includes the in-process vector digit-height guard)
//   render.partial_equals_full / render.live_equals_measured   per combo: region redraw == full frame; measure=false == true
//   render.digit_guard   56 pt "1,234,567,890" flagged at minPx 40 (flattest digit 39.5 px), 60 pt passes; no comma in rect
//   l10n.complete / l10n.badge / l10n.badge_fit / fmt.speed / fmt.pct / fmt.int / fmt.compact / ring.put
// The same model / string checks exist in `tools/bin/mockup check`. Main thread only (SecondRing).
// Owner: foundation (renderer). Golden pixels: Sources/Evidence/Golden.swift.
import CoreGraphics
import Foundation

enum RenderSelfTest {
    static func run() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        out += l10nCases()
        out += fmtCases()
        out += netTopCases()
        out += ringCases()
        out += digitGuardCases()
        out += comboCases()
        return out
    }

    // MARK: bitmap helpers (same context as Snapshot / mockup / golden)

    static func context() -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 1280 * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: 720); ctx.scaleBy(x: 1, y: -1)
        return ctx
    }
    static func bytes(_ ctx: CGContext) -> Data? { ctx.makeImage()?.dataProvider?.data as Data? }

    // MARK: L10n

    static func l10nCases() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        var missing: [String] = [], lower: [String] = []
        for k in L10n.Key.allCases {
            for l in Lang.allCases { for c in [false, true] {
                let s = L10n.t(k, l, compact: c)
                if s.isEmpty || s == k.rawValue { missing.append("\(k.rawValue).\(l.rawValue)") }
                // English on-screen labels are upper-case (glyph rule); menu strings are drawn by AppKit → mixed case
                let shown = s.replacingOccurrences(of: "%d", with: "9")   // format specifiers are not drawn
                if l == .en && !k.rawValue.hasPrefix("menu") && shown != shown.uppercased() { lower.append(k.rawValue) }
            } }
        }
        let zhKeys = ["鍵盤", "軌跡板", "滑鼠", "裝置", "AIRPODS", "左耳", "右耳", "充電盒", "電量", "耳機"]
            + [DeviceKind.keyboard, .trackpad, .mouse, .airpods, .other].map(\.label)
        let unmapped = zhKeys.filter { L10n.cellLabel($0, .en).unicodeScalars.contains { $0.value > 0x2E80 } || L10n.cellLabel($0, .zh) != $0 }
        out.append(SelfTestCase("l10n.complete", missing.isEmpty && lower.isEmpty && unmapped.isEmpty,
                                "missing=\(missing.prefix(4)) lowercase=\(Set(lower).sorted().prefix(4)) unmapped=\(unmapped)"))
        // zh badge text == the v1 badge format; en uses the short words
        let zh = L10n.badge(fail: ["mem.swap", "bat.hid"], hang: [], garbage: [], pressure: nil, .zh)
        let zhP = L10n.badge(fail: [], hang: [], garbage: [], pressure: (.critical, 92), .zh)
        let en = L10n.badge(fail: ["cpu.load"], hang: ["bat.sp"], garbage: ["net.if"], pressure: (.warning, 71), .en, view: .cpu)
        let none = L10n.badge(fail: [], hang: [], garbage: [], pressure: nil, .en)
        out.append(SelfTestCase("l10n.badge", zh == "模擬中：交換檔、HID 讀取失敗" && zhP == "模擬中：壓力 嚴重 92%"
                                && en == "SIM: CPU LOAD FAILED; BLUETOOTH LINK TIMEOUT; NET COUNTERS GARBAGE; PRESSURE WARNING 71%" && none == nil,
                                "\(zh ?? "nil") | \(zhP ?? "nil") | \(en ?? "nil")"))
        // whole-item collapse: fits the main column, keeps the active view's source, appends 另 N 項 / +N MORE, never "…"
        let m = PanelRenderer()
        var fitBad: [String] = []
        for l in Lang.allCases { for bat in [true, false] {
            let maxW = (bat ? Layout.LR : 1252) - Layout.L
            let b = L10n.badge(fail: ["mem.physical", "mem.vm", "mem.swap", "bat.hid", "cpu.load", "cpu.tasks", "net.if"], hang: ["bat.sp"],
                               garbage: ["bat.iops"], pressure: (.critical, 92), l, view: .network,
                               fits: { m.width(m.labelPieces($0, color: Theme.sim)) <= maxW }) ?? ""
            let w = m.width(m.labelPieces(b, color: Theme.sim))
            if !(w <= maxW && b.contains(L10n.sourceName("net.if", l)) && b.contains(l == .zh ? "另 " : " MORE") && !b.hasSuffix("…")) {
                fitBad.append("\(l.rawValue)/\(bat ? "bat" : "full") w=\(Int(w)): \(b)")
            }
        } }
        out.append(SelfTestCase("l10n.badge_fit", fitBad.isEmpty, fitBad.joined(separator: " | ")))
        return out
    }

    // MARK: network side column — a name wider than the column is cut with "…" and fits; a short one is untouched

    static func netTopCases() -> [SelfTestCase] {
        let r = PanelRenderer(), room = Layout.RR - Layout.RL
        let long = r.fitName("Google Chrome Helper (Renderer) Extra", maxWidth: room), cjk = r.fitName("網路流量監控工具超長名稱測試用", maxWidth: room)
        let ok = long.hasSuffix("…") && long.count > 8 && r.width(r.labelPieces(long)) <= room
            && cjk.hasSuffix("…") && r.width(r.labelPieces(cjk)) <= room && r.fitName("Safari", maxWidth: room) == "Safari"
        return [SelfTestCase("render.net_top.fit_name", ok, "\(long) | \(cjk)")]
    }

    // MARK: number formats (design/fmt.txt boundary values)

    static func fmtCases() -> [SelfTestCase] {
        func check(_ name: String, _ pairs: [(String, String)]) -> SelfTestCase {
            let bad = pairs.filter { $0.0 != $0.1 }.map { "\($0.0)≠\($0.1)" }
            return SelfTestCase(name, bad.isEmpty, bad.isEmpty ? "\(pairs.count) values" : bad.joined(separator: " "))
        }
        return [
            check("fmt.speed", [(L10n.speed(bytesPerSecond: 0, .en), "0.00 bit/s"), (L10n.speed(bytesPerSecond: 124.9, .en), "999.20 bit/s"),
                                (L10n.speed(bytesPerSecond: 125, .en), "1.00 kb/s"), (L10n.speed(bytesPerSecond: 124_999.9, .en), "1.00 Mb/s"),
                                (L10n.speed(bytesPerSecond: 739_000, .en), "5.91 Mb/s"), (L10n.speed(bytesPerSecond: 19_574, .zh), "156.59 kb/秒"),
                                (L10n.speed(bytesPerSecond: 125_000_000, .en), "1.00 Gb/s"), (L10n.speed(bytesPerSecond: 3e12, .zh), "24.00 Tb/秒"),
                                (L10n.speed(bytesPerSecond: -5, .en), "0.00 bit/s")]),
            check("fmt.speed_compact", [(L10n.speedCompact(bytesPerSecond: 0), "0 bit"), (L10n.speedCompact(bytesPerSecond: 80), "640 bit"),
                                        (L10n.speedCompact(bytesPerSecond: 124.9), "999 bit"), (L10n.speedCompact(bytesPerSecond: 124.95), "1.00 kb"),
                                        (L10n.speedCompact(bytesPerSecond: 5_800), "46.4 kb"), (L10n.speedCompact(bytesPerSecond: 1_249.4), "10.0 kb"),
                                        (L10n.speedCompact(bytesPerSecond: 16_875), "135 kb"), (L10n.speedCompact(bytesPerSecond: 124_950), "1.00 Mb"),
                                        (L10n.speedCompact(bytesPerSecond: 739_000), "5.91 Mb"), (L10n.speedCompact(bytesPerSecond: 12_495_000), "100 Mb"),
                                        (L10n.speedCompact(bytesPerSecond: 3e12), "24.0 Tb"), (L10n.speedCompact(bytesPerSecond: -5), "0 bit")]),
            check("fmt.pct", [(L10n.fmt2(4.994) + "%", "4.99%"), (L10n.fmt2(4.995) + "%", "5.00%"), (L10n.fmt2(16.649) + "%", "16.65%"),
                              (L10n.fmt2(99.995) + "%", "100.00%"), (L10n.fmt2(100) + "%", "100.00%"), (L10n.fmt2(1234.5), "1,234.50")]),
            check("fmt.int", [(L10n.int(4_783), "4,783"), (L10n.int(795), "795"), (L10n.int(0), "0"), (L10n.int(1_234_567_890), "1,234,567,890")]),
            check("fmt.compact", [(PanelRenderer.compactCount(999_999_999), "1.00 G"), (PanelRenderer.compactCount(1_234_567_890), "1.23 G"),
                                  (PanelRenderer.compactCount(12_345_678_901), "12.35 G")]),
        ]
    }

    // MARK: SecondRing.put (spec §2.1)

    static func ringCases() -> [SelfTestCase] {
        let r = SecondRing<CPUPoint>(visible: 10, slack: 4)
        for t in 0..<20 { r.put(CPUPoint(t: Double(t), system: 1, user: 1)) }
        let wrap = r.count == 10 && r.last?.t == 19
        let same = r.put(CPUPoint(t: 19, system: 2, user: 2)) == .replaced && r.last?.system == 2
        let jitter = r.put(CPUPoint(t: 18, system: 3, user: 3)) == .replaced && r.last?.t == 19 && r.last?.system == 3
        let res = r.put(CPUPoint(t: 12, system: 4, user: 4))
        var ts: [Double] = []; r.view().forEach { ts.append($0.t) }
        let back = res == .steppedBack(dropped: 8) && ts == ts.sorted() && ts.last == 12
        var n = 0; let v = r.view(); for t in 13..<40 { r.put(CPUPoint(t: Double(t), system: 1, user: 1)) }; v.forEach { _ in n += 1 }
        let stale = n < v.count
        let e = HistoryView<CPUPoint>(); var en = 0; e.forEach { _ in en += 1 }
        return [SelfTestCase("ring.put", wrap && same && jitter && back && stale && en == 0 && e.last == nil,
                             "wrap=\(wrap) same=\(same) jitter=\(jitter) back=\(res) \(ts) overwritten_skipped=\(n)/\(v.count) empty_view=\(en)")]
    }

    // MARK: digit guard (spec §2.3 r2)

    static func digitGuardCases() -> [SelfTestCase] {
        var ok = true, detail: [String] = []
        let blank = MemoryDisplay(physical: .failed, used: .failed, cached: .failed, swap: .failed, app: .failed, wired: .failed,
                                  compressed: .failed, pressurePercent: nil, pressureLevel: nil)
        for (size, want) in [(CGFloat(56), false), (60, true)] {
            guard let ctx = context() else { return [SelfTestCase("render.digit_guard", false, "no bitmap")] }
            let rr = PanelRenderer()
            rr.draw(ctx, PanelState(memory: blank, history: [], now: GoldenFixture.now, historyCoverage: 0, devices: [], clock: GoldenFixture.clock))
            rr.text(ctx, rr.valuePieces(.text("1,234,567,890"), size: size, minPx: 40), x: 28, baseline: 300, id: "value.probe")
            guard let s = rr.specs.first(where: { $0.label.hasPrefix("value.probe[") }) else { ok = false; detail.append("no probe rect"); continue }
            let flagged = rr.layoutProblems().contains { $0.hasPrefix("glyph value.probe") }
            let digits = rr.specs.filter { $0.label.hasPrefix("glyph:value.probe") || ($0.cls == "glyph-digit" && $0.label.contains("value.probe")) }.count
            ok = ok && flagged != want && digits == 10 && !s.label.contains(",")
            detail.append(String(format: "%.0fpt flattest %.1f px flagged=%@ digit_rects=%d binding=%@", size, s.inkH, flagged ? "yes" : "no", digits, s.label))
        }
        return [SelfTestCase("render.digit_guard", ok, detail.joined(separator: "; "))]
    }

    // MARK: 12 view × language × battery combinations

    struct Combo { let view: ViewKind; let lang: Lang; let battery: Bool
        var name: String { "\(view.rawValue).\(lang.rawValue).\(battery ? "bat" : "full")" }
    }

    static func cpuRing(span: Int, gapLast: Int = 0, simLast: Int = 0, now: Double) -> SecondRing<CPUPoint> {
        let r = SecondRing<CPUPoint>()
        for k in stride(from: span - 1, through: 0, by: -1) {
            let x = Double(k), failed = k < gapLast
            r.append(CPUPoint(t: now - x, system: failed ? nil : Float(5 + 3 * sin(x / 13)), user: failed ? nil : Float(17 + 9 * sin(x / 29)),
                              simulated: k < simLast))
        }
        return r
    }
    static func netRing(span: Int, gapLast: Int = 0, simLast: Int = 0, now: Double) -> SecondRing<NetPoint> {
        let r = SecondRing<NetPoint>()
        for k in stride(from: span - 1, through: 0, by: -1) {
            let x = Double(k), failed = k < gapLast
            let burst = (k % 180) < 40 ? 1_200_000 * (0.6 + 0.4 * sin(x / 7)) : 0
            r.append(NetPoint(t: now - x, rx: failed ? nil : 40_000 * (1 + 0.5 * sin(x / 5)) + burst, tx: failed ? nil : 12_000 * (1 + 0.5 * cos(x / 3)) + burst * 0.08,
                              simulated: k < simLast))
        }
        return r
    }

    static func states(_ c: Combo) -> [(String, PanelState)] {
        let base = GoldenFixture.state(), now = base.now
        let cpu = CPUDisplay(system: .text("4.99%"), user: .text("16.65%"), idle: .text("78.36%"), threads: .text("4,783"), processes: .text("795"))
        let u = c.lang == .zh ? "/秒" : "/s"
        let net = NetDisplay(download: .text("5.91 Mb" + u), upload: .text("156.59 kb" + u), packetsIn: .text("27,833,717"), packetsOut: .text("68,441,461"),
                             packetsInRate: .text("612"), packetsOutRate: .text("148"), received: .text("22.76 GB"), sent: .text("93.63 GB"))
        let cr = cpuRing(span: 900, now: now), nr = netRing(span: 900, now: now)
        func make(_ s: PanelState, cpu: CPUDisplay, net: NetDisplay, cr: SecondRing<CPUPoint>, nr: SecondRing<NetPoint>, cov: Double = 900) -> PanelState {
            var s = s
            s.view = c.view; s.lang = c.lang; s.batteryVisible = c.battery
            s.cpu = cpu; s.cpuHistory = cr.view(); s.net = net; s.netHistory = nr.view(); s.sysCoverage = cov
            return s
        }
        // side column of the network view: fixture / sim = five rows (a cut name, a CJK name), placeholder = pending
        // (the default), failed = "—", stale = nothing transferring
        let top = StateBuilder.netTop(Snapshot.netTopFixture)
        var fx = base; fx.netTop = top
        var out: [(String, PanelState)] = [("fixture", make(fx, cpu: cpu, net: net, cr: cr, nr: nr))]
        // placeholder: nothing sampled yet
        let blankMem = MemoryDisplay(physical: .failed, used: .failed, cached: .failed, swap: .failed, app: .failed, wired: .failed,
                                     compressed: .failed, pressurePercent: nil, pressureLevel: nil)
        out.append(("placeholder", make(PanelState(memory: blankMem, history: [], now: now, historyCoverage: 0, devices: [], clock: "--:--:--"),
                                        cpu: .blank, net: .blank, cr: SecondRing<CPUPoint>(), nr: SecondRing<NetPoint>(), cov: 0)))
        // failed: every value "—", last 40 s of history failed, failed / stale / offline battery rows
        var f = base; f.memory = blankMem; f.netTop = .failed
        for k in (f.history.count - 40)..<f.history.count { f.history[k].percent = nil; f.history[k].level = nil }
        f.devices = [DeviceGroup(kind: .keyboard, name: "x", ownerTag: nil, connected: false, cells: [BatteryCell(label: "鍵盤", state: .ok(100, charging: false))]),
                     DeviceGroup(kind: .trackpad, name: "x", ownerTag: nil, connected: true, cells: [BatteryCell(label: "軌跡板", state: .failed)]),
                     DeviceGroup(kind: .mouse, name: "x", ownerTag: nil, connected: true, cells: [BatteryCell(label: "滑鼠", state: .stale)])]
        out.append(("failed", make(f, cpu: .blank, net: .blank, cr: cpuRing(span: 900, gapLast: 40, now: now), nr: netRing(span: 900, gapLast: 40, now: now))))
        // stale: 3 minutes collected, stale chip, no devices
        var st = base; st.sampleStale = true; st.devices = []; st.historyCoverage = 190; st.netTop = .rows([])
        st.history = st.history.filter { now - $0.t <= 190 }
        out.append(("stale", make(st, cpu: cpu, net: net, cr: cpuRing(span: 190, now: now), nr: netRing(span: 190, now: now), cov: 190)))
        // sim: collapsed badge (whole items) + 120 s simulated of which the last 40 s failed
        let m = PanelRenderer()
        let maxW = (c.battery ? Layout.LR : 1252) - Layout.L
        var sm = base; sm.netTop = top
        sm.simulationBadge = L10n.badge(fail: ["mem.vm", "bat.hid", "cpu.load", "net.if"], hang: ["bat.sp"], garbage: ["cpu.tasks"], pressure: (.critical, 92),
                                        c.lang, view: c.view, fits: { m.width(m.labelPieces($0, color: Theme.sim)) <= maxW })
        sm.memory.pressurePercent = 92; sm.memory.pressureLevel = .critical; sm.memory.pressureSimulated = true
        for k in (sm.history.count - 120)..<sm.history.count { sm.history[k].simulated = true }
        out.append(("sim", make(sm, cpu: cpu, net: net, cr: cpuRing(span: 900, gapLast: 40, simLast: 120, now: now),
                                nr: netRing(span: 900, gapLast: 40, simLast: 120, now: now))))
        return out
    }

    static func comboCases() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        for v in ViewKind.allCases { for l in Lang.allCases { for bat in [true, false] {
            let c = Combo(view: v, lang: l, battery: bat)
            var partialBad: [String] = [], liveBad: [String] = []
            for (name, st) in states(c) {
                guard let ctx = context(), let lctx = context() else { out.append(SelfTestCase("render.\(c.name).\(name).layout", false, "no bitmap")); continue }
                let r = PanelRenderer()
                r.draw(ctx, st)
                let p = r.layoutProblems()
                out.append(SelfTestCase("render.\(c.name).\(name).layout", p.isEmpty && !r.specs.isEmpty,
                                        p.isEmpty ? "\(r.specs.count) rects" : p.prefix(3).joined(separator: "; ")))
                let full = bytes(ctx)
                // live path (measure = false) paints the identical frame
                let live = PanelRenderer(); live.measure = false
                live.draw(lctx, st)
                if bytes(lctx) != full { liveBad.append(name) }
                // repainting every region of the view onto the full frame changes no pixel
                r.draw(ctx, st, only: Set(Layout.regions(view: st.view, battery: st.batteryVisible, lang: st.lang).keys))
                if st.simulationBadge != nil { r.drawSimFrame(ctx) }
                if bytes(ctx) != full { partialBad.append(name) }
            }
            out.append(SelfTestCase("render.\(c.name).partial_equals_full", partialBad.isEmpty, partialBad.joined(separator: ",")))
            out.append(SelfTestCase("render.\(c.name).live_equals_measured", liveBad.isEmpty, liveBad.joined(separator: ",")))
        } } }
        return out
    }
}
