import Foundation
import Testing
@testable import DuolinkCore

@Suite struct SystemFixTests {
    let up = Int32(IFF_UP | IFF_RUNNING)
    let down = Int32(IFF_BROADCAST)
    let ports = ["en0": "Wi-Fi", "en13": "iPhone USB"]

    let big = SystemFix.receiveBufferMax
    let small = 4 * 1024 * 1024

    @Test func flagsAnIPhoneInterfaceThatMacOSLeftDown() {
        // A down interface comes first: there is no second link to add up yet.
        #expect(SystemFix.reason(ports: ports, flags: ["en0": up, "en13": down], receiveBuffer: small) == .tetheringDown)
    }

    @Test func asksForABiggerReceiveBufferOnceTheIPhoneIsUp() {
        #expect(SystemFix.reason(ports: ports, flags: ["en0": up, "en13": up], receiveBuffer: small) == .smallReceiveBuffer)
    }

    @Test func needsNothingWhenTheIPhoneIsUpAndTheBufferIsBigEnough() {
        #expect(SystemFix.reason(ports: ports, flags: ["en0": up, "en13": up], receiveBuffer: big) == nil)
    }

    @Test func needsNothingWithoutAnIPhone() {
        // A single link gains nothing from a bigger buffer: no password prompt.
        let ports = ["en0": "Wi-Fi", "en5": "Ethernet Adapter (en5)"]
        #expect(SystemFix.reason(ports: ports, flags: ["en0": up, "en5": down], receiveBuffer: small) == nil)
    }

    @Test func ignoresAPortWithNoKernelInterface() {
        // A stale service from a previous iPhone: the port exists, the interface does not.
        #expect(SystemFix.reason(ports: ["en7": "iPhone USB"], flags: [:], receiveBuffer: small) == nil)
    }

    @Test func recognisesTheDaemonItInstalled() {
        // The install script writes the plist through a heredoc, which adds a newline.
        #expect(SystemFix.isCurrent(installedPlist: SystemFix.daemonPlist + "\n"))
        #expect(!SystemFix.isCurrent(installedPlist: "<plist>older version</plist>"))
        #expect(!SystemFix.isCurrent(installedPlist: nil))
    }

    @Test func daemonPlistIsValid() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "duolink-\(UUID()).plist")
        try SystemFix.daemonPlist.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let plist = try #require(NSDictionary(contentsOf: file) as? [String: Any])
        #expect(plist["Label"] as? String == SystemFix.daemonLabel)
        #expect(plist["StartInterval"] as? Int == 5)
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        #expect(arguments.first == "/bin/sh")
    }

    @Test func watchScriptOnlyTouchesIPhonePortsAndKeepsABigEnoughBuffer() throws {
        // Someone who raised kern.ipc.maxsockbuf may already use more than 8 MB.
        for receiveBuffer in [big, 2 * big] {
            #expect(try runWatchScript(receiveBuffer: receiveBuffer) == "up en13\n")
        }
    }

    @Test func watchScriptRaisesASmallReceiveBuffer() throws {
        #expect(try runWatchScript(receiveBuffer: small) == "up en13\nset net.inet.tcp.autorcvbufmax=\(big)\n")
    }

    /// Runs the script against fake tools and returns the changes it made.
    private func runWatchScript(receiveBuffer: Int) throws -> String {
        let bin = FileManager.default.temporaryDirectory.appending(path: "duolink-bin-\(UUID())")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let log = bin.appending(path: "calls")
        let fakes = [
            "networksetup": """
            #!/bin/sh
            printf 'Hardware Port: Wi-Fi\\nDevice: en0\\n\\nHardware Port: iPhone USB\\nDevice: en13\\n\\nHardware Port: Ethernet Adapter (en5)\\nDevice: en5\\n'
            """,
            "ifconfig": """
            #!/bin/sh
            if [ "$2" = up ]; then echo "up $1" >> "\(log.path)"; exit 0; fi
            case "$1" in
              en13|en5) echo "$1: flags=8822<BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 1500" ;;
              *) echo "$1: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500" ;;
            esac
            """,
            "sysctl": """
            #!/bin/sh
            if [ "$1" = -w ]; then echo "set $2" >> "\(log.path)"; exit 0; fi
            echo \(receiveBuffer)
            """,
        ]
        for (name, body) in fakes {
            let url = bin.appending(path: name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SystemFix.watchScript(toolsDirectory: bin.path)]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }
}
