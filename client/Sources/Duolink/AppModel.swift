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
    private(set) var tunnelDownRate: Double = 0
    private(set) var tunnelUpRate: Double = 0
    private(set) var aggregateAllowed = AggregatePermission.isAllowed
    private(set) var notice: String?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    var mode: MultipathMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
            if isOn { restart() }
        }
    }

    /// The mode actually used: aggregation silently falls back to interactive
    /// until the admin permission is granted, instead of failing every connection.
    var effectiveMode: MultipathMode {
        mode == .aggregate && !aggregateAllowed ? .interactive : mode
    }

    var isOn: Bool { status == .running || status == .starting }

    private let store = ServerStore.default
    private let linkMonitor = LinkMonitor()
    private var tunnel: Tunnel?
    private var meters = (down: RateMeter(), up: RateMeter())
    private var ticker: Timer?

    private enum Keys {
        static let mode = "mode"
        static let enabled = "enabled"
    }

    init() {
        mode = UserDefaults.standard.string(forKey: Keys.mode).flatMap(MultipathMode.init(rawValue:)) ?? .aggregate
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
            MainActor.assumeIsolated { self?.tunnel?.stop() }
        }

        if server != nil, UserDefaults.standard.bool(forKey: Keys.enabled) { start() }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.enabled)
        enabled ? start() : stop()
    }

    func start() {
        guard let server, tunnel == nil else { return }
        status = .starting
        notice = nil
        let tunnel = Tunnel(options: Tunnel.Options(
            server: server,
            mode: effectiveMode,
            supportDirectory: store.directory
        ))
        tunnel.onFailure = { [weak self] error in
            Task { @MainActor in self?.fail(error) }
        }
        self.tunnel = tunnel
        Task {
            do {
                try await tunnel.start()
                if self.tunnel === tunnel { status = .running }
            } catch {
                fail(error)
            }
        }
    }

    func stop() {
        tunnel?.stop()
        tunnel = nil
        status = .stopped
        stats = RelayStats()
        tunnelDownRate = 0
        tunnelUpRate = 0
        meters = (RateMeter(), RateMeter())
    }

    private func restart() {
        stop()
        start()
    }

    private func fail(_ error: Error) {
        tunnel?.stop()
        tunnel = nil
        status = .failed(error.localizedDescription)
    }

    private func tick() {
        let allowed = AggregatePermission.isAllowed
        if allowed != aggregateAllowed {
            aggregateAllowed = allowed
            if mode == .aggregate, isOn { restart() }
        }
        guard let tunnel else { return }
        stats = tunnel.relayStats
        let now = ProcessInfo.processInfo.systemUptime
        tunnelDownRate = meters.down.record(bytes: stats.bytesDown, at: now) ?? 0
        tunnelUpRate = meters.up.record(bytes: stats.bytesUp, at: now) ?? 0
    }

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

    func allowAggregate() {
        Task.detached { [directory = store.directory] in
            do {
                try AggregatePermission.install(scratchDirectory: directory)
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
        NSWorkspace.shared.open(store.directory.appending(path: "sing-box.log"))
    }

    func quit() {
        tunnel?.stop()
        tunnel = nil
        NSApplication.shared.terminate(nil)
    }
}
