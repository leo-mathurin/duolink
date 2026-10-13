import Darwin
import Foundation
import Testing
@testable import DuolinkCore

@Suite struct TetheringFixTests {
    let up = Int32(IFF_UP | IFF_RUNNING)
    let down = Int32(IFF_BROADCAST)

    @Test func flagsAnIPhoneInterfaceThatMacOSLeftDown() {
        let ports = ["en0": "Wi-Fi", "en13": "iPhone USB"]
        #expect(TetheringFix.interfacesLeftDown(ports: ports, flags: ["en0": up, "en13": down]) == ["en13"])
    }

    @Test func ignoresAnIPhoneInterfaceThatIsAlreadyUp() {
        let ports = ["en13": "iPhone USB"]
        #expect(TetheringFix.interfacesLeftDown(ports: ports, flags: ["en13": up]).isEmpty)
    }

    @Test func ignoresOtherInterfacesThatAreDown() {
        let ports = ["en5": "Ethernet Adapter (en5)", "en13": "iPhone USB"]
        #expect(TetheringFix.interfacesLeftDown(ports: ports, flags: ["en5": down, "en13": up]).isEmpty)
    }

    @Test func ignoresAPortWithNoKernelInterface() {
        // A stale service from a previous iPhone: the port exists, the interface does not.
        #expect(TetheringFix.interfacesLeftDown(ports: ["en7": "iPhone USB"], flags: [:]).isEmpty)
    }

    @Test func daemonPlistIsValid() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "duolink-\(UUID()).plist")
        try TetheringFix.daemonPlist.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let plist = try #require(NSDictionary(contentsOf: file) as? [String: Any])
        #expect(plist["Label"] as? String == TetheringFix.daemonLabel)
        #expect(plist["StartInterval"] as? Int == 5)
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        #expect(arguments.first == "/bin/sh")
    }

    @Test func watchScriptOnlyTouchesIPhonePorts() throws {
        // Runs the script against fake tools: it must bring up en13 only.
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
        ]
        for (name, body) in fakes {
            let url = bin.appending(path: name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", TetheringFix.watchScript(toolsDirectory: bin.path)]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: log, encoding: .utf8) == "up en13\n")
    }
}
