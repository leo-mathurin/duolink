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
    /// Upstream connections that failed in a row. Non-zero for a while means
    /// the server is unreachable and proxied apps have no internet.
    public var consecutiveFailures = 0

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
    private let statsLock = OSAllocatedUnfairLock(initialState: RelayStats())
    private var listener: NWListener?
    private var pairs: [ObjectIdentifier: RelayPair] = [:]

    private let timing: UpstreamDialer.Timing

    public init(
        upstreamHost: String,
        upstreamPort: UInt16,
        mode: MultipathMode,
        timing: UpstreamDialer.Timing = .init()
    ) {
        self.upstreamHost = NWEndpoint.Host(upstreamHost)
        self.upstreamPort = NWEndpoint.Port(rawValue: upstreamPort)!
        self.mode = mode
        self.timing = timing
    }

    public var stats: RelayStats { statsLock.withLock { $0 } }

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
                case .cancelled:
                    // `stop()` ran before the listener was ready.
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
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
        let dialer = UpstreamDialer(queue: queue, timing: timing) { [upstreamHost, upstreamPort, mode] prohibited in
            let parameters = Self.upstreamParameters(mode: mode)
            parameters.prohibitedInterfaces = prohibited
            return NWConnection(host: upstreamHost, port: upstreamPort, using: parameters)
        }
        let pair = RelayPair(inbound: inbound, dialer: dialer, queue: queue) { [weak self] direction, count in
            self?.statsLock.withLock {
                switch direction {
                case .up: $0.bytesUp += UInt64(count)
                case .down: $0.bytesDown += UInt64(count)
                }
            }
        }
        let id = ObjectIdentifier(pair)
        pairs[id] = pair
        statsLock.withLock {
            $0.connectionsOpened += 1
            $0.activeConnections += 1
        }
        pair.onConnected = { [weak self] in
            self?.statsLock.withLock { $0.consecutiveFailures = 0 }
        }
        pair.onClose = { [weak self] dialError in
            guard let self else { return }
            self.pairs[id] = nil
            self.statsLock.withLock {
                $0.activeConnections -= 1
                if let dialError {
                    $0.lastError = dialError
                    $0.consecutiveFailures += 1
                }
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
    private let dialer: UpstreamDialer
    private var outbound: NWConnection?
    private let queue: DispatchQueue
    private let onBytes: (Direction, Int) -> Void
    private var finishedDirections = 0
    private var closed = false
    var onConnected: (() -> Void)?
    /// Receives the dial error when the upstream could not be reached.
    var onClose: ((String?) -> Void)?

    init(inbound: NWConnection, dialer: UpstreamDialer, queue: DispatchQueue, onBytes: @escaping (Direction, Int) -> Void) {
        self.inbound = inbound
        self.dialer = dialer
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
        inbound.start(queue: queue)
        dialer.dial { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .success(let outbound):
                self.outbound = outbound
                self.onConnected?()
                outbound.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .failed, .cancelled: self?.close()
                    default: break
                    }
                }
                self.pump(from: self.inbound, to: outbound, direction: .up)
                self.pump(from: outbound, to: self.inbound, direction: .down)
            case .failure(let error):
                self.close(error: error.message)
            }
        }
    }

    private func pump(from source: NWConnection, to sink: NWConnection, direction: Direction) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            let next: @Sendable () -> Void = {
                if isComplete {
                    self.finish(sink)
                } else if error != nil {
                    self.close()
                } else {
                    self.pump(from: source, to: sink, direction: direction)
                }
            }
            guard let data, !data.isEmpty else { return next() }
            self.onBytes(direction, data.count)
            sink.send(content: data, completion: .contentProcessed { [weak self] sendError in
                guard let self, !self.closed else { return }
                sendError == nil ? next() : self.close()
            })
        }
    }

    /// Forwards a half-close; the pair closes once both sides are done.
    private func finish(_ sink: NWConnection) {
        // `.finalMessage` is what makes Network.framework send a FIN.
        sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.finishedDirections += 1
            if self.finishedDirections == 2 { self.close(linger: true) }
        })
    }

    /// `linger` keeps the connections alive for a while after a clean close:
    /// cancelling right after the FIN drops data still in the send buffers.
    func close(error: String? = nil, linger: Bool = false) {
        guard !closed else { return }
        closed = true
        dialer.cancel()
        onClose?(error)
        onClose = nil
        let connections = [inbound, outbound].compactMap { $0 }
        if linger {
            queue.asyncAfter(deadline: .now() + 30) { connections.forEach { $0.cancel() } }
        } else {
            connections.forEach { $0.cancel() }
        }
    }
}
