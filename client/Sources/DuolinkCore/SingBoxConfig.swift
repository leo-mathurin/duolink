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

    /// Captive portals need the local network, and tailnet services need this
    /// Mac's Tailscale identity rather than the proxy server's.
    public static let directDomainSuffixes = [
        "local",
        "captive.apple.com",
        "wifi.sncf",
        "ts.net",
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
                "servers": [
                    ["type": "local", "tag": "local"],
                    ["type": "udp", "tag": "tailscale", "server": "100.100.100.100"],
                ],
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
                    ["domain_suffix": ["ts.net"], "action": "resolve", "server": "tailscale"],
                    ["ip_is_private": true, "action": "route", "outbound": directTag],
                    ["ip_cidr": ["100.64.0.0/10", "fd7a:115c:a1e0::/48"], "action": "route", "outbound": directTag],
                    ["domain_suffix": directDomainSuffixes, "action": "route", "outbound": directTag],
                ],
                "final": proxyTag,
                "default_domain_resolver": "local",
            ],
        ]
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }
}
