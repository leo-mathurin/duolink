import Foundation
import Network
import Testing
@testable import DuolinkCore

/// Exercises the relay over loopback with multipath off: loopback has a single
/// interface, so this checks the byte pump, not the aggregation itself.
@Suite(.timeLimit(.minutes(1))) struct MultipathRelayTests {
    @Test func pipesBytesBothWaysAndCountsThem() async throws {
        let echo = try await EchoServer.start()
        defer { echo.stop() }
        let relay = MultipathRelay(
            upstreamHost: "127.0.0.1",
            upstreamPort: echo.port,
            mode: .disabled
        )
        let port = try await relay.start(port: 0)
        defer { relay.stop() }

        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let reply = try await LoopbackClient.roundTrip(port: port, payload: payload)

        #expect(reply == payload)
        try await waitUntil { relay.stats.bytesUp == UInt64(payload.count) && relay.stats.bytesDown == UInt64(payload.count) }
        #expect(relay.stats.connectionsOpened == 1)
    }

    @Test func dropsTheClientWhenTheUpstreamIsUnreachable() async throws {
        // Port 1 on loopback refuses connections.
        let relay = MultipathRelay(upstreamHost: "127.0.0.1", upstreamPort: 1, mode: .disabled)
        let port = try await relay.start(port: 0)
        defer { relay.stop() }

        let reply = try await LoopbackClient.roundTrip(port: port, payload: Data("hi".utf8))
        #expect(reply.isEmpty)
        try await waitUntil { relay.stats.activeConnections == 0 && relay.stats.connectionsOpened == 1 }
    }

    @Test func upstreamBypassesTheSystemProxyThatPointsBackAtUs() {
        let parameters = MultipathRelay.upstreamParameters(mode: .aggregate)
        #expect(parameters.preferNoProxies)
        #expect(parameters.multipathServiceType == .aggregate)
    }

    @Test func tracksActiveConnections() async throws {
        let echo = try await EchoServer.start()
        defer { echo.stop() }
        let relay = MultipathRelay(upstreamHost: "127.0.0.1", upstreamPort: echo.port, mode: .disabled)
        let port = try await relay.start(port: 0)
        defer { relay.stop() }

        let client = try await LoopbackClient.connect(port: port)
        try await waitUntil { relay.stats.activeConnections == 1 }
        client.cancel()
        try await waitUntil { relay.stats.activeConnections == 0 }
    }
}

// MARK: - Helpers

func waitUntil(
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition not met before timeout", sourceLocation: sourceLocation)
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

final class EchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "echo")
    var port: UInt16 { listener.port!.rawValue }

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> EchoServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let server = EchoServer(listener: listener)
        listener.newConnectionHandler = { conn in
            conn.start(queue: server.queue)
            server.echo(conn)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: cont.resume(); listener.stateUpdateHandler = nil
                case .failed(let error): cont.resume(throwing: error); listener.stateUpdateHandler = nil
                default: break
                }
            }
            listener.start(queue: server.queue)
        }
        return server
    }

    private func echo(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                conn.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            self.echo(conn)
        }
    }

    func stop() { listener.cancel() }
}

enum LoopbackClient {
    static func connect(port: UInt16) async throws -> NWConnection {
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: cont.resume(); conn.stateUpdateHandler = nil
                case .failed(let error): cont.resume(throwing: error); conn.stateUpdateHandler = nil
                default: break
                }
            }
            conn.start(queue: .global())
        }
        return conn
    }

    /// Sends the payload, half-closes, then reads until the peer closes.
    static func roundTrip(port: UInt16, payload: Data) async throws -> Data {
        let conn = try await connect(port: port)
        defer { conn.cancel() }
        conn.send(content: payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        var received = Data()
        while true {
            let (chunk, done) = await withCheckedContinuation { (cont: CheckedContinuation<(Data?, Bool), Never>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    cont.resume(returning: (data, isComplete || error != nil))
                }
            }
            if let chunk { received.append(chunk) }
            if done { return received }
        }
    }
}
