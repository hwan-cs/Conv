import Foundation
import Observation

/// Files handed to the main window from elsewhere: the menu bar popover, a paste, Finder's menu.
@MainActor
@Observable
public final class ConversionInbox {
    public static let shared = ConversionInbox()

    public struct Delivery: Equatable, Sendable {
        public let urls: [URL]
        public let isPasted: Bool
        public let format: String?
        public let needsFolderAccess: Bool
        let id = UUID()
    }

    /// The latest delivery, until the window takes it.
    public private(set) var delivery: Delivery?

    public init() {}

    public func send(
        _ urls: [URL],
        isPasted: Bool = false,
        format: String? = nil,
        needsFolderAccess: Bool = false
    ) {
        guard !urls.isEmpty else {
            return
        }
        delivery = Delivery(
            urls: urls,
            isPasted: isPasted,
            format: format,
            needsFolderAccess: needsFolderAccess
        )
    }

    public func take() -> Delivery? {
        defer {
            delivery = nil
        }
        return delivery
    }
}
