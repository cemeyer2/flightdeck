import Foundation
// Peripherals › link speeds, the USB diagnosis: for each device, what it supports, what its path to the Mac supports
// (the root port, or the hub it hangs off), and why the negotiated speed is lower when it is.

public enum USBLinks {
    /// SSD-like names: USB 2-only SSDs essentially don't exist, so an SSD at 480 Mb/s is being held back.
    static func looksLikeSSD(_ name: String, vendor: String?) -> Bool {
        let s = (name + " " + (vendor ?? "")).lowercased()
        if s.contains("ssd") || s.contains("nvme") { return true }
        let words = Set(s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return s.contains("samsung") && !words.isDisjoint(with: ["t5", "t7", "t9"])
    }

    /// What the device supports, from what it negotiated, its descriptor and (for drives) its name.
    static func deviceSupport(_ d: USBLinkInput) -> LinkSupport {
        let neg = d.negotiatedMbps ?? 0
        if neg >= 5000 { return LinkSupport(mbps: neg, text: "at least \(LinkRate.text(neg)) (it linked at that)") }
        if let b = d.bcdUSB, b >= 0x0300 {
            let range = b >= 0x0320 ? "5, 10 or 20 Gb/s" : b >= 0x0310 ? "5 or 10 Gb/s" : "5 Gb/s"
            return LinkSupport(mbps: 5000, text: String(format: "USB 3 (USB %x.%x descriptor: %@)", b >> 8, (b >> 4) & 0xf, range))
        }
        if d.isStorage && looksLikeSSD(d.name, vendor: d.vendor) {
            return LinkSupport(mbps: 5000, text: "probably 5 Gb/s or more (an SSD; USB 2 SSDs are practically nonexistent)", inferred: true)
        }
        if let b = d.bcdUSB, b >= 0x0210 { return LinkSupport(mbps: nil, text: "USB 2.1 descriptor: USB 2, or a USB 3 device that fell back") }
        if let b = d.bcdUSB, b >= 0x0200 { return LinkSupport(mbps: 480, text: "USB 2 (480 Mb/s)") }
        if let b = d.bcdUSB, b > 0 { return LinkSupport(mbps: 12, text: "USB 1 (12 Mb/s)") }
        return LinkSupport(mbps: nil, text: "not reported")
    }

    /// Hubs in front of `d`, nearest the Mac first, and the topmost device (the one on the root port).
    static func chain(_ d: USBLinkInput, _ byID: [UInt64: USBLinkInput]) -> (hubs: [USBLinkInput], root: USBLinkInput) {
        var hubs: [USBLinkInput] = [], cur = d, seen: Set<UInt64> = [d.id]
        while let p = cur.parent, let h = byID[p], seen.insert(p).inserted { hubs.insert(h, at: 0); cur = h }
        return (hubs, cur)
    }

    /// A USB 3 hub shows up twice: its USB 2 half and its USB 3 half, siblings with the same vendor. The USB 3 half's
    /// link, if `hub` is the USB 2 half and the twin is present.
    static func superSpeedTwin(of hub: USBLinkInput, in all: [USBLinkInput]) -> USBLinkInput? {
        all.first { $0.id != hub.id && $0.isHub && $0.parent == hub.parent && $0.vendorID == hub.vendorID && ($0.negotiatedMbps ?? 0) >= 5000 }
    }

    /// What the path to the Mac supports: the hub directly in front, or the root port.
    static func pathSupport(_ d: USBLinkInput, hubs: [USBLinkInput], root: USBLinkInput, all: [USBLinkInput]) -> (LinkSupport, hubIsUSB2: Bool) {
        if let hub = hubs.last {
            let own = hub.negotiatedMbps ?? 0
            if own >= 5000 { return (LinkSupport(mbps: own, text: "behind \(hub.name), linked at \(LinkRate.text(own))"), false) }
            if let twin = superSpeedTwin(of: hub, in: all), let t = twin.negotiatedMbps {
                return (LinkSupport(mbps: t, text: "behind \(hub.name), a USB 3 hub linked at \(LinkRate.text(t))"), false)
            }
            if own > 0 { return (LinkSupport(mbps: own, text: "behind \(hub.name), linked at \(LinkRate.usbName(own)) (no USB 3 link)"), true) }
            return (LinkSupport(mbps: nil, text: "behind \(hub.name) (its speed not reported)"), false)
        }
        if root.tunnelled { return (LinkSupport(mbps: nil, text: "through a Thunderbolt/USB4 dock (see its link below)"), false) }
        guard let port = root.port else { return (LinkSupport(mbps: nil, text: "port not reported"), false) }
        let where_ = port.usbC.map { " (\($0.name))" } ?? ""
        switch port.superSpeedCapable {
        case false?: return (LinkSupport(mbps: 480, text: "USB 2-only port" + where_), false)
        case true?:
            if let m = port.maxMbps { return (LinkSupport(mbps: m, text: "USB 3 port, up to \(LinkRate.text(m))" + where_), false) }
            return (LinkSupport(mbps: 5000, text: "USB 3 port (at least 5 Gb/s; its maximum isn't reported)" + where_), false)
        case nil: return (LinkSupport(mbps: nil, text: "port capability not reported" + where_), false)
        }
    }

    public static func analyze(_ inputs: [USBLinkInput]) -> [USBLink] {
        let byID = Dictionary(inputs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return inputs.map { d in
            let (hubs, root) = chain(d, byID)
            let dev = deviceSupport(d)
            let (path, hubIsUSB2) = pathSupport(d, hubs: hubs, root: root, all: inputs)
            let effective = d.isStorage ? d.negotiatedMbps.map(LinkRate.usbStorageMBps) : nil
            let diag = diagnose(d, device: dev, path: path, hubs: hubs, hubIsUSB2: hubIsUSB2, effectiveMBps: effective)
            return USBLink(id: d.id, parent: d.parent, name: d.name, vendor: d.vendor, isHub: d.isHub, isStorage: d.isStorage, negotiatedMbps: d.negotiatedMbps,
                           device: dev, port: path, hubs: hubs.map(\.name), effectiveMBps: effective, diagnosis: diag)
        }
    }

    static func diagnose(_ d: USBLinkInput, device dev: LinkSupport, path: LinkSupport, hubs: [USBLinkInput], hubIsUSB2: Bool,
                         effectiveMBps: Double?) -> LinkDiagnosis {
        guard let neg = d.negotiatedMbps else { return LinkDiagnosis(level: .note, summary: "\(d.name) didn't report its link speed.") }
        let drive = effectiveMBps.map { String(format: " As a drive, expect at most about %@ MB/s.", Int($0).formatted()) } ?? ""
        let canDo = [dev.mbps, path.mbps].compactMap { $0 }.min()
        // The headline case: a SuperSpeed-capable device on a SuperSpeed-capable path, running at USB 2 or slower.
        if neg <= 480, let dm = dev.mbps, dm >= 5000 {
            let head = "\(d.name) is running at \(LinkRate.usbName(neg)) but supports \(LinkRate.text(dm))\(dev.inferred ? " (probably)" : "")"
            if let hub = hubs.last, hubIsUSB2 {
                return LinkDiagnosis(level: .slow, summary: "\(head): the hub \(hub.name) is USB 2-only or linked at USB 2.\(drive)",
                                     advice: "Plug \(d.name) straight into the Mac, or use a USB 3 hub with a 5 Gb/s (or faster) cable.")
            }
            if let hub = hubs.last {
                return LinkDiagnosis(level: .slow, summary: "\(head): \(hub.name) has USB 3, so the cable between them is probably USB 2-only.\(drive)",
                                     advice: "Try a cable rated 10 Gb/s between \(d.name) and the hub, or plug it straight into the Mac.")
            }
            if path.mbps == 480 {
                return LinkDiagnosis(level: .slow, summary: "\(head): this port is USB 2 only.\(drive)", advice: "Use a USB 3 or USB-C port on the Mac.")
            }
            return LinkDiagnosis(level: .slow, summary: "\(head): the cable or adapter is limiting it.\(drive)",
                                 advice: "Try a USB-C cable rated 10 Gb/s (charging cables are often USB 2 only), or plug it straight into the Mac without an adapter.")
        }
        // 5 Gb/s on a 10 Gb/s path from a device whose descriptor allows 10: possible, not certain (it may be a Gen 1 device).
        if neg >= 5000, neg < 10000, let pm = path.mbps, pm >= 10000, let b = d.bcdUSB, b >= 0x0310, d.isStorage {
            return LinkDiagnosis(level: .note, summary: "\(d.name) linked at \(LinkRate.text(neg)); the port supports \(LinkRate.text(pm)).\(drive)",
                                 advice: "If it is a 10 Gb/s drive, its cable may be a 5 Gb/s one.")
        }
        if d.isHub { return LinkDiagnosis(level: .ok, summary: "Hub linked at \(LinkRate.usbName(neg)).") }
        if neg <= 12 { return LinkDiagnosis(level: .ok, summary: "\(LinkRate.usbName(neg)): plenty for an input device or accessory.\(drive)") }
        if let c = canDo, neg >= c * 0.95 || neg >= 5000 {
            return LinkDiagnosis(level: .ok, summary: "Running at full speed: \(LinkRate.usbName(neg)).\(drive)")
        }
        return LinkDiagnosis(level: .ok, summary: "Linked at \(LinkRate.usbName(neg)).\(drive)")
    }

    /// Depth-first order (hubs before what hangs off them) with nesting depth, for drawing the tree.
    public static func tree(_ links: [USBLink]) -> [(link: USBLink, depth: Int)] {
        let ids = Set(links.map(\.id))
        let kids = Dictionary(grouping: links) { l in l.parent.flatMap { ids.contains($0) ? $0 : nil } ?? 0 }
        var out: [(USBLink, Int)] = []
        func walk(_ p: UInt64, _ depth: Int) {
            for l in (kids[p] ?? []).sorted(by: { $0.name < $1.name }) where depth < 8 { out.append((l, depth)); walk(l.id, depth + 1) }
        }
        walk(0, 0)
        return out
    }

    /// Engine findings for drives linked well below what they and their port support. Ids include the registry entry ID,
    /// which is new on every plug-in, so a finding is raised once per plug-in.
    public static func findings(_ links: [USBLink], now: Date) -> [Finding] {
        links.filter { $0.isStorage && $0.diagnosis.level == .slow }.map { l in
            Finding(id: "usb-slow:\(l.id)", severity: .caution, icon: "externaldrive.badge.exclamationmark",
                    title: "\(l.name) is connected at \(l.negotiatedMbps.map(LinkRate.usbName) ?? "a slow speed")",
                    detail: l.diagnosis.text, since: now, destination: "Peripherals")
        }
    }
}
