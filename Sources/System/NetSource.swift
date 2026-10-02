// NetSource.swift — network counters (AM Network-tab footer semantics, exact IFMIB source; spec §5.3).
//
// * Read: ifcount = sysctl {CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT}; for idx in 1...ifcount
//   sysctl {…, IFMIB_IFDATA, idx, IFDATA_GENERAL} → struct ifmibdata (exact 64-bit counters for an unentitled
//   process; NET_RT_IFLIST2 / getifaddrs would give bytes mod 2³² floored to 1 KiB). ENOENT (index gap) is skipped;
//   any other errno, or no ifcount → the whole read fails (`ERR src=net.if`).
// * AM filter (NetFilter.included): drop IFF_LOOPBACK; drop IFF_POINTOPOINT unless ifi_type == 0xff (IFT_CELLULAR);
//   drop names starting "anpi"; no IFF_UP check.
// * Totals: 64-bit sums of ifi_ipackets / opackets / ibytes / obytes over the included interfaces (since boot).
// * Rates (NetDelta.feed): per-interface deltas keyed by (index, name), summed only over interfaces present in both
//   reads (an interface appearing / disappearing never makes a spike); a counter that went DOWN contributes 0 and
//   writes `WARN net_counter_reset if= field=` (≤ 1 per key per 60 s, sampler throttle); divided by the measured
//   CLOCK_UPTIME_RAW dt. First read / after a reset (wake) / dt > 5 s → baseline only, rates nil (totals still
//   reported); dt < 0.5 s → `.skipped(dt_short)`, baseline unchanged. Injected `garbage net.if`: every included
//   interface's ibytes is set to (baseline − 1) and goes through the normal path (→ download rate 0 + WARN); the
//   baseline becomes the REAL reading, so the next sample is a normal 1 s delta.
// Owner: sampler agent.
import Darwin
import Foundation

/// One interface's IFMIB counters.
struct IfCounters: Equatable, Sendable {
    var index: Int32
    var name: String
    var flags: UInt32
    var type: UInt8
    var ipackets: UInt64, opackets: UInt64, ibytes: UInt64, obytes: UInt64
}

enum NetFilter {
    static let cellularType: UInt8 = 0xff   // IFT_CELLULAR
    /// AM -[SMStatisticsManager processSystemSysmonTable:] interface filter.
    static func included(name: String, flags: UInt32, type: UInt8) -> Bool {
        if flags & UInt32(IFF_LOOPBACK) != 0 { return false }
        if flags & UInt32(IFF_POINTOPOINT) != 0 && type != cellularType { return false }
        if name.hasPrefix("anpi") { return false }
        return true
    }
    static func included(_ c: IfCounters) -> Bool { included(name: c.name, flags: c.flags, type: c.type) }
}

/// Per-interface baseline + guards. sysQ only (a value type owned by the sampler engine).
struct NetDelta {
    struct Key: Hashable { let index: Int32; let name: String }
    static let minDt = 0.5, maxDt = 5.0
    private(set) var base: (ifs: [Key: IfCounters], ns: UInt64)?

    mutating func reset() { base = nil }

    /// `ifs` must already be filtered (NetFilter). Returns the reading and the counter-reset WARNs (throttle key, body).
    mutating func feed(_ ifs: [IfCounters], ns: UInt64, garbage: Bool = false) -> (Reading<NetReading>, warns: [(String, String)]) {
        if let b = base, ns >= b.ns, Double(ns - b.ns) / 1e9 < NetDelta.minDt { return (.skipped(reason: "dt_short"), []) }
        var eff = ifs
        if garbage, let b = base {
            for i in eff.indices {
                if let old = b.ifs[Key(index: eff[i].index, name: eff[i].name)] { eff[i].ibytes = old.ibytes > 0 ? old.ibytes - 1 : 0 }
            }
        }
        var pIn: UInt64 = 0, pOut: UInt64 = 0, bIn: UInt64 = 0, bOut: UInt64 = 0
        for c in eff { pIn &+= c.ipackets; pOut &+= c.opackets; bIn &+= c.ibytes; bOut &+= c.obytes }
        var real: [Key: IfCounters] = [:]
        real.reserveCapacity(ifs.count)
        for c in ifs { real[Key(index: c.index, name: c.name)] = c }

        func totalsOnly() -> NetReading {
            NetReading(pktIn: pIn, pktOut: pOut, bytesIn: bIn, bytesOut: bOut, pktInRate: nil, pktOutRate: nil, rxRate: nil, txRate: nil, ifaces: ifs.count)
        }
        guard let b = base, ns >= b.ns else { base = (real, ns); return (.value(totalsOnly()), []) }
        let dt = Double(ns - b.ns) / 1e9
        if dt > NetDelta.maxDt { base = (real, ns); return (.value(totalsOnly()), []) }

        var warns: [(String, String)] = []
        var dpi: UInt64 = 0, dpo: UInt64 = 0, dbi: UInt64 = 0, dbo: UInt64 = 0
        func d(_ new: UInt64, _ old: UInt64, _ c: IfCounters, _ field: String) -> UInt64 {
            if new >= old { return new - old }
            warns.append(("net_counter_reset:\(c.name):\(field)", "net_counter_reset if=\(c.name) field=\(field) old=\(old) new=\(new)"))
            return 0
        }
        for c in eff {
            guard let o = b.ifs[Key(index: c.index, name: c.name)] else { continue }   // appeared: baseline only
            dpi &+= d(c.ipackets, o.ipackets, c, "ipackets"); dpo &+= d(c.opackets, o.opackets, c, "opackets")
            dbi &+= d(c.ibytes, o.ibytes, c, "ibytes"); dbo &+= d(c.obytes, o.obytes, c, "obytes")
        }
        base = (real, ns)
        let r = NetReading(pktIn: pIn, pktOut: pOut, bytesIn: bIn, bytesOut: bOut,
                           pktInRate: Double(dpi) / dt, pktOutRate: Double(dpo) / dt, rxRate: Double(dbi) / dt, txRate: Double(dbo) / dt,
                           ifaces: ifs.count)
        return (.value(r), warns)
    }
}

/// Live IFMIB reads (all interfaces, unfiltered). Called on sysQ only.
final class NetReader: @unchecked Sendable {
    func read() -> Result<[IfCounters], SourceError> {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT]
        var n: Int32 = 0
        var len = MemoryLayout<Int32>.size
        guard sysctl(&mib, 5, &n, &len, nil, 0) == 0 else { return .failure(.errno(errno, "ifcount")) }
        guard n > 0 else { return .failure(.parse("ifcount=\(n)")) }
        var out: [IfCounters] = []
        out.reserveCapacity(Int(n))
        var m: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, 0, IFDATA_GENERAL]
        for idx in 1...n {
            m[4] = idx
            var d = ifmibdata()
            var l = MemoryLayout<ifmibdata>.size
            if sysctl(&m, 6, &d, &l, nil, 0) != 0 {
                let e = errno
                if e == ENOENT { continue }
                return .failure(.errno(e, "ifdata.\(idx)"))
            }
            let name = withUnsafeBytes(of: d.ifmd_name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            out.append(IfCounters(index: idx, name: name, flags: d.ifmd_flags, type: d.ifmd_data.ifi_type,
                                  ipackets: d.ifmd_data.ifi_ipackets, opackets: d.ifmd_data.ifi_opackets,
                                  ibytes: d.ifmd_data.ifi_ibytes, obytes: d.ifmd_data.ifi_obytes))
        }
        return .success(out)
    }
}
