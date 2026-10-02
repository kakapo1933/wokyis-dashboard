// HotKeys.swift — global hot keys ⌃⌥⌘ M / P / N / V / B / L through Carbon RegisterEventHotKey (spec §8.2).
// Owner: app agent.
//
// * No Accessibility permission is needed (Carbon hot keys, not an event tap). Keys are PHYSICAL key positions
//   (kVK_ANSI_*): on AZERTY / Dvorak the letter printed in the menu may sit elsewhere (README).
// * InstallEventHandler on the application event target with userData = passUnretained(self): unregisterAll() removes
//   every hot key AND the handler, and deinit calls it, so the callback can never see a freed object. AppController keeps
//   a strong reference until finishExit (unregisterAll before STOP).
// * Conflicts with another app cannot be detected at run time (measured: a second registration of the same chord in
//   another process still returns 0 and both fire) — only logged per key: `UI event=hotkey_register key=M status=0`;
//   a non-zero status → `WARN hotkey_failed key=M os=<OSStatus>` and the menu shows no key equivalent for that item.
// * A press arrives on the main thread (application event target, main run loop) → onKey(key).
import AppKit
import Carbon.HIToolbox

final class HotKeys {
    enum Key: UInt32, CaseIterable {
        case memory = 1, cpu, network, next, battery, language
        /// Letter shown in the menu (lower case = AppKit key equivalent) and in logs.
        var letter: String {
            switch self { case .memory: "m"; case .cpu: "p"; case .network: "n"; case .next: "v"; case .battery: "b"; case .language: "l" }
        }
        var keyCode: UInt32 {
            switch self {
            case .memory: UInt32(kVK_ANSI_M); case .cpu: UInt32(kVK_ANSI_P); case .network: UInt32(kVK_ANSI_N)
            case .next: UInt32(kVK_ANSI_V); case .battery: UInt32(kVK_ANSI_B); case .language: UInt32(kVK_ANSI_L)
            }
        }
        var action: UIAction {
            switch self {
            case .memory: .view(.memory); case .cpu: .view(.cpu); case .network: .view(.network)
            case .next: .nextView; case .battery: .toggleBattery; case .language: .switchLanguage
            }
        }
        /// The hot key of a menu action (nil = the action has none).
        static func of(_ a: UIAction) -> Key? { allCases.first { $0.action == a } }
    }

    /// 'WKYS'
    static let signature: OSType = 0x574B_5953
    static let modifiers = UInt32(cmdKey | optionKey | controlKey)

    private let onKey: (Key) -> Void
    private var refs: [Key: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    init(onKey: @escaping (Key) -> Void) { self.onKey = onKey }
    deinit { unregisterAll() }

    /// Registers every key; returns the ones that succeeded. `register` replaces RegisterEventHotKey (selftest fake);
    /// with a fake no Carbon handler is installed.
    @discardableResult
    func registerAll(log: EventLog?, register fake: ((Key) -> OSStatus)? = nil) -> Set<Key> {
        if fake == nil && handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let st = InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
            if st != noErr {
                log?.event("WARN", "hotkey_failed key=handler os=\(st)")
                return []
            }
        }
        var ok: Set<Key> = []
        for k in Key.allCases {
            let st: OSStatus
            if let fake { st = fake(k) } else {
                var ref: EventHotKeyRef?
                st = RegisterEventHotKey(k.keyCode, Self.modifiers, EventHotKeyID(signature: Self.signature, id: k.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
                if st == noErr, let ref { refs[k] = ref }
            }
            log?.event("UI", "event=hotkey_register key=\(k.letter.uppercased()) status=\(st)")
            if st == noErr { ok.insert(k) } else { log?.event("WARN", "hotkey_failed key=\(k.letter.uppercased()) os=\(st)") }
        }
        return ok
    }

    /// UnregisterEventHotKey for every ref + RemoveEventHandler. Idempotent.
    func unregisterAll() {
        for (_, r) in refs { UnregisterEventHotKey(r) }
        refs = [:]
        if let h = handler { RemoveEventHandler(h); handler = nil }
    }

    fileprivate func fire(_ id: UInt32) {
        guard let k = Key(rawValue: id) else { return }
        if Thread.isMainThread { onKey(k) } else { DispatchQueue.main.async { [weak self] in self?.onKey(k) } }
    }

    // MARK: selftest (hotkeys.mapping) — pure table + fake registrar, no Carbon registration

    static func selfTest() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        let letters = Key.allCases.map(\.letter).joined()
        let codes = Key.allCases.map(\.keyCode)
        let actions = Key.allCases.map(\.action)
        out.append(SelfTestCase("hotkeys.mapping", letters == "mpnvbl"
                                && codes == [UInt32(kVK_ANSI_M), UInt32(kVK_ANSI_P), UInt32(kVK_ANSI_N), UInt32(kVK_ANSI_V), UInt32(kVK_ANSI_B), UInt32(kVK_ANSI_L)]
                                && actions == [.view(.memory), .view(.cpu), .view(.network), .nextView, .toggleBattery, .switchLanguage]
                                && Key.of(.quit) == nil && Key.of(.language(.en)) == nil && Key.of(.toggleBattery) == .battery
                                && modifiers == UInt32(cmdKey | optionKey | controlKey) && signature == 0x574B_5953,
                                "letters=\(letters)"))
        // fake registrar: P and L fail → only those two are missing; nothing is installed in Carbon
        let hk = HotKeys { _ in }
        let ok = hk.registerAll(log: nil) { k in (k == .cpu || k == .language) ? OSStatus(eventHotKeyExistsErr) : noErr }
        out.append(SelfTestCase("hotkeys.fake_registrar", ok == [.memory, .network, .next, .battery] && hk.refs.isEmpty && hk.handler == nil,
                                "\(ok.map(\.letter).sorted())"))
        // fire maps the Carbon id to the key on main
        var got: [Key] = []
        let hk2 = HotKeys { got.append($0) }
        hk2.fire(Key.battery.rawValue); hk2.fire(99)
        out.append(SelfTestCase("hotkeys.fire", got == [.battery]))
        return out
    }
}

/// Carbon callback (C function pointer: no captures). userData = Unmanaged<HotKeys>.passUnretained.
private func hotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                               MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard st == noErr, id.signature == HotKeys.signature else { return OSStatus(eventNotHandledErr) }
    Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue().fire(id.id)
    return noErr
}
