import Foundation
import Network

/// Opens the connection to the server, working around a dead primary link.
///
/// MPTCP always sends its first subflow on the primary interface. On a train
/// that is often a Wi-Fi that is joined but has no internet (portal not yet
/// accepted, tunnel, dead backhaul), and the connection would hang there. When
/// the first attempt is not ready after `fallbackDelay`, a second attempt
/// starts that avoids the interface the first one is stuck on. The first
/// attempt to become ready wins; the other subflows join later if they can.
///
/// Every member is only touched on `queue`.
public final class UpstreamDialer: @unchecked Sendable {
    public struct Timing: Sendable {
        public var fallbackDelay: TimeInterval = 2.5
        public var timeout: TimeInterval = 15

        public init(fallbackDelay: TimeInterval = 2.5, timeout: TimeInterval = 15) {
            self.fallbackDelay = fallbackDelay
            self.timeout = timeout
        }
    }

    public struct Failure: Error {
        public let message: String
    }

    private let queue: DispatchQueue
    private let timing: Timing
    private let makeConnection: ([NWInterface]) -> NWConnection
    private var attempts: [NWConnection] = []
    private var fallbackStarted = false
    private var completion: ((Result<NWConnection, Failure>) -> Void)?
    private var lastError: NWError?

    /// `makeConnection` receives the interfaces the attempt must avoid.
    init(queue: DispatchQueue, timing: Timing, makeConnection: @escaping ([NWInterface]) -> NWConnection) {
        self.queue = queue
        self.timing = timing
        self.makeConnection = makeConnection
    }

    func dial(completion: @escaping (Result<NWConnection, Failure>) -> Void) {
        self.completion = completion
        start(makeConnection([]))
        queue.asyncAfter(deadline: .now() + timing.fallbackDelay) { [weak self] in self?.startFallback() }
        queue.asyncAfter(deadline: .now() + timing.timeout) { [weak self] in
            self?.finish(.failure(Failure(message: self?.lastError.map { "\($0)" } ?? "délai de connexion dépassé")))
        }
    }

    func cancel() {
        completion = nil
        for attempt in attempts { attempt.cancel() }
        attempts.removeAll()
    }

    private func start(_ connection: NWConnection) {
        attempts.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.finish(.success(connection))
            case .waiting(let error):
                self.lastError = error
                if Self.isDefinitive(error) {
                    self.finish(.failure(Failure(message: "\(error)")))
                } else {
                    self.startFallback()
                }
            case .failed(let error):
                self.lastError = error
                connection.cancel()
                self.attempts.removeAll { $0 === connection }
                if self.attempts.isEmpty {
                    self.finish(.failure(Failure(message: "\(error)")))
                } else {
                    self.startFallback()
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func startFallback() {
        guard completion != nil, !fallbackStarted,
              let first = attempts.first,
              let path = first.currentPath,
              let stuck = path.availableInterfaces.first,
              path.availableInterfaces.contains(where: { $0 != stuck })
        else { return }
        fallbackStarted = true
        start(makeConnection([stuck]))
    }

    private func finish(_ result: Result<NWConnection, Failure>) {
        guard let completion else { return }
        self.completion = nil
        let winner = try? result.get()
        for attempt in attempts where attempt !== winner {
            attempt.stateUpdateHandler = nil
            attempt.cancel()
        }
        attempts.removeAll()
        winner?.stateUpdateHandler = nil
        completion(result)
    }

    /// Errors no other interface would fix: the server refused the
    /// connection, or macOS refused the aggregation mode.
    static func isDefinitive(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .ECONNREFUSED || code == .EACCES }
        return false
    }
}
