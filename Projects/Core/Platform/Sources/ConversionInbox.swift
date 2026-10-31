import Foundation
import Observation

/// Files handed to the main window from elsewhere: the menu bar popover, a paste, Finder's menu.
/// The window takes them as if they had been dropped on it.
@MainActor
@Observable
public final class ConversionInbox {
    public static let shared = ConversionInbox()

    public struct Delivery: Equatable, Sendable {
        public let urls: [URL]
        /// Made from the clipboard into the app's own folder; the results need a place chosen.
        public let isPasted: Bool
        /// A format already picked elsewhere (Finder's menu), to show selected.
        public let format: String?
        /// From Finder, outside every folder the user allowed: the window explains how to allow it.
        public let needsFolderAccess: Bool
        let id = UUID()
    }

    /// The latest delivery, until the window takes it.
    public private(set) var delivery: Delivery?

    public init() {}

    public func send(_ urls: [URL], isPasted: Bool = false, format: String? = nil, needsFolderAccess: Bool = false) {
        guard !urls.isEmpty else { return }
        delivery = Delivery(urls: urls, isPasted: isPasted, format: format, needsFolderAccess: needsFolderAccess)
    }

    public func take() -> Delivery? {
        defer { delivery = nil }
        return delivery
    }
}
