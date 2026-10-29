import AppKit

/// Brings up the main window from AppKit code such as the menu bar item, which can't use
/// SwiftUI's `openWindow`. The app registers the action once its window has appeared.
@MainActor
public enum MainWindow {
    private static var openAction: (() -> Void)?

    public static func register(_ open: @escaping () -> Void) {
        openAction = open
    }

    public static func show() {
        openAction?()
        NSApp.activate()
    }
}
