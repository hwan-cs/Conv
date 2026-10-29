import AppKit
import DesignSystem
import DropFeature
import MenuBarFeature
import Platform
import SettingsFeature
import SwiftUI

@main
struct ConvApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        ConvFont.register()
        #if DEBUG
        if XPCSpike.isRequested {
            DispatchQueue.main.async { XPCSpike.run() }
        }
        if XPCSpike.isConvertRequested {
            DispatchQueue.main.async { XPCSpike.runConvert() }
        }
        #endif
    }

    var body: some Scene {
        // One main window: the menu bar opens this same one rather than another.
        Window("Conv", id: "main") {
            DropView()
                .background(MainWindowRegistrar())
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()
    }

    /// The menu bar item stays, so closing the window doesn't quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.show() }
        return true
    }
}

/// Hands SwiftUI's `openWindow` to AppKit code, once the main window exists.
private struct MainWindowRegistrar: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear {
            let open = openWindow
            MainWindow.register { open(id: "main") }
        }
    }
}
