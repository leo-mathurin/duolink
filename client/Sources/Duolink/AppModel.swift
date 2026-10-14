import AppKit
import DuolinkCore
import Foundation
import Observation
import ServiceManagement

@MainActor @Observable
final class AppModel {
    enum Status: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    private(set) var server: ServerConfig?
    private(set) var status: Status = .stopped
    private(set) var links: [LinkStatus] = []
    private(set) var stats = RelayStats()
    private(set) var tunnelRates = Throughput()
    private(set) var notice: String?
    /// Set when the root daemon must be installed or updated.
    private(set) var systemFix: TetheringFix.Reason?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    var mode: MultipathMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
            if isOn { restart() }
        }
    }

    var isOn: Bool { status == .running || status == .starting }

    private let store = ServerStore.default
    private let linkMonitor = LinkMonitor()
    private var tunnel: Tunnel?
    private var meters = (down: RateMeter(), up: RateMeter())
    private var ticker: Timer?
    private var activity: NSObjectProtocol?

    private enum Keys {
        static let mode = "mode"
        static let enabled = "enabled"
    }

    init() {
        mode = UserDefaults.standard.string(forKey: Keys.mode).flatMap(MultipathMode.init(rawValue:)) ?? .combine
        server = store.load()

        linkMonitor.start { [weak self] links in
            Task { @MainActor in self?.links = links }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.detachTunnel()?.stop() }
        }

        if server != nil, UserDefaults.standard.bool(forKey: Keys.enabled) { start() }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.enabled)
        if enabled {
            start()
        } else {
            Task { await stop() }
        }
    }

    func start() {
        guard let server, tunnel == nil else { return }
        status = .starting
        notice = nil
        let tunnel = Tunnel(
            options: Tunnel.Options(server: server, mode: mode, supportDirectory: store.directory)
        ) { [weak self] error in
            Task { @MainActor in self?.fail(error, from: nil) }
        }
        self.tunnel = tunnel
        // Keeps App Nap from throttling the relay while the menu is closed.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Relais du trafic réseau"
        )
        Task {
            do {
                try await tunnel.start()
                if self.tunnel === tunnel { status = .running }
            } catch is CancellationError {
            } catch {
                fail(error, from: tunnel)
            }
        }
    }

    func stop() async {
        guard let tunnel = detachTunnel() else { return }
        status = .stopped
        await tunnel.shutdown()
    }

    /// Clears the running state and hands back the tunnel to shut down.
    private func detachTunnel() -> Tunnel? {
        let tunnel = self.tunnel
        self.tunnel = nil
        stats = RelayStats()
        tunnelRates = Throughput()
        meters = (RateMeter(), RateMeter())
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        return tunnel
    }

    private func restart() {
        Task {
            await stop()
            start()
        }
    }

    /// `origin` is the tunnel that failed; nil means the current one.
    private func fail(_ error: Error, from origin: Tunnel?) {
        if let origin, origin !== tunnel { return }
        let tunnel = detachTunnel()
        status = .failed(error.localizedDescription)
        Task { await tunnel?.shutdown() }
    }

    private func tick() {
        systemFix = TetheringFix.currentReason()
        guard let tunnel else { return }
        stats = tunnel.relayStats
        let now = ProcessInfo.processInfo.systemUptime
        tunnelRates = Throughput(
            down: meters.down.record(bytes: stats.bytesDown, at: now) ?? 0,
            up: meters.up.record(bytes: stats.bytesUp, at: now) ?? 0
        )
    }

    /// A few failed connections in a row: apps behind the proxy have no internet.
    var serverUnreachable: Bool { status == .running && stats.consecutiveFailures >= 3 }

    func importLinkFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            notice = "Le presse-papiers ne contient pas de texte."
            return
        }
        do {
            let server = try ServerConfig(uri: text)
            try store.save(server)
            self.server = server
            notice = "Serveur \(server.host) enregistré."
            if isOn { restart() }
        } catch {
            notice = "Ce n'est pas un lien ss:// valide."
        }
    }

    func fixTethering() {
        Task.detached {
            do {
                try TetheringFix.install()
            } catch {
                await MainActor.run { self.notice = error.localizedDescription }
            }
            await MainActor.run { self.tick() }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            notice = "Lancement au démarrage impossible : \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openLog() {
        NSWorkspace.shared.open(Tunnel.logURL(in: store.directory))
    }

    func quit() {
        // Synchronous on purpose: sing-box must restore the proxy before exit.
        detachTunnel()?.stop()
        NSApplication.shared.terminate(nil)
    }
}
