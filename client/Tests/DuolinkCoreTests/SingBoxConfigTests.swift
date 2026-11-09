import Foundation
import Testing
@testable import DuolinkCore

@Suite struct SingBoxConfigTests {
    let server = ServerConfig(host: "203.0.113.7", port: 8443, method: "2022-blake3-aes-128-gcm", password: "secret")

    func build() throws -> [String: Any] {
        let data = try SingBoxConfig.client(server: server, relayPort: 7001, proxyPort: 7002)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func exposesASystemProxyOnLoopback() throws {
        let inbounds = try #require(try build()["inbounds"] as? [[String: Any]])
        let mixed = try #require(inbounds.first { $0["type"] as? String == "mixed" })
        #expect(mixed["listen"] as? String == "127.0.0.1")
        #expect(mixed["listen_port"] as? Int == 7002)
        #expect(mixed["set_system_proxy"] as? Bool == true)
    }

    @Test func canLeaveTheSystemProxyAlone() throws {
        let data = try SingBoxConfig.client(server: server, relayPort: 7001, proxyPort: 7002, setSystemProxy: false)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inbounds = try #require(json["inbounds"] as? [[String: Any]])
        #expect(inbounds.first?["set_system_proxy"] as? Bool == false)
    }

    @Test func sendsShadowsocksThroughTheLocalRelayNotTheServer() throws {
        let outbounds = try #require(try build()["outbounds"] as? [[String: Any]])
        let proxy = try #require(outbounds.first { $0["type"] as? String == "shadowsocks" })
        #expect(proxy["server"] as? String == "127.0.0.1")
        #expect(proxy["server_port"] as? Int == 7001)
        #expect(proxy["method"] as? String == "2022-blake3-aes-128-gcm")
        #expect(proxy["password"] as? String == "secret")
        // UDP must ride inside the MPTCP stream to be aggregated too.
        #expect(proxy["udp_over_tcp"] as? Bool == true)
        #expect(proxy["network"] as? String == "tcp")
    }

    @Test func routesEverythingThroughTheProxyByDefault() throws {
        let route = try #require(try build()["route"] as? [String: Any])
        let outbounds = try #require(try build()["outbounds"] as? [[String: Any]])
        let proxyTag = try #require(outbounds.first { $0["type"] as? String == "shadowsocks" }?["tag"] as? String)
        #expect(route["final"] as? String == proxyTag)
    }

    @Test func keepsLocalNetworksAndCaptivePortalsDirect() throws {
        let route = try #require(try build()["route"] as? [String: Any])
        let rules = try #require(route["rules"] as? [[String: Any]])
        let direct = rules.filter { $0["outbound"] as? String == "direct" }
        #expect(direct.contains { $0["ip_is_private"] as? Bool == true })
        let suffixes = direct.compactMap { $0["domain_suffix"] as? [String] }.flatMap { $0 }
        #expect(suffixes.contains("wifi.sncf"))
        #expect(suffixes.contains("local"))
    }

    @Test func keepsTailscaleDevicesDirect() throws {
        let route = try #require(try build()["route"] as? [String: Any])
        let rules = try #require(route["rules"] as? [[String: Any]])
        let direct = rules.filter { $0["outbound"] as? String == "direct" }
        let suffixes = direct.compactMap { $0["domain_suffix"] as? [String] }.flatMap { $0 }
        let networks = direct.compactMap { $0["ip_cidr"] as? [String] }.flatMap { $0 }
        #expect(suffixes.contains("ts.net"))
        #expect(networks.contains("100.64.0.0/10"))
        #expect(networks.contains("fd7a:115c:a1e0::/48"))
    }

    @Test func resolvesTailnetNamesWithMagicDNS() throws {
        let config = try build()
        let dns = try #require(config["dns"] as? [String: Any])
        let servers = try #require(dns["servers"] as? [[String: Any]])
        let tailscale = try #require(servers.first { $0["server"] as? String == "100.100.100.100" })
        let route = try #require(config["route"] as? [String: Any])
        let rules = try #require(route["rules"] as? [[String: Any]])
        #expect(rules.contains {
            ($0["domain_suffix"] as? [String])?.contains("ts.net") == true
                && $0["action"] as? String == "resolve"
                && $0["server"] as? String == tailscale["tag"] as? String
        })
    }
}

/// Validates the generated file with the real binary, when it is installed.
@Suite struct SingBoxCheckTests {
    static let binary = SingBoxBinary.locate()

    @Test(.enabled(if: binary != nil, "sing-box is not installed"))
    func singBoxAcceptsTheGeneratedConfig() throws {
        let server = ServerConfig(host: "203.0.113.7", port: 8443, method: "2022-blake3-aes-128-gcm", password: "AAAAAAAAAAAAAAAAAAAAAA==")
        let file = FileManager.default.temporaryDirectory.appending(path: "duolink-check-\(UUID()).json")
        try SingBoxConfig.client(server: server, relayPort: 7001, proxyPort: 7002).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = Self.binary
        process.arguments = ["check", "-c", file.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(output)")
        #expect(!output.contains("WARN"), "\(output)")
    }
}
