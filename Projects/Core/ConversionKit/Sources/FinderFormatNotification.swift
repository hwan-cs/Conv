import Foundation

/// What Finder's menu asks the app: convert these files, with this format picked if any.
public struct FinderRequest: Codable, Sendable, Equatable {
    public static let notification = Notification.Name("com.hwancs.Conv.finderRequest")
    /// Passed when the extension launches the app just to convert, so no window opens.
    public static let quietLaunchArgument = "--finder-quiet-launch"

    public var id = UUID()
    public var paths: [String]
    public var format: String?

    public init(paths: [String], format: String?) {
        self.paths = paths
        self.format = format
    }

    public var encoded: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public init?(encoded: String) {
        guard let request = try? JSONDecoder().decode(Self.self, from: Data(encoded.utf8)) else {
            return nil
        }
        self = request
    }
}
