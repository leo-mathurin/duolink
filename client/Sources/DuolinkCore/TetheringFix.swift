import Darwin
import Foundation

/// Root fixes that Duolink needs and that macOS does not apply by itself. A
/// LaunchDaemon runs them every few seconds, since both reset on their own.
///
/// - macOS 26 attaches the "iPhone USB" interface but never sets it UP, so
///   the iPhone never turns the link on and DHCP never starts. `ifconfig <if>
///   up` fixes it until the cable is plugged again.
/// - macOS caps the receive window of a connection at 4 MB. Under load the RTT
///   of a 5G subflow climbs from about 20 ms to 200 ms, and 4 MB then limits
///   the whole MPTCP connection below the speed of the 5G alone. The cap goes
///   back to 4 MB at every reboot.
public enum TetheringFix {
    public static let daemonLabel = "io.github.leo-mathurin.duolink.tethering"
    static var daemonPath: String { "/Library/LaunchDaemons/\(daemonLabel).plist" }

    /// The most `kern.ipc.maxsockbuf` allows by default: a larger value has no effect.
    static let receiveBufferMax = 8 * 1024 * 1024

    public enum Reason: Sendable {
        /// The iPhone is plugged in but macOS left its interface down.
        case tetheringDown
        /// Two links are up but the receive window is too small to add them up.
        case smallReceiveBuffer
    }

    /// Why the daemon should be installed or updated, nil when nothing is needed.
    public static func currentReason() -> Reason? {
        guard !isCurrent(installedPlist: try? String(contentsOfFile: daemonPath, encoding: .utf8)) else { return nil }
        return reason(ports: LinkMonitor.displayNames(), flags: readFlags(), receiveBuffer: readReceiveBufferMax())
    }

    static func isCurrent(installedPlist: String?) -> Bool {
        installedPlist?.trimmingCharacters(in: .whitespacesAndNewlines) == daemonPlist
    }

    /// Only asks when an iPhone is plugged in: a single link gains nothing.
    static func reason(ports: [String: String], flags: [String: Int32], receiveBuffer: Int) -> Reason? {
        let iPhones = ports
            .filter { $0.value.localizedCaseInsensitiveContains("iphone") }
            .compactMap { flags[$0.key] }
        if iPhones.contains(where: { $0 & Int32(IFF_UP) == 0 }) { return .tetheringDown }
        if !iPhones.isEmpty, receiveBuffer < receiveBufferMax { return .smallReceiveBuffer }
        return nil
    }

    static func readReceiveBufferMax() -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // Unreadable: assume it is fine rather than ask for a password.
        guard sysctlbyname("net.inet.tcp.autorcvbufmax", &value, &size, nil, 0) == 0 else { return .max }
        return Int(value)
    }

    static func readFlags() -> [String: Int32] {
        var result: [String: Int32] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return result }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            result[String(cString: entry.ifa_name)] = Int32(bitPattern: entry.ifa_flags)
        }
        return result
    }

    /// The check the daemon runs. `extraPath` lets tests swap in fake tools.
    static func watchScript(toolsDirectory extraPath: String? = nil) -> String {
        let path = ([extraPath].compactMap { $0 } + ["/usr/sbin", "/sbin", "/usr/bin", "/bin"]).joined(separator: ":")
        return """
        PATH='\(path)'
        networksetup -listallhardwareports | awk '/^Hardware Port: iPhone USB/ { getline; print $2 }' |
        while read -r dev; do
          line=$(ifconfig "$dev" 2>/dev/null | head -n 1) || continue
          case "$line" in
            *"<UP"*) ;;
            ?*) ifconfig "$dev" up ;;
          esac
        done
        buffer=$(sysctl -n net.inet.tcp.autorcvbufmax 2>/dev/null)
        [ "${buffer:-0}" -ge \(receiveBufferMax) ] 2>/dev/null ||
          sysctl -w net.inet.tcp.autorcvbufmax=\(receiveBufferMax) >/dev/null
        exit 0
        """
    }

    static var daemonPlist: String {
        let escaped = watchScript()
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/sh</string>
                <string>-c</string>
                <string>\(escaped)</string>
            </array>
            <key>StartInterval</key>
            <integer>5</integer>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
    }

    /// Shell script to run as root. Also printed by `duolinkctl fix-tethering`.
    /// Running it again replaces an older daemon.
    public static var installScript: String {
        """
        set -e
        cat > \(daemonPath) <<'DUOLINK_PLIST'
        \(daemonPlist)
        DUOLINK_PLIST
        chown root:wheel \(daemonPath)
        chmod 644 \(daemonPath)
        launchctl bootout system/\(daemonLabel) 2>/dev/null || true
        launchctl bootstrap system \(daemonPath)
        """
    }

    public enum InstallError: LocalizedError {
        case cancelled
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled: "Autorisation annulée."
            case .failed(let output): "Échec de l'installation : \(output)"
            }
        }
    }

    /// Runs the install script through the standard macOS admin password prompt.
    /// The script travels as an argument, never as a file another process could swap.
    public static func install() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run",
            installScript,
        ]
        let output = Pipe()
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            // -128 is AppleScript's "user cancelled".
            throw message.contains("-128") ? InstallError.cancelled : InstallError.failed(message)
        }
    }
}
