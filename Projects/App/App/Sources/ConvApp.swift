import AppKit
import ConversionKit
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    /// Finder requests already taken: the extension may post one more than once.
    private var handled: Set<UUID> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(finderRequested(_:)), name: FinderRequest.notification, object: nil
        )
    }

    /// Finder's "conv.로 바꾸기": paths and the format picked. They can be read only inside folders
    /// the user allowed in Settings; otherwise the window says how to allow them.
    @objc private func finderRequested(_ notification: Notification) {
        guard let message = notification.object as? String, let request = FinderRequest(encoded: message) else { return }
        guard handled.insert(request.id).inserted else { return }
        let files = request.paths.map { URL(filePath: $0) }
        let allowed = FolderAccess.shared.covers(files)
        // A format picked, in an allowed folder: converted beside the files without a window.
        if allowed, let format = request.format {
            QuietConversions.shared.convert(files, to: format)
            return
        }
        ConversionInbox.shared.send(files, format: request.format, needsFolderAccess: !allowed)
        MainWindow.show()
    }

    /// The menu bar item stays, so closing the window doesn't quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Files opened with Conv: "다음으로 열기", dropping on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        ConversionInbox.shared.send(files)
        MainWindow.show()
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
        Color.clear
            .onAppear {
                let open = openWindow
                MainWindow.register { open(id: "main") }
            }
            .background(QuietLaunchCloser())
    }
}

/// Finder's menu launched Conv only to convert in the background: the window SwiftUI opens at
/// launch is closed before it is shown. It opens again from the menu bar or the Dock.
private struct QuietLaunchCloser: NSViewRepresentable {
    @MainActor static var pending = CommandLine.arguments.contains(FinderRequest.quietLaunchArgument)

    func makeNSView(context: Context) -> NSView { WindowWatcher() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowWatcher: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, QuietLaunchCloser.pending else { return }
            QuietLaunchCloser.pending = false
            // SwiftUI orders the window front after this; close it once it has.
            window.alphaValue = 0
            DispatchQueue.main.async {
                window.close()
                window.alphaValue = 1
            }
        }
    }
}
