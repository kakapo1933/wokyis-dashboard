// BatteryAggregator.swift — merge HID / IOPS / system_profiler, connection truth, offline grace, ordering, owner tags,
// BAT/DEV log lines (spec §6.2–§6.6). Owner: battery agent.
//
// Connection truth (§6.4):
// - HID row: connected ⇔ the IOKit service exists AND (when sp succeeded ≤ 45 s ago) sp does not list the address under
//   device_not_connected. Service gone → offline at once (why=terminated). With --hid-trust-notify no (default) the
//   number is shown only while sp succeeded ≤ 45 s ago; otherwise the row turns grey "—" (CellState.stale, DEV
//   to=stale why=sp_stale: connection unknown → criterion #5 "grey within 60 s"; real HID/IOPS read failures stay
//   bright failed "—").
// - AirPods group: connected ⇔ the last successful sp (≤ 45 s old) lists it under device_connected. IOPS lists AirPods
//   even when they are not connected (Phase 1), so IOPS is never used for connection. sp older than 45 s → a group that
//   is on screen keeps its place with three grey stale "—" (why=sp_stale).
// - Values: HID % from IOKit, HID charging from the IOPS entry whose Accessory Identifier == BT address. AirPods L/R/Case
//   from IOPS (groupKey "0x<PID>:<name>" ↔ sp productID + name); IOPS failed → sp device_batteryLevel* if sp succeeded
//   ≤ 25 s ago, else failed "—". A part that does not report → unavailable (dim "—").
// - 「附近」(nearby, README §8.5.1, evidence/nearby/findings.md): an AirPods group whose classic entry is NOT under
//   device_connected of a fresh sp (≤ 45 s; under device_not_connected or absent) is nearby when
//   (a) the case's BLE companion (same name, no productID / minorType) is under device_connected of that sp, or
//   (b) this process saw the group's IOPS values change within `nearbyFresh` s (default 300; 0 disables nearby).
//   A change = any difference vs the previous successful IOPS read of the group in the set of parts (part + entry
//   Part Identifier), a part's Current Capacity, Is Charging or Power Source ID; a PART disappearing is a change; the
//   first read of a group after start is a baseline. A whole group missing from IOPS is no evidence (no values) and its
//   reappearing counts only if it differs from its last non-empty read. (b) also needs the group in the current IOPS
//   read. IOPS notifications alone are not evidence. A failed IOPS read gives no IOPS evidence (nearby only via (a)).
//   Values: IOPS parts, else the companion's device_connected levels (≤ 25 s); device_not_connected numbers are NEVER
//   used. Evidence gone → offline (why=nearby_stale, also after an sp-stale spell). Nearby never counts as a connection:
//   nearby groups sort after connected AirPods.
// - New rows are created only for connected or nearby devices; a row that goes offline stays in place for `offlineGrace` s
//   (why=grace_removed afterwards); reconnect restores it (AirPods: moves to the front of the AirPods groups).
// - Order: keyboard → trackpad → mouse → other HID (first-seen order within a kind) → AirPods (most recent connection
//   first). Owner tags only when ≥ 2 rows of the same kind are listed.
import Foundation

final class BatteryAggregator {
    static let spFreshSeconds: TimeInterval = 45
    static let spValueSeconds: TimeInterval = 25
    let offlineGrace: TimeInterval
    let hidTrustNotify: Bool
    /// 「附近」 freshness window for an observed IOPS change (seconds); 0 disables the nearby state.
    let nearbyFresh: TimeInterval
    let log: EventLog?
    /// Test hook: when set, DEV/BAT lines go here (kind, body without sim) instead of the EventLog.
    var sink: ((String, String) -> Void)?

    private struct Entry {
        let key: String
        let isHID: Bool
        var kind: DeviceKind
        var name: String
        var address: String
        let order: UInt64
        var connectedAt: Date      // last real connection to this Mac (nearby never sets it; .distantPast = never)
        var presence: Presence     // connected | nearby | offline (HID: connected | offline)
        /// Last decided live state was nearby (kept through sp-stale, where presence is .connected with stale cells),
        /// so a later offline is logged why=nearby_stale and the row keeps its place after connected AirPods.
        var wasNearby: Bool
        /// Owner-tag fallback when there is no BT address (AirPods sp does not list): IOPS Accessory Identifier.
        var tagHint: String
        var offlineSince: Date?
        var cells: [BatteryCell]
        var detail: String         // BAT body; a BAT line is written when it changes (or on the forced 15 s line)
        var extra: String          // appended to every BAT line but NOT compared (values that change every merge, e.g. sp_age_s)
        var state: String          // connected | failed | stale | nearby | offline  (DEV from/to)
        var live: Bool { presence != .offline }
        var nearbyLike: Bool { presence == .nearby || (presence == .connected && state == "stale" && wasNearby) }
    }
    private var entries: [String: Entry] = [:]
    private var seq: UInt64 = 0
    private var lastBAT: [String: String] = [:]
    /// IOPS change detector (「附近」 evidence (b)): last NON-EMPTY signature per groupKey and when this process last saw
    /// it change. A whole group missing from a read is not a change and keeps its last signature, so it reappearing
    /// identical (e.g. after an empty IOPS read) is not a change either. Keys are never dropped (bounded by IOPS).
    private var iopsSig: [String: [String]] = [:]
    private var iopsChangedAt: [String: Date] = [:]

    init(offlineGrace: TimeInterval, hidTrustNotify: Bool, nearbyFresh: TimeInterval = 300, log: EventLog?) {
        self.offlineGrace = offlineGrace; self.hidTrustNotify = hidTrustNotify; self.nearbyFresh = nearbyFresh; self.log = log
    }

    // MARK: merge

    func merge(hid: Result<[HIDDevice], SourceError>, acc: Result<[AccPart], SourceError>,
               sp: (devices: [BTDevice], at: Date)?, spLastError: SourceError?, now: Date) -> [DeviceGroup] {
        let spAge = sp.map { now.timeIntervalSince($0.at) }
        let spFresh = (spAge ?? .infinity) <= Self.spFreshSeconds
        let spValuesOK = (spAge ?? .infinity) <= Self.spValueSeconds
        var spByAddr: [String: BTDevice] = [:]
        for d in sp?.devices ?? [] where !d.address.isEmpty {
            if let prev = spByAddr[d.address], prev.connected { continue }   // duplicate: prefer the connected entry
            spByAddr[d.address] = d
        }
        let accParts: [AccPart]? = try? acc.get()

        // ---- HID rows
        switch hid {
        case .success(let devs):
            var present = Set<String>()
            for d in devs {
                present.insert(d.address)
                let kind = Self.kind(category: d.category)
                let spd = spFresh ? spByAddr[d.address] : nil
                let exists = entries[d.address] != nil
                if let spd, !spd.connected {
                    if exists { setOffline(d.address, why: "sp", now: now) }
                    continue
                }
                // wait for the first sp outcome before creating rows when numbers depend on sp (avoids a bogus flip)
                if !exists && !hidTrustNotify && sp == nil && spLastError == nil { continue }
                let chg = accParts?.first(where: { $0.part == .single && $0.accessoryID == d.address })?.charging ?? false
                let showNumber = hidTrustNotify || spFresh
                let cell: CellState = showNumber ? .ok(d.percent, charging: chg) : .stale
                let detail = "dev=\(d.address) kind=\(kind.rawValue) name=\(EventLog.q(d.name)) pct=\(showNumber ? String(d.percent) : "stale") "
                    + "chg=\(chg ? 1 : 0) conn=1 src=hid flags=\(d.statusFlags.map(String.init) ?? "-") sp=\(spd == nil ? (spFresh ? "absent" : "stale") : "connected")"
                upsert(key: d.address, isHID: true, kind: kind, name: d.name, address: d.address,
                       cells: [BatteryCell(label: kind.label, state: cell)], detail: detail,
                       why: showNumber ? "hid" : "sp_stale", now: now)
            }
            for (k, e) in entries where e.isHID && e.live && !present.contains(k) {
                setOffline(k, why: "terminated", now: now)
            }
        case .failure:
            for (k, e) in entries where e.isHID {
                if spFresh, let spd = spByAddr[k], !spd.connected { setOffline(k, why: "sp", now: now); continue }
                guard e.live else { continue }
                let detail = "dev=\(k) kind=\(e.kind.rawValue) name=\(EventLog.q(e.name)) pct=fail chg=0 conn=1 src=hid flags=- sp=\(spFresh ? "fresh" : "stale")"
                upsert(key: k, isHID: true, kind: e.kind, name: e.name, address: e.address,
                       cells: [BatteryCell(label: e.kind.label, state: .failed)], detail: detail, why: "hid_failed", now: now)
            }
        }

        // ---- AirPods groups
        var accGroups: [String: [AccPart]] = [:]
        for p in accParts ?? [] { accGroups[p.groupKey, default: []].append(p) }
        observeIOPS(accParts == nil ? nil : accGroups, now: now)
        if spFresh, let sp, let spAge {
            var listed = Set<String>()
            func notConnected(_ key: String, name: String, address: String) {
                nearbyOrOffline(key: key, name: name, address: address, sp: sp.devices, spAge: spAge, spValuesOK: spValuesOK,
                                parts: accParts == nil ? nil : accGroups[key], accFailed: accParts == nil, now: now)
            }
            // names of AirPods groups known from IOPS or already on screen under a real productID key: a BLE-only entry
            // with such a name is that group's case companion (evidence (a)), never a group of its own — also when sp
            // does not list the classic entry at all
            var podNames = Set(accGroups.values.flatMap { $0.filter { $0.part != .single }.map(\.name) })
            for e in entries.values where !e.isHID && !e.key.hasPrefix("0x????:") { podNames.insert(e.name) }
            for d in sp.devices where Self.isAudio(d, accGroups: accGroups) && !Self.isCompanion(d, in: sp.devices, podNames: podNames) {
                let key = Self.podKey(d)
                listed.insert(key)
                guard d.connected else { notConnected(key, name: d.name, address: d.address); continue }
                let (cells, src) = Self.podCells(parts: accGroups[key], accFailed: accParts == nil, sp: d, spValuesOK: spValuesOK)
                var detail = "dev=\(key) kind=airpods addr=\(d.address) " + Self.valueTokens(cells)
                detail += "conn=1 src=\(src) sp_L=\(d.levels["Left"].map(String.init) ?? "-") sp_R=\(d.levels["Right"].map(String.init) ?? "-") "
                    + "sp_C=\(d.levels["Case"].map(String.init) ?? "-")"
                upsert(key: key, isHID: false, kind: .airpods, name: d.name, address: d.address, cells: cells, detail: detail, why: "sp", now: now)
            }
            // AirPods that IOPS lists but sp does not list at all (absent): may be nearby, never connected
            for (key, parts) in accGroups.sorted(by: { $0.key < $1.key }) where !listed.contains(key) && parts.contains(where: { $0.part != .single }) {
                let name = parts[0].name
                if sp.devices.contains(where: { $0.name == name && $0.productID != nil }) { continue }   // sp lists it under another key
                listed.insert(key)
                nearbyOrOffline(key: key, name: name, address: entries[key]?.address ?? "", sp: sp.devices, spAge: spAge, spValuesOK: spValuesOK,
                                parts: parts, accFailed: false, tagHint: Self.tagHint(parts), now: now)
            }
            for (k, e) in entries where !e.isHID && e.live && !listed.contains(k) { notConnected(k, name: e.name, address: e.address) }
        } else {
            // sp stale: connection (and so nearby) cannot be decided → connected and nearby groups turn grey "—"
            for (k, e) in entries where !e.isHID && e.live {
                let cells = e.cells.map { BatteryCell(label: $0.label, state: .stale) }
                // sp_age_s grows every second: kept out of the compared detail so a long sp outage does not write one BAT
                // line per second per group (it rides on the forced 15 s BAT line instead)
                let detail = "dev=\(k) kind=airpods addr=\(e.address) L=stale R=stale C=stale conn=1 src=none"
                    + (spLastError.map { " sp_err=\($0.logToken)" } ?? "")
                upsert(key: k, isHID: false, kind: .airpods, name: e.name, address: e.address, cells: cells, detail: detail,
                       extra: " sp_age_s=\(spAge.map { String(Int($0)) } ?? "-")", why: "sp_stale", now: now)
            }
        }

        // ---- offline grace
        for (k, e) in entries where !e.live {
            if let since = e.offlineSince, now.timeIntervalSince(since) >= offlineGrace {
                emit("DEV", "dev=\(k) kind=\(e.kind.rawValue) from=offline to=removed why=grace_removed offline_s=\(Int(now.timeIntervalSince(since)))", event: true)
                entries[k] = nil; lastBAT[k] = nil
            }
        }
        return groups()
    }

    /// Current rows in display order (also used after `merge`).
    func groups() -> [DeviceGroup] {
        let sorted = entries.values.sorted { a, b in
            if a.isHID != b.isHID { return a.isHID }
            if a.isHID {
                let ra = Self.rank(a.kind), rb = Self.rank(b.kind)
                return ra != rb ? ra < rb : a.order < b.order
            }
            // AirPods: connected (and offline-in-place) before nearby — nearby is not a connection — then most recent
            // connection first
            if a.nearbyLike != b.nearbyLike { return !a.nearbyLike }
            return a.connectedAt != b.connectedAt ? a.connectedAt > b.connectedAt : a.order < b.order
        }
        var count: [DeviceKind: Int] = [:]
        for e in sorted { count[e.kind, default: 0] += 1 }
        return sorted.map { e in
            DeviceGroup(kind: e.kind, name: e.name, ownerTag: (count[e.kind] ?? 0) >= 2 ? Self.ownerTag(name: e.name, address: e.address.isEmpty ? e.tagHint : e.address) : nil,
                        presence: e.presence, cells: e.cells)   // offline rows keep their last cells (never drawn; SUM shows "off")
        }
    }

    /// Writes one `BAT` line per row whose detail changed since its last BAT line, or every row when `force`.
    /// `extra` (e.g. sp_age_s) is appended but never compared, so it cannot turn the 1 s re-merge into a 1 s BAT stream.
    func logBAT(force: Bool) {
        for e in entries.values.sorted(by: { $0.order < $1.order }) {
            let body = e.live ? e.detail : "dev=\(e.key) kind=\(e.kind.rawValue) name=\(EventLog.q(e.name)) conn=0 offline_since=\(e.offlineSince.map(EventLog.timestamp) ?? "-")"
            if force || lastBAT[e.key] != body {
                lastBAT[e.key] = body
                emit("BAT", body + (e.live ? e.extra : ""), event: false)
            }
        }
    }

    // MARK: state transitions

    private func upsert(key: String, isHID: Bool, kind: DeviceKind, name: String, address: String,
                        cells: [BatteryCell], detail: String, extra: String = "", presence: Presence = .connected, tagHint: String = "",
                        why: String, now: Date) {
        let newState = presence == .nearby ? "nearby"
            : (cells.contains(where: { $0.state == .failed }) ? "failed"
               : (cells.contains(where: { $0.state == .stale }) ? "stale" : "connected"))
        if var e = entries[key] {
            let from = e.state
            // a real (re)connection to this Mac (back from offline, or nearby → connected) moves the group to the front of
            // the AirPods; entering nearby never does (it is not a connection)
            if presence == .connected && newState != "stale" && (!e.live || e.presence == .nearby || e.wasNearby) { e.connectedAt = now }
            if presence == .nearby { e.wasNearby = true } else if newState != "stale" { e.wasNearby = false }
            if e.tagHint.isEmpty { e.tagHint = tagHint }
            e.offlineSince = nil
            e.presence = presence; e.kind = kind; e.name = name; e.address = address.isEmpty ? e.address : address
            e.cells = cells; e.detail = detail; e.extra = extra; e.state = newState
            entries[key] = e
            if from != newState { emit("DEV", "dev=\(key) kind=\(kind.rawValue) from=\(from) to=\(newState) why=\(why)", event: true) }
        } else {
            seq += 1
            entries[key] = Entry(key: key, isHID: isHID, kind: kind, name: name, address: address, order: seq,
                                 connectedAt: presence == .nearby ? .distantPast : now, presence: presence,
                                 wasNearby: presence == .nearby, tagHint: tagHint, offlineSince: nil, cells: cells, detail: detail,
                                 extra: extra, state: newState)
            emit("DEV", "dev=\(key) kind=\(kind.rawValue) name=\(EventLog.q(name)) from=none to=\(newState) why=\(why)", event: true)
        }
    }

    private func setOffline(_ key: String, why: String, now: Date) {
        guard var e = entries[key], e.live else { return }
        let from = e.state
        e.presence = .offline; e.offlineSince = now; e.state = "offline"
        entries[key] = e
        emit("DEV", "dev=\(key) kind=\(e.kind.rawValue) from=\(from) to=offline why=\(why)", event: true)
    }

    /// An AirPods group that a fresh sp does not list under device_connected: 「附近」 when there is fresh evidence
    /// (BLE companion connected, or an IOPS change seen within `nearbyFresh` s while this read still has IOPS data for the
    /// group), otherwise offline (an existing row only).
    /// `address` is the classic entry's address ("" when sp does not list the group); its device_not_connected levels
    /// are deliberately not a parameter: they are never used.
    private func nearbyOrOffline(key: String, name: String, address: String, sp: [BTDevice], spAge: TimeInterval, spValuesOK: Bool,
                                 parts: [AccPart]?, accFailed: Bool, tagHint: String = "", now: Date) {
        var ev: (why: String, tok: String, age: Int)?
        var companion: BTDevice?
        if nearbyFresh > 0 {
            companion = sp.first { $0.connected && $0.productID == nil && $0.minorType == nil && $0.name == name && $0.address != address }
            if companion != nil {
                ev = ("ble_companion", "ble", Int(max(0, spAge)))
            } else if !accFailed, !(parts ?? []).isEmpty, let t = iopsChangedAt[key] {
                // (b) needs the group's values in THIS read: a group IOPS no longer lists has nothing fresh to show
                var age = now.timeIntervalSince(t)
                if age < 0 { iopsChangedAt[key] = now; age = 0 }   // wall clock stepped back: restart the window at now
                if age <= nearbyFresh { ev = ("iops_change", "iops", Int(age)) }
            }
        }
        guard let ev else {
            if let e = entries[key], e.live { setOffline(key, why: e.presence == .nearby || e.wasNearby ? "nearby_stale" : "sp", now: now) }
            return
        }
        // values: IOPS parts; else the companion's device_connected levels (podCells applies the ≤ 25 s rule); else "—"
        let fresh = BTDevice(name: name, address: companion?.address ?? address, minorType: nil, productID: nil, connected: true,
                             levels: companion?.levels ?? [:])
        let (cells, src0) = Self.podCells(parts: parts, accFailed: accFailed, sp: fresh, spValuesOK: spValuesOK)
        // src = where the shown numbers came from: "ble" only when the companion actually supplied one, else "none"
        let src = src0 == "sp" ? (companion != nil && cells.contains { if case .ok = $0.state { return true }; return false } ? "ble" : "none") : src0
        let detail = "dev=\(key) kind=airpods addr=\(address.isEmpty ? "-" : address) " + Self.valueTokens(cells)
            + "conn=0 nearby=1 src=\(src) ev=\(ev.tok)"
        // fresh_age_s grows every second: kept out of the compared detail (rides on the forced 15 s BAT line)
        upsert(key: key, isHID: false, kind: .airpods, name: name, address: address, cells: cells, detail: detail,
               extra: " fresh_age_s=\(ev.age)", presence: .nearby, tagHint: tagHint, why: ev.why, now: now)
    }

    /// IOPS change detector. `groups` nil = this read failed (no evidence either way; signatures kept).
    /// A group missing from a successful read is not recorded (no values = no evidence); its last signature is kept, so
    /// it reappearing counts as a change only when parts, values or Power Source IDs differ from before it vanished.
    /// A PART missing while the group is still listed changes the signature and does count.
    private func observeIOPS(_ groups: [String: [AccPart]]?, now: Date) {
        guard let groups else { return }
        for (k, parts) in groups where !parts.isEmpty {
            let sig = Self.iopsSignature(parts)
            if let prev = iopsSig[k], prev != sig { iopsChangedAt[k] = now }   // first sight of a group = baseline
            iopsSig[k] = sig
        }
    }

    private func emit(_ kind: String, _ body: String, event: Bool) {
        if let sink { sink(kind, body); return }
        guard let log else { return }
        let b = body + " sim=\(log.simActive() ? 1 : 0)"
        if event { log.event(kind, b) } else { log.line(kind, b) }
    }

    // MARK: pure helpers

    static func kind(category: String) -> DeviceKind {
        switch category.lowercased() {
        case "keyboard": .keyboard
        case "trackpad": .trackpad
        case "mouse": .mouse
        default: .other
        }
    }
    static func rank(_ k: DeviceKind) -> Int {
        switch k { case .keyboard: 0; case .trackpad: 1; case .mouse: 2; case .other: 3; case .airpods: 4 }
    }
    static func podKey(_ d: BTDevice) -> String { "\(normalizeProductID(d.productID) ?? "0x????"):\(d.name)" }

    /// An sp device is an AirPods-style group when it reports Left/Right/Case levels, is a headphone/headset, or has
    /// a matching IOPS Left/Right/Case group.
    static func isAudio(_ d: BTDevice, accGroups: [String: [AccPart]]) -> Bool {
        if d.levels["Left"] != nil || d.levels["Right"] != nil || d.levels["Case"] != nil { return true }
        let mt = (d.minorType ?? "").lowercased()
        if mt.contains("headphone") || mt.contains("headset") { return true }
        return accGroups[podKey(d)]?.contains(where: { $0.part != .single }) ?? false
    }

    /// While AirPods are connected, sp lists them twice: the classic entry (productID 0x2024, minorType Headphones,
    /// Left/Right/Case) and a second entry with the same name, its own address, services "< BLE >", no productID and
    /// no minorType, reporting only the Case level — the charging case's own BLE identity (seen live 2026-10-01,
    /// evidence/c5/bug-dup-airpods-p1.png). It is the same physical device, so it never forms its own group. When sp
    /// does not list the classic entry at all, a same-name AirPods group known from IOPS / on screen (`podNames`) is the
    /// twin: the entry is then only 「附近」 evidence (a) for that group.
    static func isCompanion(_ d: BTDevice, in all: [BTDevice], podNames: Set<String> = []) -> Bool {
        guard d.productID == nil, d.minorType == nil else { return false }
        return podNames.contains(d.name) || all.contains { $0.name == d.name && $0.address != d.address && $0.productID != nil }
    }

    /// Owner-tag fallback for an AirPods group sp does not list (no BT address): the smallest IOPS Accessory Identifier
    /// of its L/R/Combined entries (case as a last resort), so the tag is stable instead of "?".
    static func tagHint(_ parts: [AccPart]) -> String {
        let pods = parts.filter { $0.part != .case && $0.part != .single }.map(\.accessoryID).filter { !$0.isEmpty }.sorted()
        return pods.first ?? parts.map(\.accessoryID).filter { !$0.isEmpty }.sorted().first ?? ""
    }

    /// Per-group IOPS signature: one sorted token per part = part, entry Part Identifier, capacity, charging, Power Source ID.
    static func iopsSignature(_ parts: [AccPart]) -> [String] {
        parts.map { "\($0.part.rawValue)|\($0.entryPart ?? "-")|\($0.percent)|\($0.charging ? 1 : 0)|\($0.sourceID.map(String.init) ?? "-")" }.sorted()
    }

    /// BAT value tokens of an AirPods group: "L= R= C= chgL= chgR= chgC= " or, single battery, "S= chgS= ".
    static func valueTokens(_ cells: [BatteryCell]) -> String {
        func tok(_ c: CellState?) -> String {
            switch c { case .ok(let p, _)?: return String(p); case .failed?: return "fail"; case .unavailable?: return "na"; case .stale?: return "stale"; case nil: return "-" }
        }
        func chg(_ c: CellState?) -> String { if case .ok(_, let ch)? = c { return ch ? "1" : "0" }; return "-" }
        let byLabel = Dictionary(cells.map { ($0.label, $0.state) }, uniquingKeysWith: { a, _ in a })
        let l = byLabel["左耳"], r = byLabel["右耳"], c = byLabel["充電盒"], s = byLabel["電量"]
        if s != nil { return "S=\(tok(s)) chgS=\(chg(s)) " }
        return "L=\(tok(l)) R=\(tok(r)) C=\(tok(c)) chgL=\(chg(l)) chgR=\(chg(r)) chgC=\(chg(c)) "
    }

    /// Cells for a connected AirPods group. Returns (cells, src) with src iops | sp | none.
    static func podCells(parts: [AccPart]?, accFailed: Bool, sp d: BTDevice, spValuesOK: Bool) -> ([BatteryCell], String) {
        let labels: [(PodPart, String, String)] = [(.left, "左耳", "Left"), (.right, "右耳", "Right"), (.case, "充電盒", "Case")]
        if !accFailed, let parts, !parts.isEmpty {
            if parts.allSatisfy({ $0.part == .single }), let s = parts.first {
                return ([BatteryCell(label: "電量", state: .ok(s.percent, charging: s.charging))], "iops")
            }
            return (labels.map { part, label, _ in
                if let p = parts.first(where: { $0.part == part }) { return BatteryCell(label: label, state: .ok(p.percent, charging: p.charging)) }
                return BatteryCell(label: label, state: .unavailable)
            }, "iops")
        }
        let hasPods = d.levels["Left"] != nil || d.levels["Right"] != nil || d.levels["Case"] != nil
        if spValuesOK {
            if !hasPods, let m = d.levels["Main"] { return ([BatteryCell(label: "電量", state: .ok(m, charging: false))], "sp") }
            return (labels.map { _, label, key in
                if let v = d.levels[key] { return BatteryCell(label: label, state: .ok(v, charging: false)) }
                return BatteryCell(label: label, state: .unavailable)
            }, "sp")
        }
        // IOPS failed and sp values too old → failed; IOPS fine but silent about this group → unavailable
        let st: CellState = accFailed ? .failed : .unavailable
        return (labels.map { BatteryCell(label: $0.1, state: st) }, "none")
    }

    /// Owner tag (spec §6.5): the part of the name before the earliest "’s", "'s" or "的", Latin upper-cased;
    /// otherwise the last 4 hex digits of the address, upper-cased.
    static func ownerTag(name: String, address: String) -> String {
        var cut: String.Index? = nil
        for sep in ["’s", "'s", "的"] {
            if let r = name.range(of: sep), cut.map({ r.lowerBound < $0 }) ?? true { cut = r.lowerBound }
        }
        if let cut {
            let t = String(name[..<cut]).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t.uppercased() }
        }
        let hex = address.filter(\.isHexDigit)
        return hex.isEmpty ? "?" : String(hex.suffix(4)).uppercased()
    }
}

// MARK: - self-test

/// Battery-module self-test hook called by `--selftest` (Sources/Evidence/SelfTest.swift). Pure: no files written,
/// no processes, no timers (it may read tools/fixtures/sp_sample.json to confirm it matches the embedded copy).
enum BatterySelfTest {
    /// De-identified copy of phase-1 sp.json (same content as tools/fixtures/sp_sample.json): keyboard + trackpad
    /// connected; "Alex’s AirPods Pro" not connected but with L/R/Case levels; a second AirPods without levels.
    static let spFixture = #"""
{
  "SPBluetoothDataType": [
    {
      "controller_properties": {
        "controller_address": "02:00:00:00:00:01",
        "controller_chipset": "Apple N1",
        "controller_discoverable": "attrib_off",
        "controller_firmwareVersion": "MAC FW Version: 26.72.12.0, PHY FW Version: 3.1.46.0",
        "controller_productID": "0x7930",
        "controller_state": "attrib_on",
        "controller_supportedServices": "0x1390039 < HFP AVRCP A2DP HID LEA AACP GATT SerialPort SCO >",
        "controller_transport": "PCIe",
        "controller_vendorID": "0x004C (Apple)"
      },
      "device_connected": [
        {
          "Alex’s Magic Keyboard": {
            "device_address": "02:11:22:33:44:01",
            "device_batteryLevelMain": "100%",
            "device_firmwareVersion": "2.0.6",
            "device_minorType": "Keyboard",
            "device_productID": "0x029A",
            "device_services": "0x800020 < HID ACL >",
            "device_vendorID": "0x05AC"
          }
        },
        {
          "Casey Lin的觸控式軌跡板": {
            "device_address": "02:11:22:33:44:02",
            "device_batteryLevelMain": "100%",
            "device_firmwareVersion": "3.1.8",
            "device_minorType": "Magic Trackpad",
            "device_productID": "0x0265",
            "device_services": "0x800020 < HID ACL >",
            "device_vendorID": "0x004C"
          }
        }
      ],
      "device_not_connected": [
        {
          "Living Room": {
            "device_address": "02:11:22:33:44:03",
            "device_rssi": "-69"
          }
        },
        {
          "iPhone": {
            "device_address": "02:11:22:33:44:04",
            "device_rssi": "-55"
          }
        },
        {
          "Alex’s Mac mini": {
            "device_address": "02:11:22:33:44:05"
          }
        },
        {
          "Alex’s AirPods Pro": {
            "device_address": "02:11:22:33:44:06",
            "device_batteryLevelCase": "48%",
            "device_batteryLevelLeft": "100%",
            "device_batteryLevelRight": "100%",
            "device_caseVersion": "90.0.12",
            "device_firmwareVersion": "9A348",
            "device_minorType": "Headphones",
            "device_productID": "0x2024",
            "device_serialNumber": "SERIAL0001",
            "device_serialNumberLeft": "SERIAL0002",
            "device_serialNumberRight": "SERIAL0003",
            "device_vendorID": "0x004C"
          }
        },
        {
          "Alex’s AppleTV": {
            "device_address": "02:11:22:33:44:07",
            "device_rssi": "-43"
          }
        },
        {
          "Alex’s Apple Watch": {
            "device_address": "02:11:22:33:44:08",
            "device_rssi": "-42"
          }
        },
        {
          "小明的屁屁’s AirPods Pro": {
            "device_address": "02:11:22:33:44:09",
            "device_caseVersion": "1.4.0",
            "device_firmwareVersion": "6A300",
            "device_minorType": "Headphones",
            "device_productID": "0x200E",
            "device_serialNumber": "SERIAL0004",
            "device_serialNumberLeft": "SERIAL0005",
            "device_serialNumberRight": "SERIAL0006",
            "device_vendorID": "0x004C"
          }
        }
      ]
    }
  ]
}
"""#

    /// IOPS accessory descriptions shaped like phase-1 `pmset -g accps -xml` (keyboard, trackpad, AirPods Case, Combined L/R).
    /// `left/right/casePct` and the Power Source IDs (`combinedSID` / `caseSID`, nil = key absent) feed the 「附近」 tests;
    /// `includePods` false = IOPS lists no AirPods entry at all.
    static func iopsFixture(podsCharging: Bool = true, includeCase: Bool = true, kbCharging: Bool = false,
                            left: Int = 100, right: Int = 97, casePct: Int = 48, combinedSID: Int? = nil, caseSID: Int? = nil,
                            includePods: Bool = true) -> CFTypeRef {
        var list: [NSMutableDictionary] = [
            ["Accessory Category": "Trackpad", "Accessory Identifier": "02:11:22:33:44:02", "Current Capacity": 85, "Is Charging": false,
             "Name": "Casey Lin的觸控式軌跡板", "Product ID": 613, "Transport Type": "Bluetooth", "Type": "Accessory Source"],
            ["Accessory Category": "Keyboard", "Accessory Identifier": "02:11:22:33:44:01", "Current Capacity": 100, "Is Charging": kbCharging,
             "Name": "Alex’s Magic Keyboard", "Product ID": 666, "Transport Type": "Bluetooth", "Type": "Accessory Source"],
            ["Accessory Category": "Headset", "Accessory Identifier": "95B99034-1206-8F22-52E6-897FFAC46D3B", "Current Capacity": 100,
             "Is Charging": podsCharging, "Name": "Alex’s AirPods Pro", "Part Identifier": "Combined", "Product ID": 8228,
             "Combined Parts": [["Part Identifier": "Left", "Current Capacity": left, "Is Charging": podsCharging, "Name": "Alex’s AirPods Pro"],
                                ["Part Identifier": "Right", "Current Capacity": right, "Is Charging": false, "Name": "Alex’s AirPods Pro"]]],
        ]
        if let combinedSID { list[2]["Power Source ID"] = combinedSID }
        if includeCase {
            let c: NSMutableDictionary = ["Accessory Category": "Audio Battery Case", "Accessory Identifier": "7C690BC6-342D-F08D-B7AC-4676C9F995BA",
                                          "Current Capacity": casePct, "Is Charging": false, "Name": "Alex’s AirPods Pro Case", "Part Identifier": "Case", "Product ID": 8228]
            if let caseSID { c["Power Source ID"] = caseSID }
            list.append(c)
        }
        if !includePods { list = Array(list.prefix(2)) }
        return list as CFArray
    }

    static let kb = HIDDevice(address: "02:11:22:33:44:01", name: "Alex’s Magic Keyboard", category: "Keyboard", percent: 100, statusFlags: 0)
    static let tp = HIDDevice(address: "02:11:22:33:44:02", name: "Casey Lin的觸控式軌跡板", category: "Trackpad", percent: 85, statusFlags: 0)

    /// The fixture with some devices moved between device_connected / device_not_connected (by name).
    static func spDevices(connected names: Set<String>) -> [BTDevice] {
        let base = (try? BTProfilerSource.parse(Data(spFixture.utf8))) ?? []
        return base.map { d in
            BTDevice(name: d.name, address: d.address, minorType: d.minorType, productID: d.productID,
                     connected: names.contains(d.name), levels: d.levels)
        }
    }

    static func run() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { out.append(SelfTestCase("battery." + name, ok, ok ? "" : detail())) }
        func desc(_ gs: [DeviceGroup]) -> String {
            gs.map { g in
                "\(g.kind.rawValue)\(g.ownerTag.map { "[\($0)]" } ?? "")\(g.presence == .offline ? "(off)" : (g.presence == .nearby ? "~" : "")):"
                    + (g.showsCells ? g.cells : []).map { c -> String in
                    switch c.state { case .ok(let p, let ch): return "\(p)\(ch ? "c" : "")"; case .failed: return "F"; case .unavailable: return "na"; case .stale: return "S" }
                }.joined(separator: "/")
            }.joined(separator: " ")
        }
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let kbName = "Alex’s Magic Keyboard", tpName = "Casey Lin的觸控式軌跡板", podName = "Alex’s AirPods Pro", pod2 = "小明的屁屁’s AirPods Pro"

        // ---- sp parser
        do {
            let devs = try BTProfilerSource.parse(Data(spFixture.utf8))
            let conn = devs.filter(\.connected)
            let pods = devs.first { $0.name == podName }
            check("sp.parse.fixture", devs.count == 9 && conn.count == 2 && Set(conn.map(\.name)) == [kbName, tpName]
                  && conn.first { $0.name == kbName }?.address == "02:11:22:33:44:01" && conn.first { $0.name == kbName }?.levels["Main"] == 100
                  && pods?.connected == false && pods?.levels == ["Left": 100, "Right": 100, "Case": 48] && pods?.productID == "0x2024",
                  "devs=\(devs.count) conn=\(conn.map(\.name))")
        } catch { check("sp.parse.fixture", false, "\(error)") }
        // the fixture file (if reachable) must parse to the same devices as the embedded copy
        let fixtureURL = Config.resolve("tools/fixtures/sp_sample.json")
        if let data = FileManager.default.contents(atPath: fixtureURL.path) {
            let a = (try? BTProfilerSource.parse(data))?.map { "\($0.name)|\($0.address)|\($0.connected)|\($0.levels.sorted { $0.key < $1.key })" }
            let b = (try? BTProfilerSource.parse(Data(spFixture.utf8)))?.map { "\($0.name)|\($0.address)|\($0.connected)|\($0.levels.sorted { $0.key < $1.key })" }
            check("sp.parse.fixture_file", a != nil && a == b, "file differs from embedded fixture")
        } else {
            check("sp.parse.fixture_file", true)   // not reachable from this cwd (e.g. LaunchServices); embedded copy tested above
        }
        for (name, bytes) in [("garbage", "{not json"), ("empty", ""), ("wrong_root", "[1,2]"), ("no_key", "{\"x\":1}"),
                              ("bad_section", "{\"SPBluetoothDataType\":[{\"device_connected\":5}]}")] {
            do { _ = try BTProfilerSource.parse(Data(bytes.utf8)); check("sp.parse.\(name)", false, "no error") }
            catch let e as SourceError { check("sp.parse.\(name)", e.logToken == "parse", "\(e)") }
            catch { check("sp.parse.\(name)", false, "\(error)") }
        }
        do {
            let devs = try BTProfilerSource.parse(Data("{\"SPBluetoothDataType\":[{\"controller_properties\":{}}]}".utf8))
            check("sp.parse.nothing_paired", devs.isEmpty)
        } catch { check("sp.parse.nothing_paired", false, "\(error)") }
        check("sp.percent", BTProfilerSource.percent("48%") == 48 && BTProfilerSource.percent("100 %") == 100 && BTProfilerSource.percent("x") == nil
              && BTProfilerSource.percent("140%") == nil)
        check("addr.normalize", normalizeAddress("02-11-22-33-44-01") == "02:11:22:33:44:01" && normalizeAddress("02:11:22:33:44:01") == "02:11:22:33:44:01"
              && normalizeProductID(8228) == "0x2024" && normalizeProductID("0x029a") == "0x029A")

        // ---- IOPS parser
        do {
            let parts = try AccessorySource.parse(iopsFixture())
            let pods = parts.filter { $0.groupKey == "0x2024:\(podName)" }
            check("iops.parse", parts.count == 5 && pods.count == 3 && Set(pods.map(\.part.rawValue)) == ["left", "right", "case"]
                  && pods.first { $0.part == .right }?.percent == 97 && pods.first { $0.part == .case }?.percent == 48
                  && pods.first { $0.part == .left }?.charging == true
                  && parts.first { $0.part == .single && $0.accessoryID == "02:11:22:33:44:01" }?.percent == 100,
                  "parts=\(parts.map { "\($0.groupKey)/\($0.part.rawValue)=\($0.percent)" })")
        } catch { check("iops.parse", false, "\(error)") }
        do { _ = try AccessorySource.parse("garbage" as CFString); check("iops.parse.garbage", false, "no error") }
        catch let e as SourceError { check("iops.parse.garbage", e.logToken == "parse", "\(e)") } catch { check("iops.parse.garbage", false, "\(error)") }
        do { _ = try AccessorySource.parse([1, 2] as CFArray); check("iops.parse.not_dicts", false, "no error") }
        catch let e as SourceError { check("iops.parse.not_dicts", e.logToken == "parse", "\(e)") } catch { check("iops.parse.not_dicts", false, "\(error)") }
        check("iops.symbol", AccessorySource.byType != nil, "IOPSCopyPowerSourcesByType not found (reads will be missing_symbol)")

        let acc = { try! AccessorySource.parse(iopsFixture()) }
        func agg(trust: Bool = false, grace: TimeInterval = 600, nearby: TimeInterval = 300) -> (BatteryAggregator, () -> [String]) {
            let a = BatteryAggregator(offlineGrace: grace, hidTrustNotify: trust, nearbyFresh: nearby, log: nil)
            var lines: [String] = []
            a.sink = { k, b in lines.append("\(k) \(b)") }
            return (a, { let l = lines; lines = []; return l })
        }

        // ---- 1. keyboard + trackpad connected; AirPods listed by IOPS but NOT connected in sp → not shown
        do {
            let (a, lines) = agg()
            let g = a.merge(hid: .success([tp, kb]), acc: .success(acc()), sp: (spDevices(connected: [kbName, tpName]), t0), spLastError: nil, now: t0)
            check("merge.kb_tp", desc(g) == "keyboard:100 trackpad:85", desc(g))
            check("merge.airpods_iops_only_not_shown", !g.contains { $0.kind == .airpods }, desc(g))
            let l = lines()
            check("merge.dev_lines_new", l.filter { $0.hasPrefix("DEV") && $0.contains("from=none to=connected") }.count == 2, l.joined(separator: " | "))
            a.logBAT(force: true)
            let bat = lines()
            check("merge.bat_lines", bat.count == 2 && bat.allSatisfy { $0.hasPrefix("BAT dev=") && $0.contains("conn=1 src=hid") }, bat.joined(separator: " | "))
            a.logBAT(force: false)
            check("merge.bat_unchanged_silent", lines().isEmpty)
            // keyboard charging from the IOPS entry with the same BT address
            let g2 = a.merge(hid: .success([tp, kb]), acc: .success(try! AccessorySource.parse(iopsFixture(kbCharging: true))),
                             sp: (spDevices(connected: [kbName, tpName]), t0), spLastError: nil, now: t0 + 1)
            check("merge.kb_charging", desc(g2) == "keyboard:100c trackpad:85", desc(g2))
        }
        // ---- 2. AirPods connected: L/R/Case from IOPS, after HID rows; a missing part is unavailable
        do {
            let (a, _) = agg()
            let sp = spDevices(connected: [kbName, tpName, podName])
            let g = a.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (sp, t0), spLastError: nil, now: t0)
            check("merge.airpods_connected", desc(g) == "keyboard:100 trackpad:85 airpods:100c/97/48", desc(g))
            check("merge.airpods_labels", g.last?.cells.map(\.label) == ["左耳", "右耳", "充電盒"])
            // the case's BLE companion entry (same name, no productID/minorType, Case only) must not add a second group
            let companion = BTDevice(name: podName, address: "02:11:22:33:44:99", minorType: nil, productID: nil, connected: true, levels: ["Case": 48])
            let (ac, _) = agg()
            let gc = ac.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (sp + [companion], t0), spLastError: nil, now: t0)
            check("merge.airpods_ble_companion_merged", desc(gc) == "keyboard:100 trackpad:85 airpods:100c/97/48", desc(gc))
            let lone = BTDevice(name: "Solo Buds", address: "02:11:22:33:44:98", minorType: nil, productID: nil, connected: true, levels: ["Case": 30])
            check("merge.companion_needs_named_twin", !BatteryAggregator.isCompanion(lone, in: sp + [lone]) && BatteryAggregator.isCompanion(companion, in: sp + [companion]))
            let g2 = a.merge(hid: .success([kb, tp]), acc: .success(try! AccessorySource.parse(iopsFixture(podsCharging: false, includeCase: false))),
                             sp: (sp, t0 + 1), spLastError: nil, now: t0 + 1)
            check("merge.airpods_case_unavailable", desc(g2) == "keyboard:100 trackpad:85 airpods:100/97/na", desc(g2))
            // IOPS failed: sp values while sp ≤ 25 s, then failed
            let g3 = a.merge(hid: .success([kb, tp]), acc: .failure(.injected("bat.iops")), sp: (sp, t0 + 1), spLastError: nil, now: t0 + 20)
            check("merge.iops_fail_sp_values", desc(g3) == "keyboard:100 trackpad:85 airpods:100/100/48", desc(g3))
            let g4 = a.merge(hid: .success([kb, tp]), acc: .failure(.missingSymbol("x")), sp: (sp, t0 + 1), spLastError: nil, now: t0 + 30)
            check("merge.iops_fail_sp_old_failed", desc(g4) == "keyboard:100 trackpad:85 airpods:F/F/F", desc(g4))
        }
        // ---- 3. AirPods present in IOPS but not connected; previously shown → offline in place, then removed after grace
        do {
            let (a, lines) = agg(grace: 600)
            _ = a.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (spDevices(connected: [kbName, tpName, podName]), t0), spLastError: nil, now: t0)
            _ = lines()
            let g = a.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (spDevices(connected: [kbName, tpName]), t0 + 20), spLastError: nil, now: t0 + 20)
            check("merge.airpods_offline", desc(g) == "keyboard:100 trackpad:85 airpods(off):", desc(g))
            check("merge.dev_offline_line", lines().contains { $0.contains("kind=airpods from=connected to=offline why=sp") })
            let g2 = a.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (spDevices(connected: [kbName, tpName]), t0 + 600), spLastError: nil, now: t0 + 619)
            check("merge.grace_keeps", g2.count == 3, desc(g2))
            let g3 = a.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (spDevices(connected: [kbName, tpName]), t0 + 620), spLastError: nil, now: t0 + 620)
            check("merge.grace_removes", desc(g3) == "keyboard:100 trackpad:85", desc(g3))
            check("merge.dev_grace_line", lines().contains { $0.contains("why=grace_removed") })
        }
        // ---- 4. §6.4 timeline with an injected clock (device disconnects right after the sp run at t=0)
        do {
            let before = spDevices(connected: [kbName, tpName, podName])
            let after = spDevices(connected: [kbName])       // trackpad and AirPods gone
            // (a) next sp succeeds at t=20
            let (a, _) = agg()
            _ = a.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (before, t0), spLastError: nil, now: t0)
            let ga = a.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (after, t0 + 20), spLastError: nil, now: t0 + 20.1)
            check("timeline.a_offline_at_20", desc(ga) == "keyboard:100 trackpad(off): airpods(off):", desc(ga))
            let sum = SummaryFormat.body(sample: nil, groups: ga, sim: false)
            check("summary.off_tokens", sum.contains("kb=100 tp=off") && sum.contains("airpods=off"), sum)
            // (b) sp at 20 times out (killed at 32), sp at 40 succeeds
            let (b, _) = agg()
            _ = b.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (before, t0), spLastError: nil, now: t0)
            let gb1 = b.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (before, t0), spLastError: .timeout, now: t0 + 32)
            let gb2 = b.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (after, t0 + 40), spLastError: nil, now: t0 + 40.1)
            check("timeline.b_still_shown_at_32", desc(gb1) == "keyboard:100 trackpad:85 airpods:100c/97/48", desc(gb1))
            check("timeline.b_offline_at_40", desc(gb2) == "keyboard:100 trackpad(off): airpods(off):", desc(gb2))
            // (c) both fail → at 45 s the sp data is stale: AirPods and (trust=no) HID rows turn grey stale "—"
            let (c, lc) = agg()
            _ = c.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (before, t0), spLastError: nil, now: t0)
            _ = lc()
            let gc1 = c.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (before, t0), spLastError: .timeout, now: t0 + 45)
            let gc2 = c.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (before, t0), spLastError: .timeout, now: t0 + 45.5)
            check("timeline.c_ok_at_45", desc(gc1) == "keyboard:100 trackpad:85 airpods:100c/97/48", desc(gc1))
            check("timeline.c_stale_after_45", desc(gc2) == "keyboard:S trackpad:S airpods:S/S/S", desc(gc2))
            check("timeline.c_dev_sp_stale", lc().filter { $0.contains("to=stale why=sp_stale") }.count == 3)
            // a long sp outage: 1 s re-merges with logBAT(force: false) write one BAT line per row when it turns stale,
            // then nothing until the forced 15 s line (which carries sp_age_s)
            c.logBAT(force: false); _ = lc()
            var perSecond = 0
            for s in 46...120 {
                _ = c.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (before, t0), spLastError: .timeout, now: t0 + Double(s))
                c.logBAT(force: false)
                perSecond += lc().filter { $0.hasPrefix("BAT") }.count
            }
            check("timeline.c_bat_quiet_while_sp_stale", perSecond == 0, "BAT lines in 75 s of 1 s merges: \(perSecond)")
            c.logBAT(force: true)
            let forced = lc().filter { $0.hasPrefix("BAT") && $0.contains("kind=airpods") }
            check("timeline.c_bat_forced_sp_age", forced.count == 1 && forced[0].contains("sp_age_s=120") && forced[0].contains("sp_err=timeout"),
                  forced.joined(separator: " | "))
            // trust=yes: HID keeps its number while sp is stale; the IOKit service vanishing → offline at once
            let (d, _) = agg(trust: true)
            _ = d.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (before, t0), spLastError: nil, now: t0)
            let gd = d.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (before, t0), spLastError: .timeout, now: t0 + 50)
            check("timeline.trust_yes_hid_numbers", desc(gd) == "keyboard:100 trackpad:85 airpods:S/S/S", desc(gd))
            let gd2 = d.merge(hid: .success([kb]), acc: .success(acc()), sp: (before, t0), spLastError: .timeout, now: t0 + 51)
            check("timeline.terminated_offline", desc(gd2) == "keyboard:100 trackpad(off): airpods:S/S/S", desc(gd2))
            // reconnect restores the row in place
            let gd3 = d.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (before, t0 + 60), spLastError: nil, now: t0 + 60)
            check("timeline.reconnect", desc(gd3) == "keyboard:100 trackpad:85 airpods:100c/97/48", desc(gd3))
        }
        // ---- 5. HID read failure → rows failed "—", still in place; before the first sp outcome no HID row is created
        do {
            let (a, _) = agg()
            let g0 = a.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: nil, spLastError: nil, now: t0)
            check("merge.wait_first_sp", g0.isEmpty, desc(g0))
            let g1 = a.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: nil, spLastError: .errno(2, "x"), now: t0 + 1)
            check("merge.sp_never_ok_hid_stale", desc(g1) == "keyboard:S trackpad:S", desc(g1))
            let sp = spDevices(connected: [kbName, tpName])
            _ = a.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (sp, t0 + 2), spLastError: nil, now: t0 + 2)
            let g2 = a.merge(hid: .failure(.injected("bat.hid")), acc: .success(acc()), sp: (sp, t0 + 2), spLastError: nil, now: t0 + 3)
            check("merge.hid_failed", desc(g2) == "keyboard:F trackpad:F", desc(g2))
            let g3 = a.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (sp, t0 + 2), spLastError: nil, now: t0 + 4)
            check("merge.hid_recovered", desc(g3) == "keyboard:100 trackpad:85", desc(g3))
        }
        // ---- 6. owner tags + overflow paging (two AirPods connected; three HID + two AirPods)
        do {
            check("tag.rules", BatteryAggregator.ownerTag(name: "Alex’s AirPods Pro", address: "") == "ALEX"
                  && BatteryAggregator.ownerTag(name: "小明的屁屁’s AirPods Pro", address: "") == "小明"
                  && BatteryAggregator.ownerTag(name: "Casey Lin的觸控式軌跡板", address: "") == "CASEY LIN"
                  && BatteryAggregator.ownerTag(name: "Magic Keyboard", address: "02:11:22:33:44:01") == "4401")
            let (a, _) = agg()
            var sp = spDevices(connected: [kbName, tpName, podName, pod2])
            _ = a.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (sp, t0), spLastError: nil, now: t0)
            // 小明's pair connects later → listed first among AirPods; no IOPS for it → sp has no levels → unavailable
            sp = spDevices(connected: [kbName, tpName, podName, pod2])
            let g = a.merge(hid: .success([kb, tp]), acc: .success(acc()), sp: (sp, t0 + 1), spLastError: nil, now: t0 + 1)
            let tags = g.filter { $0.kind == .airpods }.map { $0.ownerTag ?? "-" }
            check("tag.two_airpods", tags.count == 2 && Set(tags) == ["ALEX", "小明"] && g.filter { $0.kind.isHID }.allSatisfy { $0.ownerTag == nil },
                  "\(tags) \(desc(g))")
            let pages = PanelRenderer.pages(g)
            check("paging.2hid_2pods", pages.count == 2 && pages.allSatisfy { $0.count == 3 }, "pages=\(pages.map(\.count))")
            let mouse = HIDDevice(address: "02:11:22:33:44:0a", name: "Alex’s Magic Mouse", category: "Mouse", percent: 15, statusFlags: 0)
            let sp3 = sp + [BTDevice(name: "Alex’s Magic Mouse", address: "02:11:22:33:44:0a", minorType: "Mouse", productID: "0x0269", connected: true, levels: ["Main": 15])]
            let g3 = a.merge(hid: .success([mouse, kb, tp]), acc: .success(acc()), sp: (sp3, t0 + 2), spLastError: nil, now: t0 + 2)
            check("order.hid_kinds", g3.prefix(3).map(\.kind) == [.keyboard, .trackpad, .mouse], desc(g3))
            let p3 = PanelRenderer.pages(g3)
            check("paging.3hid_2pods", p3.count == 3, "pages=\(p3.map(\.count)) \(desc(g3))")
            // two keyboards → tags on both keyboard rows
            let kb2 = HIDDevice(address: "02:11:22:33:44:0b", name: "Magic Keyboard", category: "Keyboard", percent: 60, statusFlags: 0)
            let sp4 = sp3 + [BTDevice(name: "Magic Keyboard", address: "02:11:22:33:44:0b", minorType: "Keyboard", productID: "0x029A", connected: true, levels: ["Main": 60])]
            let g4 = a.merge(hid: .success([mouse, kb, tp, kb2]), acc: .success(acc()), sp: (sp4, t0 + 3), spLastError: nil, now: t0 + 3)
            check("tag.two_keyboards", g4.filter { $0.kind == .keyboard }.map { $0.ownerTag ?? "-" } == ["ALEX", "440B"], desc(g4))
        }
        // ---- 7. 「附近」(nearby): AirPods not connected to this Mac, values only from fresh IOPS / the case's BLE link
        do {
            let spNot = spDevices(connected: [kbName, tpName])            // AirPods under device_not_connected WITH cached levels 100/100/48
            let spConn = spDevices(connected: [kbName, tpName, podName])
            func iops(_ casePct: Int = 48, left: Int = 100, right: Int = 97, includeCase: Bool = true, caseSID: Int? = nil,
                      pods: Bool = true) -> Result<[AccPart], SourceError> {
                .success(try! AccessorySource.parse(iopsFixture(podsCharging: false, includeCase: includeCase, left: left, right: right,
                                                                 casePct: casePct, combinedSID: 7, caseSID: caseSID, includePods: pods)))
            }
            func pods(_ g: [DeviceGroup]) -> String { desc(g.filter { $0.kind == .airpods }) }
            check("nearby.iops_sid_parsed", (try? iops(caseSID: 9).get())?.first { $0.part == .case }?.sourceID == 9
                  && (try? iops().get())?.first { $0.part == .left }.map { $0.sourceID == 7 && $0.entryPart == "Combined" } == true)

            // (1) first IOPS read = baseline (not fresh); identical re-reads (as after an IOPS notification) are not evidence
            let (a, la) = agg()
            let g0 = a.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spNot, t0), spLastError: nil, now: t0)
            let g1 = a.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spNot, t0 + 15), spLastError: nil, now: t0 + 15)
            check("nearby.baseline_not_fresh", pods(g0) == "" && pods(g1) == "", "\(desc(g0)) | \(desc(g1))")
            _ = la()
            // (2) a value change seen by the panel → nearby with the IOPS values (never sp's cached 100/100/48)
            let g2 = a.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spNot, t0 + 30), spLastError: nil, now: t0 + 30)
            check("nearby.change_to_nearby", pods(g2) == "airpods~:100/97/47" && g2.last?.presence == .nearby && !(g2.last?.connected ?? true),
                  desc(g2))
            let l2 = la()
            check("nearby.dev_to_nearby", l2.contains { $0.contains("kind=airpods name=") && $0.contains("from=none to=nearby why=iops_change") },
                  l2.joined(separator: " | "))
            a.logBAT(force: true)
            let b2 = la().filter { $0.contains("kind=airpods") }
            check("nearby.bat_line", b2.count == 1 && b2[0].contains("L=100 R=97 C=47") && b2[0].contains("conn=0 nearby=1 src=iops ev=iops fresh_age_s=0")
                  && !b2[0].contains("sp_"), b2.joined(separator: " | "))
            // fresh_age_s grows every second but is not compared: no BAT stream between forced lines
            var quiet = 0
            for k in 31...60 {
                _ = a.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spNot, t0 + Double(k)), spLastError: nil, now: t0 + Double(k))
                a.logBAT(force: false); quiet += la().filter { $0.hasPrefix("BAT") }.count
            }
            check("nearby.bat_quiet", quiet == 0, "BAT lines: \(quiet)")
            // (3) evidence ages out after nearbyFresh (300 s) → offline why=nearby_stale, within one 1 s merge
            let g3 = a.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spNot, t0 + 320), spLastError: nil, now: t0 + 330)
            let g4 = a.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spNot, t0 + 320), spLastError: nil, now: t0 + 331)
            let l4 = la()
            check("nearby.stale_after_window", pods(g3) == "airpods~:100/97/47" && pods(g4) == "airpods(off):", "\(desc(g3)) | \(desc(g4))")
            check("nearby.dev_nearby_stale", l4.contains { $0.contains("from=nearby to=offline why=nearby_stale") }, l4.joined(separator: " | "))
            // a new change brings it back (offline → nearby), then connecting to this Mac → white numbers (connected path)
            let g5 = a.merge(hid: .success([kb, tp]), acc: iops(46), sp: (spNot, t0 + 340), spLastError: nil, now: t0 + 340)
            let g6 = a.merge(hid: .success([kb, tp]), acc: iops(46), sp: (spConn, t0 + 345), spLastError: nil, now: t0 + 345)
            let l6 = la()
            check("nearby.back_and_connected", pods(g5) == "airpods~:100/97/46" && pods(g6) == "airpods:100/97/46" && g6.last?.presence == .connected,
                  "\(desc(g5)) | \(desc(g6))")
            check("nearby.dev_from_nearby_sp", l6.contains { $0.contains("from=offline to=nearby why=iops_change") }
                  && l6.contains { $0.contains("from=nearby to=connected why=sp") }, l6.joined(separator: " | "))
            a.logBAT(force: true)
            check("nearby.connected_bat_unchanged", la().contains { $0.contains("kind=airpods") && $0.contains("conn=1 src=iops sp_L=100 sp_R=100 sp_C=48") })
            // sp stale (> 45 s) while nearby → grey stale "—" (nearby cannot be decided)
            let (s1, ls1) = agg()
            _ = s1.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spNot, t0), spLastError: nil, now: t0)
            _ = s1.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spNot, t0 + 5), spLastError: nil, now: t0 + 5)
            _ = ls1()
            let gs = s1.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spNot, t0 + 5), spLastError: .timeout, now: t0 + 51)
            check("nearby.sp_stale_grey", pods(gs) == "airpods:S/S/S" && ls1().contains { $0.contains("from=nearby to=stale why=sp_stale") }, desc(gs))
        }
        do {
            let spNot = spDevices(connected: [kbName, tpName])
            let spConn = spDevices(connected: [kbName, tpName, podName])
            let companion = BTDevice(name: podName, address: "02:11:22:33:44:99", minorType: nil, productID: nil, connected: true, levels: ["Case": 61])
            func iops(_ casePct: Int = 48, includeCase: Bool = true, caseSID: Int? = nil, pods: Bool = true) -> Result<[AccPart], SourceError> {
                .success(try! AccessorySource.parse(iopsFixture(podsCharging: false, includeCase: includeCase, casePct: casePct,
                                                                 combinedSID: 7, caseSID: caseSID, includePods: pods)))
            }
            func pods(_ g: [DeviceGroup]) -> String { desc(g.filter { $0.kind == .airpods }) }
            // (4) companion only: IOPS has no AirPods data, the case's BLE entry is under device_connected → nearby, companion levels
            let (c, lc) = agg()
            let gc = c.merge(hid: .success([kb, tp]), acc: iops(pods: false), sp: (spNot + [companion], t0), spLastError: nil, now: t0)
            c.logBAT(force: true)
            let lcs = lc()
            check("nearby.companion_only", pods(gc) == "airpods~:na/na/61", desc(gc))
            check("nearby.companion_logs", lcs.contains { $0.contains("to=nearby why=ble_companion") }
                  && lcs.contains { $0.hasPrefix("BAT") && $0.contains("L=na R=na C=61") && $0.contains("conn=0 nearby=1 src=ble ev=ble fresh_age_s=0") },
                  lcs.joined(separator: " | "))
            // IOPS read failed (injected): IOPS evidence unavailable → still nearby via the companion, companion levels
            let gcf = c.merge(hid: .success([kb, tp]), acc: .failure(.injected("bat.iops")), sp: (spNot + [companion], t0 + 5), spLastError: nil, now: t0 + 5)
            check("nearby.iops_failed_companion", pods(gcf) == "airpods~:na/na/61", desc(gcf))
            // companion values only while sp ≤ 25 s (same rule as the connected sp fallback); IOPS failed → bright failed "—"
            let gco = c.merge(hid: .success([kb, tp]), acc: .failure(.injected("bat.iops")), sp: (spNot + [companion], t0 + 5), spLastError: nil, now: t0 + 31)
            check("nearby.companion_values_25s", pods(gco) == "airpods~:F/F/F", desc(gco))
            // companion gone, IOPS failed → no evidence → offline
            let gc2 = c.merge(hid: .success([kb, tp]), acc: .failure(.injected("bat.iops")), sp: (spNot, t0 + 40), spLastError: nil, now: t0 + 40)
            check("nearby.companion_gone_offline", pods(gc2) == "airpods(off):" && lc().contains { $0.contains("from=nearby to=offline why=nearby_stale") }, desc(gc2))
            // IOPS evidence but the IOPS read now fails, no companion → offline (no stale numbers)
            let (f, lf) = agg()
            _ = f.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spNot, t0), spLastError: nil, now: t0)
            let gf1 = f.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spNot, t0 + 5), spLastError: nil, now: t0 + 5)
            _ = lf()
            let gf2 = f.merge(hid: .success([kb, tp]), acc: .failure(.injected("bat.iops")), sp: (spNot, t0 + 10), spLastError: nil, now: t0 + 10)
            check("nearby.iops_failed_offline", pods(gf1) == "airpods~:100/97/47" && pods(gf2) == "airpods(off):"
                  && lf().contains { $0.contains("from=nearby to=offline why=nearby_stale") }, "\(desc(gf1)) | \(desc(gf2))")
            // criterion #8 for CONNECTED groups unchanged: IOPS failed → sp device_connected values ≤ 25 s, then failed "—"
            let (k8, _) = agg()
            _ = k8.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spConn, t0), spLastError: nil, now: t0)
            let g8a = k8.merge(hid: .success([kb, tp]), acc: .failure(.injected("bat.iops")), sp: (spConn, t0), spLastError: nil, now: t0 + 20)
            let g8b = k8.merge(hid: .success([kb, tp]), acc: .failure(.injected("bat.iops")), sp: (spConn, t0), spLastError: nil, now: t0 + 30)
            check("nearby.connected_failure_path_unchanged", pods(g8a) == "airpods:100/100/48" && pods(g8b) == "airpods:F/F/F", "\(desc(g8a)) | \(desc(g8b))")

            // (5) device_not_connected numbers are never used: IOPS empty, no companion, sp not_connected with levels → nothing / offline
            let (n, _) = agg()
            let gn = n.merge(hid: .success([kb, tp]), acc: .success([]), sp: (spNot, t0), spLastError: nil, now: t0)
            check("nearby.not_connected_levels_unused", pods(gn) == "", desc(gn))
            _ = n.merge(hid: .success([kb, tp]), acc: .success([]), sp: (spConn, t0 + 10), spLastError: nil, now: t0 + 10)
            let gn2 = n.merge(hid: .success([kb, tp]), acc: .success([]), sp: (spNot, t0 + 20), spLastError: nil, now: t0 + 20)
            check("nearby.not_connected_levels_offline", pods(gn2) == "airpods(off):", desc(gn2))
            // a whole group missing from IOPS (GONE) is NOT evidence: no row is created, never sp's cached 100/100/48;
            // reappearing identical (an empty read in between) is not a change; reappearing different is
            let (gg, lgg) = agg()
            _ = gg.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spNot, t0), spLastError: nil, now: t0)
            let ggo = gg.merge(hid: .success([kb, tp]), acc: iops(pods: false), sp: (spNot, t0 + 5), spLastError: nil, now: t0 + 5)
            let ggs = gg.merge(hid: .success([kb, tp]), acc: .success([]), sp: (spNot, t0 + 10), spLastError: nil, now: t0 + 10)
            let ggb = gg.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spNot, t0 + 15), spLastError: nil, now: t0 + 15)
            check("nearby.group_gone_no_row", pods(ggo) == "" && pods(ggs) == "" && pods(ggb) == ""
                  && !lgg().contains { $0.contains("kind=airpods") }, "\(desc(ggo)) | \(desc(ggs)) | \(desc(ggb))")
            let ggc = gg.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spNot, t0 + 20), spLastError: nil, now: t0 + 20)
            check("nearby.group_back_changed_is_change", pods(ggc) == "airpods~:100/97/47", desc(ggc))
            // a shown nearby group whose IOPS entries vanish → offline (why=nearby_stale), not 「附近」 with "— — —"
            let ggg = gg.merge(hid: .success([kb, tp]), acc: iops(pods: false), sp: (spNot, t0 + 25), spLastError: nil, now: t0 + 25)
            check("nearby.group_gone_while_nearby_offline", pods(ggg) == "airpods(off):" && lgg().contains { $0.contains("from=nearby to=offline why=nearby_stale") },
                  desc(ggg))
            // forgotten / out-of-range device: connected, recent IOPS change, then sp stops listing it and IOPS drops the
            // group → offline why=sp at once (as before 「附近」), not 「附近」
            let spGone = spDevices(connected: [kbName, tpName]).filter { $0.name != podName }
            let (fg, lfg) = agg()
            _ = fg.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spConn, t0), spLastError: nil, now: t0)
            _ = fg.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spConn, t0), spLastError: nil, now: t0 + 10)
            _ = lfg()
            let gfg = fg.merge(hid: .success([kb, tp]), acc: iops(pods: false), sp: (spGone, t0 + 20), spLastError: nil, now: t0 + 20)
            check("nearby.forgotten_device_offline", pods(gfg) == "airpods(off):" && lfg().contains { $0.contains("from=connected to=offline why=sp") }, desc(gfg))
            // disconnect within one sp cycle while IOPS drops the group (classic under device_not_connected) → offline why=sp
            let (dg, ldg) = agg()
            _ = dg.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spConn, t0), spLastError: nil, now: t0)
            _ = dg.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spConn, t0), spLastError: nil, now: t0 + 10)
            _ = ldg()
            let gdg = dg.merge(hid: .success([kb, tp]), acc: iops(pods: false), sp: (spNot, t0 + 20), spLastError: nil, now: t0 + 20)
            check("nearby.disconnect_group_gone_offline", pods(gdg) == "airpods(off):" && ldg().contains { $0.contains("from=connected to=offline why=sp") }, desc(gdg))
            // a NULL IOPS blob is a failed read (no evidence), never an empty success
            let nullFn: AccessorySource.ByTypeFn = { _ in nil }
            do { _ = try AccessorySource.fetch(using: nullFn); check("nearby.iops_null_is_failure", false, "no error") }
            catch let e as SourceError { check("nearby.iops_null_is_failure", e.logToken == "parse", "\(e)") }
            catch { check("nearby.iops_null_is_failure", false, "\(error)") }

            // (6) disconnect within one sp cycle: recent IOPS change (while connected) → nearby; none → offline
            let (d1, l1) = agg()
            _ = d1.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spConn, t0), spLastError: nil, now: t0)
            _ = d1.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spConn, t0), spLastError: nil, now: t0 + 10)
            _ = l1()
            let gd1 = d1.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spNot, t0 + 20), spLastError: nil, now: t0 + 20.1)
            check("nearby.disconnect_recent_change", pods(gd1) == "airpods~:100/97/47" && l1().contains { $0.contains("from=connected to=nearby why=iops_change") },
                  desc(gd1))
            let (d2, l2) = agg()
            _ = d2.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spConn, t0), spLastError: nil, now: t0)
            _ = l2()
            let gd2 = d2.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spNot, t0 + 20), spLastError: nil, now: t0 + 20.1)
            check("nearby.disconnect_no_change", pods(gd2) == "airpods(off):" && l2().contains { $0.contains("from=connected to=offline why=sp") }, desc(gd2))

            // (7) a part that did not report → unavailable (dim "—")
            let (u, _) = agg()
            _ = u.merge(hid: .success([kb, tp]), acc: iops(48, includeCase: false), sp: (spNot, t0), spLastError: nil, now: t0)
            let gu = u.merge(hid: .success([kb, tp]), acc: .success(try! AccessorySource.parse(iopsFixture(podsCharging: true, includeCase: false))),
                             sp: (spNot, t0 + 5), spLastError: nil, now: t0 + 5)
            check("nearby.unreported_part", pods(gu) == "airpods~:100c/97/na", desc(gu))

            // (8) Power Source ID change (re-registration, same values) and a part GONE both count as changes
            let (i, li) = agg()
            _ = i.merge(hid: .success([kb, tp]), acc: iops(48, caseSID: 5), sp: (spNot, t0), spLastError: nil, now: t0)
            let gi = i.merge(hid: .success([kb, tp]), acc: iops(48, caseSID: 6), sp: (spNot, t0 + 5), spLastError: nil, now: t0 + 5)
            check("nearby.source_id_change", pods(gi) == "airpods~:100/97/48" && li().contains { $0.contains("to=nearby why=iops_change") }, desc(gi))
            let (p, _) = agg()
            _ = p.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spNot, t0), spLastError: nil, now: t0)
            let gp = p.merge(hid: .success([kb, tp]), acc: iops(48, includeCase: false), sp: (spNot, t0 + 5), spLastError: nil, now: t0 + 5)
            check("nearby.part_gone_change", pods(gp) == "airpods~:100/97/na", desc(gp))

            // (9) --nearby-fresh-seconds 0 disables the state (IOPS change and companion both ignored)
            let (z, _) = agg(nearby: 0)
            _ = z.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spNot + [companion], t0), spLastError: nil, now: t0)
            let gz = z.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spNot + [companion], t0 + 5), spLastError: nil, now: t0 + 5)
            check("nearby.disabled_by_zero", pods(gz) == "", desc(gz))

            // (10) AirPods that sp does not list at all (absent) but IOPS does: nearby on change, addr=-
            let spAbsent = spDevices(connected: [kbName, tpName]).filter { $0.name != podName }
            let (ab, lab) = agg()
            _ = ab.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spAbsent, t0), spLastError: nil, now: t0)
            let gab = ab.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spAbsent, t0 + 5), spLastError: nil, now: t0 + 5)
            ab.logBAT(force: true)
            check("nearby.absent_from_sp", pods(gab) == "airpods~:100/97/47" && lab().contains { $0.hasPrefix("BAT") && $0.contains("addr=- ") && $0.contains("nearby=1") },
                  desc(gab))

            // (11) DSP / SUM tokens and signature for nearby groups
            let sum = SummaryFormat.body(sample: nil, groups: gab, sim: false)
            check("nearby.sum_token", sum.contains("airpods=~100/97/47"), sum)
            var st = Snapshot.fixtureState(now: t0)
            st.devices = gab
            check("nearby.dsp_token", StateBuilder.dspBattery(st) == "kb:100 tp:85 pods~ L:100 R:97 C:47", StateBuilder.dspBattery(st))
            check("nearby.signature_distinct", BatteryMonitor.signature(gab) != BatteryMonitor.signature(gab.map { var g = $0; g.presence = .connected; return g }))

            // (12) classic entry absent from sp + the case's BLE entry under device_connected → ONE nearby row (companion
            // is evidence only, never a white "connected" group of its own), also while the IOPS read fails
            let (ac, lac) = agg()
            _ = ac.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spAbsent + [companion], t0), spLastError: nil, now: t0)
            ac.logBAT(force: true)
            let lac0 = lac()
            let gac = ac.groups()
            check("nearby.absent_companion_one_row", pods(gac) == "airpods~:100/97/48" && !lac0.contains { $0.contains("0x????") }
                  && lac0.contains { $0.contains("to=nearby why=ble_companion") } && lac0.contains { $0.hasPrefix("BAT") && $0.contains("src=iops ev=ble") },
                  "\(desc(gac)) \(lac0.joined(separator: " | "))")
            let gacf = ac.merge(hid: .success([kb, tp]), acc: .failure(.injected("bat.iops")), sp: (spAbsent + [companion], t0 + 5), spLastError: nil, now: t0 + 5)
            check("nearby.absent_companion_iops_failed_one_row", pods(gacf) == "airpods~:na/na/61" && !lac().contains { $0.contains("0x????") }, desc(gacf))

            // (13) nearby → sp stale → sp back with the evidence expired: offline is logged why=nearby_stale (not sp)
            let (st3, lst3) = agg()
            _ = st3.merge(hid: .success([kb, tp]), acc: iops(48), sp: (spNot, t0), spLastError: nil, now: t0)
            _ = st3.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spNot, t0 + 5), spLastError: nil, now: t0 + 5)
            let gst = st3.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spNot, t0 + 5), spLastError: .timeout, now: t0 + 60)
            _ = lst3()
            let gst2 = st3.merge(hid: .success([kb, tp]), acc: iops(47), sp: (spNot, t0 + 320), spLastError: nil, now: t0 + 320)
            let lst = lst3()
            check("nearby.stale_then_expired_why", pods(gst) == "airpods:S/S/S" && pods(gst2) == "airpods(off):"
                  && lst.contains { $0.contains("from=stale to=offline why=nearby_stale") }, "\(desc(gst2)) \(lst.joined(separator: " | "))")

            // (14) BAT src = where the numbers came from: companion without levels → src=none (not ble)
            let bare = BTDevice(name: podName, address: "02:11:22:33:44:99", minorType: nil, productID: nil, connected: true, levels: [:])
            let (sn, lsn) = agg()
            let gsn = sn.merge(hid: .success([kb, tp]), acc: iops(pods: false), sp: (spNot + [bare], t0), spLastError: nil, now: t0)
            sn.logBAT(force: true)
            let lsnb = lsn().filter { $0.hasPrefix("BAT") && $0.contains("kind=airpods") }
            check("nearby.src_none_without_values", pods(gsn) == "airpods~:na/na/na" && lsnb.count == 1 && lsnb[0].contains("src=none ev=ble"),
                  lsnb.joined(separator: " | "))

            // (15) order: a nearby group never sorts ahead of AirPods connected to this Mac (page 0, SUM, DSP), also after
            // an IOPS failure flap (nearby → offline → nearby)
            func pod2Parts(_ casePct: Int) -> [AccPart] {
                [AccPart(groupKey: "0x200E:\(pod2)", name: pod2, accessoryID: "aaaa0000-1111-2222-3333-44445555c0de", part: .case,
                         percent: casePct, charging: false, sourceID: 3, entryPart: "Case")]
            }
            func two(_ casePct: Int) -> Result<[AccPart], SourceError> { .success((try! iops(48).get()) + pod2Parts(casePct)) }
            let (o, lo) = agg()
            _ = o.merge(hid: .success([kb, tp]), acc: two(60), sp: (spConn, t0), spLastError: nil, now: t0)
            let go = o.merge(hid: .success([kb, tp]), acc: two(59), sp: (spConn, t0 + 30), spLastError: nil, now: t0 + 30)
            check("nearby.order_connected_first", pods(go) == "airpods[ALEX]:100/97/48 airpods[小明]~:na/na/59", desc(go))
            check("nearby.order_page0_connected", PanelRenderer.pages(go).first.map { $0.contains { if case .pods(let d) = $0 { return d.presence == .connected }; return false } } == true)
            let sumo = SummaryFormat.body(sample: nil, groups: go, sim: false)
            check("nearby.order_sum_connected", sumo.contains("airpods=100/97/48 "), sumo)
            var sto = Snapshot.fixtureState(now: t0)
            sto.devices = go
            check("nearby.order_dsp_page0", StateBuilder.dspBattery(sto) == "kb:100 tp:85 pods[ALEX] L:100 R:97 C:48", StateBuilder.dspBattery(sto))
            _ = o.merge(hid: .success([kb, tp]), acc: .failure(.injected("bat.iops")), sp: (spConn, t0 + 35), spLastError: nil, now: t0 + 35)
            let gof = o.merge(hid: .success([kb, tp]), acc: two(59), sp: (spConn, t0 + 40), spLastError: nil, now: t0 + 40)
            check("nearby.order_after_flap", pods(gof) == "airpods[ALEX]:100/97/48 airpods[小明]~:na/na/59", desc(gof))
            // the most recently connected pair drops to nearby → it moves behind the pair still connected
            let (o2, _) = agg()
            let spBoth = spDevices(connected: [kbName, tpName, podName, pod2])
            _ = o2.merge(hid: .success([kb, tp]), acc: two(60), sp: (spConn, t0), spLastError: nil, now: t0)
            let go2a = o2.merge(hid: .success([kb, tp]), acc: two(60), sp: (spBoth, t0 + 10), spLastError: nil, now: t0 + 10)
            _ = o2.merge(hid: .success([kb, tp]), acc: two(59), sp: (spBoth, t0 + 15), spLastError: nil, now: t0 + 15)
            let go2b = o2.merge(hid: .success([kb, tp]), acc: two(59), sp: (spConn, t0 + 20), spLastError: nil, now: t0 + 20)
            check("nearby.order_recent_pair_goes_nearby", pods(go2a) == "airpods[小明]:na/na/60 airpods[ALEX]:100/97/48"
                  && pods(go2b) == "airpods[ALEX]:100/97/48 airpods[小明]~:na/na/59", "\(desc(go2a)) | \(desc(go2b))")
            // a change-triggered (non-forced) BAT line carries fresh_age_s too (README 8.5.1)
            _ = lo(); o.logBAT(force: true); _ = lo()
            _ = o.merge(hid: .success([kb, tp]), acc: two(58), sp: (spConn, t0 + 45), spLastError: nil, now: t0 + 45)
            o.logBAT(force: false)
            check("nearby.bat_change_line_age", lo().contains { $0.hasPrefix("BAT") && $0.contains("C=58") && $0.contains("nearby=1") && $0.hasSuffix("fresh_age_s=0") })

            // (16) owner tag of a group sp does not list (no BT address, no possessive name) comes from the IOPS
            // Accessory Identifier, never "?"
            func anonIOPS(_ pct: Int) -> Result<[AccPart], SourceError> {
                .success((try! iops(48).get()) + [AccPart(groupKey: "0x2024:AirPods Pro", name: "AirPods Pro", accessoryID: "12345678-1206-8f22-52e6-00000000bcd1",
                                                          part: .left, percent: pct, charging: false, sourceID: 4, entryPart: "Combined")])
            }
            let (tg, _) = agg()
            _ = tg.merge(hid: .success([kb, tp]), acc: anonIOPS(70), sp: (spConn, t0), spLastError: nil, now: t0)
            let gtg = tg.merge(hid: .success([kb, tp]), acc: anonIOPS(69), sp: (spConn, t0 + 5), spLastError: nil, now: t0 + 5)
            check("nearby.absent_owner_tag", pods(gtg) == "airpods[ALEX]:100/97/48 airpods[BCD1]~:69/na/na", desc(gtg))
        }
        return out
    }
}
