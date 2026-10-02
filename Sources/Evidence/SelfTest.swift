// SelfTest.swift — `--selftest` (run by scripts/build.sh; non-zero exit fails the build).
// Collects: Config, Injector (parse + live watcher), EventLog (files, rotation, levels), Render (offscreen layout),
// and the module hooks MemorySelfTest / BatterySelfTest / AppSelfTest (docs/INTERFACES.md); v2: SettingsSelfTest,
// HotKeys.selfTest, StatusMenuModel.selfTest. Nothing here reads or writes UserDefaults.
// Temporary files live in a fresh directory under $TMPDIR that this process creates and removes.
// Owner: app agent (initial version by the skeleton step).
import Foundation
import CoreGraphics

enum SelfTest {
    /// Fast, side-effect-free subset (no files, no timers) — used for `selftest=` on the START line.
    static func runQuick() -> (ok: Bool, failed: [String]) {
        let cases = ConfigSelfTest.run() + InjectorSelfTest.run() + MemorySelfTest.run() + BatterySelfTest.run() + AppSelfTest.run()
            + SettingsSelfTest.run()
        let bad = cases.filter { !$0.ok }.map(\.name)
        return (bad.isEmpty, bad)
    }

    static func renderCases() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        let now = Date()
        for (name, st) in [("fixture", Snapshot.fixtureState(now: now)), ("placeholder", StateBuilder.placeholder(now: now))] {
            guard let (r, _) = Snapshot.renderImage(st) else { out.append(SelfTestCase("render.\(name)", false, "no bitmap")); continue }
            let p = r.layoutProblems()
            out.append(SelfTestCase("render.\(name).layout", p.isEmpty, p.prefix(3).joined(separator: "; ")))
            out.append(SelfTestCase("render.\(name).rects", !r.specs.isEmpty, "\(r.specs.count) rects"))
        }
        out += batteryLayoutCases(now: now)
        out += RenderSelfTest.run()      // v2 renderer / L10n / ring (foundation)
        out += GoldenSelfTest.run()      // render.memory.golden (foundation)
        return out
    }

    /// Battery column: paging (spec §6.6, ≤ 5 value rows per page), owner-tag labels (§6.5), grey stale rows (§6.4).
    /// Every page of every scenario is rendered and must have no layout problems.
    static func batteryLayoutCases(now: Date) -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        func hid(_ k: DeviceKind, _ st: CellState = .ok(80, charging: false), tag: String? = nil) -> DeviceGroup {
            DeviceGroup(kind: k, name: "x", ownerTag: tag, connected: true, cells: [BatteryCell(label: k.label, state: st)])
        }
        func pods(_ tag: String? = nil, _ st: [CellState] = [.ok(90, charging: false), .ok(88, charging: false), .ok(40, charging: true)],
                  connected: Bool = true, presence: Presence? = nil) -> DeviceGroup {
            DeviceGroup(kind: .airpods, name: "AirPods Pro", ownerTag: tag, presence: presence ?? (connected ? .connected : .offline),
                        cells: zip(["左耳", "右耳", "充電盒"], st).map { BatteryCell(label: $0.0, state: $0.1) })
        }
        func near(_ tag: String? = nil, _ st: [CellState] = [.ok(97, charging: false), .ok(99, charging: false), .ok(85, charging: false)]) -> DeviceGroup {
            pods(tag, st, presence: .nearby)
        }
        func rows(_ page: [PanelRenderer.Block]) -> Int {
            page.reduce(0) { n, b in if case .pods(let d) = b { return n + (d.showsCells ? 3 : 1) }; return n + 1 }
        }
        let kb = hid(.keyboard), tp = hid(.trackpad), ms = hid(.mouse), ot = hid(.other)
        let scenarios: [(String, [DeviceGroup], Int)] = [   // (name, devices, expected pages)
            ("2hid+1pods", [kb, tp, pods()], 1),
            ("2hid+2pods", [kb, tp, pods("ALEX"), pods("小明")], 2),
            ("3hid+1pods", [kb, tp, ms, pods()], 2),
            ("4hid+1pods", [kb, tp, ms, ot, pods()], 2),
            ("3hid+2pods", [kb, tp, ms, pods("A"), pods("B")], 3),
            ("5hid+0pods", [kb, tp, ms, ot, ot], 1),
            ("6hid+0pods", [kb, tp, ms, ot, ot, ot], 2),
            ("3hid+1pods_off", [kb, tp, ms, pods(connected: false)], 1),
            ("2kb_tagged", [hid(.keyboard, .ok(100, charging: true), tag: "ALEX"), hid(.keyboard, .ok(5, charging: true), tag: "小明"), tp], 1),
            ("2kb_tagged_long", [hid(.keyboard, .ok(100, charging: false), tag: "ABCDEFGHIJKLMNOP"),
                                 hid(.keyboard, .failed, tag: "440B"), hid(.keyboard, .stale, tag: "C0DE")], 1),
            // 3-character label "軌跡板": tag shrinks, then the separator and the tag go (never into the bolt / "低" chip)
            ("2tp_tagged_low_charging", [hid(.trackpad, .ok(20, charging: true), tag: "ALEX"), hid(.trackpad, .ok(10, charging: true), tag: "小明"),
                                         hid(.trackpad, .ok(15, charging: true), tag: "WWWW")], 1),
            ("2tp_tagged_full_charging_cjk", [hid(.trackpad, .ok(100, charging: true), tag: "小明"), hid(.trackpad, .ok(100, charging: true), tag: "鑫"),
                                              hid(.keyboard, .ok(5, charging: true), tag: nil)], 1),
            ("stale", [hid(.keyboard, .stale), hid(.trackpad, .stale), pods(nil, [.stale, .stale, .stale])], 1),
            // 「附近」: grey numbers + word; same three rows as connected
            ("2hid+1pods_nearby", [kb, tp, near()], 1),
            ("2hid+nearby_case_unreported", [kb, tp, near(nil, [.ok(100, charging: false), .ok(98, charging: false), .unavailable])], 1),
            ("2hid+nearby_low_charging", [kb, tp, near(nil, [.ok(9, charging: true), .ok(100, charging: true), .ok(15, charging: true)])], 1),
            ("2hid+nearby_failed", [kb, tp, near(nil, [.failed, .failed, .failed])], 1),
            ("2hid+pods+nearby_tagged", [kb, tp, pods("ALEX"), near("小明")], 2),
            ("2hid+nearby_tag_long", [kb, tp, near("ABCDEFGHIJKLMNOPQRSTUV"), pods("小明", connected: false)], 2),
            ("3hid+nearby", [kb, tp, ms, near()], 2),
            ("3hid+nearby+off", [kb, tp, ms, near("A"), pods("B", connected: false)], 2),
        ]
        var st = Snapshot.fixtureState(now: now)
        for (name, devs, want) in scenarios {
            let pages = PanelRenderer.pages(devs)
            let perPage = pages.map(rows)
            let blocks = pages.flatMap { $0 }
            let podBlocks = blocks.filter { if case .pods = $0 { return true }; return false }.count
            let covered = podBlocks == devs.filter { !$0.kind.isHID }.count && blocks.count - podBlocks >= devs.filter(\.kind.isHID).count
            out.append(SelfTestCase("render.battery.\(name).pages", pages.count == want && perPage.allSatisfy { $0 <= PanelRenderer.maxRowsPerPage } && covered,
                                    "pages=\(pages.count) (want \(want)) rows/page=\(perPage) covered=\(covered)"))
            st.devices = devs
            var problems: [String] = []
            var labels: [String: String] = [:]
            for i in 0..<pages.count {
                st.batteryPage = i
                guard let (r, _) = Snapshot.renderImage(st) else { problems.append("page \(i + 1): no bitmap"); continue }
                problems += r.layoutProblems().map { "page \(i + 1): \($0)" }
                if i == 0 { for l in r.labelTexts where l.id.hasPrefix("label.dev") { labels[l.id, default: ""] += l.text } }
            }
            out.append(SelfTestCase("render.battery.\(name).layout", problems.isEmpty, problems.prefix(3).joined(separator: "; ")))
            if name.hasPrefix("2kb_tagged") || name == "2tp_tagged_full_charging_cjk" {   // rows of one kind must be distinguishable on screen
                let texts = (0..<devs.count).map { labels["label.dev\($0)"] ?? "" }
                let kbTexts = texts.prefix(devs.filter { $0.kind == devs[0].kind }.count)
                out.append(SelfTestCase("render.battery.\(name).distinct_labels", Set(kbTexts).count == kbTexts.count && kbTexts.allSatisfy { $0.count > 2 },
                                        texts.joined(separator: " | ")))
            }
        }
        // 「附近」 on screen: the word is drawn (not 「離線」), numbers in Theme.nearby grey (not value white), digits ≥ 64 px class
        do {
            var n = Snapshot.fixtureState(now: now)
            n.devices = [kb, tp, near(nil, [.ok(97, charging: false), .ok(99, charging: true), .unavailable])]
            if let (r, img) = Snapshot.renderImage(n) {
                let words = r.labelTexts.filter { $0.id.hasPrefix("value.dev2.") }.map(\.text)
                let box = Dictionary(r.boxes.map { ($0.id, $0.r) }, uniquingKeysWith: { a, _ in a })
                let numRect: CGRect = box["value.dev2.0"] ?? .null
                let brightest: (Int, Int, Int)? = numRect.isNull ? nil : Self.brightest(img, numRect)
                n.devices[2].presence = .connected
                var white: (Int, Int, Int)? = nil
                if let (r2, img2) = Snapshot.renderImage(n), let wr = r2.boxes.first(where: { $0.id == "value.dev2.0" })?.r { white = Self.brightest(img2, wr) }
                var grey = false
                if let b = brightest { grey = abs(b.0 - 0xA0) <= 6 && abs(b.1 - 0xA9) <= 6 && abs(b.2 - 0xB4) <= 6 }
                var isWhite = false
                if let w = white { isWhite = w.0 >= 0xE8 && w.2 >= 0xEE }
                let digits = r.specs.filter { $0.label.hasPrefix("value.dev2.0[") }
                out.append(SelfTestCase("render.battery.nearby_word_and_grey", words == ["附近"] && grey && isWhite && digits.first?.minPx == 64 && digits.first?.cls == "digit",
                                        "words=\(words) nearby=\(brightest.map { String(format: "%02X%02X%02X", $0.0, $0.1, $0.2) } ?? "-") connected=\(white.map { String(format: "%02X%02X%02X", $0.0, $0.1, $0.2) } ?? "-")"))
            } else { out.append(SelfTestCase("render.battery.nearby_word_and_grey", false, "no bitmap")) }
        }
        var tn = Snapshot.fixtureState(now: now)
        tn.devices = [kb, tp, pods("ALEX"), near("小明", [.ok(97, charging: false), .ok(99, charging: true), .unavailable])]
        tn.batteryPage = 1
        let dspN = StateBuilder.dspBattery(tn)
        out.append(SelfTestCase("render.battery.dsp_nearby_tagged", dspN == "kb:80 tp:80 pods[小明]~ L:97 R:99c C:U", dspN))
        // DSP tokens: owner tags and the grey stale state are visible in the log too
        var t = Snapshot.fixtureState(now: now)
        t.devices = [hid(.keyboard, .ok(100, charging: false), tag: "ALEX"), hid(.keyboard, .stale, tag: "440B"), pods("小明", [.stale, .stale, .stale])]
        let dsp = StateBuilder.dspBattery(t)
        out.append(SelfTestCase("render.battery.dsp_tokens", dsp == "kb[ALEX]:100 kb[440B]:S pods[小明] L:S R:S C:S", dsp))
        return out
    }

    /// The brightest pixel (max R+G+B) inside `r` of an RGBA image (top-left origin), as 0…255 components.
    static func brightest(_ img: CGImage, _ r: CGRect) -> (Int, Int, Int) {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard ok else { return (0, 0, 0) }
        var best = (0, 0, 0)
        let q = r.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        for y in Int(q.minY)..<Int(q.maxY) { for x in Int(q.minX)..<Int(q.maxX) {
            let i = (y * w + x) * 4   // buffer rows are top-down (bitmap memory order)
            let c = (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
            if c.0 + c.1 + c.2 > best.0 + best.1 + best.2 { best = c }
        } }
        return best
    }

    /// Full run; prints one line per case and a summary; returns true when all pass.
    static func runAll(config: Config) -> Bool {
        var cases: [SelfTestCase] = []
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("wokyis-selftest-\(getpid())-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        var created = false
        do { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false); created = true }
        catch { cases.append(SelfTestCase("selftest.tmpdir", false, "\(error)")) }

        cases += ConfigSelfTest.run()
        cases += InjectorSelfTest.run()
        if created {
            cases += EventLogSelfTest.run(dir: tmp.appendingPathComponent("log"))
            let run = tmp.appendingPathComponent("run")
            try? FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            cases += InjectorSelfTest.runLive(dir: run)
        }
        cases += renderCases()
        cases += MemorySelfTest.run()
        cases += SystemSelfTest.run()    // v2 SystemSampler: cpu.* / net.* / sys.* / sampler.set_hz (sampler agent)
        cases += BatterySelfTest.run()
        cases += AppSelfTest.run()
        cases += SettingsSelfTest.run()       // v2 settings / UI actions (MemorySettingsStore, never UserDefaults)
        cases += HotKeys.selfTest()           // v2 hot-key table + fake registrar (no Carbon registration)
        cases += StatusMenuModel.selfTest()   // v2 menu model (pure, no NSStatusItem)
        cases += InstanceLock.selfTest()      // one app-mode panel per user (flock on a temp file)

        for c in cases { print("\(c.ok ? "PASS" : "FAIL")\t\(c.name)\(c.detail.isEmpty ? "" : "\t" + c.detail)") }
        let failed = cases.filter { !$0.ok }
        print("selftest: \(cases.count - failed.count)/\(cases.count) passed" + (failed.isEmpty ? "" : "; FAILED: " + failed.map(\.name).joined(separator: ", ")))
        // remove only the directory this run created
        if created { try? FileManager.default.removeItem(at: tmp) }
        return failed.isEmpty
    }
}
