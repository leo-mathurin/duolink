import Foundation
import Network
import os

/// How macOS spreads one MPTCP connection over the available interfaces.
public enum MultipathMode: String, CaseIterable, Codable, Sendable {
    /// Sends on every interface at once to add their bandwidth. Needs
    /// `net.inet.mptcp.allow_aggregate=1`, see `AggregatePermission`.
    case aggregate
    /// Uses the lowest-latency interface and spills over to the others.
    case interactive
    /// Uses the primary interface and keeps the others as hot standby.
    case handover
    /// Plain TCP. Used by tests over loopback.
    case disabled

    var serviceType: NWParameters.MultipathServiceType {
        switch self {
        case .aggregate: .aggregate
        case .interactive: .interactive
        case .handover: .handover
        case .disabled: .disabled
        }
    }
}

public struct RelayStats: Sendable, Equatable {
    public var connectionsOpened = 0
    public var activeConnections = 0
    public var bytesUp: UInt64 = 0
    public var bytesDown: UInt64 = 0
    public var lastError: String?

    public init() {}
}

/// Accepts plain TCP on loopback and forwards each connection to the server
/// over a Multipath TCP connection opened with Network.framework, the only
/// API that exposes MPTCP to third-party apps on macOS.
public final class MultipathRelay: @unchecked Sendable {
    private let upstreamHost: NWEndpoint.Host
    private let upstreamPort: NWEndpoint.Port
    private let mode: MultipathMode
    private let queue = DispatchQueue(label: "duolink.relay")
    private let state = OSAllocatedUnfairLock(initialState: RelayStats())
    private var listener: NWListener?
    private var pairs: [ObjectIdentifier: RelayPair] = [:]

    public init(upstreamHost: String, upstreamPort: UInt16, mode: MultipathMode) {
        self.upstreamHost = NWEndpoint.Host(upstreamHost)
        self.upstreamPort = NWEndpoint.Port(rawValue: upstreamPort)!
        self.mode = mode
    }

    public var stats: RelayStats { state.withLock { $0 } }

    /// Starts listening on 127.0.0.1. Pass 0 to pick a free port.
    /// Returns the bound port.
    public func start(port: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            queue.async {
                self.listener = listener
                listener.start(queue: self.queue)
            }
        }
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for pair in self.pairs.values { pair.close() }
            self.pairs.removeAll()
        }
    }

    static func upstreamParameters(mode: MultipathMode) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.multipathServiceType = mode.serviceType
        // Network.framework honours the system SOCKS proxy, which is sing-box
        // itself: without this the relay would loop back into the proxy.
        parameters.preferNoProxies = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            // Keeps carrier NAT mappings alive on idle connections.
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
        }
        return parameters
    }

    private func accept(_ inbound: NWConnection) {
        let parameters = Self.upstreamParameters(mode: mode)
        let outbound = NWConnection(host: upstreamHost, port: upstreamPort, using: parameters)

        let pair = RelayPair(inbound: inbound, outbound: outbound, queue: queue) { [weak self] direction, count in
            self?.state.withLock {
                switch direction {
                case .up: $0.bytesUp += UInt64(count)
                case .down: $0.bytesDown += UInt64(count)
                }
            }
        }
        let id = ObjectIdentifier(pair)
        pairs[id] = pair
        state.withLock {
            $0.connectionsOpened += 1
            $0.activeConnections += 1
        }
        pair.onClose = { [weak self] error in
            guard let self else { return }
            self.pairs[id] = nil
            self.state.withLock {
                $0.activeConnections -= 1
                if let error { $0.lastError = error }
            }
        }
        pair.start()
    }
}

/// One client connection and its upstream twin. Every member is only touched
/// on the relay queue, which is what makes the unchecked conformance safe.
private final class RelayPair: @unchecked Sendable {
    enum Direction { case up, down }

    private let inbound: NWConnection
    private let outbound: NWConnection
    private let queue: DispatchQueue
    private let onBytes: (Direction, Int) -> Void
    private var finishedDirections = 0
    private var closed = false
    var onClose: ((String?) -> Void)?

    init(inbound: NWConnection, outbound: NWConnection, queue: DispatchQueue, onBytes: @escaping (Direction, Int) -> Void) {
        self.inbound = inbound
        self.outbound = outbound
        self.queue = queue
        self.onBytes = onBytes
    }

    func start() {
        inbound.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        outbound.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.pump(from: self.inbound, to: self.outbound, direction: .up)
                self.pump(from: self.outbound, to: self.inbound, direction: .down)
            case .waiting(let error), .failed(let error):
                // `.waiting` covers refused connections and a missing
                // aggregate permission (EACCES). The client retries anyway.
                self.close(error: "\(error)")
            case .cancelled:
                self.close()
            default:
                break
            }
        }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
    }

    private func pump(from source: NWConnection, to sink: NWConnection, direction: Direction) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.onBytes(direction, data.count)
                sink.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self, !self.closed else { return }
                    if sendError != nil {
                        self.close()
                    } else if isComplete {
                        self.finish(sink)
                    } else if error != nil {
                        self.close()
                    } else {
                        self.pump(from: source, to: sink, direction: direction)
                    }
                })
            } else if isComplete {
                self.finish(sink)
            } else if error != nil {
                self.close()
            } else {
                self.pump(from: source, to: sink, direction: direction)
            }
        }
    }

    /// Forwards a half-close; the pair closes once both sides are done.
    private func finish(_ sink: NWConnection) {
        // `.finalMessage` is what makes Network.framework send a FIN.
        sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.finishedDirections += 1
            if self.finishedDirections == 2 { self.close() }
        })
    }

    func close(error: String? = nil) {
        guard !closed else { return }
        closed = true
        inbound.cancel()
        outbound.cancel()
        onClose?(error)
        onClose = nil
    }
}
