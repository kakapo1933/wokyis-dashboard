// StatusMenu.swift — the menu-bar status item and its menu (spec §8.1). Owner: app agent.
//
// * NSStatusItem squareLength; template SF Symbol per view (memorychip / cpu / network), accessibility description =
//   the localized view name, accessibility identifier "wokyis.panel.statusitem", tooltip menuStatusTooltip.
// * Menu: 記憶體 / CPU / 網路 (radio, ⌃⌥⌘M/P/N) — 下一個畫面 ⌃⌥⌘V — 顯示側邊欄 ⌃⌥⌘B (checkbox) — 語言 ▸
//   (跟隨系統（English）/ 繁體中文 / English radio, —, 切換語言 ⌃⌥⌘L) — 結束 Wokyis 面板. The ⌃⌥⌘L equivalent sits on the
//   submenu's last item (an item that opens a submenu shows no key equivalent). Items whose hot key failed to register
//   (or --hotkeys no) get no key equivalent.
// * The structure comes from the pure `StatusMenuModel.entries` (selftest statusmenu.model). A language change rebuilds
//   the whole menu; any other change updates titles / states in place (safe while the menu is open).
// * Never activates the app, never touches a window or a Space (criterion 9). Selecting an item → onAction(action, "menu");
//   the root menu closing after a selection → onClose() (de-dup window restarts, SettingsModel.menuClosed).
import AppKit

/// Pure menu description (no AppKit): what StatusMenu builds and what the selftest checks.
struct MenuEntry: Equatable {
    var title: String
    var action: UIAction?
    var keyEquivalent: String = ""          // "" = none; lower-case letter with ⌃⌥⌘
    var checked = false
    var separator = false
    var children: [MenuEntry]? = nil
    static let sep = MenuEntry(title: "", action: nil, separator: true)
}

enum StatusMenuModel {
    static func viewName(_ v: ViewKind, _ l: Lang) -> String {
        switch v { case .memory: L10n.t(.menuMemory, l); case .cpu: L10n.t(.menuCPU, l); case .network: L10n.t(.menuNetwork, l) }
    }
    static func symbol(_ v: ViewKind) -> String {
        switch v { case .memory: "memorychip"; case .cpu: "cpu"; case .network: "network" }
    }
    static func tooltip(_ v: ViewKind, _ l: Lang) -> String { String(format: L10n.t(.menuStatusTooltip, l), viewName(v, l)) }

    /// `system` = SettingsModel.systemLang (the cached 跟隨系統 resolution the panel uses), never a live re-resolve.
    static func entries(_ s: UISettings, resolved l: Lang, system: Lang, hotkeysOK: Set<HotKeys.Key>) -> [MenuEntry] {
        func key(_ a: UIAction) -> String { HotKeys.Key.of(a).flatMap { hotkeysOK.contains($0) ? $0.letter : nil } ?? "" }
        func item(_ t: String, _ a: UIAction, checked: Bool = false) -> MenuEntry { MenuEntry(title: t, action: a, keyEquivalent: key(a), checked: checked) }
        var e: [MenuEntry] = ViewKind.allCases.map { item(viewName($0, l), .view($0), checked: s.view == $0) }
        e.append(.sep)
        e.append(item(L10n.t(.menuNextView, l), .nextView))
        e.append(item(L10n.t(.menuShowBattery, l), .toggleBattery, checked: s.batteryVisible))
        let sysTitle = "\(L10n.t(.menuLangSystem, l))（\(system == .zh ? L10n.t(.menuLangZh, l) : L10n.t(.menuLangEn, l))）"
        let lang: [MenuEntry] = [
            item(l == .zh ? sysTitle : sysTitle.replacingOccurrences(of: "（", with: " (").replacingOccurrences(of: "）", with: ")"),
                 .language(.system), checked: s.language == .system),
            item(L10n.t(.menuLangZh, l), .language(.zh), checked: s.language == .zh),
            item(L10n.t(.menuLangEn, l), .language(.en), checked: s.language == .en),
            .sep,
            item(L10n.t(.menuLangSwitch, l), .switchLanguage),
        ]
        e.append(MenuEntry(title: L10n.t(.menuLanguage, l), action: nil, children: lang))
        e.append(.sep)
        e.append(item(L10n.t(.menuQuit, l), .quit))
        return e
    }

    // MARK: selftest (statusmenu.model)
    static func selfTest() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        let all = Set(HotKeys.Key.allCases)
        let zh = entries(UISettings(view: .cpu, batteryVisible: true, language: .zh), resolved: .zh, system: .en, hotkeysOK: all)
        let titles = zh.filter { !$0.separator }.map(\.title)
        let radio = zh.prefix(3).map(\.checked)
        let keys = zh.filter { !$0.separator }.map(\.keyEquivalent)
        let sub = zh.first { $0.children != nil }?.children ?? []
        out.append(SelfTestCase("statusmenu.model", titles == ["記憶體", "CPU", "網路", "下一個畫面", "顯示側邊欄", "語言", "結束 Wokyis 面板"]
                                && radio == [false, true, false] && zh[5].checked && !zh[4].checked && keys == ["m", "p", "n", "v", "b", "", ""]
                                && zh[6].action == nil && zh.last?.action == .quit && zh[2].separator == false && zh[3].separator
                                && sub.count == 5 && sub[1].checked && !sub[0].checked && sub[3].separator
                                && sub[4].action == .switchLanguage && sub[4].keyEquivalent == "l" && sub[4].title == "切換語言"
                                && sub[0].title == "跟隨系統（English）" && sub[1].title == "繁體中文" && sub[2].title == "English",
                                "\(titles) keys=\(keys) sub=\(sub.map(\.title))"))
        // English menu, battery off, language = system; failed hot keys (P, L) → no key equivalent on those items
        let en = entries(UISettings(view: .network, batteryVisible: false, language: .system), resolved: .en, system: .en, hotkeysOK: all.subtracting([.cpu, .language]))
        let enSub = en.first { $0.children != nil }?.children ?? []
        out.append(SelfTestCase("statusmenu.model_en_failed_keys", en.map(\.title).filter { !$0.isEmpty } == ["Memory", "CPU", "Network", "Next View", "Show Side Column", "Language", "Quit Wokyis Panel"]
                                && en[2].checked && !en[5].checked && en[1].keyEquivalent == "" && en[0].keyEquivalent == "m"
                                && enSub[0].checked && enSub[0].title == "System (English)" && enSub[4].title == "Switch Language" && enSub[4].keyEquivalent == "",
                                "\(en.map(\.title)) sub=\(enSub.map(\.title))"))
        // --hotkeys no → no key equivalent anywhere
        let none = entries(UISettings(), resolved: .zh, system: .zh, hotkeysOK: [])
        out.append(SelfTestCase("statusmenu.no_hotkeys", (none + (none.first { $0.children != nil }?.children ?? [])).allSatisfy { $0.keyEquivalent.isEmpty }))
        out.append(SelfTestCase("statusmenu.symbols", ViewKind.allCases.map(symbol) == ["memorychip", "cpu", "network"]
                                && tooltip(.cpu, .zh) == "Wokyis 面板：CPU" && tooltip(.memory, .en) == "Wokyis Panel: Memory"))
        return out
    }
}

final class StatusMenu: NSObject, NSMenuDelegate {
    static let accessibilityID = "wokyis.panel.statusitem"
    private let onAction: (UIAction, String) -> Void
    private let onClose: () -> Void
    private var pickedWhileOpen = false           // an item was applied during this tracking session
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private var actions: [UIAction] = []          // NSMenuItem.tag → action
    private var built: (lang: Lang, hotkeys: Set<HotKeys.Key>)?
    private var current: (s: UISettings, lang: Lang, system: Lang, hotkeys: Set<HotKeys.Key>)?

    /// `onClose`: the menu finished tracking after one of its items was applied (restarts the de-dup window).
    init(onAction: @escaping (UIAction, _ via: String) -> Void, onClose: @escaping () -> Void = {}) {
        self.onAction = onAction
        self.onClose = onClose
        super.init()
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        it.behavior = []
        it.button?.setAccessibilityIdentifier(Self.accessibilityID)
        menu.delegate = self
        menu.autoenablesItems = false
        it.menu = menu
        item = it
    }

    /// Icon, check marks and titles; a language change (or a different hot-key set) rebuilds the whole menu.
    func update(_ s: UISettings, resolved: Lang, system: Lang, hotkeysOK: Set<HotKeys.Key>) {
        current = (s, resolved, system, hotkeysOK)
        if let b = item?.button {
            let name = StatusMenuModel.viewName(s.view, resolved)
            if let img = NSImage(systemSymbolName: StatusMenuModel.symbol(s.view), accessibilityDescription: name) {
                img.isTemplate = true
                b.image = img; b.title = ""
            } else {
                b.image = nil; b.title = "W"
            }
            b.setAccessibilityLabel(name)
            b.toolTip = StatusMenuModel.tooltip(s.view, resolved)
        }
        let entries = StatusMenuModel.entries(s, resolved: resolved, system: system, hotkeysOK: hotkeysOK)
        if built?.lang != resolved || built?.hotkeys != hotkeysOK || menu.items.count != entries.count {
            rebuild(entries)
            built = (resolved, hotkeysOK)
        } else {
            refresh(menu, entries)
        }
    }

    /// Removes the status item from the menu bar (exit, before STOP).
    func remove() {
        if let it = item { NSStatusBar.system.removeStatusItem(it) }
        item = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // re-applies the last update; the 跟隨系統（…） note is the cached resolution the panel uses (never live)
        if let c = current { refresh(self.menu, StatusMenuModel.entries(c.s, resolved: c.lang, system: c.system, hotkeysOK: c.hotkeys)) }
    }

    func menuWillOpen(_ menu: NSMenu) { pickedWhileOpen = false }

    /// Root menu only (submenus have no delegate). A Carbon hot key pressed while the menu tracks is delivered after
    /// this returns, so the de-dup window of the item just applied restarts here.
    func menuDidClose(_ menu: NSMenu) {
        if pickedWhileOpen { onClose() }
        pickedWhileOpen = false
    }

    private func rebuild(_ entries: [MenuEntry]) {
        menu.removeAllItems()
        actions = []
        for e in entries { menu.addItem(make(e)) }
    }

    private func make(_ e: MenuEntry) -> NSMenuItem {
        if e.separator { return .separator() }
        let mi = NSMenuItem(title: e.title, action: nil, keyEquivalent: "")
        if let kids = e.children {
            let sub = NSMenu(title: e.title)
            sub.autoenablesItems = false
            for k in kids { sub.addItem(make(k)) }
            mi.submenu = sub
            return mi
        }
        if let a = e.action {
            mi.target = self
            mi.action = #selector(choose(_:))
            mi.tag = actions.count
            actions.append(a)
        }
        apply(e, to: mi)
        return mi
    }

    private func apply(_ e: MenuEntry, to mi: NSMenuItem) {
        if mi.title != e.title { mi.title = e.title }
        mi.state = e.checked ? .on : .off
        mi.keyEquivalent = e.keyEquivalent
        mi.keyEquivalentModifierMask = e.keyEquivalent.isEmpty ? [] : [.control, .option, .command]
        mi.isEnabled = true
    }

    private func refresh(_ m: NSMenu, _ entries: [MenuEntry]) {
        guard m.items.count == entries.count else { return }
        for (mi, e) in zip(m.items, entries) where !e.separator {
            if let kids = e.children, let sub = mi.submenu { mi.title = e.title; refresh(sub, kids) } else { apply(e, to: mi) }
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        pickedWhileOpen = true
        onAction(actions[sender.tag], "menu")
    }
}
