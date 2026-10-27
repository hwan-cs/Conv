import Platform
import SwiftUI

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        Form {
            LabeledContent("버전", value: AppInfo.version)
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
