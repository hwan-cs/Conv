import DesignSystem
import DropFeature
import MenuBarFeature
import SettingsFeature
import SwiftUI

@main
struct ConvApp: App {
    init() {
        ConvFont.register()
        #if DEBUG
        if XPCSpike.isRequested {
            DispatchQueue.main.async { XPCSpike.run() }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            DropView()
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Conv", systemImage: "arrow.down.to.line") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
