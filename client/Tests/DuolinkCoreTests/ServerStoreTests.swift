import Foundation
import Testing
@testable import DuolinkCore

@Suite struct ServerStoreTests {
    let store = ServerStore(directory: FileManager.default.temporaryDirectory.appending(path: "duolink-store-\(UUID())"))

    @Test func returnsNilWhenNothingIsSaved() {
        #expect(store.load() == nil)
    }

    @Test func savesPrivatelyAndLoadsBack() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let server = ServerConfig(host: "h", port: 1, method: "m", password: "p")
        try store.save(server)
        #expect(store.load() == server)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func overwritesThePreviousServer() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.save(ServerConfig(host: "old", port: 1, method: "m", password: "p"))
        try store.save(ServerConfig(host: "new", port: 2, method: "m", password: "p"))
        #expect(store.load()?.host == "new")
    }
}
