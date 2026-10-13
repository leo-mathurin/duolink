import Foundation
import Testing
@testable import DuolinkCore

@Suite struct ServerConfigTests {
    @Test func parsesPercentEncodedShadowsocks2022Link() throws {
        let config = try ServerConfig(
            uri: "ss://2022-blake3-aes-128-gcm%3AAbCd%2Bef%2FGh%3D%3D@129.151.243.115:8443#duolink"
        )
        #expect(config == ServerConfig(
            host: "129.151.243.115",
            port: 8443,
            method: "2022-blake3-aes-128-gcm",
            password: "AbCd+ef/Gh=="
        ))
    }

    @Test func parsesBase64UserInfo() throws {
        // base64url("aes-256-gcm:test") without padding, as SIP002 allows.
        let config = try ServerConfig(uri: "ss://YWVzLTI1Ni1nY206dGVzdA@example.com:8388")
        #expect(config.method == "aes-256-gcm")
        #expect(config.password == "test")
        #expect(config.host == "example.com")
        #expect(config.port == 8388)
    }

    @Test func keepsColonsInsidePassword() throws {
        let config = try ServerConfig(uri: "ss://aes-256-gcm%3Aa%3Ab@example.com:1")
        #expect(config.password == "a:b")
    }

    @Test func parsesBracketedIPv6Host() throws {
        let config = try ServerConfig(uri: "ss://aes-256-gcm%3Ax@[2001:db8::1]:8443")
        #expect(config.host == "2001:db8::1")
        #expect(config.port == 8443)
    }

    @Test func trimsSurroundingWhitespace() throws {
        let config = try ServerConfig(uri: "  ss://aes-256-gcm%3Ax@example.com:1\n")
        #expect(config.host == "example.com")
    }

    @Test(arguments: [
        "http://aes-256-gcm%3Ax@example.com:1",
        "ss://aes-256-gcm%3Ax@example.com",
        "ss://aes-256-gcm%3Ax@example.com:99999",
        "ss://example.com:8443",
        "ss://onlymethod@example.com:8443",
        "",
    ])
    func rejectsInvalidLinks(uri: String) {
        #expect(throws: ServerConfig.ParseError.self) { try ServerConfig(uri: uri) }
    }

    @Test func roundTripsThroughJSON() throws {
        let config = ServerConfig(host: "h", port: 1, method: "m", password: "p")
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
    }
}
