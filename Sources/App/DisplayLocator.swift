// DisplayLocator.swift — find the Wokyis screen (spec §9.1). Owner: app agent.
// Order: (1) localizedName contains "Wokyis" AND CGDisplayVendorNumber == 4691 && CGDisplayModelNumber == 9557;
//        (2) name contains "Wokyis"; (3) a non-main 1280×720 screen at scale 1. `--display-id N` overrides (strict:
//        that display or nothing). The serial number is not used (both displays report 16843009).
import AppKit

enum DisplayLocator {
    static let vendor: UInt32 = 4691
    static let model: UInt32 = 9557

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func make(_ s: NSScreen) -> WokyisScreen? {
        guard let id = displayID(of: s) else { return nil }
        return WokyisScreen(screen: s, displayID: id, appKitFrame: s.frame, cgBounds: CGDisplayBounds(id))
    }

    static func locate(override: CGDirectDisplayID?) -> WokyisScreen? {
        let screens = NSScreen.screens
        if let o = override {
            return screens.first { displayID(of: $0) == o }.flatMap(make)
        }
        func named(_ s: NSScreen) -> Bool { s.localizedName.localizedCaseInsensitiveContains("wokyis") }
        if let s = screens.first(where: { s in
            guard named(s), let id = displayID(of: s) else { return false }
            return CGDisplayVendorNumber(id) == vendor && CGDisplayModelNumber(id) == model
        }) { return make(s) }
        if let s = screens.first(where: named) { return make(s) }
        let main = CGMainDisplayID()
        if let s = screens.first(where: { s in
            guard let id = displayID(of: s) else { return false }
            return id != main && s.frame.size == NSSize(width: 1280, height: 720) && s.backingScaleFactor == 1
        }) { return make(s) }
        return nil
    }

    /// "Wokyis id=2 frame=-1280,-385,1280,720 cg=-1280,745,1280,720 scale=1" (WIN lines).
    static func describe(_ w: WokyisScreen) -> String {
        func r(_ x: CGRect) -> String { "\(Int(x.minX)),\(Int(x.minY)),\(Int(x.width)),\(Int(x.height))" }
        return "screen=\(EventLog.q(w.screen.localizedName)) id=\(w.displayID) frame=\(r(w.appKitFrame)) cg=\(r(w.cgBounds)) scale=\(StartInfo.fmt(Double(w.screen.backingScaleFactor)))"
    }

    /// Signature of the whole screen configuration (ids + frames + scale) to tell real changes from notification noise.
    static func signature() -> String {
        NSScreen.screens.map { s in
            "\(displayID(of: s) ?? 0):\(Int(s.frame.minX)),\(Int(s.frame.minY)),\(Int(s.frame.width))x\(Int(s.frame.height))@\(s.backingScaleFactor)"
        }.joined(separator: ";")
    }
}
