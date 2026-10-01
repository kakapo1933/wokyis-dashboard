// Mockup.swift — offscreen 1280×720 @1x renders of the FINAL layout (no windows, no GUI).
//   mockup render OUT_DIR   → OUT_DIR/mockup_<state>.png + OUT_DIR/data/mockup_<state>.rects.tsv + layout check
//   mockup bench            → CPU per full frame vs region redraw (criterion 7 budget)
//   mockup fmt              → ByteCountFormatter strings (AM format)
// State "n_normal" uses LIVE read-only sysctl values with the spec's sysctl-only formulas (MTE free term);
// host_statistics64 is deliberately NOT called.
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let amFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .memory; f.allowedUnits = .useAll; f.zeroPadsFractionDigits = true
    f.allowsNonnumericFormatting = false; f.formattingContext = .listItem
    return f
}()
func am(_ bytes: UInt64) -> Shown { .text(amFormatter.string(fromByteCount: Int64(bytes))) }

func sc(_ name: String) -> UInt64? {
    var v: UInt64 = 0, sz = MemoryLayout<UInt64>.size
    if sysctlbyname(name, &v, &sz, nil, 0) == 0 { return sz == 4 ? UInt64(UInt32(truncatingIfNeeded: v)) : v }
    var v32: UInt32 = 0; sz = 4
    return sysctlbyname(name, &v32, &sz, nil, 0) == 0 ? UInt64(v32) : nil
}
func liveMemory() -> MemoryDisplay {
    let P: UInt64 = 16384
    let s = { (n: String) in sc(n) ?? 0 }
    let mem = s("hw.memsize")
    let F = s("vm.page_free_count") + s("vm.page_free_cpu_count") + s("vm.mte.free.kernel_tagged") + s("vm.mte.free.cpu_claimed")
          + s("vm.mte.free.cpu_kernel_tagged") + s("vm.mte.cell.inactive")
    let E = s("vm.page_pageable_external_count") + s("vm.page_cpu_pageable_external_count")
    let I = s("vm.page_pageable_internal_count") + s("vm.page_cpu_pageable_internal_count")
    let U = s("vm.page_purgeable_count") + s("vm.page_purgeable_wired_count")
    let W = s("vm.page_wired_count") + s("vm.page_throttled_count")
    let C = s("vm.mte.compress_ts_pages_used") + s("vm.mte.compress_non_ts_pages_used")
    var sw = xsw_usage(); var sz = MemoryLayout<xsw_usage>.size
    let swapOK = sysctlbyname("vm.swapusage", &sw, &sz, nil, 0) == 0
    let lvl = Int(s("kern.memorystatus_level")), pl = Int(sc("kern.memorystatus_vm_pressure_level") ?? 1)
    let used = Int64(mem / P) - Int64(F) - Int64(E)
    return MemoryDisplay(physical: am(mem), used: used > 0 ? am(UInt64(used) * P) : .failed, cached: am((E + U) * P),
                         swap: swapOK ? am(sw.xsu_used) : .failed, app: I >= U ? am((I - U) * P) : .failed,
                         wired: am(W * P), compressed: am(C * P),
                         pressurePercent: min(100, max(0, 100 - lvl)), pressureLevel: PressureLevel(kernel: pl))
}

/// Synthetic 1 Hz history (the panel records one point per wall-clock second).
func history(now: Double, span: Double = 660, base: Double, segments: [(from: Double, level: PressureLevel, target: Double, sim: Bool)]) -> [PressureSample] {
    var out: [PressureSample] = []
    var v = base
    var rng = SystemRandomNumberGenerator()
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
func clock(_ d: Date = Date()) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d) }
let GB: UInt64 = 1 << 30, MB: UInt64 = 1 << 20

func kbd(_ s: CellState, connected: Bool = true) -> DeviceGroup { DeviceGroup(kind: .keyboard, name: "Alex’s Magic Keyboard", ownerTag: nil, connected: connected, cells: [BatteryCell(label: "鍵盤", state: s)]) }
func pad(_ s: CellState, connected: Bool = true) -> DeviceGroup { DeviceGroup(kind: .trackpad, name: "Casey Lin的觸控式軌跡板", ownerTag: nil, connected: connected, cells: [BatteryCell(label: "軌跡板", state: s)]) }
func ok(_ p: Int, _ c: Bool = false) -> CellState { .ok(p, charging: c) }
func pods(_ l: CellState, _ r: CellState, _ c: CellState, owner: String? = nil, name: String = "Alex’s AirPods Pro", connected: Bool = true,
          nearby: Bool = false) -> DeviceGroup {
    DeviceGroup(kind: .airpods, name: name, ownerTag: owner, presence: nearby ? .nearby : (connected ? .connected : .offline),
                cells: [BatteryCell(label: "左耳", state: l), BatteryCell(label: "右耳", state: r), BatteryCell(label: "充電盒", state: c)])
}

func states() -> [(String, PanelState)] {
    let now = 100_000.0
    var out: [(String, PanelState)] = []
    let live = liveMemory()
    let liveLvl = Double(live.pressurePercent ?? 50)
    // n: normal — live sysctl values + today's real device set (keyboard, trackpad; AirPods not connected)
    out.append(("n_normal", PanelState(memory: live, history: history(now: now, base: liveLvl, segments: [(660, live.pressureLevel ?? .normal, liveLvl, false)]),
                                       now: now, historyCoverage: 660, devices: [kbd(ok(100)), pad(ok(100))], clock: clock())))
    // w: worst-case strings — widest possible string in EVERY column, hero 24.00 GB, pressure 100 %, max devices all 100 % + charging
    let worst = "1,023.9 MB"
    _ = worst
    let wideS = am(1_023 * MB + 900 * 1024)
    let wide = MemoryDisplay(physical: am(24 * GB), used: am(24 * GB), cached: wideS, swap: wideS, app: wideS, wired: wideS, compressed: wideS,
                             pressurePercent: 100, pressureLevel: .critical)
    out.append(("w_worst_strings", PanelState(memory: wide, history: history(now: now, base: 60, segments: [(660, .warning, 80, false), (120, .critical, 99, false)]),
                                              now: now, historyCoverage: 900, devices: [kbd(ok(100, true)), pad(ok(100, true)), pods(ok(100, true), ok(100, true), ok(100, true))],
                                              clock: "23:59:59")))
    var zero = wide
    zero.used = am(23 * GB + 1_000 * MB); zero.physical = am(24 * GB); zero.swap = am(0); zero.compressed = am(0)
    zero.cached = am(23 * GB + 1_010 * MB); zero.app = am(23 * GB + 1_015 * MB); zero.wired = am(20 * GB + 1_000 * MB)
    zero.pressurePercent = 8; zero.pressureLevel = .normal
    out.append(("w2_zero_bytes_wide_gb", PanelState(memory: zero, history: history(now: now, base: 8, segments: [(660, .normal, 8, false)]),
                                                    now: now, historyCoverage: 900, devices: [kbd(ok(100)), pad(ok(100))], clock: "00:00:00")))
    // m: max device set on one page (current inventory) + overflow (second AirPods connected → 2 pages, HID pinned)
    let typical = MemoryDisplay(physical: am(24 * GB), used: am(18 * GB + 530 * MB), cached: am(3 * GB + 420 * MB), swap: am(39 * MB + 768 * 1024),
                                app: am(7 * GB + 880 * MB), wired: am(3 * GB + 70 * MB), compressed: am(7 * GB + 600 * MB), pressurePercent: 48, pressureLevel: .normal)
    let hNorm = history(now: now, base: 48, segments: [(660, .normal, 48, false)])
    out.append(("m_max_devices", PanelState(memory: typical, history: hNorm, now: now, historyCoverage: 900,
                                            devices: [kbd(ok(100)), pad(ok(85)), pods(ok(100), ok(97), ok(48, true))], clock: "04:12:33")))
    let two = [kbd(ok(100)), pad(ok(85)), pods(ok(100), ok(97), ok(48, true), owner: "ALEX"),
               pods(ok(62), ok(58), ok(35), owner: "小明", name: "小明的AirPods Pro")]
    out.append(("o_overflow_page1", PanelState(memory: typical, history: hNorm, now: now, historyCoverage: 900, devices: two, batteryPage: 0, clock: "04:12:34")))
    out.append(("o_overflow_page2", PanelState(memory: typical, history: hNorm, now: now, historyCoverage: 900, devices: two, batteryPage: 1, clock: "04:12:42")))
    // f: failed sources (injected) — swap "—", HID source failed (both HID rows "—"), AirPods case unavailable (dim "—")
    var fmem = typical; fmem.swap = .failed
    out.append(("f_failed_source", PanelState(memory: fmem, history: hNorm, now: now, historyCoverage: 900,
                                              devices: [kbd(.failed), pad(.failed), pods(ok(80), ok(78), .unavailable)],
                                              clock: "04:13:05", simulationBadge: "模擬中：交換檔、HID 讀取失敗")))
    // f2: VM counters + pressure failed (5 fields "—", pill 未知, graph gap), physical & swap live; keyboard offline; AirPods offline
    let f2 = MemoryDisplay(physical: am(24 * GB), used: .failed, cached: .failed, swap: am(39 * MB + 768 * 1024), app: .failed, wired: .failed,
                           compressed: .failed, pressurePercent: nil, pressureLevel: nil)
    var hGap = hNorm; for k in (hGap.count - 40)..<hGap.count { hGap[k].percent = nil; hGap[k].level = nil }
    out.append(("f2_vm_pressure_failed", PanelState(memory: f2, history: hGap, now: now, historyCoverage: 900,
                                                    devices: [kbd(ok(100), connected: false), pad(ok(100)), pods(ok(80), ok(80), .unavailable, connected: false)],
                                                    clock: "04:13:40", simulationBadge: "模擬中：記憶體計數、壓力讀取失敗")))
    // y / r: yellow and red pressure with a full 10-minute history (injected → magenta stripe + badge)
    var ymem = typical; ymem.pressurePercent = 71; ymem.pressureLevel = .warning; ymem.used = am(21 * GB + 310 * MB); ymem.pressureSimulated = true
    out.append(("y_yellow_10min", PanelState(memory: ymem, history: history(now: now, base: 45, segments: [(660, .normal, 45, false), (300, .warning, 70, true)]),
                                             now: now, historyCoverage: 900, devices: [kbd(ok(100)), pad(ok(100))], clock: "04:20:11",
                                             simulationBadge: "模擬中：壓力 警告")))
    var rmem = ymem; rmem.pressurePercent = 92; rmem.pressureLevel = .critical; rmem.used = am(23 * GB + 640 * MB)
    out.append(("r_red_10min", PanelState(memory: rmem, history: history(now: now, base: 45, segments: [(660, .normal, 45, false), (420, .warning, 72, true), (170, .critical, 92, true)]),
                                          now: now, historyCoverage: 900, devices: [kbd(ok(100)), pad(ok(100))], clock: "04:24:58", simulationBadge: "模擬中：壓力 嚴重")))
    // l: low battery + charging cues (never pressure hues)
    out.append(("l_low_battery", PanelState(memory: typical, history: hNorm, now: now, historyCoverage: 900,
                                            devices: [kbd(ok(15)), pad(ok(9, true)), pods(ok(19, true), ok(100), ok(8, true))], clock: "04:40:00")))
    // t: two+ devices of one kind → owner tags on HID rows (truncated to fit next to low / charging cues)
    let tagged = [DeviceGroup(kind: .keyboard, name: "Alex’s Magic Keyboard", ownerTag: "ALEX", connected: true, cells: [BatteryCell(label: "鍵盤", state: ok(100, true))]),
                  DeviceGroup(kind: .keyboard, name: "小明的 Magic Keyboard", ownerTag: "小明", connected: true, cells: [BatteryCell(label: "鍵盤", state: ok(5, true))]),
                  DeviceGroup(kind: .keyboard, name: "Magic Keyboard", ownerTag: "440B", connected: true, cells: [BatteryCell(label: "鍵盤", state: .failed)]),
                  pad(ok(85))]
    out.append(("t_tagged_hid", PanelState(memory: typical, history: hNorm, now: now, historyCoverage: 900, devices: tagged, clock: "04:41:00")))
    // g: system_profiler stale > 45 s → connection unknown → grey rows (criterion #5 "grey within 60 s")
    out.append(("g_sp_stale_grey", PanelState(memory: typical, history: hNorm, now: now, historyCoverage: 900,
                                              devices: [kbd(.stale), pad(.stale), pods(.stale, .stale, .stale)], clock: "04:42:00")))
    // p: three HID + one AirPods group → 6 rows > 5 → two pages (spec §6.6)
    let three = [kbd(ok(100)), pad(ok(85)), DeviceGroup(kind: .mouse, name: "Magic Mouse", ownerTag: nil, connected: true, cells: [BatteryCell(label: "滑鼠", state: ok(64))]),
                 pods(ok(100), ok(97), ok(48, true))]
    out.append(("p_3hid_pods_page1", PanelState(memory: typical, history: hNorm, now: now, historyCoverage: 900, devices: three, batteryPage: 0, clock: "04:43:00")))
    out.append(("p_3hid_pods_page2", PanelState(memory: typical, history: hNorm, now: now, historyCoverage: 900, devices: three, batteryPage: 1, clock: "04:43:08")))
    // z: 「附近」 — AirPods NOT connected to this Mac with fresh IOPS / BLE values: grey numbers + 「附近」 word
    out.append(("z1_nearby_all", PanelState(memory: typical, history: hNorm, now: now, historyCoverage: 900,
                                            devices: [kbd(ok(100)), pad(ok(85)), pods(ok(97), ok(99), ok(85), nearby: true)], clock: "05:00:00")))
    out.append(("z2_nearby_case_unreported", PanelState(memory: typical, history: hNorm, now: now, historyCoverage: 900,
                                                        devices: [kbd(ok(100)), pad(ok(85)), pods(ok(100), ok(98), .unavailable, nearby: true)], clock: "05:01:00")))
    out.append(("z3_nearby_low_charging", PanelState(memory: typical, history: hNorm, now: now, historyCoverage: 900,
                                                     devices: [kbd(ok(100)), pad(ok(85)), pods(ok(18, true), ok(9), ok(100, true), nearby: true)], clock: "05:02:00")))
    let nearTwo = [kbd(ok(100)), pad(ok(85)), pods(ok(100), ok(97), ok(48, true), owner: "ALEX"),
                   pods(ok(62), ok(58, true), ok(35), owner: "小明", name: "小明的AirPods Pro", nearby: true)]
    out.append(("z4_nearby_tag_overflow_page1", PanelState(memory: typical, history: hNorm, now: now, historyCoverage: 900, devices: nearTwo, batteryPage: 0, clock: "05:03:00")))
    out.append(("z4_nearby_tag_overflow_page2", PanelState(memory: typical, history: hNorm, now: now, historyCoverage: 900, devices: nearTwo, batteryPage: 1, clock: "05:03:08")))
    // s: startup (history 3 min) + no devices + stalled sampler
    let hShort = hNorm.filter { now - $0.t <= 190 }
    out.append(("s_startup_nodev_stale", PanelState(memory: typical, history: hShort, now: now, historyCoverage: 190, devices: [], clock: "04:30:02", sampleStale: true)))
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
            try? FileManager.default.createDirectory(atPath: "\(dir)/data", withIntermediateDirectories: true)
            var bad = 0
            var report = ""
            for (name, st) in states() {
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
                let probs = r.layoutProblems()
                bad += probs.count
                let line = "\(name): \(r.specs.filter { !$0.label.hasPrefix("glyph:") }.count) class rects + \(r.specs.filter { $0.label.hasPrefix("glyph:") }.count) glyph rects, layout problems: \(probs.count)"
                print(line); report += line + "\n"
                for p in probs { print("   ! \(p)"); report += "   ! \(p)\n" }
                for g in r.gapReport() { report += "   · \(g)\n" }
            }
            try! report.write(toFile: "\(dir)/data/layout_report.txt", atomically: true, encoding: .utf8)
            exit(bad == 0 ? 0 : 1)
        case "bench":
            let st = states().first { $0.0 == "m_max_devices" }!.1
            let r = PanelRenderer(); let ctx = makeContext()
            for _ in 0..<5 { r.draw(ctx, st) }
            let n = 300
            func run(_ only: Set<Region>?) -> Double { let c0 = cpuNow(); for _ in 0..<n { r.draw(ctx, st, only: only) }; return (cpuNow() - c0) / Double(n) * 1000 }
            let full = run(nil)
            let values = run([.used, .pressure, .sec0, .sec1, .sec2, .sec3, .sec4, .sec5, .clock])
            let used = run([.used])
            let graph = run([.graph])
            let battery = run([.battery])
            print(String(format: "full frame            %.3f ms CPU", full))
            print(String(format: "values (7 + pressure + clock) %.3f ms CPU", values))
            print(String(format: "used only             %.3f ms CPU", used))
            print(String(format: "graph (1 Hz)          %.3f ms CPU", graph))
            print(String(format: "battery (≤ 1/15 Hz)   %.3f ms CPU", battery))
            print(String(format: "budget: values@4Hz + graph@1Hz = %.3f %% of one core; full@4Hz = %.3f %%", (values * 4 + graph) / 10, full * 4 / 10))
        case "fmt":
            for b: UInt64 in [0, 1023, 1024, 1047552, 1048575, 39 * MB + 768 * 1024, 41156608, 1073217536, 1_023 * MB + 900 * 1024, 1073741823, 3293773824, 18 * GB + 530 * MB, 24 * GB] {
                print("\(b)\t\(amFormatter.string(fromByteCount: Int64(b)))")
            }
        default:
            print("usage: mockup render DIR | bench | fmt")
        }
    }
}
