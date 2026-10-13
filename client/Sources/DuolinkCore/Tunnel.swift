import Darwin
import Foundation
import os

/// The whole client data path: the MPTCP relay plus the sing-box process
/// that exposes it as the system proxy.
public final class Tunnel: @unchecked Sendable {
    public struct Options: Sendable {
        public var server: ServerConfig
        public var mode: MultipathMode
        public var relayPort: UInt16 = 20801
        public var proxyPort: UInt16 = 20802
        public var setSystemProxy = true
        public var supportDirectory: URL

        public init(server: ServerConfig, mode: MultipathMode, supportDirectory: URL) {
            self.server = server
            self.mode = mode
            self.supportDirectory = supportDirectory
        }
    }

    public enum TunnelError: LocalizedError {
        case singBoxNotFound
        case singBoxExited(Int32, String)

        public var errorDescription: String? {
            switch self {
            case .singBoxNotFound:
                "sing-box est introuvable. Installez-le avec : brew install sing-box"
            case let .singBoxExited(status, log):
                "sing-box s'est arrêté (code \(status)). \(log)"
            }
        }
    }

    public let options: Options
    private let relay: MultipathRelay
    private let lock = OSAllocatedUnfairLock<Process?>(initialState: nil)
    private var stopping = false
    private var restarts = 0

    /// Called on an unexpected sing-box exit, after the automatic restarts gave up.
    public var onFailure: (@Sendable (Error) -> Void)?

    public init(options: Options) {
        self.options = options
        relay = MultipathRelay(upstreamHost: options.server.host, upstreamPort: options.server.port, mode: options.mode)
    }

    public var relayStats: RelayStats { relay.stats }

    private var configURL: URL { options.supportDirectory.appending(path: "sing-box.json") }
    private var pidURL: URL { options.supportDirectory.appending(path: "sing-box.pid") }
    public var logURL: URL { options.supportDirectory.appending(path: "sing-box.log") }

    public func start() async throws {
        guard let binary = SingBoxBinary.locate() else { throw TunnelError.singBoxNotFound }
        try FileManager.default.createDirectory(at: options.supportDirectory, withIntermediateDirectories: true)
        killStaleSingBox()

        _ = try await relay.start(port: options.relayPort)
        do {
            let config = try SingBoxConfig.client(
                server: options.server,
                relayPort: options.relayPort,
                proxyPort: options.proxyPort,
                setSystemProxy: options.setSystemProxy
            )
            // The file holds the server password.
            FileManager.default.createFile(atPath: configURL.path, contents: config, attributes: [.posixPermissions: 0o600])
            try launch(binary: binary)
        } catch {
            relay.stop()
            throw error
        }
    }

    /// Stops sing-box gracefully so it can restore the system proxy settings.
    public func stop() {
        stopping = true
        if let process = lock.withLock({ $0 }), process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline { usleep(50_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        lock.withLock { $0 = nil }
        try? FileManager.default.removeItem(at: pidURL)
        relay.stop()
    }

    private func launch(binary: URL) throws {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["run", "-c", configURL.path, "-D", options.supportDirectory.path]
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] process in
            try? log.close()
            self?.handleExit(of: process, binary: binary)
        }
        try process.run()
        lock.withLock { $0 = process }
        try? String(process.processIdentifier).write(to: pidURL, atomically: true, encoding: .utf8)
    }

    private func handleExit(of process: Process, binary: URL) {
        guard !stopping else { return }
        let tail = (try? String(contentsOf: logURL, encoding: .utf8))?
            .split(separator: "\n").suffix(3).joined(separator: "\n") ?? ""
        restarts += 1
        if restarts <= 3 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.stopping else { return }
                do { try self.launch(binary: binary) } catch { self.onFailure?(error) }
            }
        } else {
            onFailure?(TunnelError.singBoxExited(process.terminationStatus, tail))
        }
    }

    /// A sing-box left behind by a crash would keep the system proxy pointed
    /// at a dead relay. Only kills the pid if it is still a sing-box.
    private func killStaleSingBox() {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0,
           String(decoding: path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self).hasSuffix("/sing-box") {
            kill(pid, SIGTERM)
            for _ in 0..<60 where kill(pid, 0) == 0 { usleep(50_000) }
        }
        try? FileManager.default.removeItem(at: pidURL)
    }
}
