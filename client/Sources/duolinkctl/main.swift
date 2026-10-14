import DuolinkCore
import Foundation

// Prints the root script behind the menu's Réparer and Optimiser buttons:
//   duolinkctl fix-tethering | sudo sh
if CommandLine.arguments.dropFirst().first == "fix-tethering" {
    print(SystemFix.installScript)
    exit(0)
}

// Headless runner, handy over SSH or to test without the menu bar app:
//   DUOLINK_LINK='ss://...' duolinkctl [combine|backup] [--system-proxy]
// The link comes from the environment so the password stays out of `ps`.
let arguments = CommandLine.arguments.dropFirst()
guard let link = ProcessInfo.processInfo.environment["DUOLINK_LINK"], let server = try? ServerConfig(uri: link) else {
    FileHandle.standardError.write(Data("usage: DUOLINK_LINK=<ss://link> duolinkctl [combine|backup] [--system-proxy]\n".utf8))
    exit(64)
}
let mode = arguments.compactMap(MultipathMode.init(rawValue:)).first ?? .combine
var options = Tunnel.Options(
    server: server,
    mode: mode,
    supportDirectory: FileManager.default.temporaryDirectory.appending(path: "duolinkctl")
)
options.setSystemProxy = arguments.contains("--system-proxy")
let tunnel = Tunnel(options: options) { error in
    print("error: \(error.localizedDescription)")
    exit(1)
}

// Kept in a global: a released dispatch source is cancelled.
let signalSources = [SIGINT, SIGTERM].map { signalNumber in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        tunnel.stop()
        exit(0)
    }
    source.resume()
    return source
}

Task {
    do {
        try await tunnel.start()
        print("proxy on 127.0.0.1:\(options.proxyPort) (SOCKS5 and HTTP), mode \(mode.rawValue)")
    } catch {
        print("error: \(error.localizedDescription)")
        exit(1)
    }
}

Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
    let stats = tunnel.relayStats
    print("connections \(stats.activeConnections)/\(stats.connectionsOpened)  up \(stats.bytesUp)  down \(stats.bytesDown)\(stats.lastError.map { "  last error: \($0)" } ?? "")")
}
RunLoop.main.run()
