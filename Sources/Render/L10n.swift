// L10n.swift — every on-screen and menu string, zh (Traditional Chinese, Taiwan) and en, in code (no .lproj).
// Rules: English LABELS are upper-case (glyph rule: ≥ 32 px ink, no x-height credit); units inside values keep AM casing
// ("Mb/s", "bytes", "kb/秒") because units are not labels (PanelRenderer.valuePieces cls "unit", minPx 0).
// `compact` = the 800 px main column (battery column visible); a few labels have a shorter form there.
// Menu strings are mixed case (they are drawn by AppKit in the menu bar, not on the 5" panel).
// Pure Foundation: compiled into the app AND the mockup tool (tools/build.sh).
import Foundation

enum L10n {
    enum Key: String, CaseIterable {
        // memory view
        case memUsed, memPressure, memPhysical, memCached, memSwap, memApp, memWired, memCompressed
        case levelNormal, levelWarning, levelCritical, levelUnknown
        // cpu view (AM CPU tab footer)
        case cpuSystem, cpuUser, cpuIdle, cpuThreads, cpuProcesses
        // network view (AM Network tab footer)
        case netDownload, netUpload, netPacketsIn, netPacketsOut, netPacketsInRate, netPacketsOutRate, netReceived, netSent
        // shared chrome
        case axisAgo, axisCollecting, axisNow, clockLabel, stale
        // battery column
        case batKeyboard, batTrackpad, batMouse, batOther, batAirPods, batPodsShort, batLeft, batRight, batCase, batSingle
        case batOffline, batNearby, batLow, noDevices1, noDevices2
        // simulation badge
        case simPrefix, simFailed, simHang, simGarbage, simPressure, simMore, listSep, partSep
        // status-item menu
        case menuMemory, menuCPU, menuNetwork, menuNextView, menuShowBattery, menuLanguage, menuLangSystem, menuLangZh,
             menuLangEn, menuLangSwitch, menuQuit, menuStatusTooltip
    }

    /// (zh, en, en compact?, zh compact?) — compact forms are used only when the battery column is visible.
    private static let table: [Key: (zh: String, en: String, enC: String?, zhC: String?)] = [
        .memUsed: ("記憶體用量", "MEMORY USED", nil, nil),
        .memPressure: ("記憶體壓力", "MEMORY PRESSURE", nil, nil),
        .memPhysical: ("實體記憶體", "PHYSICAL MEMORY", "PHYSICAL", nil),
        .memCached: ("快取的檔案", "CACHED FILES", nil, nil),
        .memSwap: ("使用的交換檔", "SWAP USED", nil, nil),
        .memApp: ("APP 記憶體", "APP MEMORY", nil, nil),
        .memWired: ("系統核心記憶體", "WIRED MEMORY", "WIRED", nil),
        .memCompressed: ("已壓縮", "COMPRESSED", nil, nil),
        .levelNormal: ("正常", "NORMAL", nil, nil),
        .levelWarning: ("警告", "WARNING", nil, nil),
        .levelCritical: ("嚴重", "CRITICAL", nil, nil),
        .levelUnknown: ("未知", "UNKNOWN", nil, nil),
        // "CPU" prefix (design decision r2): the CPU view's only on-screen identifier; AM's footer says "System:" etc. under
        // a "CPU LOAD" graph title, and 「系統」 alone reads like the memory view's 系統核心記憶體.
        .cpuSystem: ("CPU 系統", "CPU SYSTEM", nil, nil),
        .cpuUser: ("CPU 使用者", "CPU USER", nil, nil),
        .cpuIdle: ("CPU 閒置", "CPU IDLE", nil, nil),
        .cpuThreads: ("執行緒", "THREADS", nil, nil),
        .cpuProcesses: ("程序", "PROCESSES", nil, nil),
        .netDownload: ("下載", "DOWNLOAD", nil, nil),
        .netUpload: ("上傳", "UPLOAD", nil, nil),
        .netPacketsIn: ("封包流入量", "PACKETS IN", nil, nil),
        .netPacketsOut: ("封包流出量", "PACKETS OUT", nil, nil),
        .netPacketsInRate: ("封包流入量／秒", "PACKETS IN/SEC", "IN/SEC", "流入／秒"),
        .netPacketsOutRate: ("封包流出量／秒", "PACKETS OUT/SEC", "OUT/SEC", "流出／秒"),
        .netReceived: ("已接收的資料", "DATA RECEIVED", "RECEIVED", nil),
        .netSent: ("已傳送的資料", "DATA SENT", "SENT", nil),
        .axisAgo: ("十分鐘前", "10 MIN AGO", nil, nil),
        .axisCollecting: ("收集中 %d/10 分鐘", "COLLECTING %d/10 MIN", nil, nil),
        .axisNow: ("現在", "NOW", nil, nil),
        .clockLabel: ("更新", "AS OF", nil, nil),
        .stale: ("停滯", "STALE", nil, nil),
        .batKeyboard: ("鍵盤", "KBD", nil, nil),
        .batTrackpad: ("軌跡板", "TPAD", nil, nil),
        .batMouse: ("滑鼠", "MOUSE", nil, nil),
        .batOther: ("裝置", "DEVICE", nil, nil),
        .batAirPods: ("AIRPODS", "AIRPODS", nil, nil),
        .batPodsShort: ("耳機", "PODS", nil, nil),
        .batLeft: ("左耳", "LEFT", nil, nil),
        .batRight: ("右耳", "RIGHT", nil, nil),
        .batCase: ("充電盒", "CASE", nil, nil),
        .batSingle: ("電量", "BATT", nil, nil),
        .batOffline: ("離線", "OFFLINE", nil, nil),
        .batNearby: ("附近", "NEARBY", nil, nil),
        .batLow: ("低", "LOW", nil, nil),
        .noDevices1: ("沒有已連線的", "NO CONNECTED", nil, nil),
        .noDevices2: ("藍牙周邊", "BLUETOOTH DEVICES", nil, nil),
        // English badge words are short (48 pt caps ≈ 20 px per character: 800 px holds ~40 characters)
        .simPrefix: ("模擬中：", "SIM: ", nil, nil),
        .simFailed: (" 讀取失敗", " FAILED", nil, nil),
        .simHang: (" 逾時", " TIMEOUT", nil, nil),
        .simGarbage: (" 格式錯誤", " GARBAGE", nil, nil),
        .simPressure: ("壓力", "PRESSURE", nil, nil),
        .simMore: ("另 %d 項", "+%d MORE", nil, nil),        // badge collapsed by whole items (never cut inside a word)
        .listSep: ("、", ", ", nil, nil),
        .partSep: ("；", "; ", nil, nil),
        .menuMemory: ("記憶體", "Memory", nil, nil),
        .menuCPU: ("CPU", "CPU", nil, nil),
        .menuNetwork: ("網路", "Network", nil, nil),
        .menuNextView: ("下一個畫面", "Next View", nil, nil),
        .menuShowBattery: ("顯示藍牙電量", "Show Bluetooth Battery", nil, nil),
        .menuLanguage: ("語言", "Language", nil, nil),
        .menuLangSystem: ("跟隨系統", "System", nil, nil),
        .menuLangZh: ("繁體中文", "繁體中文", nil, nil),       // endonyms: each language names itself
        .menuLangEn: ("English", "English", nil, nil),
        .menuLangSwitch: ("切換語言", "Switch Language", nil, nil),  // ⌃⌥⌘L: 繁體中文 ↔ English
        .menuQuit: ("結束 Wokyis 面板", "Quit Wokyis Panel", nil, nil),
        .menuStatusTooltip: ("Wokyis 面板：%@", "Wokyis Panel: %@", nil, nil),
    ]

    static func t(_ k: Key, _ lang: Lang, compact: Bool = false) -> String {
        guard let e = table[k] else { return k.rawValue }
        switch lang {
        case .zh: return compact ? (e.zhC ?? e.zh) : e.zh
        case .en: return compact ? (e.enC ?? e.en) : e.en
        }
    }

    static func axisLeft(coverage: Double, span: Double = 600, _ lang: Lang) -> String {
        coverage >= span ? t(.axisAgo, lang) : String(format: t(.axisCollecting, lang), Int(coverage / 60))
    }

    static func level(_ l: PressureLevel?, _ lang: Lang) -> String {
        switch l { case .normal?: t(.levelNormal, lang); case .warning?: t(.levelWarning, lang); case .critical?: t(.levelCritical, lang); case nil: t(.levelUnknown, lang) }
    }

    /// BatteryCell.label / DeviceKind.label stay Chinese semantic keys (BatteryAggregator, BAT log); this maps them.
    static func cellLabel(_ zhKey: String, _ lang: Lang) -> String {
        guard lang == .en else { return zhKey }
        let m: [String: Key] = ["鍵盤": .batKeyboard, "軌跡板": .batTrackpad, "滑鼠": .batMouse, "裝置": .batOther, "AIRPODS": .batAirPods,
                                "左耳": .batLeft, "右耳": .batRight, "充電盒": .batCase, "電量": .batSingle, "耳機": .batPodsShort]
        return m[zhKey].map { t($0, .en) } ?? zhKey.uppercased()
    }

    /// Simulation badge source names (keyed by SourceID raw value; "mem.mib:<name>" → "MIB <NAME>").
    static func sourceName(_ id: String, _ lang: Lang) -> String {
        let names: [String: (String, String)] = [
            "mem.physical": ("實體記憶體", "PHYSICAL MEMORY"), "mem.vm": ("記憶體計數", "VM COUNTERS"), "mem.swap": ("交換檔", "SWAP"),
            "mem.level": ("壓力值", "PRESSURE VALUE"), "mem.pressure": ("壓力等級", "PRESSURE LEVEL"), "mem.audit": ("稽核", "AUDIT"),
            "bat.hid": ("HID", "HID"), "bat.iops": ("AIRPODS 電量", "AIRPODS BATTERY"), "bat.sp": ("藍牙連線", "BLUETOOTH LINK"),
            "cpu.load": ("CPU 負載", "CPU LOAD"), "cpu.tasks": ("執行緒與程序", "TASKS"), "net.if": ("網路計數", "NET COUNTERS"),
        ]
        if let n = names[id] { return lang == .zh ? n.0 : n.1 }
        if id.hasPrefix("mem.mib:") { return "MIB " + id.dropFirst("mem.mib:".count).uppercased() }
        return id.uppercased()
    }

    /// "模擬中：交換檔、HID 讀取失敗；壓力 嚴重 92%" / "SIMULATING: SWAP, HID READ FAILED; PRESSURE CRITICAL 92%".
    /// `fail`/`hang`/`garbage` arrive in SourceID order (Injector.badgeParts). Within each list the active view's sources
    /// come first, then the battery sources, then the rest. When `fits` rejects the full text, whole items (a source, or
    /// the pressure part) are dropped from the lowest-priority end and counted in a trailing 「另 N 項」/"+N MORE" part,
    /// so no word is ever cut (the renderer's character truncation stays only as a last resort).
    static func badge(fail: [String], hang: [String], garbage: [String], pressure: (PressureLevel, Int)?, _ lang: Lang,
                      view: ViewKind = .memory, fits: ((String) -> Bool)? = nil) -> String? {
        if fail.isEmpty && hang.isEmpty && garbage.isEmpty && pressure == nil { return nil }
        // priority (lower = kept longer): the active view's own sources 0; the pressure part 1 (0 on the memory view);
        // battery sources 2; everything else 3
        let own = view == .memory ? "mem." : (view == .cpu ? "cpu." : "net.")
        func rank(_ id: String) -> Int { id.hasPrefix(own) ? 0 : (id.hasPrefix("bat.") ? 2 : 3) }
        func order(_ l: [String]) -> [String] { l.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element) }
        var lists = [order(fail), order(hang), order(garbage)]
        var showPressure = pressure != nil
        let pressureRank = view == .memory ? 0 : 1
        let suffixes: [Key] = [.simFailed, .simHang, .simGarbage]
        let sep = t(.listSep, lang)
        func build(_ dropped: Int) -> String {
            var parts: [String] = []
            for (k, l) in lists.enumerated() where !l.isEmpty { parts.append(l.map { sourceName($0, lang) }.joined(separator: sep) + t(suffixes[k], lang)) }
            if showPressure, let (l, p) = pressure { parts.append("\(t(.simPressure, lang)) \(level(l, lang)) \(p)%") }
            if dropped > 0 { parts.append(String(format: t(.simMore, lang), dropped)) }
            return t(.simPrefix, lang) + parts.joined(separator: t(.partSep, lang))
        }
        var dropped = 0
        var text = build(0)
        guard let fits else { return text }
        while !fits(text) {
            // drop the lowest-priority item (highest rank); ties → the later list, then the later position
            var best: (list: Int, idx: Int, rank: Int)? = nil
            for (k, l) in lists.enumerated() { for (i, id) in l.enumerated() {
                let r = rank(id)
                if best == nil || r > best!.rank || (r == best!.rank && (k, i) > (best!.list, best!.idx)) { best = (k, i, r) }
            } }
            if showPressure && (best == nil || pressureRank > best!.rank) { showPressure = false }
            else if let b = best { lists[b.list].remove(at: b.idx) }
            else { break }
            dropped += 1
            text = build(dropped)
        }
        return text
    }

    /// AM SMNetworkSpeedFormatter: bytes/s × 8 → bits; decimal thresholds bit < 1e3 ≤ kb < 1e6 ≤ Mb < 1e9 ≤ Gb < 1e12 ≤ Tb;
    /// 2 fraction digits, half-up; "%@/s" (en) / "%@/秒" (zh). A value that rounds to 1000.00 is promoted to the next
    /// unit (keeps the hero within its width; AM would print "1,000.00 kb/s" — documented deviation).
    static func speed(bytesPerSecond b: Double, _ lang: Lang) -> String {
        var v = max(0, b) * 8
        let units = ["bit", "kb", "Mb", "Gb", "Tb", "Pb"]
        var i = 0
        while i < units.count - 1 && (v * 100).rounded(.toNearestOrAwayFromZero) / 100 >= 1000 { v /= 1000; i += 1 }
        let num = fmt2(v)
        return "\(num) \(units[i])" + (lang == .zh ? "/秒" : "/s")
    }

    /// AM paddedPercent / fraction formatter: decimal, 2 fraction digits, half-up, grouping ",". Fixed en_US_POSIX symbols
    /// (a comma-decimal region would otherwise mix "4,99%" with the "." of the speed strings; byte counts are the
    /// exception: ByteCountFormatter follows the system region exactly as AM and the v1 memory view do).
    /// Cached: creating a NumberFormatter costs ~18 µs, a cached call ~0.4 µs (review_eng/fmtbench). NumberFormatter is
    /// thread-safe for formatting; it is used on main (StateBuilder) and sysQ (CPU/NET log lines).
    private static let f2: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.numberStyle = .decimal; f.usesGroupingSeparator = true; f.groupingSeparator = ","
        f.minimumFractionDigits = 2; f.maximumFractionDigits = 2; f.roundingMode = .halfUp
        return f
    }()
    /// AM integerFormatter (threads, processes, packets, packets/s).
    private static let f0: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.numberStyle = .decimal; f.usesGroupingSeparator = true; f.groupingSeparator = ","
        f.maximumFractionDigits = 0; f.roundingMode = .halfUp
        return f
    }()
    static func fmt2(_ v: Double) -> String { f2.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v) }
    static func int(_ v: Double) -> String { f0.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v) }
}
