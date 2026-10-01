// AccessorySource.swift — IOPSCopyPowerSourcesByType(0x4) via dlsym + IOPS/IOPSAcc run-loop notifications (spec §6.1, §6.2).
// Owner: battery agent.
//
// read(): private `IOPSCopyPowerSourcesByType(4)` (accessory sources; dlsym, never linked directly) →
// IOPSCopyPowerSourcesList + IOPSGetPowerSourceDescription → a CFArray of description dictionaries → `parse`.
// A missing symbol is SourceError.missingSymbol (never a crash). `garbage bat.iops` feeds a CFString to the same parser
// in place of that array → .parse.
// Each entry becomes AccPart(s): "Combined" → its "Combined Parts" Left / Right; "Case" → .case (name without " Case");
// no Part Identifier (keyboard, trackpad, single-battery headphones) → .single with accessoryID = normalised BT address.
// groupKey = "0x<PID>:<name without trailing ' Case'>" (spec §6.2), e.g. "0x2024:Alex’s AirPods Pro".
// Notifications: public IOPSNotificationCreateRunLoopSource + private IOPSAccNotificationCreateRunLoopSource (dlsym), both
// added to the MAIN run loop (common modes); the callback runs on main and calls `onMain` (the monitor hops to batQ).
import Foundation
import IOKit.ps

final class AccessorySource: @unchecked Sendable {
    let injector: Injector
    typealias ByTypeFn = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    typealias AccNotifyFn = @convention(c) (@convention(c) (UnsafeMutableRawPointer?) -> Void, UnsafeMutableRawPointer?) -> Unmanaged<CFRunLoopSource>?
    static let accessoryType: Int32 = 0x4
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
    static let byType: ByTypeFn? = {
        guard let p = dlsym(rtldDefault, "IOPSCopyPowerSourcesByType") else { return nil }
        return unsafeBitCast(p, to: ByTypeFn.self)
    }()
    static let accNotify: AccNotifyFn? = {
        guard let p = dlsym(rtldDefault, "IOPSAccNotificationCreateRunLoopSource") else { return nil }
        return unsafeBitCast(p, to: AccNotifyFn.self)
    }()

    // main-thread only
    private final class Box { let fire: () -> Void; init(_ f: @escaping () -> Void) { fire = f } }
    private var box: Box?
    private var sources: [CFRunLoopSource] = []
    /// names of the notification sources that were installed ("iops", "iops_acc"); "iops_acc" missing → symbol absent
    private(set) var installed: [String] = []

    init(injector: Injector) { self.injector = injector }

    /// First line: try injector.check(.batIOPS); honours injector.mode(.batIOPS) == .garbage.
    func read() throws -> [AccPart] {
        try injector.check(.batIOPS)
        let raw: CFTypeRef = injector.mode(.batIOPS) == .garbage ? ("garbage" as CFString) : try Self.fetch()
        return try Self.parse(raw)
    }

    /// The real IOPS call. Returns a CFArray of description CFDictionaries (empty when the list is empty).
    /// A NULL blob or NULL list is a failed read (SourceError.parse, `ERR src=bat.iops err=parse`), never an empty
    /// success: an empty success would make every AirPods group look GONE (README 8.5.1).
    static func fetch(using byTypeFn: ByTypeFn? = byType) throws -> CFTypeRef {
        guard let f = byTypeFn else { throw SourceError.missingSymbol("IOPSCopyPowerSourcesByType") }
        guard let blob = f(accessoryType)?.takeRetainedValue() else { throw SourceError.parse("IOPSCopyPowerSourcesByType returned NULL") }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            throw SourceError.parse("IOPSCopyPowerSourcesList returned NULL")
        }
        let descs: [NSDictionary] = list.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as NSDictionary? }
        return descs as CFArray
    }

    /// The parser (pure). Input must be a CFArray of CFDictionary; anything else → .parse.
    static func parse(_ raw: CFTypeRef) throws -> [AccPart] {
        guard CFGetTypeID(raw) == CFArrayGetTypeID(), let arr = raw as? [Any] else {
            throw SourceError.parse("power source list is not an array (\(CFCopyTypeIDDescription(CFGetTypeID(raw)) as String? ?? "?"))")
        }
        var out: [AccPart] = []
        for item in arr {
            guard let d = item as? [String: Any] else { throw SourceError.parse("power source entry is not a dictionary") }
            let rawName = d["Name"] as? String ?? ""
            let partID = d["Part Identifier"] as? String
            let base = (partID == "Case" && rawName.hasSuffix(" Case")) ? String(rawName.dropLast(5)) : rawName
            let pid = normalizeProductID(d["Product ID"]) ?? "0x????"
            let key = "\(pid):\(base)"
            let accID = normalizeAddress(d["Accessory Identifier"] as? String ?? "")
            let sid = (d["Power Source ID"] as? NSNumber)?.intValue
            func cap(_ x: [String: Any]) -> Int? {
                guard let n = (x["Current Capacity"] as? NSNumber)?.intValue else { return nil }
                return max(0, min(100, n))
            }
            func chg(_ x: [String: Any]) -> Bool { (x["Is Charging"] as? NSNumber)?.boolValue ?? false }
            switch partID {
            case "Combined"?:
                for p in (d["Combined Parts"] as? [Any] ?? []) {
                    guard let pd = p as? [String: Any], let c = cap(pd) else { continue }
                    let which: PodPart
                    switch pd["Part Identifier"] as? String {
                    case "Left"?: which = .left
                    case "Right"?: which = .right
                    case "Case"?: which = .case
                    default: continue
                    }
                    out.append(AccPart(groupKey: key, name: base, accessoryID: accID, part: which, percent: c, charging: chg(pd),
                                       sourceID: sid, entryPart: "Combined"))
                }
            case "Case"?, "Left"?, "Right"?:
                guard let c = cap(d) else { continue }
                let which: PodPart = partID == "Case" ? .case : (partID == "Left" ? .left : .right)
                out.append(AccPart(groupKey: key, name: base, accessoryID: accID, part: which, percent: c, charging: chg(d),
                                   sourceID: sid, entryPart: partID))
            default:
                guard let c = cap(d) else { continue }
                out.append(AccPart(groupKey: key, name: base, accessoryID: accID, part: .single, percent: c, charging: chg(d),
                                   sourceID: sid, entryPart: nil))
            }
        }
        return out
    }

    /// Adds IOPSNotificationCreateRunLoopSource + (dlsym) IOPSAccNotificationCreateRunLoopSource to the MAIN run loop.
    /// Must be called on the main thread. `onMain` runs on main for every notification.
    func installNotifications(onMain: @escaping () -> Void) {
        precondition(Thread.isMainThread, "installNotifications must run on main")
        removeNotifications()
        let b = Box(onMain); box = b
        let ctx = Unmanaged.passUnretained(b).toOpaque()
        let cb: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
            guard let ctx else { return }
            Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue().fire()
        }
        if let src = IOPSNotificationCreateRunLoopSource(cb, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes); sources.append(src); installed.append("iops")
        }
        if let f = Self.accNotify, let src = f(cb, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes); sources.append(src); installed.append("iops_acc")
        }
    }

    /// Remove the run-loop sources (main thread).
    func removeNotifications() {
        for s in sources { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes); CFRunLoopSourceInvalidate(s) }
        sources = []; installed = []
        box = nil
    }
}
