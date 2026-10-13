import Foundation

/// The Shadowsocks server that terminates the aggregated MPTCP connections.
public struct ServerConfig: Codable, Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var method: String
    public var password: String

    public init(host: String, port: UInt16, method: String, password: String) {
        self.host = host
        self.port = port
        self.method = method
        self.password = password
    }

    public enum ParseError: Error, Equatable {
        case notAShadowsocksLink
        case missingCredentials
        case invalidCredentials
        case invalidHost
        case invalidPort
    }

    /// Parses a SIP002 link: `ss://userinfo@host:port#name`, where userinfo is
    /// either percent-encoded `method:password` or base64url of it.
    public init(uri: String) throws {
        var rest = Substring(uri.trimmingCharacters(in: .whitespacesAndNewlines))
        guard rest.hasPrefix("ss://") else { throw ParseError.notAShadowsocksLink }
        rest = rest.dropFirst("ss://".count)
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        if let query = rest.firstIndex(of: "?") { rest = rest[..<query] }
        if rest.hasSuffix("/") { rest = rest.dropLast() }

        guard let at = rest.lastIndex(of: "@") else { throw ParseError.missingCredentials }
        let (method, password) = try Self.credentials(from: rest[..<at])
        let (host, port) = try Self.endpoint(from: rest[rest.index(after: at)...])
        self.init(host: host, port: port, method: method, password: password)
    }

    private static func credentials(from userInfo: Substring) throws -> (String, String) {
        let decoded: String
        if let plain = userInfo.removingPercentEncoding, plain.contains(":") {
            decoded = plain
        } else if let data = Data(base64URLEncoded: String(userInfo)),
                  let text = String(data: data, encoding: .utf8) {
            decoded = text
        } else {
            throw ParseError.invalidCredentials
        }
        guard let colon = decoded.firstIndex(of: ":") else { throw ParseError.invalidCredentials }
        let method = String(decoded[..<colon])
        let password = String(decoded[decoded.index(after: colon)...])
        guard !method.isEmpty, !password.isEmpty,
              method.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { throw ParseError.invalidCredentials }
        return (method, password)
    }

    private static func endpoint(from hostPort: Substring) throws -> (String, UInt16) {
        let host: Substring
        let portText: Substring
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { throw ParseError.invalidHost }
            host = hostPort[hostPort.index(after: hostPort.startIndex)..<close]
            let afterBracket = hostPort[hostPort.index(after: close)...]
            guard afterBracket.hasPrefix(":") else { throw ParseError.invalidPort }
            portText = afterBracket.dropFirst()
        } else {
            guard let colon = hostPort.lastIndex(of: ":") else { throw ParseError.invalidPort }
            host = hostPort[..<colon]
            portText = hostPort[hostPort.index(after: colon)...]
        }
        guard !host.isEmpty else { throw ParseError.invalidHost }
        guard let port = UInt16(portText), port > 0 else { throw ParseError.invalidPort }
        return (String(host), port)
    }
}

extension Data {
    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
