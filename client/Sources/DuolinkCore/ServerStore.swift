import Foundation

/// Persists the server settings in Application Support, readable by the user only.
public struct ServerStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var `default`: ServerStore {
        ServerStore(directory: URL.applicationSupportDirectory.appending(path: "Duolink"))
    }

    var fileURL: URL { directory.appending(path: "server.json") }

    public func load() -> ServerConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ServerConfig.self, from: data)
    }

    public func save(_ server: ServerConfig) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(server)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
