import Darwin
import Foundation

/// macOS 26 attaches the "iPhone USB" interface but never sets it UP, so the
/// iPhone never turns the link on and DHCP never starts. `ifconfig <if> up`
/// fixes it until the cable is plugged again, and needs root. A LaunchDaemon
/// therefore checks every few seconds and brings those interfaces up.
public enum TetheringFix {
    public static let daemonLabel = "io.github.leo-mathurin.duolink.tethering"
    static var daemonPath: String { "/Library/LaunchDaemons/\(daemonLabel).plist" }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: daemonPath) }

    /// iPhone USB interfaces that exist in the kernel but are down.
    static func interfacesLeftDown(ports: [String: String], flags: [String: Int32]) -> [String] {
        ports
            .filter { $0.value.localizedCaseInsensitiveContains("iphone") }
            .compactMap { bsd, _ in flags[bsd].map { (bsd, $0) } }
            .filter { $0.1 & Int32(IFF_UP) == 0 }
            .map(\.0)
            .sorted()
    }

    public static func currentInterfacesLeftDown() -> [String] {
        interfacesLeftDown(ports: LinkMonitor.displayNames(), flags: readFlags())
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
