// HIDSource.swift — IOKit AppleDeviceManagementHIDEventService + matching/terminated notifications on batQ (spec §6.1).
// Owner: battery agent.
//
// read(): IOServiceGetMatchingServices + IORegistryEntryCreateCFProperty (BatteryPercent, Product, DeviceAddress,
// "Accessory Category", BatteryStatusFlags); only services that report BatteryPercent are devices.
// Notifications: one IONotificationPort whose callbacks run on `queue` (IONotificationPortSetDispatchQueue);
// kIOFirstMatchNotification + kIOTerminatedNotification for the same class; both iterators are drained once at
// install (arming them) and `onChange` is invoked on `queue` for every later arrival / removal.
import Foundation
import IOKit

final class HIDSource: @unchecked Sendable {
    static let serviceClass = "AppleDeviceManagementHIDEventService"
    let queue: DispatchQueue
    let injector: Injector
    let onChange: @Sendable () -> Void
    private var port: IONotificationPortRef?
    private var addIt: io_iterator_t = 0
    private var remIt: io_iterator_t = 0
    private let key = DispatchSpecificKey<UInt8>()
    /// last notification kind seen ("matched" / "terminated") — informational for DEV lines
    private(set) var notifications: (matched: Int, terminated: Int) = (0, 0)

    /// Installs kIOFirstMatch/kIOTerminated notifications with IONotificationPortSetDispatchQueue(queue);
    /// onChange is invoked on `queue` when a service appears or disappears.
    init(queue: DispatchQueue, injector: Injector, onChange: @escaping @Sendable () -> Void) {
        self.queue = queue; self.injector = injector; self.onChange = onChange
        queue.setSpecific(key: key, value: 1)
        install()
    }

    deinit { teardown() }

    private func install() {
        guard let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = p
        IONotificationPortSetDispatchQueue(p, queue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOServiceMatchingCallback = { refcon, it in
            guard let refcon else { return }
            let me = Unmanaged<HIDSource>.fromOpaque(refcon).takeUnretainedValue()
            me.fired(it)
        }
        // the iterators must be drained once to arm them; do that on `queue` so it never races a callback
        let arm = {
            if let m = IOServiceMatching(Self.serviceClass),
               IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, m, cb, refcon, &self.addIt) == KERN_SUCCESS {
                Self.drain(self.addIt)
            }
            if let m = IOServiceMatching(Self.serviceClass),
               IOServiceAddMatchingNotification(p, kIOTerminatedNotification, m, cb, refcon, &self.remIt) == KERN_SUCCESS {
                Self.drain(self.remIt)
            }
        }
        if DispatchQueue.getSpecific(key: key) != nil { arm() } else { queue.sync(execute: arm) }
    }

    /// queue only (IOKit delivers on `queue`)
    private func fired(_ it: io_iterator_t) {
        let n = Self.drain(it)
        guard n > 0 else { return }
        if it == addIt { notifications.matched += n } else { notifications.terminated += n }
        onChange()
    }

    @discardableResult private static func drain(_ it: io_iterator_t) -> Int {
        var n = 0
        while case let s = IOIteratorNext(it), s != 0 { n += 1; IOObjectRelease(s) }
        return n
    }

    /// First line: try injector.check(.batHID). Real failure → .kern(kr).
    func read() throws -> [HIDDevice] {
        try injector.check(.batHID)
        guard let match = IOServiceMatching(Self.serviceClass) else { throw SourceError.kern(-1) }
        var it: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &it)
        guard kr == KERN_SUCCESS else { throw SourceError.kern(kr) }
        defer { IOObjectRelease(it) }
        var out: [HIDDevice] = []
        var seen = Set<String>()
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            guard let pct = (prop("BatteryPercent") as? NSNumber)?.intValue else { continue }
            let addr = normalizeAddress(prop("DeviceAddress") as? String ?? "")
            let key = addr.isEmpty ? "svc:\(s)" : addr
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(HIDDevice(address: key, name: prop("Product") as? String ?? "",
                                 category: prop("Accessory Category") as? String ?? "",
                                 percent: max(0, min(100, pct)),
                                 statusFlags: (prop("BatteryStatusFlags") as? NSNumber)?.intValue))
        }
        return out
    }

    /// Remove notifications (shutdown). Safe from any thread; idempotent.
    func stop() {
        if DispatchQueue.getSpecific(key: key) != nil { teardown() } else { queue.sync { teardown() } }
    }

    private func teardown() {
        if addIt != 0 { IOObjectRelease(addIt); addIt = 0 }
        if remIt != 0 { IOObjectRelease(remIt); remIt = 0 }
        if let p = port { IONotificationPortDestroy(p); port = nil }
    }
}
