import Foundation
import Observation

/// Files handed to the main window from elsewhere: the menu bar popover, a paste. The window
/// takes them as if they had been dropped on it.
@MainActor
@Observable
public final class ConversionInbox {
    public static let shared = ConversionInbox()

    public struct Delivery: Equatable, Sendable {
        public let urls: [URL]
        /// Made from the clipboard into the app's own folder; the results need a place chosen.
        public let isPasted: Bool
        let id = UUID()
    }

    /// The latest delivery, until the window takes it.
    public private(set) var delivery: Delivery?

    public func send(_ urls: [URL], isPasted: Bool = false) {
        guard !urls.isEmpty else { return }
        delivery = Delivery(urls: urls, isPasted: isPasted)
    }

    public func take() -> Delivery? {
        defer { delivery = nil }
        return delivery
    }
}
