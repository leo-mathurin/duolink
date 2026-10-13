import Darwin
import Foundation

/// macOS refuses the MPTCP aggregation mode to third-party apps (EACCES)
/// unless `net.inet.mptcp.allow_aggregate` is 1. The sysctl resets on boot,
/// so a LaunchDaemon sets it again at every startup.
public enum AggregatePermission {
    public static let sysctlName = "net.inet.mptcp.allow_aggregate"
    public static let daemonLabel = "io.github.leo-mathurin.duolink.allow-aggregate"
    static var daemonPath: String { "/Library/LaunchDaemons/\(daemonLabel).plist" }

    public static var isAllowed: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(sysctlName, &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }

    /// Shell script to run as root. Also printed by `duolinkctl allow-aggregate`.
    public static var installScript: String {
        """
        set -e
        cat > \(daemonPath) <<'PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/sbin/sysctl</string>
                <string>-w</string>
                <string>\(sysctlName)=1</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        PLIST
        chown root:wheel \(daemonPath)
        chmod 644 \(daemonPath)
        launchctl bootout system/\(daemonLabel) 2>/dev/null || true
        launchctl bootstrap system \(daemonPath)
        /usr/sbin/sysctl -w \(sysctlName)=1
        """
    }

    public enum InstallError: LocalizedError {
        case cancelled
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled: "Autorisation annulée."
            case .failed(let output): "Échec de l'autorisation : \(output)"
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
