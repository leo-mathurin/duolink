import Foundation

/// Builds the sing-box configuration for the Mac side.
///
/// Apps → system proxy (sing-box `mixed` inbound) → Shadowsocks 2022 →
/// local `MultipathRelay` → MPTCP over every interface → server.
/// sing-box cannot open MPTCP sockets on macOS (Go only supports it on Linux),
/// so it talks plain TCP to the relay, which owns the multipath connection.
public enum SingBoxConfig {
    public static let proxyTag = "duolink"
    public static let directTag = "direct"

    /// Hosts that must stay on the local network: captive portal login pages
    /// only answer from inside the train network, never through the server.
    public static let directDomainSuffixes = [
        "local",
        "captive.apple.com",
        "wifi.sncf",
    ]

    public static func client(
        server: ServerConfig,
        relayPort: UInt16,
        proxyPort: UInt16,
        setSystemProxy: Bool = true
    ) throws -> Data {
        let config: [String: Any] = [
            "log": ["level": "warn", "timestamp": true],
            "dns": [
                "servers": [["type": "local", "tag": "local"]],
            ],
            "inbounds": [
                [
                    "type": "mixed",
                    "tag": "mixed-in",
                    "listen": "127.0.0.1",
                    "listen_port": Int(proxyPort),
                    "set_system_proxy": setSystemProxy,
                ],
            ],
            "outbounds": [
                [
                    "type": "shadowsocks",
                    "tag": proxyTag,
                    "server": "127.0.0.1",
                    "server_port": Int(relayPort),
                    "method": server.method,
                    "password": server.password,
                    "network": "tcp",
                    "udp_over_tcp": true,
                ],
                ["type": "direct", "tag": directTag],
            ],
            "route": [
                "rules": [
                    ["ip_is_private": true, "action": "route", "outbound": directTag],
                    ["domain_suffix": directDomainSuffixes, "action": "route", "outbound": directTag],
                ],
                "final": proxyTag,
                "default_domain_resolver": "local",
            ],
        ]
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }
}
