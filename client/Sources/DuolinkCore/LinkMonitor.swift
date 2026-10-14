import Darwin
import Foundation
import Network
import SystemConfiguration

public struct LinkStatus: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case wifi, iPhone, ethernet, cellular }

    public var id: String { interface }
    public var interface: String
    public var name: String
    public var kind: Kind
    public var rates: Throughput
}

/// Lists the interfaces MPTCP can use and how much traffic each one carries,
/// which is the visible proof that both links are working together.
public final class LinkMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "duolink.links")
    private let pathMonitor = NWPathMonitor()
    private var timer: DispatchSourceTimer?
    private var available: [NWInterface] = []
    private var meters: [String: (down: RateMeter, up: RateMeter)] = [:]

    public init() {}

    public func start(update: @escaping @Sendable ([LinkStatus]) -> Void) {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            // The same interface can be listed once per address family.
            var seen = Set<String>()
            self?.available = path.availableInterfaces.filter {
                [.wifi, .wiredEthernet, .cellular].contains($0.type) && seen.insert($0.name).inserted
            }
        }
        pathMonitor.start(queue: queue)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            update(self.sample())
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        pathMonitor.cancel()
    }

    private func sample() -> [LinkStatus] {
        let counters = Self.readCounters()
        let names = Self.displayNames()
        let now = ProcessInfo.processInfo.systemUptime
        return available.map { interface in
            let bsd = interface.name
            let name = names[bsd] ?? bsd
            var meter = meters[bsd] ?? (RateMeter(counterWidth: 32), RateMeter(counterWidth: 32))
            let bytes = counters[bsd] ?? (0, 0)
            let down = meter.down.record(bytes: bytes.received, at: now) ?? 0
            let up = meter.up.record(bytes: bytes.sent, at: now) ?? 0
            meters[bsd] = meter
            return LinkStatus(
                interface: bsd,
                name: name,
                kind: Self.kind(of: interface, displayName: name),
                rates: Throughput(down: down, up: up)
            )
        }
    }

    static func kind(of interface: NWInterface, displayName: String) -> LinkStatus.Kind {
        if isIPhone(displayName: displayName) { return .iPhone }
        switch interface.type {
        case .wifi: return .wifi
        case .cellular: return .cellular
        default: return .ethernet
        }
    }

    /// Matches the port macOS creates for a USB-tethered iPhone, such as "iPhone USB".
    static func isIPhone(displayName: String) -> Bool {
        displayName.localizedCaseInsensitiveContains("iphone")
    }

    /// Byte counters per BSD interface. `if_data` holds 32-bit counters.
    static func readCounters() -> [String: (received: UInt64, sent: UInt64)] {
        var result: [String: (UInt64, UInt64)] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return result }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let raw = entry.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            result[String(cString: entry.ifa_name)] = (UInt64(data.ifi_ibytes), UInt64(data.ifi_obytes))
        }
        return result
    }

    /// Maps `en7` to the name System Settings shows, such as "iPhone USB".
    static func displayNames() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var names: [String: String] = [:]
        for interface in interfaces {
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                names[bsd] = name
            }
        }
        return names
    }
}
