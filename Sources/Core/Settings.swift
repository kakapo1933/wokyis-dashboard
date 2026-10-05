// Settings.swift — UI settings persistence and precedence (spec §7, §8.3). Owner: app agent.
// The value types (LanguagePref, UISettings, SettingsLayer, SettingsKey) live in Sources/Core/Types.swift.
//
// * Three layers: defaults (UISettings()) < stored (UserDefaults, domain io.github.kakapo1933.wokyis-panel) < cli (this
//   run's --view / --battery / --lang). The CLI layer is NEVER written back.
// * A runtime change (menu / hot key) touches exactly one field f: stored[f] = new value, settingsStore.save(f) writes
//   only that key, and cli[f] = nil (the runtime change wins over this run's CLI override of f; the other CLI overrides
//   stay in effect for this run and are still never persisted).
// * --selftest, --snapshot and --headless never construct a DefaultsSettingsStore (no UserDefaults read or write).
// * `SettingsModel.apply` is pure apart from the injected store: it is what AppController calls and what the selftest
//   drives with a MemorySettingsStore (settings.cli_not_persisted, ui.dedup, ui.switch_language).
import Foundation

/// A UI action from the status menu or a hot key (spec §8.1). Pure value (also used by the selftest).
enum UIAction: Equatable, Sendable {
    case view(ViewKind), nextView, toggleBattery, language(LanguagePref), switchLanguage, quit
    /// About submenu: copy the version line to the pasteboard. Changes no setting (AppController handles it).
    case copyAbout
    /// Short log token (UI event=dedup action=…).
    var token: String {
        switch self {
        case .view(let v): "view_\(v.token)"
        case .nextView: "next_view"
        case .toggleBattery: "toggle_battery"
        case .language(let l): "lang_\(l.rawValue)"
        case .switchLanguage: "switch_language"
        case .quit: "quit"
        case .copyAbout: "copy_about"
        }
    }
}

protocol SettingsStore: AnyObject {
    /// Only the keys that exist in the store AND hold a valid value; every invalid value → a warning
    /// ("key=ui.view value=gpu") and the key is treated as absent.
    func load() -> (layer: SettingsLayer, warnings: [String])
    /// Writes exactly one key (never the whole layer). `value` is the canonical string (Settings.string(for:in:)).
    func save(_ key: SettingsKey, _ value: String)
}

/// UserDefaults of the app domain through CFPreferences (works the same whether the binary runs inside the bundle or
/// not). Booleans are stored as property-list booleans, the other keys as strings.
final class DefaultsSettingsStore: SettingsStore {
    static let domain = "io.github.kakapo1933.wokyis-panel"
    let domain: String
    init(domain: String = DefaultsSettingsStore.domain) { self.domain = domain }

    func load() -> (layer: SettingsLayer, warnings: [String]) {
        var raw: [String: Any] = [:]
        for k in SettingsKey.allCases {
            if let v = CFPreferencesCopyAppValue(k.rawValue as CFString, domain as CFString) { raw[k.rawValue] = v }
        }
        return Settings.parse(raw)
    }

    func save(_ key: SettingsKey, _ value: String) {
        let v: CFPropertyList = key == .batteryVisible ? ((value == "true") as CFBoolean) : (value as CFString)
        CFPreferencesSetAppValue(key.rawValue as CFString, v, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }
}

/// In-memory store for the selftest: records every save (key order) and never touches UserDefaults.
final class MemorySettingsStore: SettingsStore {
    var values: [String: Any]
    private(set) var saves: [(SettingsKey, String)] = []
    init(_ values: [String: Any] = [:]) { self.values = values }
    func load() -> (layer: SettingsLayer, warnings: [String]) { Settings.parse(values) }
    func save(_ key: SettingsKey, _ value: String) {
        saves.append((key, value))
        values[key.rawValue] = key == .batteryVisible ? (value == "true") : value
    }
}

enum Settings {
    /// defaults < stored < cli, field by field.
    static func effective(defaults: UISettings, stored: SettingsLayer, cli: SettingsLayer) -> UISettings {
        UISettings(view: cli.view ?? stored.view ?? defaults.view,
                   batteryVisible: cli.batteryVisible ?? stored.batteryVisible ?? defaults.batteryVisible,
                   language: cli.language ?? stored.language ?? defaults.language)
    }

    /// `.system` looks at the FIRST preferred language only: zh… → .zh, anything else (also an empty list) → .en —
    /// macOS's own rule for an app without that localization (spec §7). This Mac: ["en-TW", "zh-Hant-TW", …] → .en.
    static func resolve(_ p: LanguagePref, preferred: [String] = Locale.preferredLanguages) -> Lang {
        switch p {
        case .zh: return .zh
        case .en: return .en
        case .system: return (preferred.first?.lowercased().hasPrefix("zh") ?? false) ? .zh : .en
        }
    }

    /// Raw UserDefaults values → layer + warnings. Accepted: ui.view memory|cpu|network; ui.batteryVisible a boolean
    /// (property-list bool, or the strings true|false|yes|no|1|0); ui.language system|zh|en.
    static func parse(_ raw: [String: Any]) -> (layer: SettingsLayer, warnings: [String]) {
        var l = SettingsLayer(), w: [String] = []
        func bad(_ k: SettingsKey, _ v: Any) { w.append("key=\(k.rawValue) value=\(EventLog.q("\(v)"))") }
        if let v = raw[SettingsKey.view.rawValue] {
            if let s = v as? String, let k = ViewKind(rawValue: s) { l.view = k } else { bad(.view, v) }
        }
        if let v = raw[SettingsKey.batteryVisible.rawValue] {
            if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { l.batteryVisible = n.boolValue }
            else if let s = v as? String, let b = bool(s) { l.batteryVisible = b }
            else { bad(.batteryVisible, v) }
        }
        if let v = raw[SettingsKey.language.rawValue] {
            if let s = v as? String, let p = LanguagePref(rawValue: s) { l.language = p } else { bad(.language, v) }
        }
        return (l, w)
    }

    static func bool(_ s: String) -> Bool? {
        switch s.lowercased() { case "true", "yes", "1": true; case "false", "no", "0": false; default: nil }
    }

    /// Canonical stored string of one field of a layer (nil = field absent).
    static func string(for k: SettingsKey, in l: SettingsLayer) -> String? {
        switch k {
        case .view: l.view?.rawValue
        case .batteryVisible: l.batteryVisible.map { $0 ? "true" : "false" }
        case .language: l.language?.rawValue
        }
    }

    /// Per-field source for the START line: "view:cli,battery:stored,lang:default".
    static func sources(stored: SettingsLayer, cli: SettingsLayer) -> String {
        func src(_ k: SettingsKey) -> String {
            string(for: k, in: cli) != nil ? "cli" : (string(for: k, in: stored) != nil ? "stored" : "default")
        }
        return "view:\(src(.view)),battery:\(src(.batteryVisible)),lang:\(src(.language))"
    }
}

/// The three layers + the runtime change rule + menu / hot-key de-duplication (spec §7, §8.3). Main thread only.
final class SettingsModel {
    let defaults: UISettings
    private(set) var stored: SettingsLayer
    private(set) var cli: SettingsLayer
    /// nil = never persist (headless / snapshot / selftest without a store).
    let store: SettingsStore?
    let preferred: () -> [String]
    /// A second identical action from ANOTHER source within this window is the same key press seen twice (the menu's
    /// key equivalent fires while the menu tracks, and the Carbon hot key fires too) → ignored (spec §8.3 step 0).
    /// For a menu action the window runs from when the menu finished closing (`menuClosed`): measured 2026-10-02, a
    /// Carbon hot key pressed while the menu tracks is held until tracking ends, and a submenu item (切換語言) is applied
    /// ~38 ms after the click while its menu closes ~245 ms later, so a window counted from the action missed it.
    static let dedupWindow: Double = 0.150
    private var last: (action: UIAction, via: String, at: Double)?

    enum Outcome: Equatable {
        case changed(key: SettingsKey, from: String, to: String)   // log tokens (view mem|cpu|net, battery 1|0, lang system|zh|en)
        case unchanged
        case dedup(firstVia: String)
        case quit
    }

    /// What 跟隨系統 resolves to: read once at init and again only on an explicit language action (menu 跟隨系統,
    /// ⌃⌥⌘L), never live. A macOS language reorder while the panel runs therefore cannot flip the panel as a side
    /// effect of an unrelated action (battery / view), and the menu note 「跟隨系統（…）」 shows this same value.
    private(set) var systemLang: Lang

    init(defaults: UISettings = UISettings(), stored: SettingsLayer, cli: SettingsLayer, store: SettingsStore?,
         preferred: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults; self.stored = stored; self.cli = cli; self.store = store; self.preferred = preferred
        systemLang = Settings.resolve(.system, preferred: preferred())
    }

    var effective: UISettings { Settings.effective(defaults: defaults, stored: stored, cli: cli) }
    var resolvedLang: Lang { effective.language == .system ? systemLang : Settings.resolve(effective.language, preferred: []) }
    var sources: String { Settings.sources(stored: stored, cli: cli) }

    /// The status menu finished closing at `t` (monotonic seconds) after one of its items was applied: the de-dup window
    /// of that menu action restarts here.
    func menuClosed(at t: Double) {
        if let l = last, l.via == "menu", t >= l.at { last = (l.action, l.via, t) }
    }

    /// `at` = monotonic seconds. Changes at most one field; persists only that key.
    func apply(_ a: UIAction, via: String, at t: Double) -> Outcome {
        if let l = last, l.action == a, l.via != via, t - l.at >= 0, t - l.at < Self.dedupWindow { return .dedup(firstVia: l.via) }
        last = (a, via, t)
        let cur = effective
        var next = cur
        let sysBefore = systemLang
        switch a {
        case .quit: return .quit
        case .copyAbout: return .unchanged
        case .view(let v): next.view = v
        case .nextView: next.view = cur.view.next
        case .toggleBattery: next.batteryVisible.toggle()
        case .language(let p):
            systemLang = Settings.resolve(.system, preferred: preferred())     // explicit language action → re-resolve
            next.language = p
        case .switchLanguage:
            next.language = resolvedLang == .zh ? .en : .zh   // never .system (spec §8.1); toggles what is SHOWN
            systemLang = Settings.resolve(.system, preferred: preferred())     // refresh the 跟隨系統（…） note
        }
        let key: SettingsKey
        let from: String, to: String
        if next.view != cur.view {
            key = .view; from = cur.view.token; to = next.view.token
            stored.view = next.view; cli.view = nil
        } else if next.batteryVisible != cur.batteryVisible {
            key = .batteryVisible; from = cur.batteryVisible ? "1" : "0"; to = next.batteryVisible ? "1" : "0"
            stored.batteryVisible = next.batteryVisible; cli.batteryVisible = nil
        } else if next.language != cur.language {
            key = .language; from = cur.language.rawValue; to = next.language.rawValue
            stored.language = next.language; cli.language = nil
        } else if cur.language == .system, systemLang != sysBefore, case .language(.system) = a {
            // re-selecting 跟隨系統 after a macOS language reorder: same preference, new resolution → apply it (logged)
            return .changed(key: .language, from: LanguagePref.system.rawValue, to: LanguagePref.system.rawValue)
        } else {
            return .unchanged
        }
        if let s = Settings.string(for: key, in: stored) { store?.save(key, s) }
        return .changed(key: key, from: from, to: to)
    }
}

// MARK: - self test (spec §10.1: settings.*, ui.*) — MemorySettingsStore only, never UserDefaults

enum SettingsSelfTest {
    static func run() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        func expect(_ n: String, _ ok: Bool, _ d: String = "") { out.append(SelfTestCase(n, ok, d)) }
        let en: () -> [String] = { ["en-TW", "zh-Hant-TW", "ja-TW"] }

        // roundtrip: a runtime change writes one key; a fresh load of that store reads it back
        let mem = MemorySettingsStore()
        let m0 = SettingsModel(stored: mem.load().layer, cli: SettingsLayer(), store: mem, preferred: en)
        let r1 = m0.apply(.view(.network), via: "menu", at: 0)
        let r2 = m0.apply(.toggleBattery, via: "menu", at: 1)
        let r3 = m0.apply(.language(.en), via: "menu", at: 2)
        let back = mem.load()
        expect("settings.roundtrip", r1 == .changed(key: .view, from: "mem", to: "net") && r2 == .changed(key: .batteryVisible, from: "1", to: "0")
               && r3 == .changed(key: .language, from: "zh", to: "en") && back.warnings.isEmpty
               && back.layer == SettingsLayer(view: .network, batteryVisible: false, language: .en)
               && mem.saves.map(\.0) == [.view, .batteryVisible, .language] && mem.saves.map(\.1) == ["network", "false", "en"],
               "\(mem.saves) \(back.layer)")
        // precedence: defaults < stored < cli, field by field
        let eff = Settings.effective(defaults: UISettings(), stored: SettingsLayer(view: .cpu, batteryVisible: nil, language: .en),
                                     cli: SettingsLayer(view: .network, batteryVisible: nil, language: nil))
        let eff2 = Settings.effective(defaults: UISettings(), stored: SettingsLayer(), cli: SettingsLayer())
        expect("settings.precedence", eff == UISettings(view: .network, batteryVisible: true, language: .en) && eff2 == UISettings()
               && eff2.language == .zh && Settings.sources(stored: SettingsLayer(view: .cpu, batteryVisible: false),
                                                            cli: SettingsLayer(view: .network)) == "view:cli,battery:stored,lang:default",
               "\(eff)")
        // invalid stored values → that key absent + a warning each; valid keys still load; booleans as bool or text
        let bad = Settings.parse(["ui.view": "gpu", "ui.batteryVisible": "maybe", "ui.language": 5])
        let mixed = Settings.parse(["ui.view": "cpu", "ui.batteryVisible": NSNumber(value: false), "ui.language": "fr"])
        let txt = Settings.parse(["ui.batteryVisible": "no", "ui.language": "system"])
        expect("settings.invalid", bad.layer == SettingsLayer() && bad.warnings.count == 3 && bad.warnings[0].hasPrefix("key=ui.view value=")
               && mixed.layer == SettingsLayer(view: .cpu, batteryVisible: false, language: nil) && mixed.warnings == ["key=ui.language value=\"fr\""]
               && txt.layer == SettingsLayer(view: nil, batteryVisible: false, language: .system) && txt.warnings.isEmpty,
               "\(bad.warnings) \(mixed.warnings)")
        // CLI never persisted: stored {view: memory}, cli {view: cpu, lang: en}
        let st = MemorySettingsStore(["ui.view": "memory"])
        let m = SettingsModel(stored: st.load().layer, cli: SettingsLayer(view: .cpu, batteryVisible: nil, language: .en), store: st, preferred: en)
        let a1 = m.apply(.toggleBattery, via: "hotkey", at: 10)
        let ok1 = st.saves.count == 1 && st.saves[0].0 == .batteryVisible && st.saves[0].1 == "false"
            && m.effective == UISettings(view: .cpu, batteryVisible: false, language: .en)
            && m.stored.view == .memory && m.stored.language == nil && m.cli.view == .cpu && m.cli.language == .en
        let a2 = m.apply(.nextView, via: "hotkey", at: 11)
        let ok2 = st.saves.count == 2 && st.saves[1].0 == .view && st.saves[1].1 == "network" && m.cli.view == nil
            && m.effective == UISettings(view: .network, batteryVisible: false, language: .en) && m.cli.language == .en
            && st.values["ui.language"] == nil && (st.values["ui.view"] as? String) == "network"
        expect("settings.cli_not_persisted", a1 == .changed(key: .batteryVisible, from: "1", to: "0") && ok1
               && a2 == .changed(key: .view, from: "cpu", to: "net") && ok2, "\(st.saves) eff=\(m.effective)")
        // de-dup: the same action from the other source within 150 ms is one key press seen twice
        let d = SettingsModel(stored: SettingsLayer(), cli: SettingsLayer(), store: MemorySettingsStore(), preferred: en)
        let d1 = d.apply(.toggleBattery, via: "menu", at: 100.000)
        let d2 = d.apply(.toggleBattery, via: "hotkey", at: 100.100)
        let afterDup = d.effective.batteryVisible
        let d3 = d.apply(.toggleBattery, via: "hotkey", at: 100.300)
        let d4 = d.apply(.toggleBattery, via: "hotkey", at: 100.350)   // same source twice = two presses
        expect("ui.dedup", d1 == .changed(key: .batteryVisible, from: "1", to: "0") && d2 == .dedup(firstVia: "menu") && !afterDup
               && d3 == .changed(key: .batteryVisible, from: "0", to: "1") && d4 == .changed(key: .batteryVisible, from: "1", to: "0"),
               "\([d1, d2, d3, d4])")
        // submenu item: applied at 200.000, menu closed at 200.245, the held hot key arrives at 200.270 → one press
        let s = SettingsModel(stored: SettingsLayer(), cli: SettingsLayer(), store: MemorySettingsStore(), preferred: en)
        let s1 = s.apply(.switchLanguage, via: "menu", at: 200.000)
        s.menuClosed(at: 200.245)
        let s2 = s.apply(.switchLanguage, via: "hotkey", at: 200.270)
        let s3 = s.apply(.switchLanguage, via: "hotkey", at: 200.600)          // a later press counts again
        // without a menu close the window still runs from the action; a close after a hot key does not extend it
        let n = SettingsModel(stored: SettingsLayer(), cli: SettingsLayer(), store: MemorySettingsStore(), preferred: en)
        let n1 = n.apply(.toggleBattery, via: "menu", at: 300.000)
        let n2 = n.apply(.toggleBattery, via: "hotkey", at: 300.245)
        n.menuClosed(at: 300.300)                                              // last = the hot key → not restarted
        let n3 = n.apply(.toggleBattery, via: "menu", at: 300.400)             // 155 ms after the hot key → counts
        expect("ui.dedup_menu_close", s1 == .changed(key: .language, from: "zh", to: "en") && s2 == .dedup(firstVia: "menu")
               && s3 == .changed(key: .language, from: "en", to: "zh")
               && n1 == .changed(key: .batteryVisible, from: "1", to: "0") && n2 == .changed(key: .batteryVisible, from: "0", to: "1")
               && n3 == .changed(key: .batteryVisible, from: "1", to: "0"),
               "\([s1, s2, s3, n1, n2, n3])")
        // switch language: zh ↔ en on the RESOLVED language; never .system
        func sw(_ p: LanguagePref, _ pref: [String]) -> LanguagePref {
            let x = SettingsModel(stored: SettingsLayer(view: nil, batteryVisible: nil, language: p), cli: SettingsLayer(), store: nil, preferred: { pref })
            _ = x.apply(.switchLanguage, via: "hotkey", at: 0)
            return x.effective.language
        }
        let swr = [sw(.system, ["en-TW", "zh-Hant-TW"]), sw(.en, []), sw(.zh, []), sw(.system, ["zh-Hant-TW"]), sw(.system, [])]
        expect("ui.switch_language", swr == [.zh, .zh, .en, .en, .zh], "\(swr)")
        expect("settings.resolve", Settings.resolve(.system, preferred: ["en-TW", "zh-Hant-TW"]) == .en
               && Settings.resolve(.system, preferred: ["zh-Hant-TW"]) == .zh && Settings.resolve(.system, preferred: ["zh-Hans-CN"]) == .zh
               && Settings.resolve(.system, preferred: []) == .en && Settings.resolve(.zh, preferred: ["en"]) == .zh
               && Settings.resolve(.en, preferred: ["zh-Hant"]) == .en)
        // 跟隨系統 is resolved at init / on an explicit language action only: a macOS reorder mid-run does not flip the
        // panel on an unrelated action; re-selecting 跟隨系統 applies it (.changed system→system, logged)
        var live = ["en-TW", "zh-Hant-TW"]
        let r = SettingsModel(stored: SettingsLayer(view: nil, batteryVisible: nil, language: .system), cli: SettingsLayer(),
                              store: MemorySettingsStore(), preferred: { live })
        live = ["zh-Hant-TW", "en-TW"]
        let rb = r.apply(.toggleBattery, via: "hotkey", at: 0)
        let afterBattery = (r.resolvedLang, r.systemLang)
        let rs = r.apply(.language(.system), via: "menu", at: 1)
        let rs2 = r.apply(.language(.system), via: "menu", at: 2)
        expect("ui.lang_system_cached", rb == .changed(key: .batteryVisible, from: "1", to: "0") && afterBattery == (.en, .en)
               && rs == .changed(key: .language, from: "system", to: "system") && r.resolvedLang == .zh && r.systemLang == .zh
               && rs2 == .unchanged, "battery=\(afterBattery) rs=\(rs) rs2=\(rs2)")
        // view cycling (⌃⌥⌘V): memory → cpu → network → memory; selecting the current view changes nothing
        let c = SettingsModel(stored: SettingsLayer(), cli: SettingsLayer(), store: MemorySettingsStore(), preferred: en)
        var seen: [ViewKind] = []
        for i in 0..<3 { _ = c.apply(.nextView, via: "hotkey", at: Double(i)); seen.append(c.effective.view) }
        let same = c.apply(.view(.memory), via: "menu", at: 10)
        let quit = c.apply(.quit, via: "menu", at: 20)
        expect("ui.view_cycle", seen == [.cpu, .network, .memory] && same == .unchanged && quit == .quit, "\(seen)")
        return out
    }
}
