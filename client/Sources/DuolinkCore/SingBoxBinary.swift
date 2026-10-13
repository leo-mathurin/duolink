import Foundation

public enum SingBoxBinary {
    static let candidates = [
        "/opt/homebrew/bin/sing-box",
        "/usr/local/bin/sing-box",
    ]

    /// Finds the Homebrew install. A menu bar app does not inherit the shell PATH.
    public static func locate(fileManager: FileManager = .default) -> URL? {
        candidates.first(where: fileManager.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }
}
